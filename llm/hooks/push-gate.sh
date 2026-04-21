#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

pg_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

pg_fail() {
  echo "$*" >&2
  return 1
}

pg_helper_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

pg_helper_path() {
  echo "$(pg_helper_dir)/$(basename "${BASH_SOURCE[0]}")"
}

pg_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

pg_git_common_dir() {
  local common_dir repo_root
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  if [[ "$common_dir" != /* ]]; then
    repo_root=$(pg_repo_root) || return 1
    common_dir="$repo_root/$common_dir"
  fi
  echo "$common_dir"
}

pg_store_dir() {
  echo "$(pg_git_common_dir)/push-gate"
}

pg_branch_name() {
  git branch --show-current 2>/dev/null
}

pg_branch_ref() {
  local branch="${1:-}"
  if [[ -z "$branch" ]]; then
    branch=$(pg_branch_name) || return 1
  fi
  if [[ "$branch" == refs/heads/* ]]; then
    echo "$branch"
  else
    echo "refs/heads/$branch"
  fi
}

pg_branch_display() {
  local branch_ref="$1"
  echo "${branch_ref#refs/heads/}"
}

pg_branch_slug() {
  echo "$1" | tr '/: ' '___'
}

pg_repo_name() {
  basename "$(pg_repo_root)"
}

pg_has_remote() {
  git remote | grep -qx "$1"
}

pg_branch_upstream_remote() {
  local branch="${1:-}"
  local upstream=""
  [[ -n "$branch" ]] || return 1
  upstream=$(git rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || true)
  if [[ -n "$upstream" && "$upstream" == */* ]]; then
    echo "${upstream%%/*}"
    return 0
  fi
  return 1
}

pg_remote_url() {
  git remote get-url "$1" 2>/dev/null || true
}

pg_remote_repo_spec() {
  local remote="$1"
  local url
  url=$(pg_remote_url "$remote")
  [[ -n "$url" ]] || return 0
  python3 - "$url" <<'PY'
import re, sys

url = sys.argv[1]
patterns = [
    r'^(?:https?|ssh|git)://(?:[^@/]+@)?([^/]+)/([^/]+)/([^/]+?)(?:\.git)?/?$',
    r'^(?:[^@]+@)?([^:]+):([^/]+)/([^/]+?)(?:\.git)?/?$',
]
for pattern in patterns:
    match = re.match(pattern, url)
    if match:
        host, owner, repo = match.groups()
        print(f"{host}/{owner}/{repo}")
        raise SystemExit(0)
print("")
PY
}

pg_remote_viewer_permission() {
  local remote="$1"
  local repo_spec
  repo_spec=$(pg_remote_repo_spec "$remote")
  [[ -n "$repo_spec" ]] || return 0
  gh repo view "$repo_spec" --json viewerPermission 2>/dev/null | jq -r '.viewerPermission // empty' 2>/dev/null || true
}

pg_remote_is_writable() {
  local remote="$1"
  local permission
  permission=$(pg_remote_viewer_permission "$remote")
  case "$permission" in
    ADMIN|MAINTAIN|WRITE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pg_default_pr_repo() {
  local repo_spec remote
  if pg_has_remote upstream; then
    repo_spec=$(pg_remote_repo_spec upstream)
    if [[ -n "$repo_spec" ]]; then
      echo "$repo_spec"
      return 0
    fi
  fi
  if pg_has_remote origin; then
    repo_spec=$(pg_remote_repo_spec origin)
    if [[ -n "$repo_spec" ]]; then
      echo "$repo_spec"
      return 0
    fi
  fi
  remote=$(git remote | head -n1)
  [[ -n "$remote" ]] || return 1
  repo_spec=$(pg_remote_repo_spec "$remote")
  [[ -n "$repo_spec" ]] || return 1
  echo "$repo_spec"
}

pg_default_remote() {
  local branch="${1:-}"
  local branch_ref="" existing_lease="" lease_remote="" upstream_remote="" remote
  if [[ -n "$branch" ]]; then
    branch_ref=$(pg_branch_ref "$branch")
    existing_lease=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
    if [[ -n "$existing_lease" ]]; then
      lease_remote=$(echo "$existing_lease" | jq -r '.remote // empty')
      if [[ -n "$lease_remote" ]]; then
        echo "$lease_remote"
        return 0
      fi
    fi
    upstream_remote=$(pg_branch_upstream_remote "$branch" || true)
    if [[ -n "$upstream_remote" ]]; then
      echo "$upstream_remote"
      return 0
    fi
  else
    branch=$(pg_branch_name || true)
    if [[ -n "$branch" ]]; then
      upstream_remote=$(pg_branch_upstream_remote "$branch" || true)
      if [[ -n "$upstream_remote" ]]; then
        echo "$upstream_remote"
        return 0
      fi
    fi
  fi
  if pg_has_remote upstream && pg_remote_is_writable upstream; then
    echo "upstream"
    return 0
  fi
  if pg_has_remote origin; then
    echo "origin"
    return 0
  fi
  if pg_has_remote upstream; then
    echo "upstream"
    return 0
  fi
  remote=$(git remote | head -n1)
  [[ -n "$remote" ]] || return 1
  echo "$remote"
}

pg_upstream_ref() {
  local branch
  branch=$(pg_branch_name) || return 1
  git rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" 2>/dev/null || true
}

pg_default_base_ref_snapshot() {
  local upstream remote
  upstream=$(pg_upstream_ref)
  if [[ -n "$upstream" ]]; then
    echo "$upstream"
    return 0
  fi
  remote=$(pg_default_remote || true)
  if [[ -n "$remote" ]] && git show-ref --verify --quiet "refs/remotes/$remote/main"; then
    echo "refs/remotes/$remote/main"
    return 0
  fi
  if [[ -n "$remote" ]] && git show-ref --verify --quiet "refs/remotes/$remote/master"; then
    echo "refs/remotes/$remote/master"
    return 0
  fi
  echo ""
}

pg_find_pr_json() {
  local branch="$1"
  local pr_repo="${2:-}"
  local raw
  if [[ -n "$pr_repo" ]]; then
    raw=$(gh pr list --repo "$pr_repo" --head "$branch" --state open --json number,url 2>/dev/null || true)
  else
    raw=$(gh pr list --head "$branch" --state open --json number,url 2>/dev/null || true)
  fi
  if [[ -z "$raw" ]]; then
    echo "{}"
    return 0
  fi
  echo "$raw" | jq -c '.[0] // {}'
}

pg_default_user_intent() {
  local branch="$1"
  local pr_number="$2"
  if [[ -n "$pr_number" ]]; then
    cat <<EOF
allow pushes for $branch
same branch
same pr #$pr_number
new lease after rewrite
EOF
  else
    cat <<EOF
allow pushes for $branch
same branch
bind pr after first push
new lease after rewrite
EOF
  fi
}

pg_default_assert_flow() {
  local branch="$1"
  local pr_number="$2"
  if [[ -n "$pr_number" ]]; then
    cat <<EOF
update pr #$pr_number
branch $branch
describe change here
no rewrite
EOF
  else
    cat <<EOF
new pr flow
branch $branch
describe change here
no rewrite
EOF
  fi
}

pg_lease_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/leases/$branch_ref.json"
}

