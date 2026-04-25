#!/bin/bash
# stack: local-first stacked-PR tooling.
#
# Subcommands:
#   status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]
#   sync   [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
#   squash [--dry-run] [-m SUBJECT] [--branch BRANCH] [--onto REF|--onto-pr-base] [--pr N] [--base REF] [--prefix PREFIX]
#   push   [--dry-run] [--base REF] [--prefix PREFIX] [--pr N] [--children]
#
# Data sources merged into one view:
#   1. git topology        (for-each-ref + merge-base)
#   2. gh pr list          (PRs for @me)
#   3. pg leases --json    (push-gate approval status)

set -euo pipefail

# ------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------

stack_fail() {
  echo "stack: $*" >&2
  exit 1
}

stack_warn() {
  echo "stack: $*" >&2
}

stack_debug_enabled() {
  case "${STACK_DEBUG:-}" in
    1|true|TRUE|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

stack_debug() {
  stack_debug_enabled || return 0
  echo "stack: debug: $*" >&2
}

stack_helper_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

stack_require() {
  command -v "$1" >/dev/null 2>&1 \
    || stack_fail "missing required tool: $1"
}

stack_require_branchless() {
  command -v git-branchless >/dev/null 2>&1 && return 0
  stack_fail "git-branchless not found on PATH.
  macOS:    brew install git-branchless
  Ubuntu:   ~/repos/dotfiles/locations/workspace/installers/14-install-git-branchless.sh
  Manual:   https://github.com/arxanas/git-branchless/releases"
}

stack_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null \
    || stack_fail "not inside a git repo"
}

stack_common_dir() {
  local common repo_root
  common=$(git rev-parse --git-common-dir)
  case "$common" in
    /*) printf '%s\n' "$common" ;;
    *)
      repo_root=$(stack_repo_root)
      printf '%s\n' "$repo_root/$common"
      ;;
  esac
}

stack_shell_quote() {
  local quoted
  printf -v quoted '%q' "$1"
  printf '%s' "$quoted"
}

stack_append_flag() {
  local cmd="$1" flag="$2" value="$3"
  [[ -z "$value" ]] && { printf '%s\n' "$cmd"; return 0; }
  printf '%s %s %s\n' "$cmd" "$flag" "$(stack_shell_quote "$value")"
}

stack_ref_name() {
  printf 'refs/heads/%s\n' "$1"
}

stack_lookup_tip() {
  local branch="$1" tips="$2"
  awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' <<<"$tips"
}

stack_count_nonempty_lines() {
  awk 'NF { n++ } END { print n + 0 }'
}

stack_fetch_base_remote() {
  local base="$1"
  if [[ "$base" != */* ]]; then
    echo "Base $base is local; fetch skipped."
    return 0
  fi

  local remote="${base%%/*}"
  if ! git remote get-url "$remote" >/dev/null 2>&1; then
    stack_warn "base remote '$remote' is not configured; fetch skipped"
    return 0
  fi

  echo "Fetching ${remote}..."
  git fetch "$remote" 2>&1 | sed 's/^/  /'
}

stack_branch_tips_from_parent_map() {
  local parent_map="$1"
  awk -F'\t' '{print $1}' <<<"$parent_map" | while read -r b; do
    [[ -z "$b" ]] && continue
    printf '%s\t%s\n' "$b" "$(git rev-parse --verify "$b" 2>/dev/null || echo '')"
  done
}

stack_descendants_ordered() {
  local root="$1" ordered="$2"
  awk -F'\t' -v root="$root" '
    { name[NR]=$2; parent[$2]=$3; line[$2]=$0 }
    END {
      for (i=1; i<=NR; i++) {
        n=name[i]
        p=parent[n]
        while (p != "") {
          if (p == root) {
            print line[n]
            break
          }
          p=parent[p]
        }
      }
    }
  ' <<<"$ordered"
}

# Detect the base ref to compare feature branches against.
# Mirrors push-gate.sh:pg_default_base_ref_snapshot so we stay self-contained.
stack_upstream_ref() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    if git show-ref --verify --quiet "refs/remotes/$override" \
       || git rev-parse --verify --quiet "$override" >/dev/null; then
      printf '%s\n' "$override"
      return 0
    fi
    stack_fail "base ref not found: $override"
  fi
  local remote
  for remote in upstream origin; do
    if git show-ref --verify --quiet "refs/remotes/$remote/main"; then
      printf '%s\n' "$remote/main"
      return 0
    fi
    if git show-ref --verify --quiet "refs/remotes/$remote/master"; then
      printf '%s\n' "$remote/master"
      return 0
    fi
  done
  stack_fail "could not detect base ref (no upstream/main or origin/main). Use --base."
}

# Branch prefix (default mho/), overridable via --prefix or git config stack.prefix.
stack_prefix() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  local cfg
  cfg=$(git config --get stack.prefix 2>/dev/null || true)
  printf '%s\n' "${cfg:-mho/}"
}

# Enumerate candidate feature branches (one per line: "name\tsha").
stack_enumerate_branches() {
  local prefix="$1"
  git for-each-ref --format='%(refname:short)	%(objectname)' refs/heads 2>/dev/null \
    | awk -F'\t' -v prefix="$prefix" 'index($1, prefix) == 1'
}

