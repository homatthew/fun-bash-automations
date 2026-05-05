#!/bin/bash
# stack: local-first stacked-PR tooling.
#
# Subcommands:
#   status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]
#   checkout --pr N [--base REF] [--prefix PREFIX]
#   sync   [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
#   insert --branch BRANCH (--after BRANCH|--after-pr N) [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
#   trunk  init --name NAME --base REF --trunk BRANCH
#   trunk  add --stack NAME --id ID --branch BRANCH [--pr N] [--after ID] [--base REF]
#   trunk  move --stack NAME --id ID (--after ID|--before ID|--first|--last) [--dry-run]
#   trunk  remove --stack NAME --id ID [--dry-run]
#   trunk  materialize --name NAME|--stack NAME|--manifest PATH [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
#   trunk  push --stack NAME [--tip] [--dry-run] [--remote NAME]
#   trunk  status --name NAME|--stack NAME|--manifest PATH [--json] [--base REF] [--prefix PREFIX]
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

stack_dolt_required_message() {
  cat <<'EOF'
Dolt is required for stack trunk store commands.
Install: brew install dolt
Verify: dolt version
Store: ~/.push-gate/dolt-store by default; set PG_STORE_DIR to override.
EOF
}

stack_is_dolt_missing_output() {
  local output="$1"
  grep -qiE 'dolt is required|dolt.*not found|command not found: dolt' <<<"$output"
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

stack_pg_helper() {
  local helper
  helper="$(stack_helper_dir)/push-gate.sh"
  [[ -f "$helper" ]] || stack_fail "push-gate.sh not found at $helper"
  printf '%s\n' "$helper"
}

stack_run_pg_store_command() {
  local helper="$1"
  shift
  local err
  err=$(mktemp "${TMPDIR:-/tmp}/stack-pg.XXXXXX")
  if ! bash "$helper" "$@" 2>"$err"; then
    local detail
    detail=$(cat "$err")
    rm -f "$err"
    if stack_is_dolt_missing_output "$detail"; then
      stack_fail "$(stack_dolt_required_message)"
    fi
    stack_fail "push-gate stack store command failed: $*
${detail}"
  fi
  rm -f "$err"
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

stack_common_dir_for_repo() {
  local repo="$1" common
  common=$(git -C "$repo" rev-parse --git-common-dir)
  case "$common" in
    /*) printf '%s\n' "$common" ;;
    *) printf '%s\n' "$repo/$common" ;;
  esac
}

stack_enable_rerere_for_repo() {
  local repo="$1"
  git -C "$repo" config --local rerere.enabled true >/dev/null 2>&1 || true
  git -C "$repo" config --local rerere.autoupdate true >/dev/null 2>&1 || true
  stack_debug "enabled git rerere for $repo"
}

stack_copy_rerere_cache() {
  local src_repo="$1" dst_repo="$2" src_common dst_common
  src_common=$(stack_common_dir_for_repo "$src_repo" 2>/dev/null || true)
  dst_common=$(stack_common_dir_for_repo "$dst_repo" 2>/dev/null || true)
  [[ -n "$src_common" && -n "$dst_common" && -d "$src_common/rr-cache" ]] || return 0
  mkdir -p "$dst_common/rr-cache"
  cp -R "$src_common/rr-cache/." "$dst_common/rr-cache/" 2>/dev/null || true
  stack_debug "copied rerere cache into scratch"
}

stack_has_unmerged_paths() {
  [[ -n "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]]
}

stack_rebase_in_progress() {
  local common
  common=$(git rev-parse --git-common-dir)
  [[ -d "$common/rebase-merge" || -d "$common/rebase-apply" ]]
}

stack_cherry_pick_in_progress() {
  local common
  common=$(git rev-parse --git-common-dir)
  [[ -f "$common/CHERRY_PICK_HEAD" ]]
}

stack_continue_rebase_after_rerere() {
  local branch="$1" continued=0
  while stack_rebase_in_progress; do
    if stack_has_unmerged_paths; then
      return 1
    fi
    echo "  rerere reused recorded resolution for $branch; continuing rebase..."
    if ! GIT_EDITOR=true git rebase --continue >/dev/null 2>&1; then
      stack_has_unmerged_paths && return 1
      return 1
    fi
    continued=1
  done
  [[ "$continued" == "1" ]]
}

stack_rebase_onto() {
  local target="$1" old_base="$2" branch="$3"
  git rebase --onto "$target" "$old_base" "$branch" >/dev/null 2>&1 && return 0
  stack_continue_rebase_after_rerere "$branch" && return 0
  return 1
}

stack_cherry_pick_commit() {
  local commit="$1" branch="$2"
  git cherry-pick "$commit" >/dev/null 2>&1 && return 0
  if stack_cherry_pick_in_progress && ! stack_has_unmerged_paths; then
    echo "  rerere reused recorded resolution for $branch commit ${commit:0:8}; continuing cherry-pick..."
    GIT_EDITOR=true git cherry-pick --continue >/dev/null 2>&1 && return 0
  fi
  return 1
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

stack_print_next_step() {
  echo
  echo "Next step:"
  local line
  for line in "$@"; do
    printf '  %s\n' "$line"
  done
}

stack_status_rerun_command() {
  local base_override="$1" prefix_override="$2" pr_filter="${3:-}" include_children="${4:-false}"
  local cmd="stack status"
  cmd=$(stack_append_flag "$cmd" "--base" "$base_override")
  cmd=$(stack_append_flag "$cmd" "--prefix" "$prefix_override")
  cmd=$(stack_append_flag "$cmd" "--pr" "$pr_filter")
  [[ "$include_children" == "true" ]] && cmd="$cmd --children"
  printf '%s\n' "$cmd"
}

stack_sync_rerun_command() {
  local base_override="$1" prefix_override="$2"
  local cmd="stack sync"
  cmd=$(stack_append_flag "$cmd" "--base" "$base_override")
  cmd=$(stack_append_flag "$cmd" "--prefix" "$prefix_override")
  printf '%s\n' "$cmd"
}

stack_insert_rerun_command() {
  local base_override="$1" prefix_override="$2" branch="$3" after="$4" after_pr="$5" keep_scratch="${6:-false}"
  local cmd="stack insert"
  cmd=$(stack_append_flag "$cmd" "--base" "$base_override")
  cmd=$(stack_append_flag "$cmd" "--prefix" "$prefix_override")
  cmd=$(stack_append_flag "$cmd" "--branch" "$branch")
  cmd=$(stack_append_flag "$cmd" "--after" "$after")
  cmd=$(stack_append_flag "$cmd" "--after-pr" "$after_pr")
  [[ "$keep_scratch" == "true" ]] && cmd="$cmd --keep-scratch"
  printf '%s\n' "$cmd"
}

stack_ref_name() {
  printf 'refs/heads/%s\n' "$1"
}

stack_lookup_tip() {
  local branch="$1" tips="$2"
  awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' <<<"$tips"
}

stack_zero_oid() {
  printf '0000000000000000000000000000000000000000\n'
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

stack_parent_map_contains_branch() {
  local branch="$1" parent_map="$2"
  awk -F'\t' -v b="$branch" '$1 == b { found=1 } END { exit(found ? 0 : 1) }' <<<"$parent_map"
}

stack_parent_from_map() {
  local branch="$1" parent_map="$2"
  awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }' <<<"$parent_map"
}

stack_remove_subtree_from_ordered() {
  local root="$1" ordered="$2"
  awk -F'\t' -v root="$root" '
    { name[NR]=$2; parent[$2]=$3; line[$2]=$0 }
    END {
      for (i=1; i<=NR; i++) {
        n=name[i]
        if (n == root) continue
        p=parent[n]
        skip=0
        while (p != "") {
          if (p == root) {
            skip=1
            break
          }
          p=parent[p]
        }
        if (!skip) print line[n]
      }
    }
  ' <<<"$ordered"
}

stack_remove_existing_git_descendants_from_ordered() {
  local root="$1" ordered="$2"
  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    if [[ "$name" != "$root" ]] && git merge-base --is-ancestor "$root" "$name" 2>/dev/null; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$depth" "$name" "$parent" "$ahead" "$behind"
  done <<<"$ordered"
}

stack_children_blob_from_ordered() {
  local ordered="$1"
  awk -F'\t' 'NF { print $3 "\t" $2 }' <<<"$ordered"
}

stack_branch_list_from_ordered() {
  local ordered="$1"
  awk -F'\t' 'NF { print $2 }' <<<"$ordered"
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

stack_fetch_prs_for_scope() {
  local pr_filter="${1:-}"
  command -v gh >/dev/null 2>&1 || { echo '{}'; return 0; }
  if [[ -z "$pr_filter" ]]; then
    stack_fetch_prs
    return 0
  fi

  local raw prs has_pr view_json
  raw=$(gh pr list --state open --limit 200 \
          --json number,title,headRefName,baseRefName,mergeable,reviewDecision,statusCheckRollup,url \
          2>/dev/null || echo '[]')
  [[ -z "$raw" ]] && raw='[]'
  prs=$(jq 'map({(.headRefName): .}) | add // {}' <<<"$raw")
  has_pr=$(jq -r --argjson n "$pr_filter" 'any(.[]; (.number // null) == $n)' <<<"$prs")
  if [[ "$has_pr" == "true" ]]; then
    printf '%s\n' "$prs"
    return 0
  fi

  view_json=$(gh pr view "$pr_filter" \
    --json number,title,headRefName,baseRefName,mergeable,reviewDecision,statusCheckRollup,url \
    2>/dev/null || echo '')
  if [[ -n "$view_json" ]]; then
    prs=$(jq --argjson pr "$view_json" '. + {($pr.headRefName): $pr}' <<<"$prs")
  fi
  printf '%s\n' "$prs"
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
  local root pr_branches
  root=$(stack_pr_branch_by_number "$prs" "$pr_number")
  [[ -n "$root" ]] || stack_fail "open PR not found in stack data: #$pr_number"

  if [[ "$include_children" != "true" ]]; then
    awk -F'\t' -v root="$root" '$1 == root' <<<"$parent_map"
    return 0
  fi

  pr_branches=$(jq -r 'keys | join(" ")' <<<"$prs")
  awk -F'\t' -v root="$root" -v pr_branches="$pr_branches" '
    BEGIN {
      split(pr_branches, pr_branch_lines, " ")
      for (i in pr_branch_lines) if (pr_branch_lines[i] != "") has_pr[pr_branch_lines[i]]=1
    }
    { line[$1]=$0; parent[$1]=$2; names[NR]=$1 }
    END {
      if (root in line) { print line[root]; printed[root]=1 }
      changed=1
      while (changed) {
        changed=0
        for (i=1; i<=NR; i++) {
          n=names[i]
          if (printed[n]) continue
          if ((n in has_pr) == 0) continue
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

stack_topology_mismatch_lines() {
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$pr_num" "$branch" "$pr_base" "$pr_parent" "$local_parent"
  done <<<"$scoped_map"
}

stack_trunk_materialized_branch_context() {
  local branch="$1" helper
  helper=$(stack_pg_helper)
  bash "$helper" stack-store-branch-materialization --branch "$branch" --json 2>/dev/null || true
}

stack_topology_expected_trunk_context() {
  local branch="$1" local_parent="$2"
  local context trunk_branch recorded_commit branch_head
  context=$(stack_trunk_materialized_branch_context "$branch")
  [[ -n "$context" && "$context" != "null" ]] || return 1
  trunk_branch=$(jq -r '.trunk // ""' <<<"$context" 2>/dev/null) || return 1
  recorded_commit=$(jq -r '.commit // ""' <<<"$context" 2>/dev/null) || return 1
  [[ -n "$trunk_branch" && "$local_parent" == "$trunk_branch" ]] || return 1
  branch_head=$(git rev-parse --verify "$branch" 2>/dev/null || echo "")
  [[ -n "$recorded_commit" && "$branch_head" == "$recorded_commit" ]] || return 1
  jq -c --arg branch_head "$branch_head" '. + {branch_head: $branch_head}' <<<"$context"
}

stack_unexpected_topology_mismatch_lines() {
  local mismatches="$1" pr_num branch pr_base pr_parent local_parent
  while IFS=$'\t' read -r pr_num branch pr_base pr_parent local_parent; do
    [[ -z "$branch" ]] && continue
    if stack_topology_expected_trunk_context "$branch" "$local_parent" >/dev/null; then
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$pr_num" "$branch" "$pr_base" "$pr_parent" "$local_parent"
  done <<<"$mismatches"
}

stack_warn_topology_mismatches() {
  local scoped_map="$1" local_parent_map="$2" prs="$3" base="$4"
  local mismatches pr_num branch pr_base pr_parent local_parent trunk_context stack_name
  mismatches=$(stack_topology_mismatch_lines "$scoped_map" "$local_parent_map" "$prs" "$base")
  while IFS=$'\t' read -r pr_num branch pr_base pr_parent local_parent; do
    [[ -z "$branch" ]] && continue
    if trunk_context=$(stack_topology_expected_trunk_context "$branch" "$local_parent"); then
      stack_name=$(jq -r '.stack // ""' <<<"$trunk_context")
      stack_warn "Topology note: PR #$pr_num base is $pr_base, and local nearest parent is private trunk $local_parent from Dolt stack $stack_name. This is expected after stack trunk materialize; GitHub PR base still wins for PR-scoped commands."
      continue
    fi
    stack_warn "Topology mismatch: PR #$pr_num base is $pr_base, but local nearest parent is $local_parent. GitHub PR base wins; local ancestry is stale/diagnostic. Using PR base $pr_parent."
  done <<<"$mismatches"
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
  local ordered="$1" prs="$2" rerun_cmd="$3" phase="${4:-ready to push}"
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

  echo
  echo "Agent handoff:"
  echo "  Phase: $phase"
  echo "  Re-run this stack: $rerun_cmd"

  if (( existing_count > 0 )); then
    echo "  Existing PRs to update/describe:"
    jq -r '.[] | "  - #\(.number) \(.branch) (description base \(.base)): \(.title)\n    update description: /update-pr-description \(.number)"' <<<"$existing"
  fi

  if (( missing_count > 0 )); then
    echo "  Branches without PRs:"
    jq -r '.[] | "  - \(.branch) -> base \(.base)\n    create draft PR via /commit-push-pr after push-gate approval\n    suggested title: \(.subject)"' <<<"$missing"
  fi
}

stack_print_status_next_step() {
  local base_override="$1" prefix_override="$2" pr_filter="${3:-}" include_children="$4"
  local parent_map="$5" local_parent_map="$6" prs="$7" base="$8" prefix="$9"
  local ordered mismatches unexpected_mismatches push_cmd status_cmd sync_cmd
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  if [[ -z "$ordered" ]]; then
    stack_print_next_step "No stacked branches found under $prefix. Nothing to push."
    return 0
  fi

  mismatches=$(stack_topology_mismatch_lines "$parent_map" "$local_parent_map" "$prs" "$base")
  unexpected_mismatches=$(stack_unexpected_topology_mismatch_lines "$mismatches")
  if [[ -n "$pr_filter" ]]; then
    push_cmd=$(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "true")
    status_cmd=$(stack_status_rerun_command "$base_override" "$prefix_override" "$pr_filter" "true")
    if [[ "$include_children" != "true" ]]; then
      stack_print_next_step \
        "Use the PR-scoped stack view: $status_cmd" \
        "Then push only that PR stack: $push_cmd"
      return 0
    fi
    if [[ -n "$unexpected_mismatches" ]]; then
      stack_print_next_step \
        "GitHub PR base wins; local ancestry is stale/diagnostic." \
        "For middle-stack edits, first check out the PR branch: stack checkout --pr $pr_filter" \
        "If this PR needs cleanup, run: stack squash --pr $pr_filter --onto-pr-base" \
        "Otherwise push only this PR stack: $push_cmd"
      return 0
    fi
    stack_print_next_step \
      "For middle-stack edits, first check out the PR branch: stack checkout --pr $pr_filter" \
      "Push only this PR stack: $push_cmd"
    return 0
  fi

  sync_cmd=$(stack_sync_rerun_command "$base_override" "$prefix_override")
  push_cmd=$(stack_push_rerun_command "$base_override" "$prefix_override" "" "false")
  if awk -F'\t' 'NF && ($4 + 0) > 0 { found=1 } END { exit(found ? 0 : 1) }' <<<"$parent_map"; then
    stack_print_next_step \
      "Base has commits not in at least one branch; preflight a restack: $sync_cmd" \
      "After sync and tests pass, run: $push_cmd"
    return 0
  fi
  if [[ -n "$unexpected_mismatches" ]]; then
    stack_print_next_step \
      "GitHub PR bases are authoritative. Use PR-scoped commands for affected PRs before broad push." \
      "Example: stack status --pr <N> --children"
    return 0
  fi
  stack_print_next_step "Run a dry-run push to see approvals and order: $push_cmd --dry-run"
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
  prs=$(stack_fetch_prs_for_scope "$pr_filter")
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
    stack_print_status_next_step \
      "$base_override" "$prefix_override" "$pr_filter" "$include_children" \
      "$parent_map" "$local_parent_map" "$prs" "$base" "$prefix"
  fi
}

stack_cmd_checkout() {
  local pr_filter="" base_override="" prefix_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)     pr_filter="${2:-}"; [[ "$pr_filter" =~ ^[0-9]+$ ]] || stack_fail "--pr requires a PR number"; shift 2 ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown checkout flag: $1" ;;
    esac
  done
  [[ -n "$pr_filter" ]] || stack_fail "stack checkout requires --pr N"
  stack_require jq
  stack_repo_root >/dev/null

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. Commit or stash before stack checkout."

  local base prefix local_parent_map parent_map prs branch
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  prs=$(stack_fetch_prs_for_scope "$pr_filter")
  branch=$(stack_pr_branch_by_number "$prs" "$pr_filter")
  [[ -n "$branch" ]] || stack_fail "open PR not found in stack data: #$pr_filter"
  stack_local_ref_exists "$branch" \
    || stack_fail "PR #$pr_filter branch not found locally: $branch. Fetch or create the local branch first."

  git checkout "$branch" >/dev/null 2>&1 \
    || stack_fail "checkout failed: $branch"

  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
  parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$pr_filter" "true")
  stack_warn_topology_mismatches "$parent_map" "$local_parent_map" "$prs" "$base"

  echo "Checked out PR #$pr_filter: $branch"
  echo
  echo "=== Stack context ==="
  stack_render_table "$base" "$prefix" "$parent_map" "$prs" "$(stack_fetch_leases)"
  stack_print_next_step \
    "Edit files on $branch." \
    "Commit changes: git add <files> && git commit -m \"<subject>\"" \
    "Squash this PR against its GitHub base: stack squash --pr $pr_filter --onto-pr-base" \
    "Run affected tests." \
    "Dry-run push: stack push --dry-run --pr $pr_filter --children" \
    "Live push: stack push --pr $pr_filter --children"
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
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Run the preflight and apply refs: $(stack_sync_rerun_command "$base_override" "$prefix_override")"
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
  local moved=0 moved_branches="" stale_branches=""
  while IFS=$'\t' read -r b old_sha new_sha; do
    [[ -z "$b" ]] && continue
    if [[ -z "$new_sha" && -n "$old_sha" ]]; then
      echo "  branch removed: $b (was $old_sha)"
      moved=$((moved + 1))
      moved_branches="${moved_branches}${moved_branches:+, }$b"
      continue
    fi
    if [[ -n "$old_sha" && -n "$new_sha" && "$old_sha" != "$new_sha" ]]; then
      moved=$((moved + 1))
      moved_branches="${moved_branches}${moved_branches:+, }$b"
      local lease
      lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
      if [[ "$lease" != "null" ]]; then
        stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
        stale_branches="${stale_branches}${stale_branches:+, }$b"
      else
        echo "  tip moved: $b ($old_sha -> $new_sha)"
      fi
    fi
  done <<<"$moved_tips"
  if (( moved == 0 )); then
    echo "No branches moved."
    stack_print_next_step \
      "Refs unchanged." \
      "Confirm current state: $(stack_status_rerun_command "$base_override" "$prefix_override" "" "false")" \
      "Then dry-run push if needed: $(stack_push_rerun_command "$base_override" "$prefix_override" "" "false") --dry-run"
  else
    local lease_line
    if [[ -n "$stale_branches" ]]; then
      lease_line="Stale push-gate leases: $stale_branches"
    else
      lease_line="No existing push-gate leases became stale."
    fi
    stack_print_next_step \
      "Refs changed: $moved_branches" \
      "$lease_line" \
      "Run affected tests, then inspect: $(stack_status_rerun_command "$base_override" "$prefix_override" "" "false")" \
      "When ready, dry-run push: $(stack_push_rerun_command "$base_override" "$prefix_override" "" "false") --dry-run"
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
  stack_enable_rerere_for_repo "$repo_root"
  stack_enable_rerere_for_repo "$scratch_repo"
  stack_copy_rerere_cache "$repo_root" "$scratch_repo"

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

stack_insert_print_debug() {
  local scratch_repo="$1" script_path="$2" branch="$3" after="$4" after_pr="$5" base="$6" prefix="$7"
  echo
  echo "Scratch kept: $scratch_repo"
  local cmd
  cmd="Debug command: cd $(stack_shell_quote "$scratch_repo") && bash $(stack_shell_quote "$script_path") __insert-preflight"
  cmd=$(stack_append_flag "$cmd" "--branch" "$branch")
  cmd=$(stack_append_flag "$cmd" "--after" "$after")
  cmd=$(stack_append_flag "$cmd" "--after-pr" "$after_pr")
  cmd=$(stack_append_flag "$cmd" "--base" "$base")
  cmd=$(stack_append_flag "$cmd" "--prefix" "$prefix")
  printf '%s\n' "$cmd"
}

stack_insert_report_failure() {
  local scratch_repo="$1" rc="$2" keep_scratch="$3" script_path="$4" branch="$5" after="$6" after_pr="$7" base="$8" prefix="$9"
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
    stack_insert_print_debug "$scratch_repo" "$script_path" "$branch" "$after" "$after_pr" "$base" "$prefix"
  else
    stack_warn "rerun with --keep-scratch to preserve the scratch clone and preflight log."
  fi

  stack_fail "scratch insert preflight failed (exit $rc). Real branch refs were not changed."
}

stack_trunk_validate_manifest_json() {
  local manifest_json="$1" source="$2"
  jq -e '
    (.version == 1)
    and (.name | type == "string" and length > 0)
    and (.base | type == "string" and length > 0)
    and (.trunk | type == "string" and length > 0)
    and (.items | type == "array" and length > 0)
    and all(.items[]; (.id | type == "string" and length > 0) and (.branch | type == "string" and length > 0))
  ' <<<"$manifest_json" >/dev/null \
    || stack_fail "invalid stack trunk manifest: $source"
  stack_trunk_validate_private_trunk_ref "$(jq -r '.trunk' <<<"$manifest_json")"
}

stack_trunk_validate_private_trunk_ref() {
  local trunk="$1"
  case "$trunk" in
    main|master|refs/heads/main|refs/heads/master|origin/main|origin/master|upstream/main|upstream/master|refs/remotes/origin/main|refs/remotes/origin/master|refs/remotes/upstream/main|refs/remotes/upstream/master)
      stack_fail "stack trunk must be a private branch, not protected main ref: $trunk"
      ;;
  esac
}

stack_trunk_load_manifest_file() {
  local manifest="$1"
  [[ -f "$manifest" ]] || stack_fail "stack trunk manifest not found: $manifest"
  local manifest_json
  manifest_json=$(jq -c . "$manifest")
  stack_trunk_validate_manifest_json "$manifest_json" "$manifest"
  printf '%s\n' "$manifest_json"
}

stack_trunk_load_manifest_store() {
  local stack_name="$1" helper manifest_json
  [[ -n "$stack_name" ]] || stack_fail "stack trunk store load requires --name/--stack NAME"
  helper=$(stack_pg_helper)
  local err
  err=$(mktemp "${TMPDIR:-/tmp}/stack-pg.XXXXXX")
  if ! manifest_json=$(bash "$helper" stack-store-manifest --stack "$stack_name" --json 2>"$err"); then
    local detail
    detail=$(cat "$err")
    rm -f "$err"
    if stack_is_dolt_missing_output "$detail"; then
      stack_fail "$(stack_dolt_required_message)"
    fi
    stack_fail "failed to load stack manifest from Dolt store: $stack_name
${detail}"
  fi
  rm -f "$err"
  stack_trunk_validate_manifest_json "$manifest_json" "Dolt stack $stack_name"
  printf '%s\n' "$manifest_json"
}

stack_trunk_load_manifest() {
  local name="$1" manifest_override="${2:-}"
  if [[ -n "$manifest_override" ]]; then
    stack_trunk_load_manifest_file "$manifest_override"
  else
    stack_trunk_load_manifest_store "$name"
  fi
}

stack_trunk_source_label() {
  local name="$1" manifest_override="${2:-}"
  if [[ -n "$manifest_override" ]]; then
    printf 'manifest %s\n' "$(stack_shell_quote "$manifest_override")"
  else
    printf 'Dolt stack %s\n' "$(stack_shell_quote "$name")"
  fi
}

stack_trunk_status_command() {
  local name="$1" manifest_override="${2:-}"
  if [[ -n "$manifest_override" ]]; then
    printf 'stack trunk status --manifest %s\n' "$(stack_shell_quote "$manifest_override")"
  else
    printf 'stack trunk status --stack %s\n' "$(stack_shell_quote "$name")"
  fi
}

stack_trunk_materialize_command() {
  local name="$1" manifest_override="${2:-}"
  if [[ -n "$manifest_override" ]]; then
    printf 'stack trunk materialize --manifest %s\n' "$(stack_shell_quote "$manifest_override")"
  else
    printf 'stack trunk materialize --stack %s\n' "$(stack_shell_quote "$name")"
  fi
}

stack_trunk_manifest_field() {
  local manifest_json="$1" field="$2"
  jq -r --arg f "$field" '.[$f] // ""' <<<"$manifest_json"
}

stack_trunk_item_lines() {
  local manifest_json="$1"
  jq -r '.items[] | [.id, .branch, ((.pr // "-") | tostring), (.base // "-")] | @tsv' <<<"$manifest_json"
}

stack_trunk_branch_tips() {
  local manifest_json="$1"
  local trunk id branch pr item_base
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  printf '%s\t%s\n' "$trunk" "$(git rev-parse --verify "$trunk" 2>/dev/null || stack_zero_oid)"
  while IFS=$'\t' read -r id branch pr item_base; do
    [[ -z "$branch" ]] && continue
    printf '%s\t%s\n' "$branch" "$(git rev-parse --verify "$branch" 2>/dev/null || echo '')"
  done < <(stack_trunk_item_lines "$manifest_json")
}

stack_trunk_resolve_item_bases() {
  local manifest_json="$1" parent_map="$2" manifest_base="$3"
  local id branch pr item_base patch_base patch_base_sha
  while IFS=$'\t' read -r id branch pr item_base; do
    [[ -z "$branch" ]] && continue
    [[ "$pr" == "-" ]] && pr=""
    [[ "$item_base" == "-" ]] && item_base=""
    git rev-parse --verify "$branch" >/dev/null 2>&1 \
      || stack_fail "stack trunk item branch not found: $branch"
    patch_base="$item_base"
    if [[ -z "$patch_base" ]]; then
      patch_base=$(stack_parent_from_map "$branch" "$parent_map")
    fi
    [[ -n "$patch_base" ]] || patch_base="$manifest_base"
    git rev-parse --verify "$patch_base" >/dev/null 2>&1 \
      || stack_fail "patch base for $branch not found: $patch_base"
    patch_base_sha=$(git rev-parse --verify "$patch_base")
    printf '%s\t%s\t%s\t%s\n' "$id" "$branch" "${pr:-"-"}" "$patch_base_sha"
  done < <(stack_trunk_item_lines "$manifest_json")
}

stack_trunk_print_plan() {
  local manifest_json="$1" item_bases="$2" base_override="${3:-}"
  local manifest_name manifest_base trunk resolved_base
  manifest_name=$(stack_trunk_manifest_field "$manifest_json" "name")
  manifest_base=$(stack_trunk_manifest_field "$manifest_json" "base")
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  resolved_base=$(stack_upstream_ref "${base_override:-$manifest_base}")

  echo "Stack trunk: $manifest_name"
  echo "  Base:  $resolved_base"
  echo "  Trunk: $trunk"
  echo
  echo "Materialization order:"
  local idx=0 id branch pr patch_base count pr_label
  while IFS=$'\t' read -r id branch pr patch_base; do
    [[ -z "$branch" ]] && continue
    [[ "$pr" == "-" ]] && pr=""
    idx=$((idx + 1))
    count=$(git rev-list --count "$patch_base..$branch" 2>/dev/null || echo 0)
    pr_label=""
    [[ -n "$pr" ]] && pr_label=" (#$pr)"
    printf '  %d. %s%s -> %s (%s commit(s) from %s)\n' "$idx" "$id" "$pr_label" "$branch" "$count" "$patch_base"
  done <<<"$item_bases"
}

stack_trunk_apply_item_in_scratch() {
  local id="$1" branch="$2" patch_base="$3"
  local count commit
  count=$(git rev-list --count "$patch_base..$branch" 2>/dev/null || echo 0)
  echo "  item $id: $branch ($count commit(s) from $patch_base)"
  while read -r commit; do
    [[ -z "$commit" ]] && continue
    if ! stack_cherry_pick_commit "$commit" "$branch"; then
      git cherry-pick --abort >/dev/null 2>&1 || true
      stack_fail "cherry-pick failed for $branch commit ${commit:0:8}"
    fi
  done < <(git rev-list --reverse "$patch_base..$branch")
  git update-ref "refs/heads/$branch" HEAD
}

stack_trunk_run_materialize_preflight() {
  local manifest_json="$1" item_bases="$2" base_override="${3:-}"
  local manifest_base trunk resolved_base id branch pr patch_base
  manifest_base=$(stack_trunk_manifest_field "$manifest_json" "base")
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  resolved_base=$(stack_upstream_ref "${base_override:-$manifest_base}")

  git checkout -q -B "$trunk" "$resolved_base"
  while IFS=$'\t' read -r id branch pr patch_base; do
    [[ -z "$branch" ]] && continue
    stack_trunk_apply_item_in_scratch "$id" "$branch" "$patch_base"
  done <<<"$item_bases"
  git update-ref "refs/heads/$trunk" HEAD
}

stack_trunk_report_failure() {
  local scratch_repo="$1" rc="$2" keep_scratch="$3"
  local conflicts status_short
  conflicts=$(git -C "$scratch_repo" diff --name-only --diff-filter=U 2>/dev/null || true)
  status_short=$(git -C "$scratch_repo" status --short 2>/dev/null || true)
  if [[ -n "$conflicts" ]]; then
    stack_warn "stack trunk scratch conflict files:"
    sed 's/^/  /' <<<"$conflicts" >&2
  elif [[ -n "$status_short" ]]; then
    stack_warn "stack trunk scratch left changes:"
    sed 's/^/  /' <<<"$status_short" >&2
  fi
  if [[ "$keep_scratch" == "true" ]]; then
    echo
    echo "Scratch kept: $scratch_repo"
  else
    stack_warn "rerun with --keep-scratch to preserve the scratch clone and preflight log."
  fi
  stack_fail "stack trunk materialize preflight failed (exit $rc). Real branch refs were not changed."
}

stack_trunk_materialization_json() {
  local stack_name="$1" manifest_json="$2"
  local materialization_id manifest_hash trunk trunk_tip items='[]'
  local idx=0 id branch pr item_base commit_sha
  manifest_hash=$(printf '%s' "$manifest_json" | jq -S -c . | shasum -a 256 | awk '{print $1}')
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  trunk_tip=$(git rev-parse --verify "$trunk")
  materialization_id="$trunk_tip"
  while IFS=$'\t' read -r id branch pr item_base; do
    [[ -z "$branch" ]] && continue
    idx=$((idx + 1))
    [[ "$pr" == "-" ]] && pr=""
    commit_sha=$(git rev-parse --verify "$branch")
    items=$(jq \
      --arg id "$id" \
      --arg branch "$branch" \
      --arg commit "$commit_sha" \
      --arg pr "$pr" \
      --argjson order_index "$idx" \
      '. + [{
        id: $id,
        order_index: $order_index,
        branch: $branch,
        commit: $commit,
        pr: (if $pr == "" then null else ($pr | tonumber) end)
      }]' <<<"$items")
  done < <(stack_trunk_item_lines "$manifest_json")
  jq -n \
    --arg stack "$stack_name" \
    --arg materialization_id "$materialization_id" \
    --arg manifest_hash "$manifest_hash" \
    --arg trunk_tip "$trunk_tip" \
    --argjson items "$items" \
    '{
      stack: $stack,
      materialization_id: $materialization_id,
      manifest_hash: $manifest_hash,
      trunk_tip: $trunk_tip,
      items: $items
    }'
}

stack_trunk_alignment_state() {
  local manifest_json="$1" trunk item_head prev_head="" id branch pr item_base trunk_head
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  trunk_head=$(git rev-parse --verify "$trunk" 2>/dev/null || echo "")
  [[ -n "$trunk_head" ]] || { printf 'not_materialized\n'; return 0; }

  while IFS=$'\t' read -r id branch pr item_base; do
    [[ -z "$branch" ]] && continue
    item_head=$(git rev-parse --verify "$branch" 2>/dev/null || echo "")
    [[ -n "$item_head" ]] || { printf 'missing_pointer\n'; return 0; }
    if [[ -n "$prev_head" ]] && ! git merge-base --is-ancestor "$prev_head" "$item_head" 2>/dev/null; then
      printf 'needs_materialize\n'
      return 0
    fi
    prev_head="$item_head"
  done < <(stack_trunk_item_lines "$manifest_json")

  if [[ -n "$prev_head" && "$prev_head" == "$trunk_head" ]]; then
    printf 'up_to_date\n'
  else
    printf 'needs_materialize\n'
  fi
}

stack_trunk_record_materialization() {
  local stack_name="$1" manifest_json="$2" materialization_json helper
  [[ -n "$stack_name" ]] || return 0
  helper=$(stack_pg_helper)
  materialization_json=$(stack_trunk_materialization_json "$stack_name" "$manifest_json")
  stack_run_pg_store_command "$helper" stack-store-record-materialization --stack "$stack_name" --json "$materialization_json" >/dev/null
}

stack_refresh_worktree_if_current_branch_moved() {
  local current_branch="$1" moved_tips="$2"
  [[ -n "$current_branch" && "$current_branch" != "HEAD" ]] || return 0
  awk -F'\t' -v b="$current_branch" '$1 == b && $2 != $3 { found=1 } END { exit(found ? 0 : 1) }' <<<"$moved_tips" \
    || return 0
  git reset --hard HEAD >/dev/null
  echo "Refreshed checked-out worktree for moved branch $current_branch."
}

stack_cmd_trunk_init() {
  local name="" base_ref="" trunk=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--stack) name="${2:-}"; [[ -n "$name" ]] || stack_fail "--name requires a value"; shift 2 ;;
      --base) base_ref="${2:-}"; [[ -n "$base_ref" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --trunk) trunk="${2:-}"; [[ -n "$trunk" ]] || stack_fail "--trunk requires a branch"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk init flag: $1" ;;
    esac
  done
  [[ -n "$name" && -n "$base_ref" && -n "$trunk" ]] \
    || stack_fail "stack trunk init requires --name, --base, and --trunk"
  stack_trunk_validate_private_trunk_ref "$trunk"
  stack_repo_root >/dev/null
  local helper
  helper=$(stack_pg_helper)
  stack_run_pg_store_command "$helper" stack-store-init --name "$name" --base "$base_ref" --trunk "$trunk"
  stack_print_next_step \
    "Add the first item: stack trunk add --stack $(stack_shell_quote "$name") --id <id> --branch <branch>" \
    "Inspect the Dolt manifest: stack trunk status --stack $(stack_shell_quote "$name")"
}

stack_cmd_trunk_add() {
  local stack_name="" item_id="" branch="" pr_number="" after="" item_base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="${2:-}"; [[ -n "$stack_name" ]] || stack_fail "--stack requires a value"; shift 2 ;;
      --id) item_id="${2:-}"; [[ -n "$item_id" ]] || stack_fail "--id requires a value"; shift 2 ;;
      --branch) branch="${2:-}"; [[ -n "$branch" ]] || stack_fail "--branch requires a value"; shift 2 ;;
      --pr) pr_number="${2:-}"; [[ "$pr_number" =~ ^[0-9]+$ ]] || stack_fail "--pr requires a number"; shift 2 ;;
      --after) after="${2:-}"; [[ -n "$after" ]] || stack_fail "--after requires an item id"; shift 2 ;;
      --base) item_base="${2:-}"; [[ -n "$item_base" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk add flag: $1" ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" && -n "$branch" ]] \
    || stack_fail "stack trunk add requires --stack, --id, and --branch"
  stack_repo_root >/dev/null
  git rev-parse --verify "$branch" >/dev/null 2>&1 \
    || stack_fail "stack trunk item branch not found: $branch"
  local helper cmd_args=()
  helper=$(stack_pg_helper)
  cmd_args=(stack-store-add --stack "$stack_name" --id "$item_id" --branch "$branch")
  [[ -n "$pr_number" ]] && cmd_args+=(--pr "$pr_number")
  [[ -n "$after" ]] && cmd_args+=(--after "$after")
  [[ -n "$item_base" ]] && cmd_args+=(--base "$item_base")
  stack_run_pg_store_command "$helper" "${cmd_args[@]}"
  stack_print_next_step \
    "Inspect order: stack trunk status --stack $(stack_shell_quote "$stack_name")" \
    "Materialize when ready: stack trunk materialize --stack $(stack_shell_quote "$stack_name")"
}

stack_trunk_print_item_order() {
  local manifest_json="$1"
  jq -r '.items[] | "  - " + .id + ": " + .branch' <<<"$manifest_json"
}

stack_trunk_move_proposed_order() {
  local manifest_json="$1" move_id="$2" after="$3" before="$4" first="$5" last="$6"
  local ids=() branches=() remaining_ids=() remaining_branches=()
  local id branch pr item_base found_item="false" found_target="false" i
  while IFS=$'\t' read -r id branch pr item_base; do
    [[ -z "$id" ]] && continue
    ids+=("$id")
    branches+=("$branch")
  done < <(stack_trunk_item_lines "$manifest_json")
  for i in "${!ids[@]}"; do
    if [[ "${ids[$i]}" == "$move_id" ]]; then
      found_item="true"
      continue
    fi
    remaining_ids+=("${ids[$i]}")
    remaining_branches+=("${branches[$i]}")
  done
  [[ "$found_item" == "true" ]] || stack_fail "stack item not found: $move_id"
  if [[ "$first" == "true" ]]; then
    printf '%s\t%s\n' "$move_id" "$(jq -r --arg id "$move_id" '.items[] | select(.id == $id) | .branch' <<<"$manifest_json")"
    for i in "${!remaining_ids[@]}"; do printf '%s\t%s\n' "${remaining_ids[$i]}" "${remaining_branches[$i]}"; done
    return 0
  fi
  if [[ "$last" == "true" ]]; then
    for i in "${!remaining_ids[@]}"; do printf '%s\t%s\n' "${remaining_ids[$i]}" "${remaining_branches[$i]}"; done
    printf '%s\t%s\n' "$move_id" "$(jq -r --arg id "$move_id" '.items[] | select(.id == $id) | .branch' <<<"$manifest_json")"
    return 0
  fi
  [[ "$after" != "$move_id" && "$before" != "$move_id" ]] || stack_fail "cannot move stack item relative to itself: $move_id"
  for i in "${!remaining_ids[@]}"; do
    if [[ -n "$before" && "${remaining_ids[$i]}" == "$before" ]]; then
      printf '%s\t%s\n' "$move_id" "$(jq -r --arg id "$move_id" '.items[] | select(.id == $id) | .branch' <<<"$manifest_json")"
      found_target="true"
    fi
    printf '%s\t%s\n' "${remaining_ids[$i]}" "${remaining_branches[$i]}"
    if [[ -n "$after" && "${remaining_ids[$i]}" == "$after" ]]; then
      printf '%s\t%s\n' "$move_id" "$(jq -r --arg id "$move_id" '.items[] | select(.id == $id) | .branch' <<<"$manifest_json")"
      found_target="true"
    fi
  done
  [[ "$found_target" == "true" ]] || stack_fail "stack item not found for move target: ${after:-$before}"
}

stack_trunk_print_proposed_lines() {
  local lines="$1"
  awk -F'\t' 'NF { print "  - " $1 ": " $2 }' <<<"$lines"
}

stack_cmd_trunk_move() {
  local stack_name="" item_id="" after="" before="" first="false" last="false" dry_run="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="${2:-}"; [[ -n "$stack_name" ]] || stack_fail "--stack requires a value"; shift 2 ;;
      --id) item_id="${2:-}"; [[ -n "$item_id" ]] || stack_fail "--id requires a value"; shift 2 ;;
      --after) after="${2:-}"; [[ -n "$after" ]] || stack_fail "--after requires an item id"; shift 2 ;;
      --before) before="${2:-}"; [[ -n "$before" ]] || stack_fail "--before requires an item id"; shift 2 ;;
      --first) first="true"; shift ;;
      --last) last="true"; shift ;;
      --dry-run) dry_run="true"; shift ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk move flag: $1" ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" ]] || stack_fail "stack trunk move requires --stack and --id"
  local choices=0
  [[ -n "$after" ]] && choices=$((choices + 1))
  [[ -n "$before" ]] && choices=$((choices + 1))
  [[ "$first" == "true" ]] && choices=$((choices + 1))
  [[ "$last" == "true" ]] && choices=$((choices + 1))
  [[ "$choices" == "1" ]] || stack_fail "stack trunk move requires exactly one of --after, --before, --first, or --last"
  stack_repo_root >/dev/null

  local manifest_json proposed helper cmd_args=() position_arg=""
  manifest_json=$(stack_trunk_load_manifest "$stack_name" "")
  proposed=$(stack_trunk_move_proposed_order "$manifest_json" "$item_id" "$after" "$before" "$first" "$last")
  if [[ "$dry_run" == "true" ]]; then
    [[ -n "$after" ]] && position_arg=" --after $(stack_shell_quote "$after")"
    [[ -n "$before" ]] && position_arg=" --before $(stack_shell_quote "$before")"
    [[ "$first" == "true" ]] && position_arg=" --first"
    [[ "$last" == "true" ]] && position_arg=" --last"
    echo "Current order:"
    stack_trunk_print_item_order "$manifest_json"
    echo
    echo "Proposed order:"
    stack_trunk_print_proposed_lines "$proposed"
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Apply order change: stack trunk move --stack $(stack_shell_quote "$stack_name") --id $(stack_shell_quote "$item_id")$position_arg" \
      "Then materialize: stack trunk materialize --stack $(stack_shell_quote "$stack_name")"
    return 0
  fi

  helper=$(stack_pg_helper)
  cmd_args=(stack-store-move --stack "$stack_name" --id "$item_id")
  [[ -n "$after" ]] && cmd_args+=(--after "$after")
  [[ -n "$before" ]] && cmd_args+=(--before "$before")
  [[ "$first" == "true" ]] && cmd_args+=(--first)
  [[ "$last" == "true" ]] && cmd_args+=(--last)
  stack_run_pg_store_command "$helper" "${cmd_args[@]}"
  echo "New order:"
  stack_trunk_print_item_order "$(stack_trunk_load_manifest "$stack_name" "")"
  stack_print_next_step \
    "Materialize reordered trunk: stack trunk materialize --stack $(stack_shell_quote "$stack_name")" \
    "Inspect order: stack trunk status --stack $(stack_shell_quote "$stack_name")"
}

stack_cmd_trunk_remove() {
  local stack_name="" item_id="" dry_run="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="${2:-}"; [[ -n "$stack_name" ]] || stack_fail "--stack requires a value"; shift 2 ;;
      --id) item_id="${2:-}"; [[ -n "$item_id" ]] || stack_fail "--id requires a value"; shift 2 ;;
      --dry-run) dry_run="true"; shift ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk remove flag: $1" ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" ]] || stack_fail "stack trunk remove requires --stack and --id"
  stack_repo_root >/dev/null
  local manifest_json proposed helper
  manifest_json=$(stack_trunk_load_manifest "$stack_name" "")
  jq -e --arg id "$item_id" '.items[] | select(.id == $id)' <<<"$manifest_json" >/dev/null \
    || stack_fail "stack item not found: $item_id"
  proposed=$(jq -r --arg id "$item_id" '.items[] | select(.id != $id) | [.id, .branch] | @tsv' <<<"$manifest_json")
  if [[ "$dry_run" == "true" ]]; then
    echo "Current order:"
    stack_trunk_print_item_order "$manifest_json"
    echo
    echo "Proposed order:"
    if [[ -n "$proposed" ]]; then
      stack_trunk_print_proposed_lines "$proposed"
    else
      echo "  (empty)"
    fi
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Apply removal: stack trunk remove --stack $(stack_shell_quote "$stack_name") --id $(stack_shell_quote "$item_id")" \
      "Then materialize: stack trunk materialize --stack $(stack_shell_quote "$stack_name")"
    return 0
  fi
  helper=$(stack_pg_helper)
  stack_run_pg_store_command "$helper" stack-store-remove --stack "$stack_name" --id "$item_id"
  echo "New order:"
  stack_trunk_print_item_order "$(stack_trunk_load_manifest "$stack_name" "")"
  stack_print_next_step \
    "Materialize reordered trunk: stack trunk materialize --stack $(stack_shell_quote "$stack_name")" \
    "Inspect order: stack trunk status --stack $(stack_shell_quote "$stack_name")"
}

stack_cmd_trunk_materialize() {
  local name="" manifest_override="" dry_run="false" keep_scratch="false" base_override="" prefix_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--stack) name="${2:-}"; [[ -n "$name" ]] || stack_fail "--name requires a value"; shift 2 ;;
      --manifest) manifest_override="${2:-}"; [[ -n "$manifest_override" ]] || stack_fail "--manifest requires a path"; shift 2 ;;
      --dry-run) dry_run="true"; shift ;;
      --keep-scratch) keep_scratch="true"; shift ;;
      --base) base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk materialize flag: $1" ;;
    esac
  done
  stack_require jq
  stack_repo_root >/dev/null

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. git stash or commit first."
  stack_enable_rerere_for_repo "$(stack_repo_root)"

  local manifest_json manifest_base base prefix parent_map item_bases pre_tips trunk
  manifest_json=$(stack_trunk_load_manifest "$name" "$manifest_override")
  manifest_base=$(stack_trunk_manifest_field "$manifest_json" "base")
  base=$(stack_upstream_ref "${base_override:-$manifest_base}")
  prefix=$(stack_prefix "$prefix_override")
  parent_map=$(stack_build_parent_map "$prefix" "$base")
  item_bases=$(stack_trunk_resolve_item_bases "$manifest_json" "$parent_map" "$base")
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  stack_trunk_print_plan "$manifest_json" "$item_bases" "${base_override:-$manifest_base}"

  if [[ "$dry_run" == "true" ]]; then
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Build the private trunk and branch pointers: $(stack_trunk_materialize_command "$name" "$manifest_override")"
    return 0
  fi

  pre_tips=$(stack_trunk_branch_tips "$manifest_json")

  local repo_root current_branch scratch_root scratch_repo preflight_log
  repo_root=$(stack_repo_root)
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/stack-trunk.XXXXXX")
  scratch_repo="$scratch_root/repo"

  STACK_TRUNK_CLEANUP_ROOT="$scratch_root"
  STACK_TRUNK_KEEP_SCRATCH="$keep_scratch"
  trap 'if [[ "${STACK_TRUNK_KEEP_SCRATCH:-}" != "true" && -n "${STACK_TRUNK_CLEANUP_ROOT:-}" ]]; then rm -rf "$STACK_TRUNK_CLEANUP_ROOT"; fi' EXIT

  echo
  echo "Creating scratch clone: $scratch_repo"
  stack_sync_create_scratch "$repo_root" "$scratch_repo" "$current_branch" "$parent_map"

  preflight_log="$scratch_root/preflight.log"
  echo "Preflighting private trunk materialization in scratch..."
  set +e
  (
    cd "$scratch_repo"
    stack_trunk_run_materialize_preflight "$manifest_json" "$item_bases" "${base_override:-$manifest_base}"
  ) >"$preflight_log" 2>&1
  local preflight_rc=$?
  set -e
  sed 's/^/  /' "$preflight_log"

  if (( preflight_rc != 0 )); then
    stack_trunk_report_failure "$scratch_repo" "$preflight_rc" "$keep_scratch"
    return 1
  fi

  local scratch_tips moved_tips
  scratch_tips=$(awk -F'\t' '{print $1}' <<<"$pre_tips" | while read -r b; do
    [[ -z "$b" ]] && continue
    printf '%s\t%s\n' "$b" "$(git -C "$scratch_repo" rev-parse --verify "$b" 2>/dev/null || echo '')"
  done)
  moved_tips=$(stack_sync_moved_tips "$pre_tips" "$scratch_tips")
  if [[ -n "$moved_tips" ]]; then
    stack_sync_apply_refs "$scratch_repo" "$moved_tips"
    stack_refresh_worktree_if_current_branch_moved "$current_branch" "$moved_tips"
  fi

  local leases moved=0 moved_branches="" stale_branches="" b old_sha new_sha lease
  leases=$(stack_fetch_leases)
  echo
  while IFS=$'\t' read -r b old_sha new_sha; do
    [[ -z "$b" ]] && continue
    [[ "$old_sha" == "$new_sha" ]] && continue
    moved=$((moved + 1))
    moved_branches="${moved_branches}${moved_branches:+, }$b"
    lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
    if [[ "$lease" != "null" && "$b" != "$trunk" ]]; then
      stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
      stale_branches="${stale_branches}${stale_branches:+, }$b"
    else
      echo "  tip moved: $b ($old_sha -> $new_sha)"
    fi
  done <<<"$moved_tips"

  if [[ -z "$manifest_override" ]]; then
    stack_trunk_record_materialization "$name" "$manifest_json"
  fi

  if (( moved == 0 )); then
    echo "No refs moved."
    stack_print_next_step "Private trunk already materialized."
  else
    local lease_line
    if [[ -n "$stale_branches" ]]; then
      lease_line="Stale push-gate leases: $stale_branches"
    else
      lease_line="No existing push-gate leases became stale."
    fi
    stack_print_next_step \
      "Materialized private trunk: $trunk" \
      "Moved refs: $moved_branches" \
      "$lease_line" \
      "Run affected tests, then inspect: $(stack_trunk_status_command "$name" "$manifest_override")"
  fi

  if [[ "$keep_scratch" == "true" ]]; then
    echo
    echo "Scratch kept: $scratch_repo"
  fi
}

stack_cmd_trunk_status() {
  local name="" manifest_override="" format="table" base_override="" prefix_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|--stack) name="${2:-}"; [[ -n "$name" ]] || stack_fail "--name requires a value"; shift 2 ;;
      --manifest) manifest_override="${2:-}"; [[ -n "$manifest_override" ]] || stack_fail "--manifest requires a path"; shift 2 ;;
      --json) format="json"; shift ;;
      --base) base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk status flag: $1" ;;
    esac
  done
  stack_require jq
  stack_repo_root >/dev/null

  local manifest_json manifest_base base prefix parent_map item_bases trunk alignment_state
  manifest_json=$(stack_trunk_load_manifest "$name" "$manifest_override")
  manifest_base=$(stack_trunk_manifest_field "$manifest_json" "base")
  base=$(stack_upstream_ref "${base_override:-$manifest_base}")
  prefix=$(stack_prefix "$prefix_override")
  parent_map=$(stack_build_parent_map "$prefix" "$base")
  item_bases=$(stack_trunk_resolve_item_bases "$manifest_json" "$parent_map" "$base")
  trunk=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  alignment_state=$(stack_trunk_alignment_state "$manifest_json")

  if [[ "$format" == "json" ]]; then
    local items='[]' id branch pr patch_base head trunk_head
    trunk_head=$(git rev-parse --verify "$trunk" 2>/dev/null || echo "")
  while IFS=$'\t' read -r id branch pr patch_base; do
    [[ -z "$branch" ]] && continue
    [[ "$pr" == "-" ]] && pr=""
    head=$(git rev-parse --verify "$branch" 2>/dev/null || echo "")
      items=$(jq --arg id "$id" --arg branch "$branch" --arg pr "$pr" --arg patch_base "$patch_base" --arg head "$head" \
        '. + [{id:$id, branch:$branch, pr:$pr, patch_base:$patch_base, head:$head}]' <<<"$items")
    done <<<"$item_bases"
    jq -n --argjson manifest "$manifest_json" --arg base "$base" --arg trunk_head "$trunk_head" --arg alignment_state "$alignment_state" --argjson items "$items" \
      '{manifest:$manifest, resolved_base:$base, trunk_head:$trunk_head, alignment_state:$alignment_state, items:$items}'
    return 0
  fi

  stack_trunk_print_plan "$manifest_json" "$item_bases" "${base_override:-$manifest_base}"
  echo "  Source: $(stack_trunk_source_label "$name" "$manifest_override")"
  echo
  printf '%-22s %-36s %s\n' "Pointer" "Branch" "Head"
  printf '%-22s %-36s %s\n' "-------" "------" "----"
  printf '%-22s %-36s %s\n' "trunk" "$trunk" "$(git rev-parse --short "$trunk" 2>/dev/null || echo "missing")"
  local id branch pr patch_base
  while IFS=$'\t' read -r id branch pr patch_base; do
    [[ -z "$branch" ]] && continue
    printf '%-22s %-36s %s\n' "$id" "$branch" "$(git rev-parse --short "$branch" 2>/dev/null || echo "missing")"
  done <<<"$item_bases"
  case "$alignment_state" in
    up_to_date)
      stack_print_next_step \
        "Private trunk is up to date; no materialize needed." \
        "Run affected tests, then prepare approval if needed: pg prepare-trunk --stack $(stack_shell_quote "${name:-$(stack_trunk_manifest_field "$manifest_json" "name")}") --what <what> --why <why> --approach <approach> --item-briefs <file>"
      ;;
    not_materialized)
      stack_print_next_step "Private trunk missing; Materialize changes: $(stack_trunk_materialize_command "$name" "$manifest_override")"
      ;;
    missing_pointer)
      stack_print_next_step "One or more stack item branches are missing; fix refs before materializing."
      ;;
    *)
      stack_print_next_step "Materialize changes: $(stack_trunk_materialize_command "$name" "$manifest_override")"
      ;;
  esac
}

stack_cmd_trunk_push() {
  local stack_name="" dry_run="false" remote="" tip_only="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="${2:-}"; [[ -n "$stack_name" ]] || stack_fail "--stack requires a value"; shift 2 ;;
      --tip) tip_only="true"; shift ;;
      --dry-run) dry_run="true"; shift ;;
      --remote) remote="${2:-}"; [[ -n "$remote" ]] || stack_fail "--remote requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown trunk push flag: $1" ;;
    esac
  done
  [[ -n "$stack_name" ]] || stack_fail "stack trunk push requires --stack NAME"
  stack_require jq
  stack_repo_root >/dev/null
  local helper check allowed reason
  helper=$(stack_pg_helper)
  local err
  err=$(mktemp "${TMPDIR:-/tmp}/stack-pg.XXXXXX")
  if ! check=$(bash "$helper" check-trunk --stack "$stack_name" 2>"$err"); then
    local detail
    detail=$(cat "$err")
    rm -f "$err"
    if stack_is_dolt_missing_output "$detail"; then
      stack_fail "$(stack_dolt_required_message)"
    fi
    stack_fail "failed to check trunk lease for $stack_name
${detail}"
  fi
  rm -f "$err"
  allowed=$(jq -r '.allowed' <<<"$check")
  if [[ "$allowed" != "true" ]]; then
    reason=$(jq -r '.reason' <<<"$check")
    echo "$reason"
    stack_print_next_step \
      "Refresh the materialization if needed: stack trunk materialize --stack $(stack_shell_quote "$stack_name")" \
      "Prepare approval: pg prepare-trunk --stack $(stack_shell_quote "$stack_name") --what <what> --why <why> --approach <approach>" \
      "Ask the human to review: pg trunk --stack $(stack_shell_quote "$stack_name")"
    return 0
  fi

  local manifest_json trunk_ref trunk_tip
  manifest_json=$(stack_trunk_load_manifest "$stack_name" "")
  trunk_ref=$(stack_trunk_manifest_field "$manifest_json" "trunk")
  trunk_tip=$(jq -r '.materialization.trunk_tip // ""' <<<"$check")

  if [[ "$tip_only" == "true" ]]; then
    echo "Trunk push mode: tip only"
    echo "Pushing validation ref:"
    printf '  %s @ %s\n' "$trunk_ref" "${trunk_tip:0:12}"
    echo
    echo "Not pushing item branches:"
    jq -r '.materialization.items[] | [.order_index, .id, .branch, .commit] | @tsv' <<<"$check" |
    while IFS=$'\t' read -r order_index id branch commit_sha; do
      [[ -z "$branch" ]] && continue
      printf '  %s. %s -> %s @ %s\n' "$order_index" "$id" "$branch" "${commit_sha:0:12}"
    done

    if [[ "$dry_run" == "true" ]]; then
      stack_print_next_step "Push validation trunk tip: stack trunk push --stack $(stack_shell_quote "$stack_name") --tip"
      return 0
    fi

    local assert_flow
    assert_flow=$(printf 'push stack trunk tip %s\nbranch %s\nsource %s\napproved tip %s\n' "$stack_name" "$trunk_ref" "$trunk_ref" "$trunk_tip")
    local args=(push --trunk-stack "$stack_name" --branch "$trunk_ref" --source-ref "$trunk_ref" --force-with-lease --assert-flow "$assert_flow")
    [[ -n "$remote" ]] && args+=(--remote "$remote")
    bash "$helper" "${args[@]}"

    stack_print_next_step "Trunk tip push complete for $stack_name."
    return 0
  fi

  echo "Trunk push order: $stack_name"
  jq -r '.materialization.items[] | [.order_index, .id, .branch, .commit] | @tsv' <<<"$check" |
  while IFS=$'\t' read -r order_index id branch commit_sha; do
    [[ -z "$branch" ]] && continue
    printf '  %s. %s -> %s @ %s\n' "$order_index" "$id" "$branch" "${commit_sha:0:12}"
  done

  if [[ "$dry_run" == "true" ]]; then
    stack_print_next_step "Push approved trunk items: stack trunk push --stack $(stack_shell_quote "$stack_name")"
    return 0
  fi

  jq -r '.materialization.items[] | [.id, .branch, .commit] | @tsv' <<<"$check" |
  while IFS=$'\t' read -r id branch commit_sha; do
    [[ -z "$branch" ]] && continue
    local assert_flow
    assert_flow=$(printf 'push stack trunk %s\nitem %s\nbranch %s\nsource %s\napproved commit %s\n' "$stack_name" "$id" "$branch" "$branch" "$commit_sha")
    local args=(push --trunk-stack "$stack_name" --branch "$branch" --source-ref "$branch" --force-with-lease --assert-flow "$assert_flow")
    [[ -n "$remote" ]] && args+=(--remote "$remote")
    bash "$helper" "${args[@]}"
  done

  stack_print_next_step "Trunk push complete for $stack_name."
}

stack_cmd_trunk() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || stack_fail "stack trunk requires a subcommand: init, add, move, remove, status, materialize, or push"
  shift
  case "$sub" in
    init) stack_cmd_trunk_init "$@" ;;
    add) stack_cmd_trunk_add "$@" ;;
    move) stack_cmd_trunk_move "$@" ;;
    remove) stack_cmd_trunk_remove "$@" ;;
    status) stack_cmd_trunk_status "$@" ;;
    materialize) stack_cmd_trunk_materialize "$@" ;;
    push) stack_cmd_trunk_push "$@" ;;
    -h|--help|help) stack_usage ;;
    *) stack_fail "unknown trunk subcommand: $sub" ;;
  esac
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
    if ! stack_rebase_onto "$target" "$off" "$cur"; then
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

stack_insert_plan_order() {
  local after_branch="$1" branch="$2" parent_map="$3" base="$4"
  local ordered after_line descendants selected
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  after_line=$(awk -F'\t' -v b="$after_branch" '$2 == b { print; exit }' <<<"$ordered")
  [[ -n "$after_line" ]] || stack_fail "insertion point is not in the selected stack: $after_branch"
  descendants=$(stack_descendants_ordered "$after_branch" "$ordered")
  selected="$after_line"
  [[ -n "$descendants" ]] && selected="${selected}"$'\n'"${descendants}"
  selected=$(stack_remove_subtree_from_ordered "$branch" "$selected")
  stack_remove_existing_git_descendants_from_ordered "$branch" "$selected"
}

stack_insert_run_preflight() {
  local branch="$1" after_branch="$2" insert_base="$3" children_blob="$4" dry_run="${5:-false}"
  local after_tip branch_tip
  after_tip=$(git rev-parse --verify "$after_branch")
  branch_tip=$(git rev-parse --verify "$branch")

  if [[ "$branch_tip" == "$after_tip" ]]; then
    stack_fail "$branch has no commits to insert after $after_branch"
  fi

  if [[ "$dry_run" == "true" ]]; then
    echo "  (dry-run) git rebase --onto ${after_branch} ${insert_base:0:8} ${branch}"
  else
    echo "  rebasing inserted branch ${branch} onto ${after_branch} (off ${insert_base:0:8})"
    if ! stack_rebase_onto "$after_branch" "$insert_base" "$branch"; then
      git rebase --abort >/dev/null 2>&1 || true
      stack_fail "rebase failed for inserted branch ${branch}. Resolve manually:
  git rebase --onto ${after_branch} ${insert_base} ${branch}"
    fi
  fi

  local kids child actions=0
  kids=$(awk -F'\t' -v p="$after_branch" '$1 == p {print $2}' <<<"$children_blob")
  for child in $kids; do
    [[ -z "$child" ]] && continue
    stack_adopt_rebase_descendant "$child" "$branch" "$after_tip" "$dry_run" "$children_blob"
    actions=$((actions + ${STACK_ADOPT_REBASES:-0}))
  done

  if (( actions == 0 )); then
    echo "  no selected descendants to restack"
  elif [[ "$dry_run" != "true" ]]; then
    echo "  restacked ${actions} descendant branch(es)"
  fi
}

# stack insert — place a local branch after an existing stack branch and
# cascade-rebase the selected descendants onto the inserted branch in scratch.
stack_cmd_insert() {
  local dry_run="false" keep_scratch="false"
  local base_override="" prefix_override="" branch="" after_branch="" after_pr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift ;;
      --keep-scratch) keep_scratch="true"; shift ;;
      --branch) branch="${2:-}"; [[ -n "$branch" ]] || stack_fail "--branch requires a branch"; shift 2 ;;
      --after) after_branch="${2:-}"; [[ -n "$after_branch" ]] || stack_fail "--after requires a branch"; shift 2 ;;
      --after-pr) after_pr="${2:-}"; [[ "$after_pr" =~ ^[0-9]+$ ]] || stack_fail "--after-pr requires a PR number"; shift 2 ;;
      --base)   base_override="${2:-}"; [[ -n "$base_override" ]] || stack_fail "--base requires a ref"; shift 2 ;;
      --prefix) prefix_override="${2:-}"; [[ -n "$prefix_override" ]] || stack_fail "--prefix requires a value"; shift 2 ;;
      -h|--help) stack_usage; return 0 ;;
      *) stack_fail "unknown insert flag: $1" ;;
    esac
  done
  stack_require jq
  stack_repo_root >/dev/null
  [[ -n "$branch" ]] || stack_fail "stack insert requires --branch BRANCH"
  if [[ -n "$after_branch" && -n "$after_pr" ]]; then
    stack_fail "choose exactly one insertion point: --after or --after-pr"
  fi
  [[ -n "$after_branch" || -n "$after_pr" ]] \
    || stack_fail "stack insert requires --after BRANCH or --after-pr N"

  local dirty
  dirty=$(git status --porcelain 2>/dev/null)
  [[ -z "$dirty" ]] || stack_fail "working tree dirty. git stash or commit first."

  local base prefix local_parent_map parent_map prs rerun_cmd
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  stack_local_ref_exists "$branch" \
    || stack_fail "branch to insert not found locally: $branch"
  case "$branch" in
    "$prefix"*) ;;
    *) stack_fail "branch to insert must be under stack prefix $prefix: $branch" ;;
  esac

  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  prs=$(stack_fetch_prs_for_scope "$after_pr")
  parent_map="$local_parent_map"
  if [[ -n "$after_pr" ]]; then
    after_branch=$(stack_pr_branch_by_number "$prs" "$after_pr")
    [[ -n "$after_branch" ]] || stack_fail "open PR not found in stack data: #$after_pr"
    stack_local_ref_exists "$after_branch" \
      || stack_fail "PR #$after_pr branch not found locally: $after_branch"
    parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
    parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$after_pr" "true")
    stack_warn_topology_mismatches "$parent_map" "$local_parent_map" "$prs" "$base"
  else
    stack_local_ref_exists "$after_branch" \
      || stack_fail "insertion point branch not found locally: $after_branch"
    stack_parent_map_contains_branch "$after_branch" "$local_parent_map" \
      || stack_fail "insertion point is not under stack prefix $prefix: $after_branch"
  fi

  [[ "$branch" != "$after_branch" ]] || stack_fail "--branch and insertion point cannot be the same branch"
  if git merge-base --is-ancestor "$branch" "$after_branch" 2>/dev/null; then
    stack_fail "$branch is an ancestor of $after_branch; inserting it there would create an invalid stack order"
  fi

  local selected_ordered children_blob insert_base insert_commits tracked_branches pre_tips
  selected_ordered=$(stack_insert_plan_order "$after_branch" "$branch" "$parent_map" "$base")
  children_blob=$(stack_children_blob_from_ordered "$selected_ordered")
  insert_base=$(stack_parent_from_map "$branch" "$local_parent_map")
  if [[ -z "$insert_base" ]]; then
    insert_base=$(git merge-base "$after_branch" "$branch" 2>/dev/null || true)
  fi
  [[ -n "$insert_base" ]] || stack_fail "could not determine base for inserted branch $branch"
  git rev-parse --verify "$insert_base" >/dev/null 2>&1 \
    || stack_fail "inserted branch base not found: $insert_base"
  insert_commits=$(git rev-list --count "$insert_base..$branch" 2>/dev/null || echo 0)
  (( insert_commits > 0 )) || stack_fail "$branch has no commits to insert relative to $insert_base"

  local after_arg=""
  [[ -z "$after_pr" ]] && after_arg="$after_branch"
  rerun_cmd=$(stack_insert_rerun_command "$base_override" "$prefix_override" "$branch" "$after_arg" "$after_pr" "$keep_scratch")
  stack_debug "insert base=$base prefix=$prefix branch=$branch after=$after_branch after_pr=${after_pr:-none} dry_run=$dry_run keep_scratch=$keep_scratch"

  echo "Insert plan:"
  echo "  Insert branch: $branch"
  echo "  After branch:  $after_branch"
  if [[ -n "$after_pr" ]]; then
    echo "  Scope:         GitHub PR DAG rooted at #$after_pr (baseRefName children)"
    echo "  PR bases:      not changed by this command"
  else
    echo "  Scope:         local descendants under $prefix"
  fi

  tracked_branches=$(
    printf '%s\n' "$branch"
    stack_branch_list_from_ordered "$selected_ordered" | awk -v after="$after_branch" '$0 != after'
  )
  tracked_branches=$(awk 'NF && !seen[$0]++' <<<"$tracked_branches")
  pre_tips=$(while read -r b; do
    [[ -z "$b" ]] && continue
    printf '%s\t%s\n' "$b" "$(git rev-parse --verify "$b" 2>/dev/null || echo '')"
  done <<<"$tracked_branches")

  echo
  echo "Planned rebases:"
  if [[ "$dry_run" == "true" ]]; then
    stack_insert_run_preflight "$branch" "$after_branch" "$insert_base" "$children_blob" "true"
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Run the preflight and apply refs: $rerun_cmd"
    return 0
  fi

  local repo_root current_branch scratch_root scratch_repo script_path
  repo_root=$(stack_repo_root)
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/stack-insert.XXXXXX")
  scratch_repo="$scratch_root/repo"
  script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  STACK_INSERT_CLEANUP_ROOT="$scratch_root"
  STACK_INSERT_KEEP_SCRATCH="$keep_scratch"
  trap 'if [[ "${STACK_INSERT_KEEP_SCRATCH:-}" != "true" && -n "${STACK_INSERT_CLEANUP_ROOT:-}" ]]; then rm -rf "$STACK_INSERT_CLEANUP_ROOT"; fi' EXIT

  echo "Creating scratch clone: $scratch_repo"
  stack_sync_create_scratch "$repo_root" "$scratch_repo" "$current_branch" "$local_parent_map"

  local preflight_log="$scratch_root/preflight.log"
  echo "Preflighting insert in scratch..."
  set +e
  (
    cd "$scratch_repo"
    stack_insert_run_preflight "$branch" "$after_branch" "$insert_base" "$children_blob" "false"
  ) >"$preflight_log" 2>&1
  local preflight_rc=$?
  set -e
  sed 's/^/  /' "$preflight_log"

  if (( preflight_rc != 0 )); then
    stack_insert_report_failure "$scratch_repo" "$preflight_rc" "$keep_scratch" "$script_path" "$branch" "$after_arg" "$after_pr" "$base" "$prefix"
    return 1
  fi

  local scratch_tips moved_tips
  scratch_tips=$(while read -r b; do
    [[ -z "$b" ]] && continue
    printf '%s\t%s\n' "$b" "$(git -C "$scratch_repo" rev-parse --verify "$b" 2>/dev/null || echo '')"
  done <<<"$tracked_branches")
  moved_tips=$(stack_sync_moved_tips "$pre_tips" "$scratch_tips")

  if [[ -n "$moved_tips" ]]; then
    stack_sync_apply_refs "$scratch_repo" "$moved_tips"
  fi

  local leases moved=0 moved_branches="" stale_branches="" b old_sha new_sha lease
  leases=$(stack_fetch_leases)
  echo
  while IFS=$'\t' read -r b old_sha new_sha; do
    [[ -z "$b" ]] && continue
    [[ "$old_sha" == "$new_sha" ]] && continue
    moved=$((moved + 1))
    moved_branches="${moved_branches}${moved_branches:+, }$b"
    lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
    if [[ "$lease" != "null" ]]; then
      stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
      stale_branches="${stale_branches}${stale_branches:+, }$b"
    else
      echo "  tip moved: $b ($old_sha -> $new_sha)"
    fi
  done <<<"$moved_tips"

  if (( moved == 0 )); then
    echo "No branches moved."
    stack_print_next_step \
      "Refs unchanged." \
      "Inspect state: $(stack_status_rerun_command "$base_override" "$prefix_override" "" "false")"
  else
    local lease_line
    if [[ -n "$stale_branches" ]]; then
      lease_line="Stale push-gate leases: $stale_branches"
    else
      lease_line="No existing push-gate leases became stale."
    fi
    stack_print_next_step \
      "Inserted $branch after $after_branch." \
      "Restacked branches: $moved_branches" \
      "$lease_line" \
      "Run affected tests, then inspect: $(stack_status_rerun_command "$base_override" "$prefix_override" "" "false")" \
      "When ready, dry-run push: $(stack_push_rerun_command "$base_override" "$prefix_override" "${after_pr:-}" "${after_pr:+true}") --dry-run"
  fi

  if [[ "$keep_scratch" == "true" ]]; then
    stack_insert_print_debug "$scratch_repo" "$script_path" "$branch" "$after_arg" "$after_pr" "$base" "$prefix"
  fi
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
  stack_enable_rerere_for_repo "$(stack_repo_root)"

  local current
  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -n "$pr_filter" ]]; then
    local prs_for_branch
    prs_for_branch=$(stack_fetch_prs_for_scope "$pr_filter")
    branch_override=$(stack_pr_branch_by_number "$prs_for_branch" "$pr_filter")
    [[ -n "$branch_override" ]] || stack_fail "open PR not found in stack data: #$pr_filter"
  fi
  if [[ -n "$branch_override" ]]; then
    current="$branch_override"
  fi
  [[ -n "$current" && "$current" != "HEAD" ]] || stack_fail "stack squash requires a checked-out branch or --branch/--pr"

  local base prefix local_parent_map parent_map ordered current_line parent commit_count prs push_children
  base=$(stack_upstream_ref "$base_override")
  prefix=$(stack_prefix "$prefix_override")
  push_children="false"
  [[ -n "$pr_filter" ]] && push_children="true"
  local_parent_map=$(stack_build_parent_map "$prefix" "$base")
  prs=$(stack_fetch_prs_for_scope "$pr_filter")
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
    stack_print_next_step \
      "No squash needed." \
      "Inspect state: $(stack_status_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$push_children")"
    return 0
  fi
  if (( commit_count == 1 )); then
    echo "$current already has one incremental commit relative to $parent."
    stack_print_next_step \
      "No squash needed." \
      "Push when ready: $(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$push_children")"
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
    stack_print_next_step \
      "Refs unchanged in dry-run." \
      "Run the same squash command without --dry-run, then push: $(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$push_children")"
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
    if ! stack_rebase_onto "$child_parent" "$old_parent_tip" "$child"; then
      git rebase --abort >/dev/null 2>&1 || true
      git checkout "$current" >/dev/null 2>&1 || true
      stack_fail "rebase failed for ${child}. Resolve manually:
  git rebase --onto ${child_parent} ${old_parent_tip} ${child}"
    fi
  done <<<"$descendants"

  git checkout "$current" >/dev/null 2>&1 || true

  local leases moved=0 moved_branches="" stale_branches=""
  leases=$(stack_fetch_leases)
  local b old_sha new_sha lease
  while IFS=$'\t' read -r b old_sha; do
    [[ -z "$b" ]] && continue
    new_sha=$(git rev-parse --verify "$b" 2>/dev/null || echo "")
    [[ "$old_sha" == "$new_sha" ]] && continue
    moved=$((moved + 1))
    moved_branches="${moved_branches}${moved_branches:+, }$b"
    lease=$(jq -c --arg k "$b" '.[$k] // null' <<<"$leases")
    if [[ "$lease" != "null" ]]; then
      stack_warn "lease stale: $b tip moved ($old_sha -> $new_sha). Re-run \`pg\` to refresh."
      stale_branches="${stale_branches}${stale_branches:+, }$b"
    else
      echo "  tip moved: $b ($old_sha -> $new_sha)"
    fi
  done <<<"$pre_tips"

  [[ "$old_current_tip" != "$(git rev-parse --verify "$current")" ]] || stack_fail "squash did not move $current"
  (( moved > 0 )) || echo "No branches moved."
  if (( moved > 0 )); then
    local lease_line
    if [[ -n "$stale_branches" ]]; then
      lease_line="Stale push-gate leases: $stale_branches"
    else
      lease_line="No existing push-gate leases became stale."
    fi
    stack_print_next_step \
      "Restacked branches: $moved_branches" \
      "$lease_line" \
      "Run affected tests, then approve/push with: $(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$push_children")"
  else
    stack_print_next_step \
      "Squash completed." \
      "Run affected tests, then approve/push with: $(stack_push_rerun_command "$base_override" "$prefix_override" "$pr_filter" "$push_children")"
  fi
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
  prs=$(stack_fetch_prs_for_scope "$pr_filter")
  parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
  if [[ -n "$pr_filter" ]]; then
    parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$pr_filter" "$include_children")
  fi
  stack_warn_topology_mismatches "$parent_map" "$local_parent_map" "$prs" "$base"

  local ordered
  ordered=$(echo "$parent_map" | stack_order_tree "$base")
  if [[ -z "$ordered" ]]; then
    echo "No stacked branches under $prefix."
    stack_print_next_step "No push needed for this scope."
    return 0
  fi

  local total=0
  while IFS=$'\t' read -r d n p a b; do
    [[ -z "$n" ]] && continue
    total=$((total + 1))
  done <<<"$ordered"

  if [[ "$dry_run" == "true" ]]; then
    echo "Push order:"
    local order_idx=0 order_pr order_pr_num order_base
    while IFS=$'\t' read -r d n p a b; do
      [[ -z "$n" ]] && continue
      order_idx=$((order_idx + 1))
      order_pr=$(jq -c --arg k "$n" '.[$k] // null' <<<"$prs")
      if [[ "$order_pr" == "null" ]]; then
        order_base=$(stack_pr_base_from_parent "$p")
        printf '  %d. %s (new PR base %s)\n' "$order_idx" "$n" "$order_base"
      else
        order_pr_num=$(jq -r '.number' <<<"$order_pr")
        printf '  %d. %s (#%s)\n' "$order_idx" "$n" "$order_pr_num"
      fi
    done <<<"$ordered"
    echo
  fi

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

  local idx=0 pushed=0 skipped=0 first_approval_name="" first_approval_idx=0 delayed_after_first=""
  local depth name parent ahead behind
  while IFS=$'\t' read -r depth name parent ahead behind; do
    [[ -z "$name" ]] && continue
    idx=$((idx + 1))
    if [[ "$dry_run" == "true" && -n "$first_approval_name" ]]; then
      delayed_after_first="${delayed_after_first}${delayed_after_first:+, }$name"
    fi

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
    if [[ -n "$pr_num" ]]; then
      base_for_log="$parent"
    else
      base_for_log="${remote_ref:-$parent}"
    fi
    approach=$(git log "${base_for_log}..${name}" --format='%s' 2>/dev/null \
                | head -5 | paste -sd ';' -)
    [[ -z "$approach" ]] && approach="straightforward"

    if [[ "$dry_run" == "true" ]]; then
      echo "[$idx/$total] $name: (dry-run) lease missing/stale; would: pg prepare \\"
      echo "    --what '$what' --why '$why' --approach '$approach'"
      if [[ -z "$pr_num" ]]; then
        echo "    then push branch and create draft PR with base '$create_pr_base'"
      fi
      if [[ -z "$first_approval_name" ]]; then
        first_approval_name="$name"
        first_approval_idx="$idx"
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

[$idx/$total] $name prepared.

Next step:
  Human approval: pg -C $repo_root
  Agent re-run: $rerun_cmd

(Stopping here — $pushed pushed, $skipped skipped before this branch.)
EOM
    stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd" "needs approval"
    return 0
  done <<<"$ordered"

  restore_branch
  echo
  echo "Done. Pushed $pushed, skipped $skipped, total $total."
  if [[ "$dry_run" == "true" ]]; then
    if [[ -n "$first_approval_name" ]]; then
      local delayed_line
      if [[ -n "$delayed_after_first" ]]; then
        delayed_line="Downstream approvals wait: $delayed_after_first. Push-gate leases are per branch tip, so approve one changed tip at a time."
      else
        delayed_line="No downstream approvals are reached before the first approval."
      fi
      stack_print_next_step \
        "First live push action: $rerun_cmd will prepare $first_approval_name at position $first_approval_idx/$total." \
        "Then human approval: pg -C $repo_root" \
        "Then agent re-run: $rerun_cmd" \
        "$delayed_line"
      stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd" "ready to push"
    else
      stack_print_next_step \
        "No blocking approvals found in dry-run." \
        "Run live push: $rerun_cmd"
      stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd" "ready to push"
    fi
  else
    stack_print_next_step \
      "Push loop complete." \
      "Update PR descriptions for changed PRs, using each PR's GitHub base."
    stack_push_print_agent_handoff "$ordered" "$prs" "$rerun_cmd" "needs PR description update"
  fi
}

stack_usage() {
  cat <<'EOF'
Usage: stack <command> [options]

Commands:
  status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]
    Show one-table view merging git topology, gh PR state, and pg leases.
    With --pr N, scope the view to that PR; --children follows GitHub PR
    baseRefName children instead of broad local branch prefix. Human output
    ends with a guided Next step block; --json stays machine-readable.

  checkout --pr N [--base REF] [--prefix PREFIX]
    Check out the local branch for an open PR, refusing dirty worktrees, then
    print the scoped stack context and exact edit -> commit -> squash -> test
    -> push workflow for middle-stack edits.

  sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
    Fetch the base remote, preflight cascade-rebase in a throwaway scratch
    clone, then atomically apply branch ref updates if preflight succeeds.
    Combines a PR-state pass with git-branchless patch-id detection.

  insert --branch BRANCH (--after BRANCH|--after-pr N)
         [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
    Insert a local branch after an existing stack branch. The inserted branch
    is rebased onto the insertion point, selected descendants are rebased onto
    the inserted branch in a scratch clone, and moved refs are applied
    atomically. --after uses local ancestry; --after-pr scopes descendants by
    GitHub PR baseRefName.

  trunk init --name NAME --base REF --trunk BRANCH
    Create or update a Dolt-backed stack manifest. The private trunk is per
    stack and is not main.

  trunk add --stack NAME --id ID --branch BRANCH [--pr N] [--after ID]
            [--base REF]
    Add or update one item in the Dolt-backed stack manifest.

  trunk move --stack NAME --id ID (--after ID|--before ID|--first|--last)
             [--dry-run]
    Reorder an existing item in the Dolt-backed stack manifest. This changes
    manifest order only; run trunk materialize to rebuild the private trunk.

  trunk remove --stack NAME --id ID [--dry-run]
    Remove one item from the Dolt-backed stack manifest and compact order.

  trunk status --name NAME|--stack NAME|--manifest PATH [--json]
               [--base REF] [--prefix PREFIX]
  trunk materialize --name NAME|--stack NAME|--manifest PATH
                   [--dry-run] [--keep-scratch] [--base REF]
                   [--prefix PREFIX]
    Use a per-stack private trunk manifest as the source of truth. --name and
    --stack read the manifest from push-gate's Dolt store; --manifest is a
    compatibility/import path. Materialize builds the trunk in scratch by
    replaying item branches in manifest order, then atomically moves the trunk
    ref and each item branch pointer to the corresponding trunk commit. If the
    checked-out branch moves, the worktree is refreshed to the new HEAD.
    Dolt is required for --stack: brew install dolt && dolt version.

  trunk push --stack NAME [--tip] [--dry-run] [--remote NAME]
    Push each approved item commit from the materialized private trunk through
    push-gate's trunk lease flow. With --tip, push only the private trunk ref
    as the composed-stack validation target and leave item branches untouched.

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

Guided workflow:
  Prefer PR-scoped commands when a PR number is known:
    stack status --pr N --children
    stack checkout --pr N
    stack push --pr N --children
  Every human-readable command prints Next step: with the safe command or
  human approval action to run next. Topology warnings mean GitHub PR
  baseRefName wins; local ancestry is stale/diagnostic unless the warning is
  an expected Dolt trunk materialization note.

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
    checkout)      stack_cmd_checkout "$@" ;;
    sync)          stack_cmd_sync "$@" ;;
    insert)        stack_cmd_insert "$@" ;;
    trunk)         stack_cmd_trunk "$@" ;;
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
    __insert-preflight)
      stack_require jq
      local branch="" after_branch="" after_pr="" base_override="" prefix_override=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --branch) branch="${2:-}"; shift 2 ;;
          --after) after_branch="${2:-}"; shift 2 ;;
          --after-pr) after_pr="${2:-}"; shift 2 ;;
          --base) base_override="${2:-}"; shift 2 ;;
          --prefix) prefix_override="${2:-}"; shift 2 ;;
          *) stack_fail "unknown __insert-preflight flag: $1" ;;
        esac
      done
      [[ -n "$branch" ]] || stack_fail "__insert-preflight requires --branch"
      [[ -n "$after_branch" || -n "$after_pr" ]] || stack_fail "__insert-preflight requires --after or --after-pr"
      local base prefix local_parent_map parent_map prs selected_ordered children_blob insert_base
      base=$(stack_upstream_ref "$base_override")
      prefix=$(stack_prefix "$prefix_override")
      local_parent_map=$(stack_build_parent_map "$prefix" "$base")
      prs=$(stack_fetch_prs_for_scope "$after_pr")
      parent_map="$local_parent_map"
      if [[ -n "$after_pr" ]]; then
        after_branch=$(stack_pr_branch_by_number "$prs" "$after_pr")
        [[ -n "$after_branch" ]] || stack_fail "open PR not found in stack data: #$after_pr"
        parent_map=$(stack_resolve_parent_map_from_prs "$local_parent_map" "$prs" "$base")
        parent_map=$(stack_filter_parent_map_for_pr "$parent_map" "$prs" "$after_pr" "true")
      fi
      selected_ordered=$(stack_insert_plan_order "$after_branch" "$branch" "$parent_map" "$base")
      children_blob=$(stack_children_blob_from_ordered "$selected_ordered")
      insert_base=$(stack_parent_from_map "$branch" "$local_parent_map")
      [[ -n "$insert_base" ]] || insert_base=$(git merge-base "$after_branch" "$branch" 2>/dev/null || true)
      [[ -n "$insert_base" ]] || stack_fail "could not determine base for inserted branch $branch"
      stack_insert_run_preflight "$branch" "$after_branch" "$insert_base" "$children_blob" "false"
      ;;
    -h|--help|help) stack_usage ;;
    *) stack_fail "unknown command: $cmd (see \`stack --help\`)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  stack_main "$@"
fi
