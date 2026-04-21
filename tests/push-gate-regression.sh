#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/claude/hooks/push-gate.sh"
GUARD="$ROOT/claude/hooks/bash-safety-guard.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/push-gate-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain [$needle], got: $haystack"
  fi
}

expect_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

expect_no_file() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected file to be absent: $path"
}

make_fake_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  repo=""
  head=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R)
        repo="$2"
        shift 2
        ;;
      --head|-H)
        head="$2"
        shift 2
        ;;
      --json|--jq|--state)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ -n "${PG_TEST_PR_LIST_MAP:-}" ]]; then
    result=$(jq -cn \
      --argjson map "${PG_TEST_PR_LIST_MAP}" \
      --arg key "${repo}|${head}" \
      --arg repo "$repo" \
      --arg head "$head" \
      '$map[$key] // $map[$repo] // $map[$head] // empty')
    if [[ -n "$result" && "$result" != "null" ]]; then
      printf '%s\n' "$result"
      exit 0
    fi
  fi
  printf '%s\n' "${PG_TEST_PR_JSON:-[]}"
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
  printf '%s\n' "${PG_TEST_CREATE_URL:-https://example.test/pr/new}"
  exit 0
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  repo=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R|--branch|--json|--jq|--template)
        if [[ "$1" == "--json" || "$1" == "--jq" || "$1" == "--template" || "$1" == "--branch" || "$1" == "--repo" || "$1" == "-R" ]]; then
          if [[ "$1" == "--repo" || "$1" == "-R" ]]; then
            repo="$2"
          fi
          shift 2
        fi
        ;;
      -*)
        shift
        ;;
      *)
        repo="$1"
        shift
        ;;
    esac
  done
  if [[ -n "${PG_TEST_REPO_VIEW_MAP:-}" ]]; then
    result=$(jq -cn --argjson map "${PG_TEST_REPO_VIEW_MAP}" --arg repo "$repo" '$map[$repo] // $map["default"] // {}')
    printf '%s\n' "$result"
    exit 0
  fi
  printf '%s\n' '{"viewerPermission":"READ"}'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$bin_dir/gh"
}

make_repo() {
  local name="$1"
  local base="$TEST_TMP/$name"
  local origin="$base/origin.git"
  local repo="$base/repo"
  local bin_dir="$base/bin"
  mkdir -p "$base"
  git -c init.defaultBranch=main init --bare "$origin" >/dev/null
  git -c init.defaultBranch=main init "$repo" >/dev/null
  (
    cd "$repo"
    git config user.name "Push Gate Test"
    git config user.email "push-gate@test"
    printf 'base\n' >README.md
    git add README.md
    git commit -m "base" >/dev/null
    git branch -M main
    git remote add origin "$origin"
    git push -u origin main >/dev/null
  )
  make_fake_gh "$bin_dir"
  echo "$repo|$bin_dir|$origin"
}

run_helper() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$FAKE_BIN:$PATH" bash "$HELPER" "$@"
  )
}

run_guard() {
  local repo="$1"
  local command="$2"
  (
    cd "$repo"
    jq -n --arg command "$command" '{tool_input:{command:$command}}' | PATH="$FAKE_BIN:$PATH" bash "$GUARD"
  )
}