pg_pending_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/pending/$branch_ref.json"
}

pg_log_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/logs/$branch_ref.jsonl"
}

pg_ensure_parent_dir() {
  mkdir -p "$(dirname "$1")"
}

pg_render_lease_summary() {
  local file="$1"
  jq -r '
    "Push lease approval",
    "",
    "Repo: " + .repo_name,
    "Branch: " + .branch_name,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Remote: " + .remote,
    "Anchor: " + .approved_anchor,
    "",
    "User intent:",
    (.user_intent // ""),
    "",
    "Agent says push is:",
    (.agent_assertion_template // ""),
    "",
    (if (.approved_scope // null) == null then "Approved scope: (none — single-push anchor-exact lease)" else
      "Approved scope:\n  base_ref:        " + (.approved_scope.base_ref // "") +
      "\n  paths:           " + ((.approved_scope.paths // []) | join(", ")) +
      "\n  subjects:        " + ((.approved_scope.subjects // []) | join(", ")) +
      "\n  max_commits:     " + ((.approved_scope.max_commits // 0) | tostring) +
      "\n  max_added_lines: " + ((.approved_scope.max_added_lines // 0) | tostring)
    end)
  ' "$file"
}

pg_migration_help() {
  cat <<'EOF'
Durable leases replaced minute windows.
Use `pg` or `push-gate` with no numeric argument to generate an approval draft.
Example:
  pg
  pg push --assert-flow $'update pr #123\nbranch mho/example\nno rewrite'
EOF
}

pg_parse_common_flag() {
  local arg="$1"
  [[ "$arg" =~ ^[0-9]+$ ]]
}

pg_parse_push_command() {
  local command="$1"
  python3 - "$command" <<'PY'
import json, shlex, sys

cmd = sys.argv[1]
result = {
    "is_push": False,
    "remote": None,
    "source_ref": None,
    "target_branch": None,
    "force_with_lease": False,
}
try:
    tokens = shlex.split(cmd)
except Exception as exc:
    result["error"] = f"Unable to parse git push command: {exc}"
    print(json.dumps(result))
    raise SystemExit(0)

git_idx = None
for i, token in enumerate(tokens):
    if token == "git":
        git_idx = i
        break
if git_idx is None or git_idx + 1 >= len(tokens) or tokens[git_idx + 1] != "push":
    print(json.dumps(result))
    raise SystemExit(0)

result["is_push"] = True
args = tokens[git_idx + 2 :]
remote = None
refspecs = []
skip_next = False
for i, token in enumerate(args):
    if skip_next:
        skip_next = False
        continue
    if token == "--":
        refspecs.extend(args[i + 1 :])
        break
    if token.startswith("-"):
        if token == "--force-with-lease":
            result["force_with_lease"] = True
        if token in {"--repo"}:
            skip_next = True
        continue
    if remote is None:
        remote = token
    else:
        refspecs.append(token)

source_ref = None
target_branch = None
if refspecs:
    refspec = refspecs[0]
    if ":" in refspec:
      source_ref, target_branch = refspec.split(":", 1)
    else:
      source_ref = refspec
      target_branch = refspec
    if source_ref == "":
      source_ref = None
    if target_branch == "HEAD" or target_branch == "":
      target_branch = None
    if source_ref and source_ref.startswith("refs/heads/"):
      source_ref = source_ref[len("refs/heads/"):]
    if target_branch and target_branch.startswith("refs/heads/"):
      target_branch = target_branch[len("refs/heads/"):]

result["remote"] = remote
result["source_ref"] = source_ref
result["target_branch"] = target_branch
print(json.dumps(result))
PY
}

pg_load_lease_for_ref() {
  local branch_ref="$1"
  local path
  path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$path" ]] || return 1
  cat "$path"
}

pg_pr_json_for_branch() {
  local branch="$1"
  local pr_repo="${2:-}"
  [[ -n "$branch" ]] || return 1
  pg_find_pr_json "$branch" "$pr_repo"
}

pg_validate_pr_binding() {
  local branch_ref="$1"
  local lease_json="$2"
  local branch_name pr_mode pr_repo expected_number expected_url actual_pr actual_number actual_url
  branch_name=$(pg_branch_display "$branch_ref")
  pr_mode=$(echo "$lease_json" | jq -r '.pr_mode')
  [[ "$pr_mode" == "bound" ]] || return 0
  pr_repo=$(echo "$lease_json" | jq -r '.pr_repo // empty')
  expected_number=$(echo "$lease_json" | jq -r '.pr_number // empty')
  expected_url=$(echo "$lease_json" | jq -r '.pr_url // empty')
  actual_pr=$(pg_pr_json_for_branch "$branch_name" "$pr_repo")
  actual_number=$(echo "$actual_pr" | jq -r '.number // empty')
  actual_url=$(echo "$actual_pr" | jq -r '.url // empty')
  if [[ -z "$actual_number" ]]; then
    pg_fail "Blocked: bound lease expects PR #$expected_number for $branch_name${pr_repo:+ in $pr_repo}, but no open PR was found. Run: pg bind-pr --auto or create a new lease."
    return 1
  fi
  if [[ -n "$expected_number" && "$expected_number" != "$actual_number" ]]; then
    pg_fail "Blocked: lease for $branch_name is bound to PR #$expected_number, but that branch now maps to PR #$actual_number. Rebind PR metadata or create a new lease."
    return 1
  fi
  if [[ -n "$expected_url" && -n "$actual_url" && "$expected_url" != "$actual_url" ]]; then
    pg_fail "Blocked: lease for $branch_name is bound to $expected_url, but that branch now maps to $actual_url. Rebind PR metadata or create a new lease."
    return 1
  fi
}

# Auto-detect a "scope" fingerprint from the current branch state relative to
# the base ref. Produces a JSON object the user can edit at approval time.
#   paths:             changed file paths as globs (literal path = glob)
#   subjects:          keyword hints from commit subjects (lowercased, tokenized)
#   max_commits:       current commit count + buffer
#   max_added_lines:   current added-line count * 1.5 + 200
# Emits "null" if no base ref is available.
pg_detect_scope() {
  local base_ref paths subjects count added buffer_commits buffer_lines
  base_ref=$(pg_default_base_ref_snapshot)
  if [[ -z "$base_ref" ]] || ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "null"
    return 0
  fi
  paths=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))')
  subjects=$(git log --format='%s' "$base_ref"..HEAD 2>/dev/null \
    | tr 'A-Z' 'a-z' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 3' \
    | grep -vE '^(the|and|for|fix|add|use|new|ref|feat|chore|docs|test|into|from|with|this|that|when|where|why|how|what|also|not|but|all|any|can|did|does|has|have|had|was|were|been|being|make|made|set|get|run|put)$' \
    | sort -u \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  added=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+' || echo 0)
  [[ -z "$added" ]] && added=0
  buffer_commits=$(( count + 3 ))
  buffer_lines=$(( added * 3 / 2 + 200 ))
  jq -n \
    --arg base "$base_ref" \
    --argjson paths "${paths:-[]}" \
    --argjson subjects "${subjects:-[]}" \
    --argjson max_commits "$buffer_commits" \
    --argjson max_added_lines "$buffer_lines" \
    '{base_ref: $base, paths: $paths, subjects: $subjects, max_commits: $max_commits, max_added_lines: $max_added_lines}'
}

# Validate that the current HEAD diff against lease's base_ref stays within
# the approved scope. Emits {allowed, reason}.
pg_validate_scope() {
  local lease_json="$1"
  local scope base_ref paths subjects max_commits max_added
  local changed_files count added

  scope=$(echo "$lease_json" | jq -c '.approved_scope // null')
  if [[ "$scope" == "null" ]]; then
    jq -n '{allowed:true}'
    return 0
  fi

  base_ref=$(echo "$scope" | jq -r '.base_ref // empty')
  if [[ -z "$base_ref" ]] || ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    jq -n '{allowed:true, note: "scope base_ref unavailable, skipping scope check"}'
    return 0
  fi

  # Paths allowlist
  changed_files=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null)
  local allow_paths_json allow_paths_count
  allow_paths_json=$(echo "$scope" | jq -c '.paths // []')
  allow_paths_count=$(echo "$allow_paths_json" | jq 'length')
  if [[ "$allow_paths_count" -gt 0 ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local ok="false" pat
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$f" == $pat ]] || [[ "$f" == "$pat" ]]; then
          ok="true"
          break
        fi
      done < <(echo "$allow_paths_json" | jq -r '.[]')
      if [[ "$ok" != "true" ]]; then
        jq -n --arg file "$f" '{allowed:false, reason:("Blocked: file \($file) is outside approved_scope.paths. Re-run `pg` to re-approve, or set PG_SCOPE_OVERRIDE=1 for a one-time bypass.")}'
        return 0
      fi
    done <<<"$changed_files"
  fi

  # Commit cap
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  max_commits=$(echo "$scope" | jq -r '.max_commits // 0')
  if [[ "$max_commits" -gt 0 && "$count" -gt "$max_commits" ]]; then
    jq -n --arg count "$count" --arg cap "$max_commits" '{allowed:false, reason:("Blocked: \($count) commits since base exceeds approved_scope.max_commits (\($cap)). Re-run `pg`.")}'
    return 0
  fi

  # Added-line cap
  added=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+')
  [[ -z "$added" ]] && added=0
  max_added=$(echo "$scope" | jq -r '.max_added_lines // 0')
  if [[ "$max_added" -gt 0 && "$added" -gt "$max_added" ]]; then
    jq -n --arg a "$added" --arg cap "$max_added" '{allowed:false, reason:("Blocked: \($a) added lines since base exceeds approved_scope.max_added_lines (\($cap)). Re-run `pg`.")}'
    return 0
  fi

  # Subject keyword match (every new commit must hit ≥1 approved keyword)
  local subj_count subj_list
  subj_list=$(echo "$scope" | jq -r '.subjects // [] | .[]')
  subj_count=$(echo "$scope" | jq -r '.subjects // [] | length')
  if [[ "$subj_count" -gt 0 ]]; then
    local subjects_lc
    subjects_lc=$(git log --format='%s' "$base_ref"..HEAD 2>/dev/null | tr 'A-Z' 'a-z')
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      local hit="false" kw
      while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        if [[ "$s" == *"$kw"* ]]; then
          hit="true"
          break
        fi
      done <<<"$subj_list"
      if [[ "$hit" != "true" ]]; then
        jq -n --arg s "$s" '{allowed:false, reason:("Blocked: commit subject \"\($s)\" does not match any keyword in approved_scope.subjects. Re-run `pg` if this is intended scope expansion.")}'
        return 0
      fi
    done <<<"$subjects_lc"
  fi

  jq -n '{allowed:true}'
}

pg_validate_push_guard() {
  local command="$1"
  local parsed is_push remote source_ref target_branch force_with_lease current_branch lease_branch branch_ref current_head
  local lease_json lease_remote lease_status approved_anchor pending_path pending_json pending_remote pending_head pending_branch_ref
  local branch_upstream

  parsed=$(pg_parse_push_command "$command")
  is_push=$(echo "$parsed" | jq -r '.is_push')
  [[ "$is_push" == "true" ]] || {
    jq -n '{allowed:true}'
    return 0
  }

  current_branch=$(pg_branch_name 2>/dev/null || true)
  current_head=$(git rev-parse HEAD 2>/dev/null || true)

  remote=$(echo "$parsed" | jq -r '.remote // empty')
  source_ref=$(echo "$parsed" | jq -r '.source_ref // empty')
  target_branch=$(echo "$parsed" | jq -r '.target_branch // empty')
  force_with_lease=$(echo "$parsed" | jq -r '.force_with_lease')
  [[ -n "$remote" ]] || remote=$(pg_default_remote 2>/dev/null || true)
  if [[ -n "$target_branch" ]]; then
    lease_branch="$target_branch"
  else
    lease_branch="$current_branch"
  fi
  if [[ -z "$lease_branch" ]]; then
    jq -n --arg reason "Blocked: detached HEAD pushes require an explicit target branch like HEAD:<branch>. Use pg push --branch <branch> --source-ref HEAD." '{allowed:false, reason:$reason}'
    return 0
  fi
  [[ -n "$target_branch" ]] || target_branch="$lease_branch"
  branch_ref=$(pg_branch_ref "$lease_branch")

  if [[ "$remote" =~ ^(origin|upstream)$ && "$target_branch" =~ ^(main|master)$ ]]; then
    jq -n --arg reason "Blocked: pushing directly to $remote/$target_branch is not allowed." '{allowed:false, reason:$reason}'
    return 0
  fi

  branch_upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  if [[ -n "$current_branch" && "$lease_branch" == "$current_branch" && "$branch_upstream" =~ ^(origin|upstream)/(main|master)$ && ! "$current_branch" =~ ^(main|master)$ ]]; then
    jq -n --arg reason "Blocked: branch '$current_branch' tracks $branch_upstream. Re-set upstream first: git branch --set-upstream-to=origin/$current_branch" '{allowed:false, reason:$reason}'
    return 0
  fi

  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  if [[ -z "$lease_json" ]]; then
    jq -n --arg reason "Blocked: git push requires a durable lease for $lease_branch. Ask the user to run: cd $(pg_repo_root) && pg draft-approve --branch $lease_branch" '{allowed:false, reason:$reason}'
    return 0
  fi

  lease_status=$(echo "$lease_json" | jq -r '.status')
  lease_remote=$(echo "$lease_json" | jq -r '.remote')
  if [[ "$lease_status" != "active" ]]; then
    jq -n --arg reason "Blocked: push lease for $lease_branch is not active. Generate a new approval draft with pg." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$lease_remote" != "$remote" ]]; then
    jq -n --arg reason "Blocked: lease for $lease_branch is scoped to remote '$lease_remote', but push targets '$remote'. Generate a new draft or use the leased remote." '{allowed:false, reason:$reason}'
    return 0
  fi

  approved_anchor=$(echo "$lease_json" | jq -r '.approved_anchor')
  if ! git merge-base --is-ancestor "$approved_anchor" "$current_head" 2>/dev/null; then
    jq -n --arg reason "Blocked: branch history was rewritten after lease anchor $approved_anchor. Create a new lease before pushing." '{allowed:false, reason:$reason}'
    return 0
  fi
  # Scope-aware anchor check:
  #   - If lease has approved_scope (semantic approval), accept any descendant
  #     as long as pg_validate_scope passes below.
  #   - If lease has NO approved_scope (back-compat / one-shot), require HEAD
  #     to match approved_anchor exactly — the user approved THESE commits.
  #   - PG_ALLOW_DESCENDANT=1 bypasses the anchor-exact rule for one push.
  local has_scope
  has_scope=$(echo "$lease_json" | jq -r '.approved_scope // empty | if . == null or . == {} then "" else "1" end')
  if [[ -z "$has_scope" && "${PG_ALLOW_DESCENDANT:-0}" != "1" && "$current_head" != "$approved_anchor" ]]; then
    jq -n --arg reason "Blocked: new commits landed after lease was approved (lease anchor $approved_anchor, HEAD $current_head). Run \`pg\` to re-approve with a semantic scope, or override once with PG_ALLOW_DESCENDANT=1 pg push ..." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$force_with_lease" == "true" && "$current_head" != "$approved_anchor" ]]; then
    jq -n --arg reason "Blocked: --force-with-lease requires a lease approved at the rewritten HEAD. Create a new lease before pushing." '{allowed:false, reason:$reason}'
    return 0
  fi

  # Semantic scope check — applies only when lease has approved_scope.
  if [[ -n "$has_scope" && "${PG_SCOPE_OVERRIDE:-0}" != "1" ]]; then
    local scope_result scope_allowed scope_reason
    scope_result=$(pg_validate_scope "$lease_json")
    scope_allowed=$(echo "$scope_result" | jq -r '.allowed')
    if [[ "$scope_allowed" != "true" ]]; then
      scope_reason=$(echo "$scope_result" | jq -r '.reason')
      jq -n --arg reason "$scope_reason" '{allowed:false, reason:$reason}'
      return 0
    fi
  fi

  local pr_reason=""
  pr_reason=$(pg_validate_pr_binding "$branch_ref" "$lease_json" 2>&1 >/dev/null) || true
  if [[ -n "$pr_reason" ]]; then
    jq -n --arg reason "$pr_reason" '{allowed:false, reason:$reason}'
    return 0
  fi

  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  if [[ ! -f "$pending_path" ]]; then
    jq -n --arg reason "Blocked: git push requires a fresh self-assertion for $lease_branch. Use: pg push --branch $lease_branch --assert-flow \$'update pr line\nbranch $lease_branch\nno rewrite'" '{allowed:false, reason:$reason}'
    return 0
  fi
  pending_json=$(cat "$pending_path")
  pending_remote=$(echo "$pending_json" | jq -r '.remote')
  pending_head=$(echo "$pending_json" | jq -r '.head')
  pending_branch_ref=$(echo "$pending_json" | jq -r '.branch_ref')

  if [[ "$pending_branch_ref" != "$branch_ref" ]]; then
    jq -n --arg reason "Blocked: pending self-assertion was recorded for $pending_branch_ref, not $branch_ref. Re-run pg push." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$pending_remote" != "$remote" ]]; then
    jq -n --arg reason "Blocked: pending self-assertion targets remote '$pending_remote', but push targets '$remote'. Re-run pg push." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$pending_head" != "$current_head" ]]; then
    jq -n --arg reason "Blocked: branch HEAD changed after self-assertion. Re-run pg push with updated caveman text." '{allowed:false, reason:$reason}'
    return 0
  fi

  jq -n '{allowed:true}'
}

pg_collect_changed_files_json() {
  local remote="$1"
  local branch="$2"
  local lease_json="$3"
  local compare_ref=""
  if git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
    compare_ref="refs/remotes/$remote/$branch"
  else
    compare_ref=$(echo "$lease_json" | jq -r '.base_ref_snapshot // empty')
    if [[ -z "$compare_ref" ]] || ! git rev-parse --verify "$compare_ref" >/dev/null 2>&1; then
      compare_ref=$(echo "$lease_json" | jq -r '.approved_anchor')
    fi
  fi
  git diff --name-only "$compare_ref..HEAD" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

pg_write_pending_assertion() {
  local remote="$1"
  local branch_ref="$2"
  local assert_flow="$3"
  local lease_json="$4"
  local branch_name current_head pending_path changed_files pr_number
  branch_name=$(pg_branch_display "$branch_ref")
  current_head=$(git rev-parse HEAD)
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  changed_files=$(pg_collect_changed_files_json "$remote" "$branch_name" "$lease_json")
  pr_number=$(echo "$lease_json" | jq -r '.pr_number // empty')

  pg_ensure_parent_dir "$pending_path"
  jq -n \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg head "$current_head" \
    --arg assert_flow "$assert_flow" \
    --arg overall_flow "$assert_flow" \
    --argjson files "$changed_files" \
    --arg pr_number "$pr_number" \
    --arg timestamp "$(pg_now_utc)" \
    '{
      branch_ref: $branch_ref,
      remote: $remote,
      head: $head,
      assert_flow: $assert_flow,
      agent_asserted_pr: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      agent_asserted_overall_flow: $overall_flow,
      agent_asserted_files: $files,
      timestamp: $timestamp
    }' >"$pending_path"
}

pg_append_push_log() {
  local branch_ref="$1"
  local result="$2"
  local pending_path log_path
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  log_path=$(pg_log_path_for_ref "$branch_ref")
  [[ -f "$pending_path" ]] || return 0
  pg_ensure_parent_dir "$log_path"
  jq -c --arg result "$result" --arg timestamp "$(pg_now_utc)" '. + {result:$result, logged_at:$timestamp}' "$pending_path" >>"$log_path"
}

pg_cmd_preview_draft() {
  local draft=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft)
        draft="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown preview-draft option: $1"
        return 1
        ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"
  pg_render_lease_summary "$draft"
}

pg_cmd_draft_approve() {
  local intent="" assert_flow="" remote="" branch="" pr_override="" pr_repo=""
  local approved_paths="" approved_subjects="" max_commits="" max_added_lines="" no_scope="false"
  local branch_name branch_ref repo_name repo_root common_dir pr_json pr_number pr_url pr_mode approved_anchor base_ref draft_file script_file script_path scope_json
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --intent)
        intent="$2"
        shift 2
        ;;
      --assert-flow)
        assert_flow="$2"
        shift 2
        ;;
      --remote)
        remote="$2"
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      --pr)
        pr_override="$2"
        shift 2
        ;;
      --pr-repo)
        pr_repo="$2"
        shift 2
        ;;
      --approved-paths)
        approved_paths="$2"
        shift 2
        ;;
      --approved-subjects)
        approved_subjects="$2"
        shift 2
        ;;
      --max-commits)
        max_commits="$2"
        shift 2
        ;;
      --max-added-lines)
        max_added_lines="$2"
        shift 2
        ;;
      --no-scope)
        no_scope="true"
        shift
        ;;
      *)
        pg_fail "Unknown draft-approve option: $1"
        return 1
        ;;
    esac
  done

  repo_root=$(pg_repo_root) || return 1
  common_dir=$(pg_git_common_dir) || return 1
  repo_name=$(pg_repo_name)
  branch_name="${branch:-$(pg_branch_name)}"
  [[ -n "$branch_name" ]] || pg_fail "Not on a branch."
  branch_ref=$(pg_branch_ref "$branch_name")
  remote="${remote:-$(pg_default_remote "$branch_name")}"
  pr_repo="${pr_repo:-$(pg_default_pr_repo || true)}"
  approved_anchor=$(git rev-parse HEAD)
  base_ref=$(pg_default_base_ref_snapshot)

  if [[ -n "$pr_override" ]]; then
    pr_number="$pr_override"
    pr_url=""
    pr_mode="bound"
  else
    pr_json=$(pg_find_pr_json "$branch_name" "$pr_repo")
    pr_number=$(echo "$pr_json" | jq -r '.number // empty')
    pr_url=$(echo "$pr_json" | jq -r '.url // empty')
    if [[ -n "$pr_number" ]]; then
      pr_mode="bound"
    else
      pr_mode="unbound"
    fi
  fi

  [[ -n "$intent" ]] || intent=$(pg_default_user_intent "$branch_name" "$pr_number")
  [[ -n "$assert_flow" ]] || assert_flow=$(pg_default_assert_flow "$branch_name" "$pr_number")

  # Build approved_scope. Auto-detect then let explicit flags override.
  # --no-scope disables semantic approval (falls back to single-push anchor-exact).
  if [[ "$no_scope" == "true" ]]; then
    scope_json="null"
  else
    scope_json=$(pg_detect_scope)
    if [[ "$scope_json" != "null" ]]; then
      if [[ -n "$approved_paths" ]]; then
        scope_json=$(echo "$scope_json" | jq --arg raw "$approved_paths" '.paths = ($raw | split("\n") | map(select(length > 0)))')
      fi
      if [[ -n "$approved_subjects" ]]; then
        scope_json=$(echo "$scope_json" | jq --arg raw "$approved_subjects" '.subjects = ($raw | split("\n") | map(select(length > 0) | ascii_downcase))')
      fi
      if [[ -n "$max_commits" ]]; then
        scope_json=$(echo "$scope_json" | jq --argjson n "$max_commits" '.max_commits = $n')
      fi
      if [[ -n "$max_added_lines" ]]; then
        scope_json=$(echo "$scope_json" | jq --argjson n "$max_added_lines" '.max_added_lines = $n')
      fi
    fi
  fi

  draft_file="/tmp/pg-approve-$(pg_branch_slug "$repo_name")-$(pg_branch_slug "$branch_name").json"
  script_file="/tmp/pg-approve-$(pg_branch_slug "$repo_name")-$(pg_branch_slug "$branch_name").sh"
  script_path=$(pg_helper_path)

  jq -n \
    --arg schema_version "2" \
    --arg repo_name "$repo_name" \
    --arg repo_root "$repo_root" \
    --arg common_dir "$common_dir" \
    --arg branch_name "$branch_name" \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg pr_repo "$pr_repo" \
    --arg pr_mode "$pr_mode" \
    --arg pr_number "$pr_number" \
    --arg pr_url "$pr_url" \
    --arg approved_anchor "$approved_anchor" \
    --arg base_ref_snapshot "$base_ref" \
    --arg user_intent "$intent" \
    --arg agent_assertion_template "$assert_flow" \
    --argjson approved_scope "$scope_json" \
    --arg created_by "${USER:-unknown}" \
    --arg created_at "$(pg_now_utc)" \
    '{
      schema_version: ($schema_version | tonumber),
      repo_name: $repo_name,
      repo_root: $repo_root,
      common_dir: $common_dir,
      branch_name: $branch_name,
      branch_ref: $branch_ref,
      remote: $remote,
      pr_repo: (if $pr_repo == "" then null else $pr_repo end),
      pr_mode: $pr_mode,
      pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      pr_url: (if $pr_url == "" then null else $pr_url end),
      approved_anchor: $approved_anchor,
      base_ref_snapshot: (if $base_ref_snapshot == "" then null else $base_ref_snapshot end),
      user_intent: $user_intent,
      agent_assertion_template: $agent_assertion_template,
      approved_scope: $approved_scope,
      created_by: $created_by,
      created_at: $created_at,
      status: "active"
    }' >"$draft_file"

  cat >"$script_file" <<EOF