# Build parent map. Input: prefix, base_ref. Output lines: "child\tparent\tahead\tbehind".
# parent is either another mho/* branch (nearest ancestor) or the base ref.
stack_build_parent_map() {
  local prefix="$1" base="$2"
  local -a names shas
  local name sha
  while IFS=$'\t' read -r name sha; do
    [[ -n "$name" ]] || continue
    names+=("$name")
    shas+=("$sha")
  done < <(stack_enumerate_branches "$prefix")

  local i j best_parent best_depth depth ahead behind
  for ((i=0; i<${#names[@]}; i++)); do
    name="${names[$i]}"
    sha="${shas[$i]}"
    best_parent=""
    best_depth=-1
    for ((j=0; j<${#names[@]}; j++)); do
      [[ "$i" == "$j" ]] && continue
      # Candidate parent X: X's tip is ancestor of current tip.
      if git merge-base --is-ancestor "${shas[$j]}" "$sha" 2>/dev/null; then
        # Depth of X: commits from base to X.
        depth=$(git rev-list --count "$base..${shas[$j]}" 2>/dev/null || echo 0)
        if (( depth > best_depth )); then
          best_depth=$depth
          best_parent="${names[$j]}"
        fi
      fi
    done
    if [[ -z "$best_parent" ]]; then
      best_parent="$base"
    fi
    ahead=$(git rev-list --count "$base..$sha" 2>/dev/null || echo 0)
    behind=$(git rev-list --count "$sha..$base" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\n' "$name" "$best_parent" "$ahead" "$behind"
  done
}

# Fetch PR data for @me, emit one JSON object per branch keyed by headRefName.
stack_fetch_prs() {
  command -v gh >/dev/null 2>&1 || { echo '{}'; return 0; }
  local raw
  raw=$(gh pr list --author @me --state open \
          --json number,title,headRefName,baseRefName,mergeable,reviewDecision,statusCheckRollup,url \
          2>/dev/null || echo '[]')
  [[ -z "$raw" ]] && raw='[]'
  jq 'map({(.headRefName): .}) | add // {}' <<<"$raw"
}

# Fetch push-gate leases for this repo or its main worktree; index by branch_name.
# Silent-fail: if push-gate.sh missing or errors, emit {}.
stack_fetch_leases() {
  local helper repo_root main_repo_root common_dir
  helper="$(stack_helper_dir)/push-gate.sh"
  repo_root=$(stack_repo_root)
  common_dir=$(stack_common_dir)
  main_repo_root=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd || printf '%s\n' "$repo_root")
  [[ -f "$helper" ]] || { echo '{}'; return 0; }
  local raw
  raw=$(bash "$helper" leases --all --json 2>/dev/null || echo '[]')
  [[ -z "$raw" ]] && raw='[]'
  if stack_debug_enabled; then
    local total matched
    total=$(jq 'length' <<<"$raw" 2>/dev/null || echo "?")
    matched=$(jq --arg rr "$repo_root" --arg mr "$main_repo_root" \
      '[.[] | select(.repo_root == $rr or .repo_root == $mr)] | length' \
      <<<"$raw" 2>/dev/null || echo "?")
    stack_debug "lease lookup repo_root=$repo_root main_repo_root=$main_repo_root total=$total matched=$matched"
  fi
  jq --arg rr "$repo_root" --arg mr "$main_repo_root" \
    '[.[] | select(.repo_root == $rr or .repo_root == $mr)] | map({(.branch_name): .}) | add // {}' \
    <<<"$raw"
}

# Summarize CI rollup: PASS / FAIL / PENDING / "—".
stack_ci_summary() {
  local rollup="$1"
  [[ -z "$rollup" || "$rollup" == "null" || "$rollup" == "[]" ]] && { echo "—"; return 0; }
  jq -r '
    if length == 0 then "—"
    else
      ([.[] | (.conclusion // .status // "")] | unique) as $states |
      if any($states[]; . == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ACTION_REQUIRED") then "FAIL"
      elif any($states[]; . == "IN_PROGRESS" or . == "QUEUED" or . == "PENDING" or . == "WAITING" or . == "") then "PENDING"
      else "PASS" end
    end
  ' <<<"$rollup"
}

# Summarize lease state for one branch.
# Input: lease JSON (or null) + current tip sha.
# Output: "—" | "allowed" | "stale-tip" | "revoked" | "<status>"
stack_lease_summary() {
  local lease="$1" head_sha="$2"
  [[ -z "$lease" || "$lease" == "null" ]] && { echo "—"; return 0; }
  local status anchor
  status=$(jq -r '.status // "unknown"' <<<"$lease")
  anchor=$(jq -r '.approved_anchor // ""' <<<"$lease")
  case "$status" in
    active)
      if [[ -n "$anchor" && "$anchor" != "$head_sha" ]]; then
        echo "stale-tip"
      else
        echo "allowed"
      fi
      ;;
    revoked) echo "revoked" ;;
    *)       echo "$status" ;;
  esac
}

# ------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------

# Order branches topologically and compute depth. Stdin: parent-map lines.
# Stdout: "depth\tname\tparent\tahead\tbehind" lines, in render order.
stack_order_tree() {
  local base="$1"
  awk -F'\t' -v base="$base" '
    { parent[$1]=$2; ahead[$1]=$3; behind[$1]=$4; names[NR]=$1; exists[$1]=1 }
    END {
      # Build children map.
      for (i=1; i<=NR; i++) {
        n=names[i]; p=parent[n]
        kids[p]=kids[p] " " n
      }
      # DFS starting from each root. In scoped PR views, a branch parent
      # may be outside the selected subset; treat that branch as a display root
      # while preserving the real parent column.
      for (i=1; i<=NR; i++) {
        n=names[i]
        if (parent[n] == base || !(parent[n] in exists)) walk(n, 0)
      }
    }
    function walk(n, d,   split_out, j, k) {
      printf "%d\t%s\t%s\t%s\t%s\n", d, n, parent[n], ahead[n], behind[n]
      k=split(kids[n], split_out, " ")
      for (j=1; j<=k; j++) if (split_out[j] != "") walk(split_out[j], d+1)
    }
  '
}

# Render human table from ordered tree + PR + lease JSON.
stack_render_table() {
  local base="$1" prefix="$2" parent_map="$3" prs="$4" leases="$5"

  local ordered
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  if [[ -z "$ordered" ]]; then
    echo "No stacked branches found under $prefix (base $base)."
    return 0
  fi

  printf 'Base: %s    Prefix: %s\n\n' "$base" "$prefix"
  printf '%-42s %-5s %-6s %-22s %-11s %-8s %s\n' \
    "Branch" "+/-" "PR" "Base" "Mergeable" "CI" "pg lease"
  printf '%-42s %-5s %-6s %-22s %-11s %-8s %s\n' \
    "------" "---" "--" "----" "---------" "--" "--------"

  local depth name parent ahead behind
  local indent head_sha pr pr_num pr_base mergeable ci rollup lease lease_state
  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    indent=""
    if (( depth > 0 )); then
      indent="$(printf '%*s' $((depth*2)) '')└ "
    fi
    head_sha=$(git rev-parse "$name" 2>/dev/null || echo "")

    pr=$(jq -c --arg k "$name" '.[$k] // null' <<<"$prs")
    if [[ "$pr" == "null" ]]; then
      pr_num="—"; pr_base="—"; mergeable="—"; ci="—"
    else
      pr_num="#$(jq -r '.number' <<<"$pr")"
      pr_base=$(jq -r '.baseRefName // "—"' <<<"$pr")
      mergeable=$(jq -r '.mergeable // "—"' <<<"$pr")
      rollup=$(jq -c '.statusCheckRollup // []' <<<"$pr")
      ci=$(stack_ci_summary "$rollup")
    fi

    lease=$(jq -c --arg k "$name" '.[$k] // null' <<<"$leases")
    lease_state=$(stack_lease_summary "$lease" "$head_sha")

    printf '%-42s %-5s %-6s %-22s %-11s %-8s %s\n' \
      "${indent}${name}" \
      "${ahead}/${behind}" \
      "$pr_num" \
      "$pr_base" \
      "$mergeable" \
      "$ci" \
      "$lease_state"
  done <<<"$ordered"
}

# Render JSON from parent-map + PR + lease sources.
stack_render_json() {
  local base="$1" prefix="$2" parent_map="$3" prs="$4" leases="$5"
  local ordered
  ordered=$(echo "$parent_map" | stack_order_tree "$base")

  local roots_json='[]'
  local current_root='' current_branches='[]'
  local depth name parent ahead behind head_sha pr lease lease_state ci rollup

  flush_root() {
    if [[ -n "$current_root" ]]; then
      roots_json=$(jq --arg root "$current_root" --argjson br "$current_branches" \
        '. + [{root: $root, branches: $br}]' <<<"$roots_json")
    fi
    current_root=""
    current_branches='[]'
  }

  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    if (( depth == 0 )); then
      flush_root
      current_root="$name"
    fi
    head_sha=$(git rev-parse "$name" 2>/dev/null || echo "")
    pr=$(jq -c --arg k "$name" '.[$k] // null' <<<"$prs")
    lease=$(jq -c --arg k "$name" '.[$k] // null' <<<"$leases")
    lease_state=$(stack_lease_summary "$lease" "$head_sha")
    rollup='[]'
    [[ "$pr" != "null" ]] && rollup=$(jq -c '.statusCheckRollup // []' <<<"$pr")
    ci=$(stack_ci_summary "$rollup")

    current_branches=$(jq \
      --arg name "$name" \
      --arg parent "$parent" \
      --argjson depth "$depth" \
      --argjson ahead "$ahead" \
      --argjson behind "$behind" \
      --arg head "$head_sha" \
      --argjson pr "$pr" \
      --argjson lease "$lease" \
      --arg lease_state "$lease_state" \
      --arg ci "$ci" \
      '. + [{
        name: $name, parent: $parent, depth: $depth,
        ahead: $ahead, behind: $behind, head: $head,
        pr: $pr, lease: $lease, lease_state: $lease_state, ci: $ci
      }]' <<<"$current_branches")
  done <<<"$ordered"
  flush_root

  jq -n --arg base "$base" --arg prefix "$prefix" --argjson stacks "$roots_json" \
    '{base: $base, prefix: $prefix, stacks: $stacks}'
}

stack_pr_base_from_parent() {
  local parent="$1"
  case "$parent" in
    refs/heads/*) printf '%s\n' "${parent#refs/heads/}" ;;
    refs/remotes/*/*) printf '%s\n' "${parent#refs/remotes/*/}" ;;
    */*)
      if git show-ref --verify --quiet "refs/remotes/$parent"; then
        printf '%s\n' "${parent#*/}"
      else
        printf '%s\n' "$parent"
      fi
      ;;
    *) printf '%s\n' "$parent" ;;
  esac
}

stack_short_base_name() {
  local base="$1"
  printf '%s\n' "${base#*/}"
}

stack_local_ref_exists() {
  local ref="$1"
  git show-ref --verify --quiet "refs/heads/$ref"
}

stack_resolve_pr_parent() {
  local pr_base="$1" base="$2"
  local short_base
  short_base=$(stack_short_base_name "$base")
  if [[ "$pr_base" == "$short_base" || "$pr_base" == "$base" ]]; then
    printf '%s\n' "$base"
  elif stack_local_ref_exists "$pr_base"; then
    printf '%s\n' "$pr_base"
  else
    printf '%s\n' "$base"
  fi
}

stack_resolve_pr_base_ref() {
  local pr_base="$1" base="$2"
  local short_base remote
  short_base=$(stack_short_base_name "$base")
  if [[ "$pr_base" == "$short_base" || "$pr_base" == "$base" ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  if git show-ref --verify --quiet "refs/heads/$pr_base"; then
    printf '%s\n' "$pr_base"
    return 0
  fi
  for remote in upstream origin; do
    if git show-ref --verify --quiet "refs/remotes/$remote/$pr_base"; then
      printf '%s/%s\n' "$remote" "$pr_base"
      return 0
    fi
  done
  printf '%s\n' "$pr_base"
}

stack_pr_branch_by_number() {
  local prs="$1" pr_number="$2"
  jq -r --argjson n "$pr_number" '
    to_entries[] | select((.value.number // null) == $n) | .key
  ' <<<"$prs" | head -1
}

stack_pr_json_by_branch() {
  local prs="$1" branch="$2"
  jq -c --arg k "$branch" '.[$k] // null' <<<"$prs"
}

stack_resolve_parent_map_from_prs() {
  local local_parent_map="$1" prs="$2" base="$3"
  local branch local_parent ahead behind pr pr_base parent
  while IFS=$'\t' read -r branch local_parent ahead behind; do
    [[ -z "$branch" ]] && continue
    pr=$(stack_pr_json_by_branch "$prs" "$branch")
    if [[ "$pr" != "null" ]]; then
      pr_base=$(jq -r '.baseRefName // ""' <<<"$pr")
      parent=$(stack_resolve_pr_parent "$pr_base" "$base")
    else
      parent="$local_parent"
    fi
    printf '%s\t%s\t%s\t%s\n' "$branch" "$parent" "$ahead" "$behind"
  done <<<"$local_parent_map"
}

stack_filter_parent_map_for_pr() {
  local parent_map="$1" prs="$2" pr_number="$3" include_children="$4"
  local root
  root=$(stack_pr_branch_by_number "$prs" "$pr_number")
  [[ -n "$root" ]] || stack_fail "open PR not found in stack data: #$pr_number"

  if [[ "$include_children" != "true" ]]; then
    awk -F'\t' -v root="$root" '$1 == root' <<<"$parent_map"
    return 0
  fi

  awk -F'\t' -v root="$root" '
    { line[$1]=$0; parent[$1]=$2; names[NR]=$1 }
    END {
      if (root in line) print line[root]
      changed=1
      while (changed) {
        changed=0
        for (i=1; i<=NR; i++) {
          n=names[i]
          if (printed[n]) continue
          p=parent[n]
          if (p == root || printed[p]) {
            print line[n]
            printed[n]=1
            changed=1
          }
        }
      }
    }
  ' <<<"$parent_map"
}

stack_warn_topology_mismatches() {
  local scoped_map="$1" local_parent_map="$2" prs="$3" base="$4"
  local branch parent ahead behind pr pr_num pr_base pr_parent local_parent
  while IFS=$'\t' read -r branch parent ahead behind; do
    [[ -z "$branch" ]] && continue
    pr=$(stack_pr_json_by_branch "$prs" "$branch")
    [[ "$pr" == "null" ]] && continue
    pr_num=$(jq -r '.number // ""' <<<"$pr")
    pr_base=$(jq -r '.baseRefName // ""' <<<"$pr")
    pr_parent=$(stack_resolve_pr_parent "$pr_base" "$base")
    local_parent=$(awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' <<<"$local_parent_map")
    [[ -z "$local_parent" || "$local_parent" == "$pr_parent" ]] && continue
    stack_warn "Topology mismatch: PR #$pr_num base is $pr_base, but local nearest parent is $local_parent. Using PR base $pr_parent."
  done <<<"$scoped_map"
}

stack_push_rerun_command() {
  local base_override="$1" prefix_override="$2" pr_filter="${3:-}" include_children="${4:-false}"
  local cmd="stack push"
  cmd=$(stack_append_flag "$cmd" "--base" "$base_override")
  cmd=$(stack_append_flag "$cmd" "--prefix" "$prefix_override")
  cmd=$(stack_append_flag "$cmd" "--pr" "$pr_filter")
  [[ "$include_children" == "true" ]] && cmd="$cmd --children"
  printf '%s\n' "$cmd"
}

stack_push_remote_ref() {
  local branch="$1"
  local remote_ref
  remote_ref=$(git rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" 2>/dev/null || echo "")
  if [[ -n "$remote_ref" ]]; then
    printf '%s\n' "$remote_ref"
    return 0
  fi

  local remote
  for remote in origin upstream; do
    if git show-ref --verify --quiet "refs/remotes/${remote}/${branch}"; then
      printf '%s/%s\n' "$remote" "$branch"
      return 0
    fi
  done
}

stack_push_assert_flow() {
  local branch="$1" pr_num="$2" rewrite_note="$3" create_base="${4:-}"
  if [[ -n "$pr_num" ]]; then
    printf 'update pr #%s\nbranch %s\n%s\nforce-with-lease' "$pr_num" "$branch" "$rewrite_note"
  else
    printf 'create stacked pr\nbranch %s\nbase %s\n%s\nforce-with-lease' "$branch" "$create_base" "$rewrite_note"
  fi
}

stack_push_print_agent_handoff() {
  local ordered="$1" prs="$2" rerun_cmd="$3"
  local depth name parent ahead behind
  local pr pr_num pr_base pr_title pr_url create_base subject
  local existing='[]' missing='[]'

  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    pr=$(jq -c --arg k "$name" '.[$k] // null' <<<"$prs")
    if [[ "$pr" == "null" ]]; then
      create_base=$(stack_pr_base_from_parent "$parent")
      subject=$(git log -1 --format='%s' "$name" 2>/dev/null || echo "$name")
      missing=$(jq \
        --arg branch "$name" \
        --arg base "$create_base" \
        --arg subject "$subject" \
        '. + [{branch: $branch, base: $base, subject: $subject}]' <<<"$missing")
      continue
    fi

    pr_num=$(jq -r '.number' <<<"$pr")
    pr_base=$(jq -r '.baseRefName // ""' <<<"$pr")
    pr_title=$(jq -r '.title // ""' <<<"$pr")
    pr_url=$(jq -r '.url // ""' <<<"$pr")
    existing=$(jq \
      --arg branch "$name" \
      --arg number "$pr_num" \
      --arg base "$pr_base" \
      --arg title "$pr_title" \
      --arg url "$pr_url" \
      '. + [{branch: $branch, number: $number, base: $base, title: $title, url: $url}]' <<<"$existing")
  done <<<"$ordered"

  local existing_count missing_count
  existing_count=$(jq 'length' <<<"$existing")
  missing_count=$(jq 'length' <<<"$missing")
  (( existing_count > 0 || missing_count > 0 )) || return 0

  echo
  echo "Agent handoff:"
  echo "  Re-run this stack: $rerun_cmd"

  if (( existing_count > 0 )); then
    echo "  Existing PRs to update/describe:"
    jq -r '.[] | "  - #\(.number) \(.branch) (base \(.base)): \(.title)\n    update description: /update-pr-description \(.number)"' <<<"$existing"
  fi

  if (( missing_count > 0 )); then
    echo "  Branches without PRs:"
    jq -r '.[] | "  - \(.branch) -> base \(.base)\n    create draft PR via /commit-push-pr after push-gate approval\n    suggested title: \(.subject)"' <<<"$missing"
  fi
}

# ------------------------------------------------------------------------
# Subcommands
# ------------------------------------------------------------------------

stack_cmd_status() {
  local format="table"
  local base_override="" prefix_override="" pr_filter="" include_children="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)   format="json"; shift ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      --pr)     pr_filter="${2:-}"; [[ "$pr_filter" =~ ^[0-9]+$ ]] || stack_fail "--pr requires a PR number"; shift 2 ;;
      --children) include_children="true"; shift ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown status flag: $1" ;;
    esac
  done
  stack_require jq
  stack_repo_root >/dev/null

  local base prefix local_parent_map parent_map prs leases
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  stack_debug "status base=$base prefix=$prefix branches=$(stack_count_nonempty_lines <<<"$local_parent_map") pr=${pr_filter:-none} children=$include_children"
  prs=$(stack_fetch_prs)
  parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
  if [[ -n "$pr_filter" ]]; then
    parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$pr_filter" "$include_children")
  fi
  stack_warn_topology_mismatches "$parent_map" "$local_parent_map" "$prs" "$base"
  leases=$(stack_fetch_leases)

  if [[ "$format" == "json" ]]; then
    stack_render_json "$base" "$prefix" "$parent_map" "$prs" "$leases"
  else
    stack_render_table "$base" "$prefix" "$parent_map" "$prs" "$leases"
  fi
}

stack_cmd_sync() {
  local dry_run="false" keep_scratch="false"
  local base_override="" prefix_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      --keep-scratch) keep_scratch="true"; shift ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown sync flag: $1" ;;
    esac
  done
  stack_require jq
  stack_require_branchless
  stack_repo_root >/dev/null

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. git stash or commit first."

  local base prefix parent_map prs leases
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  parent_map=$(stack_build_parent_map "$prefix" "$base")
  stack_debug "sync base=$base prefix=$prefix branches=$(stack_count_nonempty_lines <<<"$parent_map") dry_run=$dry_run keep_scratch=$keep_scratch"
  prs=$(stack_fetch_prs)
  leases=$(stack_fetch_leases)

  echo "=== Before ==="
  stack_render_table "$base" "$prefix" "$parent_map" "$prs" "$leases"
  echo

  # Record pre-sync tips for diff surface.
  # `--verify` suppresses the misleading "echo input on failure" of plain rev-parse.
  local pre_tips
  pre_tips=$(stack_branch_tips_from_parent_map "$parent_map")
  stack_debug "pre-sync tips captured=$(stack_count_nonempty_lines <<<"$pre_tips")"

  # Always fetch upstream.
  stack_fetch_base_remote "$base"

  if [[ "$dry_run" == "true" ]]; then
    echo "(dry-run) Would create a scratch clone and preflight stack sync"
    echo "(dry-run) Would run PR-state adoption in scratch"
    echo "(dry-run) Would invoke: git-branchless sync --pull"
    return 0
  fi

  local repo_root current_branch scratch_root scratch_repo script_path
  repo_root=$(stack_repo_root)
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/stack-sync.XXXXXX")
  scratch_repo="$scratch_root/repo"
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  STACK_SYNC_CLEANUP_ROOT="$scratch_root"
  STACK_SYNC_KEEP_SCRATCH="$keep_scratch"
  trap 'if [[ "${STACK_SYNC_KEEP_SCRATCH:-}" != "true" && -n "${STACK_SYNC_CLEANUP_ROOT:-}" ]]; then rm -rf "$STACK_SYNC_CLEANUP_ROOT"; fi' EXIT

  echo "Creating scratch clone: $scratch_repo"
  stack_sync_create_scratch "$repo_root" "$scratch_repo" "$current_branch" "$parent_map"

  local preflight_log="$scratch_root/preflight.log"
  stack_debug "scratch_root=$scratch_root scratch_repo=$scratch_repo preflight_log=$preflight_log"
  echo "Preflighting sync in scratch..."
  set +e
  (
    cd "$scratch_repo"
    stack_sync_run_preflight "$base" "$prefix"
  ) >"$preflight_log" 2>&1
  local preflight_rc=$?
  set -e
  sed 's/^/  /' "$preflight_log"

  if (( preflight_rc != 0 )); then
    stack_sync_report_failure "$scratch_repo" "$preflight_rc" "$keep_scratch" "$script_path" "$base" "$prefix"
    return 1
  fi

  local scratch_tips moved_tips
  scratch_tips=$(awk -F'\t' '{print $1}' <<<"$pre_tips" | while read -r b; do
    [[ -z "$b" ]] && continue
    printf '%s\t%s\n' "$b" "$(git -C "$scratch_repo" rev-parse --verify "$b" 2>/dev/null || echo '')"
  done)
  moved_tips=$(stack_sync_moved_tips "$pre_tips" "$scratch_tips")
  stack_debug "scratch moved tips=$(stack_count_nonempty_lines <<<"$moved_tips")"

  if [[ -n "$moved_tips" ]]; then
    stack_sync_apply_refs "$scratch_repo" "$moved_tips"
  fi

  # Post-sync snapshot.
  parent_map=$(stack_build_parent_map "$prefix" "$base")
  prs=$(stack_fetch_prs)
  leases=$(stack_fetch_leases)
  echo
  echo "=== After ==="
  stack_render_table "$base" "$prefix" "$parent_map" "$prs" "$leases"

  # Flag branches whose tip moved — their leases will need re-approval.
  echo
  local moved=0
  while IFS=$'\t' read -r b old_sha new_sha; do
    [[ -z "$b" ]] && continue
    if [[ -z "$new_sha" && -n "$old_sha" ]]; then
      echo "  branch removed: $b (was $old_sha)"
      moved=$((moved + 1))
      continue
    fi
    if [[ -n "$old_sha" && -n "$new_sha" && "$old_sha" != "$new_sha" ]]; then
      moved=$((moved + 1))
      local lease
      lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
      if [[ "$lease" != "null" ]]; then
        stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
      else
        echo "  tip moved: $b ($old_sha -> $new_sha)"
      fi
    fi
  done <<<"$moved_tips"
  if (( moved == 0 )); then
    echo "No branches moved."
  fi

  if [[ "$keep_scratch" == "true" ]]; then
    stack_sync_print_debug "$scratch_repo" "$script_path" "$base" "$prefix"
  fi
}

stack_sync_create_scratch() {
  local repo_root="$1" scratch_repo="$2" current_branch="$3" parent_map="$4"
  stack_debug "initializing scratch clone from repo_root=$repo_root"
  git -c init.defaultBranch=main init "$scratch_repo" >/dev/null
  git -C "$scratch_repo" symbolic-ref HEAD refs/heads/__stack_scratch_head

  local remote url remote_count=0
  while read -r remote; do
    [[ -z "$remote" ]] && continue
    url=$(git -C "$repo_root" remote get-url "$remote" 2>/dev/null || true)
    if [[ -n "$url" ]]; then
      git -C "$scratch_repo" remote add "$remote" "$url"
      remote_count=$((remote_count + 1))
    fi
  done < <(git -C "$repo_root" remote)

  git -C "$scratch_repo" remote add stack-source "$repo_root"
  stack_debug "scratch remotes copied=$remote_count plus stack-source"
  git -C "$scratch_repo" fetch --quiet stack-source \
    '+refs/heads/*:refs/heads/*' \
    '+refs/remotes/*:refs/remotes/*'

  local user_name user_email checkout_branch
  user_name=$(git -C "$repo_root" config --get user.name 2>/dev/null || echo "Stack Sync")
  user_email=$(git -C "$repo_root" config --get user.email 2>/dev/null || echo "stack-sync@example.invalid")
  git -C "$scratch_repo" config user.name "$user_name"
  git -C "$scratch_repo" config user.email "$user_email"

  checkout_branch="$current_branch"
  if [[ -z "$checkout_branch" || "$checkout_branch" == "HEAD" ]]; then
    checkout_branch=$(awk -F'\t' 'NF { print $1; exit }' <<<"$parent_map")
  fi
  if [[ -n "$checkout_branch" ]]; then
    stack_debug "scratch checkout=$checkout_branch"
    git -C "$scratch_repo" checkout -q "$checkout_branch"
  fi
}

stack_sync_run_preflight() {
  local base="$1" prefix="$2"
  stack_cmd_adopt_merged_inner "false" "$base" "$prefix"
  echo "Running: git-branchless sync --pull"
  git-branchless sync --pull
}

stack_sync_moved_tips() {
  local pre_tips="$1" scratch_tips="$2"
  while IFS=$'\t' read -r b old_sha; do
    [[ -z "$b" ]] && continue
    local new_sha
    new_sha=$(stack_lookup_tip "$b" "$scratch_tips")
    [[ "$old_sha" == "$new_sha" ]] && continue
    printf '%s\t%s\t%s\n' "$b" "$old_sha" "$new_sha"
  done <<<"$pre_tips"
}

stack_sync_apply_refs() {
  local scratch_repo="$1" moved_tips="$2"
  local import_ns="refs/stack-sync/$RANDOM-$$"
  local update_count
  update_count=$(awk -F'\t' 'NF && $3 != "" { n++ } END { print n + 0 }' <<<"$moved_tips")

  echo "Applying $update_count branch ref update(s) atomically..."
  stack_debug "import namespace=$import_ns"
  git fetch --quiet "$scratch_repo" "+refs/heads/*:${import_ns}/*"

  local update_input
  update_input=$(
    echo "start"
    while IFS=$'\t' read -r b old_sha new_sha; do
      [[ -z "$b" || -z "$new_sha" ]] && continue
      printf 'update %s %s %s\n' "$(stack_ref_name "$b")" "$new_sha" "$old_sha"
    done <<<"$moved_tips"
    echo "prepare"
    echo "commit"
  )

  if ! git update-ref --stdin >/dev/null <<<"$update_input"; then
    git for-each-ref --format='delete %(refname)' "$import_ns" | git update-ref --stdin >/dev/null || true
    stack_warn "planned ref updates:"
    awk -F'\t' 'NF && $3 != "" { printf "  %s %s -> %s\n", $1, $2, $3 }' <<<"$moved_tips" >&2
    stack_fail "real branch tips changed since scratch preflight; aborted without partial updates."
  fi

  git for-each-ref --format='delete %(refname)' "$import_ns" | git update-ref --stdin >/dev/null || true
}

stack_sync_print_debug() {
  local scratch_repo="$1" script_path="$2" base="$3" prefix="$4"
  echo
  echo "Scratch kept: $scratch_repo"
  printf 'Debug command: cd %s && bash %s __sync-preflight --base %s --prefix %s\n' \
    "$(stack_shell_quote "$scratch_repo")" \
    "$(stack_shell_quote "$script_path")" \
    "$(stack_shell_quote "$base")" \
    "$(stack_shell_quote "$prefix")"
}

stack_sync_report_failure() {
  local scratch_repo="$1" rc="$2" keep_scratch="$3" script_path="$4" base="$5" prefix="$6"
  local conflicts status_short
  conflicts=$(git -C "$scratch_repo" diff --name-only --diff-filter=U 2>/dev/null || true)
  status_short=$(git -C "$scratch_repo" status --short 2>/dev/null || true)

  if [[ -n "$conflicts" ]]; then
    stack_warn "scratch preflight conflict files:"
    sed 's/^/  /' <<<"$conflicts" >&2
  elif [[ -n "$status_short" ]]; then
    stack_warn "scratch preflight left changes:"
    sed 's/^/  /' <<<"$status_short" >&2
  fi

  if [[ "$keep_scratch" == "true" ]]; then
    stack_sync_print_debug "$scratch_repo" "$script_path" "$base" "$prefix"
  else
    stack_warn "rerun with --keep-scratch to preserve the scratch clone and preflight log."
  fi

  stack_fail "scratch sync preflight failed (exit $rc). Real branch refs were not changed."
}

# Rebase one branch (and its descendants) off old parent tip onto new parent.
# Recursive depth-first walk over children_blob (lines: "parent\tchild").
# Sets STACK_ADOPT_REBASES to the number of rebases performed in the subtree.
stack_adopt_rebase_descendant() {
  local cur="$1" target="$2" off="$3" dry_run="$4" children_blob="$5"
  local old_cur_tip
  old_cur_tip=$(git rev-parse --verify "$cur" 2>/dev/null || echo "")
  [[ -z "$old_cur_tip" ]] && return 0

  if [[ "$dry_run" == "true" ]]; then
    echo "  (dry-run) git rebase --onto ${target} ${off:0:8} ${cur}"
  else
    echo "  rebasing ${cur} onto ${target} (off ${off:0:8})"
    if ! git rebase --onto "$target" "$off" "$cur" >/dev/null 2>&1; then
      git rebase --abort >/dev/null 2>&1 || true
      stack_fail "rebase failed for ${cur}. Resolve manually:
  git rebase --onto ${target} ${off} ${cur}"
    fi
  fi
  local count=1

  # Recurse into grandchildren: each rebases onto new $cur tip, off $old_cur_tip.
  local gkids
  gkids=$(awk -F'\t' -v p="$cur" '$1==p {print $2}' <<<"$children_blob")
  local g sub
  for g in $gkids; do
    [[ -z "$g" ]] && continue
    stack_adopt_rebase_descendant "$g" "$cur" "$old_cur_tip" "$dry_run" "$children_blob"
    sub="${STACK_ADOPT_REBASES:-0}"
    count=$((count + sub))
  done
  STACK_ADOPT_REBASES=$count
}

# PR-state-driven cascade for the multi-commit-squash case that patch-id
# (git-branchless sync --pull) can't detect.
#
# Algorithm:
#   For each branch B with a MERGED PR:
#     new_base = pr.baseRefName     (often "main" after retarget)
#     old_tip  = pr.headRefOid      (B's tip at merge time)
#     For each local child C of B:
#       git rebase --onto <new_base_resolved> <old_tip> <C>
#
# Source of truth is GitHub via `gh pr view`. No patch-id guessing.
# Internal helper: callers (stack_cmd_sync) pass dry_run; gh availability
# is best-effort — warn and skip if missing.
stack_cmd_adopt_merged_inner() {
  local dry_run="${1:-false}"
  local base_override="${2:-}"
  local prefix_override="${3:-}"

  if ! command -v gh >/dev/null 2>&1; then
    stack_warn "gh not on PATH; skipping PR-state cascade"
    return 0
  fi

  local base prefix parent_map
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  parent_map=$(stack_build_parent_map "$prefix" "$base")
  local default_remote="${base%%/*}"

  # Build child map: parent -> "child1 child2 ...".
  local children_blob
  children_blob=$(awk -F'\t' '{print $2"\t"$1}' <<<"$parent_map" \
    | awk -F'\t' '{ kids[$1] = kids[$1] " " $2 } END { for (p in kids) print p"\t"kids[p] }')

  local saved_branch
  saved_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  local actions=0 skipped=0
  while IFS=$'\t' read -r b parent ahead behind; do
    [[ -z "$b" ]] && continue

    # Find the most recent PR for this branch.
    local pr_json pr_num pr_state pr_base pr_merge_oid
    pr_json=$(gh pr list --head "$b" --state all \
                --json number,state,baseRefName,headRefOid \
                --limit 5 2>/dev/null || echo '[]')
    pr_num=$(jq -r '[.[] | select(.state == "MERGED")] | .[0].number // ""' <<<"$pr_json")
    [[ -z "$pr_num" ]] && continue
    pr_state=$(jq -r --argjson n "$pr_num" '[.[] | select(.number == $n)] | .[0].state' <<<"$pr_json")
    [[ "$pr_state" != "MERGED" ]] && continue
    pr_base=$(jq -r --argjson n "$pr_num" '[.[] | select(.number == $n)] | .[0].baseRefName' <<<"$pr_json")
    pr_merge_oid=$(jq -r --argjson n "$pr_num" '[.[] | select(.number == $n)] | .[0].headRefOid' <<<"$pr_json")

    # Resolve the rebase target locally.
    local target_ref=""
    if git show-ref --verify --quiet "refs/remotes/${default_remote}/${pr_base}"; then
      target_ref="${default_remote}/${pr_base}"
    elif git show-ref --verify --quiet "refs/heads/${pr_base}"; then
      target_ref="${pr_base}"
    else
      stack_warn "adopt-merged: PR base ref '$pr_base' not present locally. Skip $b."
      skipped=$((skipped + 1))
      continue
    fi

    # Find local children of this merged branch.
    local kids
    kids=$(awk -F'\t' -v p="$b" '$1==p {print $2}' <<<"$children_blob")
    if [[ -z "$kids" ]]; then
      continue
    fi

    echo "Adopting #${pr_num}: ${b} merged into ${pr_base} at ${pr_merge_oid:0:8}"

    local child
    for child in $kids; do
      [[ -z "$child" ]] && continue
      stack_adopt_rebase_descendant "$child" "$target_ref" "$pr_merge_oid" \
        "$dry_run" "$children_blob"
      actions=$((actions + ${STACK_ADOPT_REBASES:-0}))
    done
  done <<<"$parent_map"

  # Restore caller's branch.
  if [[ -n "$saved_branch" && "$saved_branch" != "HEAD" ]]; then
    git checkout "$saved_branch" >/dev/null 2>&1 || true
  fi

  if (( actions == 0 )); then
    if (( skipped > 0 )); then
      echo "No merged parents adoptable. ($skipped skipped — see warnings.)"
    fi
    return 0
  fi
  echo "Adopted ${actions} child rebase(s)."
}

# stack squash — collapse the current branch's incremental commits into one
# commit relative to its stack parent, then restack local descendants.
stack_cmd_squash() {
  local dry_run="false" subject="" branch_override="" onto_override="" onto_pr_base="false" pr_filter=""
  local base_override="" prefix_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      -m) subject="${2:-}"; [[ -n "$subject" ]] || stack_fail "-m requires a subject"; shift 2 ;;
      --branch) branch_override="${2:-}"; [[ -n "$branch_override" ]] || stack_fail "--branch requires a branch"; shift 2 ;;
      --onto)   onto_override="${2:-}"; [[ -n "$onto_override" ]] || stack_fail "--onto requires a ref"; shift 2 ;;
      --onto-pr-base) onto_pr_base="true"; shift ;;
      --pr)     pr_filter="${2:-}"; [[ "$pr_filter" =~ ^[0-9]+$ ]] || stack_fail "--pr requires a PR number"; shift 2 ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown squash flag: $1" ;;
    esac
  done
  stack_require jq
  stack_repo_root >/dev/null

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. git stash or commit first."

  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -n "$pr_filter" ]]; then
    local prs_for_branch
    prs_for_branch=$(stack_fetch_prs)
    branch_override=$(stack_pr_branch_by_number "$prs_for_branch" "$pr_filter")
    [[ -n "$branch_override" ]] || stack_fail "open PR not found in stack data: #$pr_filter"
  fi
  if [[ -n "$branch_override" ]]; then
    current="$branch_override"
  fi
  [[ -n "$current" && "$current" != "HEAD" ]] || stack_fail "stack squash requires a checked-out branch or --branch/--pr"

  local base prefix local_parent_map parent_map ordered current_line parent commit_count prs
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  prs=$(stack_fetch_prs)
  parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
  stack_debug "squash base=$base prefix=$prefix current=$current branches=$(stack_count_nonempty_lines <<<"$parent_map") dry_run=$dry_run pr=${pr_filter:-none}"
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  current_line=$(awk -F'\t' -v b="$current" '$2 == b { print; exit }' <<<"$ordered")
  [[ -n "$current_line" ]] || stack_fail "$current is not under stack prefix $prefix"
  parent=$(awk -F'\t' '{print $3}' <<<"$current_line")
  if [[ "$onto_pr_base" == "true" ]]; then
    local pr pr_base
    pr=$(stack_pr_json_by_branch "$prs" "$current")
    [[ "$pr" != "null" ]] || stack_fail "--onto-pr-base requires $current to have an open PR"
    pr_base=$(jq -r '.baseRefName // ""' <<<"$pr")
    parent=$(stack_resolve_pr_base_ref "$pr_base" "$base")
  fi
  if [[ -n "$onto_override" ]]; then
    parent="$onto_override"
  fi
  git rev-parse --verify "$parent" >/dev/null 2>&1 || stack_fail "squash base not found: $parent"

  commit_count=$(git rev-list --count "$parent..$current" 2>/dev/null || echo 0)
  if (( commit_count == 0 )); then
    echo "$current has no incremental commits relative to $parent."
    return 0
  fi
  if (( commit_count == 1 )); then
    echo "$current already has one incremental commit relative to $parent."
    return 0
  fi

  if [[ -z "$subject" ]]; then
    local pr
    pr=$(jq -c --arg k "$current" '.[$k] // null' <<<"$prs")
    if [[ "$pr" != "null" ]]; then
      subject=$(jq -r '.title // ""' <<<"$pr")
    fi
  fi
  if [[ -z "$subject" || "$subject" == "null" ]]; then
    subject=$(git log --reverse --format='%s' "$parent..$current" | head -1)
  fi
  [[ -n "$subject" ]] || subject="squash $current"

  local pre_tips descendants old_current_tip
  pre_tips=$(stack_branch_tips_from_parent_map "$parent_map")
  descendants=$(stack_descendants_ordered "$current" "$ordered")
  old_current_tip=$(git rev-parse --verify "$current")

  echo "Squashing $commit_count commits on $current relative to $parent"
  echo "Subject: $subject"
  if [[ "$dry_run" == "true" ]]; then
    echo "(dry-run) Would reset --soft $parent and commit one squashed change"
    if [[ -n "$descendants" ]]; then
      echo "(dry-run) Would restack descendants:"
      awk -F'\t' '{print "  " $2 " onto " $3}' <<<"$descendants"
    fi
    return 0
  fi

  git checkout "$current" >/dev/null 2>&1
  git reset --soft "$parent"
  git commit -m "$subject" >/dev/null

  local depth child child_parent ahead behind old_parent_tip
  while IFS=$'\t' read -r depth child child_parent ahead behind; do
    [[ -z "$child" ]] && continue
    old_parent_tip=$(stack_lookup_tip "$child_parent" "$pre_tips")
    [[ -n "$old_parent_tip" ]] || stack_fail "could not find old parent tip for $child_parent"
    echo "Restacking $child onto $child_parent"
    if ! git rebase --onto "$child_parent" "$old_parent_tip" "$child" >/dev/null 2>&1; then
      git rebase --abort >/dev/null 2>&1 || true
      git checkout "$current" >/dev/null 2>&1 || true
      stack_fail "rebase failed for ${child}. Resolve manually:
  git rebase --onto ${child_parent} ${old_parent_tip} ${child}"
    fi
  done <<<"$descendants"

  git checkout "$current" >/dev/null 2>&1 || true

  local leases moved=0
  leases=$(stack_fetch_leases)
  local b old_sha new_sha lease
  while IFS=$'\t' read -r b old_sha; do
    [[ -z "$b" ]] && continue
    new_sha=$(git rev-parse --verify "$b" 2>/dev/null || echo "")
    [[ "$old_sha" == "$new_sha" ]] && continue
    moved=$((moved + 1))
    lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
    if [[ "$lease" != "null" ]]; then
      stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
    else
      echo "  tip moved: $b ($old_sha -> $new_sha)"
    fi
  done <<<"$pre_tips"

  [[ "$old_current_tip" != "$(git rev-parse --verify "$current")" ]] || stack_fail "squash did not move $current"
  (( moved > 0 )) || echo "No branches moved."
}