current_common_dir() {
  (
    cd "$1"
    local common_dir repo_root
    common_dir=$(git rev-parse --git-common-dir)
    if [[ "$common_dir" != /* ]]; then
      repo_root=$(git rev-parse --show-toplevel)
      common_dir="$repo_root/$common_dir"
    fi
    printf '%s\n' "$common_dir"
  )
}

current_head() {
  (
    cd "$1"
    git rev-parse HEAD
  )
}

write_pending() {
  local repo="$1"
  local remote="$2"
  local branch_ref="$3"
  local head="$4"
  local pr_number="$5"
  local common_dir
  common_dir=$(current_common_dir "$repo")
  local pending="$common_dir/push-gate/pending/$branch_ref.json"
  mkdir -p "$(dirname "$pending")"
  jq -n \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg head "$head" \
    --arg assert_flow "update pr line" \
    --arg pr_number "$pr_number" \
    '{
      branch_ref: $branch_ref,
      remote: $remote,
      head: $head,
      assert_flow: $assert_flow,
      agent_asserted_pr: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      agent_asserted_overall_flow: $assert_flow,
      agent_asserted_files: ["README.md"],
      timestamp: "2026-04-21T00:00:00Z"
    }' >"$pending"
}

extract_path() {
  local output="$1"
  local prefix="$2"
  echo "$output" | awk -v prefix="$prefix" '$0 ~ prefix {print $NF}'
}

echo "1..19"

legacy_output=$(bash "$HELPER" 5 2>&1 || true)
expect_contains "$legacy_output" "Durable leases replaced minute windows"
echo "ok 1 - legacy numeric syntax rejected"

IFS='|' read -r REPO FAKE_BIN ORIGIN <<<"$(make_repo existing-pr)"
EXISTING_FAKE_BIN="$FAKE_BIN"
(
  cd "$REPO"
  git checkout -b mho/existing-pr >/dev/null
  printf 'one\n' >feature.txt
  git add feature.txt
  git commit -m "feature start" >/dev/null
)
export PG_TEST_PR_JSON='[{"number":123,"url":"https://example.test/pr/123"}]'
draft_output=$(run_helper "$REPO" draft-approve \
  --intent $'allow durable lease\nsame branch\nsame pr' \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nchange guard + docs\nno rewrite')
draft_script=$(extract_path "$draft_output" "^Approval script:")
draft_file=$(extract_path "$draft_output" "^Draft file:")
expect_file "$draft_script"
expect_file "$draft_file"
preview_output=$(printf 'n\n' | bash "$draft_script" 2>&1 || true)
expect_contains "$preview_output" "Push lease approval"
expect_contains "$preview_output" "PR: #123"
expect_contains "$preview_output" "update pr #123"
echo "ok 2 - draft script renders readable approval summary"

printf 'y\n' | bash "$draft_script" >/dev/null
common_dir=$(current_common_dir "$REPO")
lease_path="$common_dir/push-gate/leases/refs/heads/mho/existing-pr.json"
expect_file "$lease_path"
lease_pr=$(jq -r '.pr_number' "$lease_path")
[[ "$lease_pr" == "123" ]] || fail "expected PR number 123 in lease, got $lease_pr"
echo "ok 3 - approve stamps durable lease in git-common-dir"

raw_output=$(run_guard "$REPO" "git push -u origin mho/existing-pr")
expect_contains "$raw_output" "pg push"
echo "ok 4 - raw git push denied without pending assertion"

run_helper "$REPO" push \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nchange guard + docs\nno rewrite' \
  --set-upstream >/dev/null
remote_feature=$(git -C "$REPO" rev-parse refs/remotes/origin/mho/existing-pr)
[[ "$remote_feature" == "$(current_head "$REPO")" ]] || fail "expected pg push to update origin/mho/existing-pr"
expect_no_file "$common_dir/push-gate/pending/refs/heads/mho/existing-pr.json"
echo "ok 5 - pg push succeeds and clears pending assertion"

(
  cd "$REPO"
  printf 'three\n' >>feature.txt
  git add feature.txt
  git commit -m "feature additive" >/dev/null
)
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
allow_output=$(run_guard "$REPO" "git push -u origin mho/existing-pr")
[[ -z "$allow_output" ]] || fail "expected guarded push to be allowed, got: $allow_output"
echo "ok 6 - guarded push allowed with valid pending assertion"

write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
head_push_output=$(run_guard "$REPO" "git push -u origin HEAD")
[[ -z "$head_push_output" ]] || fail "expected git push -u origin HEAD to be allowed, got: $head_push_output"
echo "ok 7 - attached-branch git push -u origin HEAD is allowed"

(
  cd "$REPO"
  printf 'four\n' >>feature.txt
  git add feature.txt
  git commit --amend -m "feature rewritten" >/dev/null
)
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
rewrite_output=$(run_guard "$REPO" "git push --force-with-lease origin mho/existing-pr")
expect_contains "$rewrite_output" "new lease"
echo "ok 8 - rewrite requires new lease"

IFS='|' read -r BOOTSTRAP_REPO BOOTSTRAP_BIN BOOTSTRAP_ORIGIN <<<"$(make_repo bootstrap)"
FAKE_BIN="$BOOTSTRAP_BIN"
(
  cd "$BOOTSTRAP_REPO"
  git checkout -b mho/bootstrap >/dev/null
  printf 'bootstrap\n' >bootstrap.txt
  git add bootstrap.txt
  git commit -m "bootstrap start" >/dev/null
)
export PG_TEST_PR_JSON='[]'
bootstrap_output=$(run_helper "$BOOTSTRAP_REPO" draft-approve \
  --intent $'allow bootstrap\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/bootstrap\nno rewrite')
bootstrap_script=$(extract_path "$bootstrap_output" "^Approval script:")
printf 'y\n' | bash "$bootstrap_script" >/dev/null
write_pending "$BOOTSTRAP_REPO" "origin" "refs/heads/mho/bootstrap" "$(current_head "$BOOTSTRAP_REPO")" ""
bootstrap_allow=$(run_guard "$BOOTSTRAP_REPO" "git push -u origin mho/bootstrap")
[[ -z "$bootstrap_allow" ]] || fail "expected bootstrap push to be allowed, got: $bootstrap_allow"
export PG_TEST_PR_JSON='[{"number":55,"url":"https://example.test/pr/55"}]'
run_helper "$BOOTSTRAP_REPO" bind-pr --auto >/dev/null
export PG_TEST_PR_JSON='[{"number":99,"url":"https://example.test/pr/99"}]'
write_pending "$BOOTSTRAP_REPO" "origin" "refs/heads/mho/bootstrap" "$(current_head "$BOOTSTRAP_REPO")" "55"
pr_mismatch=$(run_guard "$BOOTSTRAP_REPO" "git push -u origin mho/bootstrap")
expect_contains "$pr_mismatch" "PR"
echo "ok 9 - bootstrap lease binds PR later and mismatched PR is denied"

export PG_TEST_PR_JSON='[{"number":123,"url":"https://example.test/pr/123"}]'
FAKE_BIN="$EXISTING_FAKE_BIN"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
upstream_block=$(run_guard "$REPO" "git push upstream HEAD:main")
expect_contains "$upstream_block" "upstream/main"
origin_block=$(run_guard "$REPO" "git push origin HEAD:main")
expect_contains "$origin_block" "origin/main"
echo "ok 10 - protected main pushes are blocked on origin and upstream"

(
  cd "$REPO"
  git remote add upstream "$ORIGIN"
)
upstream_draft=$(run_helper "$REPO" draft-approve \
  --remote upstream \
  --intent $'allow upstream branch push\nsame branch\nsame pr' \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nremote upstream\nno rewrite')
upstream_script=$(extract_path "$upstream_draft" "^Approval script:")
printf 'y\n' | bash "$upstream_script" >/dev/null
write_pending "$REPO" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
upstream_feature=$(run_guard "$REPO" "git push upstream mho/existing-pr")
[[ -z "$upstream_feature" ]] || fail "expected upstream feature push to be allowed, got: $upstream_feature"
echo "ok 11 - upstream feature push allowed with matching lease"

(
  cd "$REPO"
  git branch temp/upstream-source >/dev/null
  git worktree add "$TEST_TMP/upstream-worktree" temp/upstream-source >/dev/null
)
WORKTREE="$TEST_TMP/upstream-worktree"
write_pending "$WORKTREE" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$WORKTREE")" "123"
worktree_refspec=$(run_guard "$WORKTREE" "git push upstream temp/upstream-source:mho/existing-pr")
[[ -z "$worktree_refspec" ]] || fail "expected worktree explicit refspec push to be allowed, got: $worktree_refspec"
echo "ok 12 - worktree explicit refspec push is allowed"

(
  cd "$WORKTREE"
  git checkout --detach >/dev/null
)
write_pending "$WORKTREE" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$WORKTREE")" "123"
detached_refspec=$(run_guard "$WORKTREE" "git push upstream HEAD:mho/existing-pr")
[[ -z "$detached_refspec" ]] || fail "expected detached HEAD explicit refspec push to be allowed, got: $detached_refspec"
echo "ok 13 - detached HEAD explicit refspec push is allowed"

detached_head=$(run_guard "$WORKTREE" "git push upstream HEAD")
expect_contains "$detached_head" "explicit target branch"
[[ "$detached_head" != *"git branch context"* ]] || fail "expected detached HEAD denial to avoid generic branch-context message, got: $detached_head"
echo "ok 14 - detached HEAD without explicit target gets accurate denial"

(
  cd "$REPO"
  git worktree add "$TEST_TMP/existing-pr-view" main >/dev/null
)
shared_view=$(run_helper "$TEST_TMP/existing-pr-view" show mho/existing-pr)
expect_contains "$shared_view" "mho/existing-pr"
expect_contains "$shared_view" "123"
echo "ok 15 - leases are visible across worktrees via git-common-dir"

IFS='|' read -r TOPO_REPO TOPO_BIN TOPO_ORIGIN <<<"$(make_repo topology-write)"
FAKE_BIN="$TOPO_BIN"
(
  cd "$TOPO_REPO"
  git checkout -b mho/topology-write >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-write.git
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-write":{"viewerPermission":"WRITE"}}'
topo_output=$(run_helper "$TOPO_REPO" draft-approve \
  --intent $'allow topology write\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-write\nno rewrite')
topo_draft=$(extract_path "$topo_output" "^Draft file:")
[[ "$(jq -r '.remote' "$topo_draft")" == "upstream" ]] || fail "expected writable-upstream default remote to be upstream"
[[ "$(jq -r '.pr_repo' "$topo_draft")" == "example.test/Netflix-Skunkworks/topology-write" ]] || fail "expected pr_repo to default to upstream topology"
echo "ok 16 - topology picks upstream PR repo and upstream push remote when writable"

IFS='|' read -r TOPO_READ_REPO TOPO_READ_BIN TOPO_READ_ORIGIN <<<"$(make_repo topology-read)"
FAKE_BIN="$TOPO_READ_BIN"
(
  cd "$TOPO_READ_REPO"
  git checkout -b mho/topology-read >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-read.git
)
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-read":{"viewerPermission":"READ"}}'
topo_read_output=$(run_helper "$TOPO_READ_REPO" draft-approve \
  --intent $'allow topology read\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-read\nno rewrite')
topo_read_draft=$(extract_path "$topo_read_output" "^Draft file:")
[[ "$(jq -r '.remote' "$topo_read_draft")" == "origin" ]] || fail "expected non-writable upstream to fall back to origin push remote"
[[ "$(jq -r '.pr_repo' "$topo_read_draft")" == "example.test/Netflix-Skunkworks/topology-read" ]] || fail "expected pr_repo to stay on upstream even when push remote falls back"
echo "ok 17 - topology falls back to origin push remote when upstream is not writable"

IFS='|' read -r TOPO_TRACK_REPO TOPO_TRACK_BIN TOPO_TRACK_ORIGIN <<<"$(make_repo topology-track)"
FAKE_BIN="$TOPO_TRACK_BIN"
(
  cd "$TOPO_TRACK_REPO"
  git checkout -b mho/topology-track >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git push -u origin mho/topology-track >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-track.git
)
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-track":{"viewerPermission":"WRITE"}}'
topo_track_output=$(run_helper "$TOPO_TRACK_REPO" draft-approve \
  --intent $'allow topology track\nsame branch' \
  --assert-flow $'update pr line\nbranch mho/topology-track\nno rewrite')
topo_track_draft=$(extract_path "$topo_track_output" "^Draft file:")
[[ "$(jq -r '.remote' "$topo_track_draft")" == "origin" ]] || fail "expected tracked branch to keep origin remote"
echo "ok 18 - tracked branch keeps existing remote instead of auto-flipping to upstream"

IFS='|' read -r TOPO_BIND_REPO TOPO_BIND_BIN TOPO_BIND_ORIGIN <<<"$(make_repo topology-bind)"
FAKE_BIN="$TOPO_BIND_BIN"
(
  cd "$TOPO_BIND_REPO"
  git checkout -b mho/topology-bind >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-bind.git
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-bind":{"viewerPermission":"READ"}}'
topo_bind_output=$(run_helper "$TOPO_BIND_REPO" draft-approve \
  --intent $'allow topology bind\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-bind\nno rewrite')
topo_bind_script=$(extract_path "$topo_bind_output" "^Approval script:")
printf 'y\n' | bash "$topo_bind_script" >/dev/null
export PG_TEST_PR_LIST_MAP='{"example.test/Netflix-Skunkworks/topology-bind|mho/topology-bind":[{"number":77,"url":"https://example.test/pr/77"}]}'
run_helper "$TOPO_BIND_REPO" bind-pr --auto >/dev/null
topo_bind_common=$(current_common_dir "$TOPO_BIND_REPO")
topo_bind_lease="$topo_bind_common/push-gate/leases/refs/heads/mho/topology-bind.json"
[[ "$(jq -r '.pr_number' "$topo_bind_lease")" == "77" ]] || fail "expected bind-pr to use upstream pr_repo and bind PR #77"
[[ "$(jq -r '.pr_repo' "$topo_bind_lease")" == "example.test/Netflix-Skunkworks/topology-bind" ]] || fail "expected bound lease to retain upstream pr_repo"
echo "ok 19 - bind-pr uses topology-selected upstream PR repo"