#!/bin/bash
set -euo pipefail

DRAFT_FILE="$draft_file"
HELPER="$script_path"

# Edit-before-approve: open \$EDITOR on the draft JSON so you can tweak
# .user_intent / .agent_assertion_template before approving. Skip with
# PG_SKIP_EDIT=1 (useful when running the script non-interactively).
if [ "\${PG_SKIP_EDIT:-0}" != "1" ]; then
  editor="\${EDITOR:-vi}"
  echo "Opening \$editor on \$DRAFT_FILE — edit .user_intent, .agent_assertion_template, and .approved_scope (paths / subjects / max_commits / max_added_lines). Save + quit to continue. :cq to abort."
  cp "\$DRAFT_FILE" "\$DRAFT_FILE.bak"
  if ! "\$editor" "\$DRAFT_FILE"; then
    echo "Editor exited non-zero — aborting."
    mv "\$DRAFT_FILE.bak" "\$DRAFT_FILE"
    exit 1
  fi
  if ! jq empty "\$DRAFT_FILE" >/dev/null 2>&1; then
    echo "Draft is no longer valid JSON — restoring previous version, aborting."
    mv "\$DRAFT_FILE.bak" "\$DRAFT_FILE"
    exit 1
  fi
  rm -f "\$DRAFT_FILE.bak"