# stack push — orchestrate per-branch pg flow across the stack.
#
# For each branch (parents first):
#   - Existing PR: update through pg push when unpushed commits exist.
#   - No PR: push the branch through pg, then print draft-PR instructions.
#   - Skip if remote tracks branch and there are no unpushed commits.
#   - Checkout branch, then `pg check`:
#       * lease fresh (allowed && anchor==HEAD):
#         `pg push --force-with-lease --assert-flow`.
#       * else: `pg prepare` with auto-derived fields, STOP, instruct user
#         to run `pg` and re-invoke `stack push`. Restore caller's branch.
# Never bypasses push-gate. Hard-fails on a dirty working tree.
stack_cmd_push() {
  local dry_run="false"
  local base_override="" prefix_override="" pr_filter="" include_children="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      --pr)     pr_filter="${2:-}"; [[ "$pr_filter" =~ ^[0-9]+$ ]] || stack_fail "--pr requires a PR number"; shift 2 ;;
      --children) include_children="true"; shift ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown push flag: $1" ;;
    esac
  done
  stack_require jq
  command -v gh >/dev/null 2>&1 \
    || stack_fail "gh CLI required for stack push"
  stack_repo_root >/dev/null

  local pg_helper
  pg_helper="$(stack_helper_dir)/push-gate.sh"
  [[ -f "$pg_helper" ]] || stack_fail "push-gate.sh not found at $pg_helper"

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. git stash or commit first."

  local base prefix local_parent_map parent_map prs rerun_cmd
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  rerun_cmd=$(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$include_children")
  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  stack_debug "push base=$base prefix=$prefix branches=$(stack_count_nonempty_lines <<<"$local_parent_map") dry_run=$dry_run pr=${pr_filter:-none} children=$include_children"
  prs=$(stack_fetch_prs)
  parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
  if [[ -n "$pr_filter" ]]; then
    parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$pr_filter" "$include_children")
  fi
  stack_warn_topology_mismatches "$parent_map" "$local_parent_map" "$prs" "$base"

  local ordered
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  if [[ -z "$ordered" ]]; then
    echo "No stacked branches under $prefix."
    return 0
  fi

  local total=0
  while IFS=$'\t' read -r d n p a b; do
    [[ -z "$n" ]] && continue
    total=$((total + 1))
  done <<<"$ordered"

  local saved_branch repo_root
  saved_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  repo_root=$(stack_repo_root)
  restore_branch() {
    if [[ "$dry_run" != "true" && -n "$saved_branch" && "$saved_branch" != "HEAD" ]]; then
      local cur
      cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      [[ "$cur" == "$saved_branch" ]] || git checkout "$saved_branch" >/dev/null 2>&1 || true
    fi
  }

  local idx=0 pushed=0 skipped=0
  local depth name parent ahead behind
  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    idx=$((idx + 1))

    local pr pr_num create_pr_base
    pr=$(jq -c --arg k "$name" '.[$k] // null' <<<"$prs")
    if [[ "$pr" == "null" ]]; then
      pr_num=""
      create_pr_base=$(stack_pr_base_from_parent "$parent")
    else
      pr_num=$(jq -r '.number' <<<"$pr")
      create_pr_base=""
    fi

    local remote_ref ahead_remote=""
    remote_ref=$(stack_push_remote_ref "$name")
    if [[ -n "$remote_ref" ]]; then
      ahead_remote=$(git rev-list --count "${remote_ref}..${name}" 2>/dev/null || echo 0)
      stack_debug "push branch=$name pr=${pr_num:-none} upstream=$remote_ref ahead_upstream=$ahead_remote"
      if [[ "$ahead_remote" == "0" ]]; then
        if [[ -n "$pr_num" ]]; then
          echo "[$idx/$total] $name: up to date with $remote_ref (#$pr_num); skip"
        else
          echo "[$idx/$total] $name: pushed branch exists at $remote_ref, but no PR yet; create draft PR with base $create_pr_base"
        fi
        skipped=$((skipped + 1))
        continue
      fi
    fi

    if [[ "$dry_run" != "true" ]]; then
      git checkout "$name" >/dev/null 2>&1 \
        || { restore_branch; stack_fail "checkout failed: $name"; }
    fi

    local check_json allowed anchor_matches
    check_json=$(bash "$pg_helper" check "$name" 2>/dev/null || echo '{"allowed":false}')
    allowed=$(jq -r '.allowed // false' <<<"$check_json")
    anchor_matches=$(jq -r '.current.anchor_matches_head // false' <<<"$check_json")
    stack_debug "push branch=$name pr=${pr_num:-none} lease_allowed=$allowed anchor_matches_head=$anchor_matches"

    if [[ "$allowed" == "true" && "$anchor_matches" == "true" ]]; then
      local assert_flow rewrite_note="no rewrite"
      if [[ -n "$remote_ref" ]] && ! git merge-base --is-ancestor "$remote_ref" "$name" 2>/dev/null; then
        rewrite_note="rewrite branch"
      fi
      assert_flow=$(stack_push_assert_flow "$name" "$pr_num" "$rewrite_note" "$create_pr_base")
      if [[ "$dry_run" == "true" ]]; then
        if [[ -n "$pr_num" ]]; then
          echo "[$idx/$total] $name: (dry-run) lease fresh; would update #$pr_num with pg push --force-with-lease"
        else
          echo "[$idx/$total] $name: (dry-run) lease fresh; would push branch with pg push --force-with-lease --set-upstream, then create draft PR with base $create_pr_base"
        fi
      else
        if [[ -n "$pr_num" ]]; then
          echo "[$idx/$total] $name: pushing #$pr_num..."
        else
          echo "[$idx/$total] $name: pushing branch for new stacked PR (base $create_pr_base)..."
        fi
        local -a pg_push_args=(push --force-with-lease --assert-flow "$assert_flow")
        [[ -z "$pr_num" ]] && pg_push_args+=(--set-upstream)
        if ! bash "$pg_helper" "${pg_push_args[@]}"; then
          restore_branch
          stack_fail "pg push failed for $name. Aborting."
        fi
        pushed=$((pushed + 1))
      fi
      continue
    fi

    # Lease missing or stale — prepare and stop.
    local what why approach base_for_log
    if [[ "$pr" != "null" ]]; then
      what=$(jq -r '.title // ""' <<<"$pr")
    else
      what=""
    fi
    [[ -z "$what" || "$what" == "null" ]] \
      && what=$(git log -1 --format='%s' "$name" 2>/dev/null || echo "update $name")
    if [[ -n "$pr_num" ]]; then
      why="see PR #$pr_num"
    else
      why="create stacked PR based on $create_pr_base"
    fi
    base_for_log="${remote_ref:-$parent}"
    approach=$(git log "${base_for_log}..${name}" --format='%s' 2>/dev/null \
                | head -5 | paste -sd ';' -)
    [[ -z "$approach" ]] && approach="straightforward"

    if [[ "$dry_run" == "true" ]]; then
      echo "[$idx/$total] $name: (dry-run) lease missing/stale; would: pg prepare \\"
      echo "    --what '$what' --why '$why' --approach '$approach'"
      if [[ -z "$pr_num" ]]; then
        echo "    then push branch and create draft PR with base '$create_pr_base'"
      fi
      continue
    fi

    echo "[$idx/$total] $name: needs approval, preparing brief..."
    if ! bash "$pg_helper" prepare \
           --what "$what" --why "$why" --approach "$approach"; then
      restore_branch
      stack_fail "pg prepare failed for $name."
    fi
    restore_branch
    cat <<EOM

[$idx/$total] $name prepared. To approve and continue:
  1. Run: pg -C $repo_root
  2. Re-run: $rerun_cmd

(Stopping here — $pushed pushed, $skipped skipped before this branch.)
EOM
    stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd"
    return 0
  done <<<"$ordered"

  restore_branch
  echo
  echo "Done. Pushed $pushed, skipped $skipped, total $total."
  stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd"
}