fi

"\$HELPER" preview-draft --draft "\$DRAFT_FILE"
echo
printf 'Proceed? [y/N] '
read -r answer
case "\$answer" in
  y|Y|yes|YES)
    "\$HELPER" approve --draft "\$DRAFT_FILE"
    ;;
  *)
    echo "Canceled"
    exit 1
    ;;
esac
EOF
  chmod +x "$script_file"

  echo "Approval script: $script_file"
  echo "Draft file: $draft_file"

  # Auto-run the approval script unless explicitly suppressed. This gives the
  # user a single `pg` command that opens vim on the draft (intent + assert +
  # scope) then prompts y/N.
  if [[ "${PG_AUTO_RUN_APPROVAL:-1}" == "1" ]] && [[ -t 0 || -t 1 ]]; then
    bash "$script_file"
  fi
}

pg_cmd_approve() {
  # Require interactive terminal — prevent agents from self-approving by calling this directly
  if [[ ! -t 0 ]]; then
    pg_fail "Blocked: pg approve requires an interactive terminal. Run the approval script printed by pg draft-approve instead."
    return 1
  fi
  local draft="" lease_path repo_root approved_anchor existing_created_at existing_created_by
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft)
        draft="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown approve option: $1"
        return 1
        ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"

  repo_root=$(jq -r '.repo_root' "$draft")
  approved_anchor=$(jq -r '.approved_anchor' "$draft")
  git -C "$repo_root" cat-file -e "${approved_anchor}^{commit}" >/dev/null 2>&1 || pg_fail "Draft anchor commit no longer exists: $approved_anchor"

  lease_path="$(jq -r '.common_dir' "$draft")/push-gate/leases/$(jq -r '.branch_ref' "$draft").json"
  pg_ensure_parent_dir "$lease_path"
  existing_created_at=$(jq -r '.created_at // empty' "$lease_path" 2>/dev/null || true)
  existing_created_by=$(jq -r '.created_by // empty' "$lease_path" 2>/dev/null || true)

  jq \
    --arg updated_at "$(pg_now_utc)" \
    --arg created_at "${existing_created_at:-$(jq -r '.created_at' "$draft")}" \
    --arg created_by "${existing_created_by:-$(jq -r '.created_by' "$draft")}" \
    '.created_at = $created_at | .created_by = $created_by | .updated_at = $updated_at | .status = "active"' \
    "$draft" >"$lease_path"

  echo "Lease approved: $lease_path"
  pg_notify_approved "$draft" "$lease_path" || true
}

# Notify the initiating Claude/Codex session that the lease was approved.
# Fires three channels (each fail-silent):
#   1. Sentinel file at /tmp/pg-approved/<repo>__<branch> (polled by agents).
#   2. Threaded Slack reply on the existing notify-slack thread for this branch.
#   3. macOS terminal-notifier desktop notification.
pg_notify_approved() {
  local draft="$1" lease_path="$2"
  local repo_name branch_name pr_number key sentinel_dir sentinel_file
  repo_name=$(jq -r '.repo_name // empty' "$draft" 2>/dev/null)
  branch_name=$(jq -r '.branch_name // empty' "$draft" 2>/dev/null)
  pr_number=$(jq -r '.pr_number // empty' "$draft" 2>/dev/null)
  [[ -n "$repo_name" && -n "$branch_name" ]] || return 0

  key="${repo_name}__${branch_name}"
  key=$(printf '%s' "$key" | tr '/ ' '__')

  # 1. Sentinel file. Agents can poll this ("test -f /tmp/pg-approved/<key>")
  #    to know approval happened out-of-band.
  sentinel_dir="${PG_APPROVAL_SENTINEL_DIR:-/tmp/pg-approved}"
  mkdir -p "$sentinel_dir" 2>/dev/null || true
  sentinel_file="$sentinel_dir/$key"
  {
    printf 'approved_at=%s\n' "$(pg_now_utc)"
    printf 'lease=%s\n' "$lease_path"
    [[ -n "$pr_number" ]] && printf 'pr_number=%s\n' "$pr_number"
  } > "$sentinel_file" 2>/dev/null || true

  # 2. Slack threaded reply (same convention as notify-slack.sh).
  #    OFF by default — opt in with PG_NOTIFY_SLACK=1 when you actually want
  #    the approval to surface in the branch's Slack thread.
  local thread_dir thread_file thread_ts token chan payload msg
  thread_dir="${NOTIFY_THREAD_DIR:-/tmp/claude-slack-threads}"
  thread_file="$thread_dir/$key"
  if [[ "${PG_NOTIFY_SLACK:-0}" == "1" ]] \
     && [[ -r "$thread_file" ]] \
     && command -v security >/dev/null 2>&1; then
    thread_ts=$(cat "$thread_file" 2>/dev/null || true)
    token=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-bot-token -w 2>/dev/null || true)
    chan=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-channel -w 2>/dev/null || true)
    if [[ -n "$thread_ts" && -n "$token" && -n "$chan" ]]; then
      msg="🔐 *lease approved* for \`$branch_name\`"
      [[ -n "$pr_number" ]] && msg="$msg · PR #$pr_number"
      msg="$msg — agent may now push"
      payload=$(jq -n \
        --arg channel "$chan" \
        --arg text "$msg" \
        --arg thread_ts "$thread_ts" \
        '{channel: $channel, text: $text, thread_ts: $thread_ts, unfurl_links: false, unfurl_media: false}')
      curl -sS https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$payload" >/dev/null 2>&1 || true
    fi
  fi

  # 3. macOS desktop notification.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier \
      -title "push-gate" \
      -subtitle "lease approved" \
      -message "$branch_name${pr_number:+ · PR #$pr_number} — agent may now push" \
      -sound Pop \
      -group "pg-approval-$key" \
      -timeout 10 >/dev/null 2>&1 &
  fi
}