stack_usage() {
  cat <<'EOF'
Usage: stack <command> [options]

Commands:
  status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]
    Show one-table view merging git topology, gh PR state, and pg leases.
    With --pr N, scope the view to that PR; --children follows GitHub PR
    baseRefName children instead of broad local branch prefix.

  sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
    Fetch the base remote, preflight cascade-rebase in a throwaway scratch
    clone, then atomically apply branch ref updates if preflight succeeds.
    Combines a PR-state pass with git-branchless patch-id detection.

  squash [--dry-run] [-m SUBJECT] [--branch BRANCH] [--onto REF|--onto-pr-base]
         [--pr N] [--base REF] [--prefix PREFIX]
    Squash the current branch's incremental commits relative to its stack
    parent into one commit, then restack selected descendants. Use --onto or
    --onto-pr-base when local ancestry disagrees with PR topology.

  push [--dry-run] [--base REF] [--prefix PREFIX] [--pr N] [--children]
    Walk stack parents-first. Existing PR branches update through
    `pg push --force-with-lease`. Branches without PRs are still pushed
    through push-gate when their lease is fresh, using --set-upstream, then
    listed as draft-PR creation targets. If any branch needs approval, run
    `pg prepare` and stop with instructions to run `pg`; re-run after
    approval to continue. Never bypasses push-gate.

Base ref auto-detected from upstream/main or origin/main. Branch prefix
defaults to mho/ (override via `git config stack.prefix`).

Debugging:
  Set STACK_DEBUG=1 to print repo roots, branch counts, scratch paths,
  lease-match counts, and push-gate decision breadcrumbs to stderr.
EOF
}

stack_main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { stack_usage; exit 1; }
  shift
  case "$cmd" in
    status)        stack_cmd_status "$@" ;;
    sync)          stack_cmd_sync "$@" ;;
    squash)        stack_cmd_squash "$@" ;;
    push)          stack_cmd_push "$@" ;;
    __sync-preflight)
      stack_require_branchless
      local base_override="" prefix_override=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --base)   base_override="${2:-}"; shift 2 ;;
          --prefix) prefix_override="${2:-}"; shift 2 ;;
          *) stack_fail "unknown __sync-preflight flag: $1" ;;
        esac
      done
      stack_sync_run_preflight \
        "$(stack_upstream_ref "$base_override")" \
        "$(stack_prefix "$prefix_override")"
      ;;
    -h|--help|help) stack_usage ;;
    *) stack_fail "unknown command: $cmd (see \`stack --help\`)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  stack_main "$@"
fi