pg_load_current_lease_json() {
  local branch_ref
  branch_ref=$(pg_branch_ref)
  pg_load_lease_for_ref "$branch_ref"
}

pg_cmd_status() {
  local lease_json branch_ref
  branch_ref=$(pg_branch_ref)
  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  if [[ -z "$lease_json" ]]; then
    echo "No lease for $(pg_branch_display "$branch_ref")"
    return 0
  fi
  echo "$lease_json" | jq -r '
    "Branch: " + .branch_name,
    "Remote: " + .remote,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Anchor: " + .approved_anchor,
    "Status: " + .status,
    "Updated: " + (.updated_at // .created_at)
  '
}

pg_cmd_show() {
  local branch="${1:-}" branch_ref lease_path
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$lease_path" ]] || pg_fail "No lease found for $(pg_branch_display "$branch_ref")"
  jq -r '
    "Branch: " + .branch_name,
    "Remote: " + .remote,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Anchor: " + .approved_anchor,
    "Intent:",
    .user_intent,
    "",
    "Assertion template:",
    .agent_assertion_template
  ' "$lease_path"
}

pg_cmd_list() {
  local leases_root
  leases_root="$(pg_store_dir)/leases/refs/heads"
  if [[ ! -d "$leases_root" ]]; then
    echo "No leases"
    return 0
  fi
  find "$leases_root" -name '*.json' -print | sort | while read -r file; do
    jq -r '[.branch_name, .remote, (.pr_repo // "(default)"), (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end), .approved_anchor] | @tsv' "$file"
  done
}

pg_cmd_revoke() {
  local branch="${1:-}" branch_ref lease_path pending_path
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  rm -f "$lease_path" "$pending_path"
  echo "Revoked lease for $(pg_branch_display "$branch_ref")"
}

pg_cmd_doctor() {
  local branch current_branch remote
  current_branch=$(pg_branch_name)
  remote=$(pg_default_remote || true)
  branch="${current_branch:-HEAD}"
  pg_validate_push_guard "git push ${remote:+$remote }$branch" | jq -r 'if .allowed then "Push guard: ready" else .reason end'
}

pg_cmd_bind_pr() {
  local auto="false" branch branch_ref lease_path actual_pr number url pr_repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)
        auto="true"
        shift
        ;;
      --repo)
        pr_repo="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown bind-pr option: $1"
        return 1
        ;;
    esac
  done
  [[ "$auto" == "true" ]] || pg_fail "bind-pr currently supports only --auto"
  branch=$(pg_branch_name) || return 1
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$lease_path" ]] || pg_fail "No lease found for $branch"
  pr_repo="${pr_repo:-$(jq -r '.pr_repo // empty' "$lease_path")}"
  pr_repo="${pr_repo:-$(pg_default_pr_repo || true)}"
  actual_pr=$(pg_find_pr_json "$branch" "$pr_repo")
  number=$(echo "$actual_pr" | jq -r '.number // empty')
  url=$(echo "$actual_pr" | jq -r '.url // empty')
  [[ -n "$number" ]] || pg_fail "No open PR found for $branch"
  jq \
    --arg updated_at "$(pg_now_utc)" \
    --argjson pr_number "$number" \
    --arg pr_url "$url" \
    --arg pr_repo "$pr_repo" \
    '.pr_mode = "bound" | .pr_number = $pr_number | .pr_url = $pr_url | .pr_repo = (if $pr_repo == "" then null else $pr_repo end) | .updated_at = $updated_at' \
    "$lease_path" >"$lease_path.tmp"
  mv "$lease_path.tmp" "$lease_path"
  echo "Lease bound to PR #$number"
}

pg_cmd_push() {
  local assert_flow="" remote="" branch="" source_ref="" force_with_lease="false" set_upstream="false"
  local current_branch branch_ref lease_json pending_path result refspec use_upstream="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --assert-flow)
        assert_flow="$2"
        shift 2
        ;;
      --remote)
        remote="$2"
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      --source-ref)
        source_ref="$2"
        shift 2
        ;;
      --force-with-lease)
        force_with_lease="true"
        shift
        ;;
      --set-upstream)
        set_upstream="true"
        shift
        ;;
      *)
        pg_fail "Unknown push option: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$assert_flow" ]] || pg_fail "pg push requires --assert-flow with caveman text."
  current_branch=$(pg_branch_name || true)
  branch="${branch:-$current_branch}"
  [[ -n "$branch" ]] || pg_fail "pg push requires --branch when not on a branch."
  source_ref="${source_ref:-${current_branch:-HEAD}}"
  branch_ref=$(pg_branch_ref "$branch")
  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  [[ -n "$lease_json" ]] || pg_fail "No lease found for $branch. Run pg to draft an approval first."
  remote="${remote:-$(echo "$lease_json" | jq -r '.remote')}"
  pending_path=$(pg_pending_path_for_ref "$branch_ref")

  # Enforce semantic scope directly here so pg push is strict regardless of
  # which harness-level hook ran. PG_SCOPE_OVERRIDE=1 bypasses (one-shot).
  local has_scope current_head approved_anchor
  has_scope=$(echo "$lease_json" | jq -r '.approved_scope // empty | if . == null or . == {} then "" else "1" end')
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  approved_anchor=$(echo "$lease_json" | jq -r '.approved_anchor')
  if [[ -n "$has_scope" && "${PG_SCOPE_OVERRIDE:-0}" != "1" ]]; then
    local scope_result scope_allowed scope_reason
    scope_result=$(pg_validate_scope "$lease_json")
    scope_allowed=$(echo "$scope_result" | jq -r '.allowed')
    if [[ "$scope_allowed" != "true" ]]; then
      scope_reason=$(echo "$scope_result" | jq -r '.reason')
      pg_fail "$scope_reason"
    fi
  elif [[ -z "$has_scope" && "${PG_ALLOW_DESCENDANT:-0}" != "1" && "$current_head" != "$approved_anchor" ]]; then
    pg_fail "Blocked: new commits landed after lease was approved (lease anchor $approved_anchor, HEAD $current_head). Run \`pg\` to re-approve with a semantic scope."
  fi

  pg_write_pending_assertion "$remote" "$branch_ref" "$assert_flow" "$lease_json"
  cleanup_pending() {
    rm -f "$pending_path"
  }
  trap cleanup_pending EXIT

  refspec="$branch"
  if [[ "$source_ref" != "$branch" ]]; then
    refspec="$source_ref:$branch"
  fi
  if [[ "$set_upstream" == "true" ]]; then
    use_upstream="true"
  elif [[ -n "$current_branch" && "$current_branch" == "$branch" ]] && ! git rev-parse --abbrev-ref "${branch}@{upstream}" >/dev/null 2>&1; then
    use_upstream="true"
  fi

  if [[ "$force_with_lease" == "true" && "$use_upstream" == "true" ]]; then
    git push --force-with-lease -u "$remote" "$refspec"
  elif [[ "$force_with_lease" == "true" ]]; then
    git push --force-with-lease "$remote" "$refspec"
  elif [[ "$use_upstream" == "true" ]]; then
    git push -u "$remote" "$refspec"
  else
    git push "$remote" "$refspec"
  fi
  result=$?
  pg_append_push_log "$branch_ref" "pushed"
  trap - EXIT
  rm -f "$pending_path"
  return "$result"
}

pg_cmd_compose() {
  local reset="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reset)
        reset="true"
        shift
        ;;
      *)
        pg_fail "Unknown compose option: $1"
        return 1
        ;;
    esac
  done

  local branch repo_name tmpfile helper_path pr_json pr_number intent_body assert_body
  repo_name=$(pg_repo_name)
  branch=$(pg_branch_name) || { pg_fail "Not on a branch."; return 1; }
  tmpfile="/tmp/pg-compose-$(pg_branch_slug "$repo_name")-$(pg_branch_slug "$branch").sh"
  helper_path=$(pg_helper_path)

  if [[ "$reset" == "true" ]]; then
    rm -f "$tmpfile"
  fi

  if [[ ! -f "$tmpfile" ]]; then
    pr_json=$(pg_find_pr_json "$branch" "$(pg_default_pr_repo 2>/dev/null || true)" 2>/dev/null || echo "{}")
    pr_number=$(echo "$pr_json" | jq -r '.number // empty')

    if [[ -n "$pr_number" ]]; then
      intent_body="allow pushes for $branch
same branch
same pr #$pr_number
new commit"
      assert_body="update pr #$pr_number
branch $branch
describe change here
no rewrite"
    else
      intent_body="allow pushes for $branch
same branch
bind pr after first push
new commit"
      assert_body="push to $branch
branch $branch
describe change here
no rewrite"
    fi

    cat >"$tmpfile" <<SH
#!/bin/bash
# Edit the --intent and --assert-flow strings below. Save + quit to run draft-approve.
# Empty-save to cancel. File persists — re-run with: pg compose (or: bash $tmpfile)
# Regenerate template with: pg compose --reset

"$helper_path" draft-approve \\
  --intent '$intent_body' \\
  --assert-flow '$assert_body'
SH
    chmod +x "$tmpfile"
  fi

  "${EDITOR:-vi}" "$tmpfile"

  if [[ ! -s "$tmpfile" ]]; then
    echo "Canceled (empty file)"
    rm -f "$tmpfile"
    return 1
  fi

  # Compose runs draft-approve, which now auto-runs the approval script
  # (vim on JSON → preview → y/N → approve). No further chaining needed.
  if ! bash "$tmpfile"; then
    echo "draft-approve failed — leaving $tmpfile for re-edit."
    return 1
  fi
}

pg_main() {
  # Bare `pg` → draft-approve with auto-run of the approval script. That
  # opens vim on the draft JSON (intent + assert + scope), preview, y/N,
  # approve. One vim session, no copy-paste.
  local command="${1:-draft-approve}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  if pg_parse_common_flag "$command"; then
    pg_migration_help
    return 1
  fi

  case "$command" in
    draft-approve)
      pg_cmd_draft_approve "$@"
      ;;
    compose)
      pg_cmd_compose "$@"
      ;;
    approve)
      pg_cmd_approve "$@"
      ;;
    preview-draft)
      pg_cmd_preview_draft "$@"
      ;;
    push)
      pg_cmd_push "$@"
      ;;
    status)
      pg_cmd_status "$@"
      ;;
    show)
      pg_cmd_show "$@"
      ;;
    list)
      pg_cmd_list "$@"
      ;;
    revoke)
      pg_cmd_revoke "$@"
      ;;
    doctor)
      pg_cmd_doctor "$@"
      ;;
    bind-pr)
      pg_cmd_bind_pr "$@"
      ;;
    guard-check)
      local command_text=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --command)
            command_text="$2"
            shift 2
            ;;
          *)
            pg_fail "Unknown guard-check option: $1"
            return 1
            ;;
        esac
      done
      pg_validate_push_guard "$command_text"
      ;;
    ""|help|--help|-h)
      cat <<'EOF'
Usage:
  pg                     Generate approval draft for current branch
  pg compose [--reset]   Open $EDITOR with a draft-approve template, run on save
  pg draft-approve       Generate approval draft
  pg draft-approve --pr-repo HOST/OWNER/REPO
  pg approve --draft F   Approve durable lease from draft file
  pg preview-draft --draft F
  pg push --assert-flow TEXT [--remote origin] [--force-with-lease] [--set-upstream]
  pg push --branch TARGET [--source-ref HEAD|local-branch] --assert-flow TEXT
  pg status | show [branch] | list | revoke [branch] | doctor | bind-pr --auto [--repo HOST/OWNER/REPO]
EOF
      ;;
    *)
      pg_fail "Unknown push-gate command: $command"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  pg_main "$@"
fi
