#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/llm/hooks/stack.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stack-test.XXXXXX")
export TMPDIR="$TEST_TMP"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected [$needle] in: $haystack"
}

expect_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "did NOT expect [$needle] in: $haystack"
}

# ------------------------------------------------------------------------
# Fakes
# ------------------------------------------------------------------------

make_fake_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  # Two query modes: --author @me (status) vs --head <branch> (sync's
  # adopt-merged-inner pass). Different schemas; route by flag presence.
  is_head=""
  head=""
  saved=("$@")
  for arg in "${saved[@]}"; do
    [[ "$arg" == "--head" ]] && is_head=1
  done
  if [[ -n "$is_head" ]]; then
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --head) head="$2"; shift 2;;
        *) shift;;
      esac
    done
    if [[ -n "${STACK_TEST_MERGED_HEAD:-}" && "$head" == "$STACK_TEST_MERGED_HEAD" ]]; then
      printf '%s\n' "${STACK_TEST_MERGED_PR_JSON:-[]}"
    else
      printf '%s\n' '[]'
    fi
    exit 0
  fi
  printf '%s\n' "${STACK_TEST_PR_JSON:-[]}"
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
  chmod +x "$bin_dir/gh"
}

make_fake_pg() {
  # stack.sh invokes push-gate.sh via stack_helper_dir/push-gate.sh.
  # The fake handles every subcommand stack.sh calls into:
  #   leases  - canned JSON (status, sync flag staleness, push lease check)
  #   check   - per-branch lease state via STACK_TEST_PG_CHECK_<branch>
  #   prepare - records args to STACK_TEST_PG_LOG (no-op success)
  #   push    - records args to STACK_TEST_PG_LOG (no-op success)
  local hook_dir="$1"
  cat >"$hook_dir/push-gate.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
log() {
  [[ -n "${STACK_TEST_PG_LOG:-}" ]] && echo "$@" >>"$STACK_TEST_PG_LOG"
}
case "${1:-}" in
  leases)
    printf '%s\n' "${STACK_TEST_LEASES_JSON:-[]}"
    exit 0
    ;;
  check)
    branch="${2:-}"
    var="STACK_TEST_PG_CHECK_${branch//[^A-Za-z0-9]/_}"
    val="${!var:-}"
    if [[ -z "$val" ]]; then
      val="${STACK_TEST_PG_CHECK_DEFAULT:-}"
    fi
    if [[ -z "$val" ]]; then
      val='{"allowed":false}'
    fi
    printf '%s\n' "$val"
    exit 0
    ;;
  prepare)
    log "prepare $*"
    echo "Prepared brief written: /tmp/fake-prepare.json"
    exit 0
    ;;
  push)
    log "push $*"
    echo "(fake) git push ok"
    exit 0
    ;;
esac
echo "unexpected push-gate: $*" >&2
exit 1
EOF
  chmod +x "$hook_dir/push-gate.sh"
}

make_fake_branchless() {
  local bin_dir="$1" log_file="$2"
  cat >"$bin_dir/git-branchless" <<EOF
#!/bin/bash
set -euo pipefail
echo "git-branchless \$*" >>"$log_file"
case "\${STACK_TEST_BRANCHLESS_MODE:-ok}" in
  advance-base)
    git checkout mho/feature-base >/dev/null 2>&1
    printf 'scratch advance\n' >>scratch-sync.txt
    git add scratch-sync.txt
    git commit -m "scratch sync advance" >/dev/null
    ;;
  advance-all)
    for branch in mho/feature-base mho/feature-api mho/feature-ui; do
      git checkout "\$branch" >/dev/null 2>&1
      safe="\${branch//[^A-Za-z0-9]/_}"
      printf 'scratch advance %s\n' "\$branch" >>"scratch-\$safe.txt"
      git add "scratch-\$safe.txt"
      git commit -m "scratch sync \$branch" >/dev/null
    done
    ;;
  fail)
    echo "CONFLICT conflict.txt" >&2
    exit "\${STACK_TEST_BRANCHLESS_EXIT:-7}"
    ;;
esac
if [[ -n "\${STACK_TEST_STALE_REAL_REPO:-}" ]]; then
  git -C "\$STACK_TEST_STALE_REAL_REPO" update-ref refs/heads/mho/feature-base \
    "\$(git -C "\$STACK_TEST_STALE_REAL_REPO" rev-parse mho/feature-api)"
fi
exit 0
EOF
  chmod +x "$bin_dir/git-branchless"
}

# ------------------------------------------------------------------------
# Repo + stack of three branches
# ------------------------------------------------------------------------

make_stacked_repo() {
  local repo_tmp
  repo_tmp=$(mktemp -d "$TEST_TMP/repo.XXXXXX")
  local base="$repo_tmp/work"
  local origin="$repo_tmp/origin.git"
  git -c init.defaultBranch=main init --bare "$origin" >/dev/null
  git -c init.defaultBranch=main init "$base" >/dev/null
  (
    cd "$base"
    git config user.name "Stack Test"
    git config user.email "stack@test"
    printf 'base\n' >README.md
    git add README.md
    git commit -m "base" >/dev/null
    git branch -M main
    git remote add origin "$origin"
    git push -u origin main >/dev/null

    git checkout -b mho/feature-base main >/dev/null
    printf 'a\n' >a.txt && git add a.txt && git commit -m "feature-base 1" >/dev/null
    printf 'aa\n' >>a.txt && git add a.txt && git commit -m "feature-base 2" >/dev/null

    git checkout -b mho/feature-api mho/feature-base >/dev/null
    printf 'b\n' >b.txt && git add b.txt && git commit -m "feature-api 1" >/dev/null

    git checkout -b mho/feature-ui mho/feature-api >/dev/null
    printf 'c\n' >c.txt && git add c.txt && git commit -m "feature-ui 1" >/dev/null

    # Set up a synthetic remote ref so the tool finds origin/main as base.
    git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  )
  echo "$base"
}

# ------------------------------------------------------------------------
# Test setup
# ------------------------------------------------------------------------

REPO=$(make_stacked_repo)
# Canonicalize REPO path — git rev-parse --show-toplevel resolves symlinks
# (e.g. macOS /var → /private/var), and stack.sh keys leases by that.
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
make_fake_gh "$FAKE_BIN"

# Sandbox stack.sh by copying it into a writable hook dir alongside fake push-gate.sh.
HOOK_DIR="$TEST_TMP/hooks"
mkdir -p "$HOOK_DIR"
cp "$HOOK" "$HOOK_DIR/stack.sh"
chmod +x "$HOOK_DIR/stack.sh"
make_fake_pg "$HOOK_DIR"

BRANCHLESS_LOG="$TEST_TMP/branchless.log"
: >"$BRANCHLESS_LOG"
make_fake_branchless "$FAKE_BIN" "$BRANCHLESS_LOG"

run_stack() {
  (
    cd "$REPO"
    PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" "$@"
  )
}

UI_HEAD=$(git -C "$REPO" rev-parse mho/feature-ui)
API_HEAD=$(git -C "$REPO" rev-parse mho/feature-api)
BASE_HEAD=$(git -C "$REPO" rev-parse mho/feature-base)

export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":42,"headRefName":"mho/feature-base","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"url":"https://x/42","title":"base"},
  {"number":43,"headRefName":"mho/feature-api","baseRefName":"mho/feature-base","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"url":"https://x/43","title":"api"}
]')

export STACK_TEST_LEASES_JSON
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$BASE_HEAD" '[
  {"repo_root":$rr,"branch_name":"mho/feature-base","status":"active","approved_anchor":$anchor,"pr_number":42,"updated_at":"2026-04-24T00:00:00Z"},
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":"deadbeef","pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

echo "1..18"

# ------------------------------------------------------------------------
# 1. status renders all three branches
# ------------------------------------------------------------------------
out=$(run_stack status 2>&1)
expect_contains "$out" "mho/feature-base"
expect_contains "$out" "mho/feature-api"
expect_contains "$out" "mho/feature-ui"
expect_contains "$out" "#42"
expect_contains "$out" "#43"
echo "ok 1 - status renders 3-branch stack with PR numbers"

# ------------------------------------------------------------------------
# 2. status surfaces lease state: allowed, stale-tip, missing
# ------------------------------------------------------------------------
expect_contains "$out" "allowed"
expect_contains "$out" "stale-tip"
# feature-ui has no lease → "—"
ui_line=$(echo "$out" | grep "mho/feature-ui" || true)
expect_contains "$ui_line" "—"
echo "ok 2 - lease states render allowed / stale-tip / —"

# ------------------------------------------------------------------------
# 3. status surfaces CI state: PASS for #42, PENDING for #43
# ------------------------------------------------------------------------
base_line=$(echo "$out" | grep "mho/feature-base" || true)
api_line=$(echo "$out" | grep "mho/feature-api" || true)
expect_contains "$base_line" "PASS"
expect_contains "$api_line" "PENDING"
echo "ok 3 - CI rollup summarized to PASS / PENDING"

# ------------------------------------------------------------------------
# 4. status --json is valid and has 3 branches in one stack
# ------------------------------------------------------------------------
json_out=$(run_stack status --json 2>&1)
n_stacks=$(echo "$json_out" | jq '.stacks | length')
[[ "$n_stacks" == "1" ]] || fail "expected 1 stack, got $n_stacks"
n_branches=$(echo "$json_out" | jq '.stacks[0].branches | length')
[[ "$n_branches" == "3" ]] || fail "expected 3 branches in stack, got $n_branches: $json_out"
root=$(echo "$json_out" | jq -r '.stacks[0].root')
[[ "$root" == "mho/feature-base" ]] || fail "expected root mho/feature-base, got $root"
echo "ok 4 - status --json shape is valid"

# ------------------------------------------------------------------------
# 5. status accepts explicit --base and --prefix
# ------------------------------------------------------------------------
explicit_out=$(run_stack status --base origin/main --prefix mho/feature- 2>&1)
expect_contains "$explicit_out" "Base: origin/main"
expect_contains "$explicit_out" "Prefix: mho/feature-"
expect_contains "$explicit_out" "mho/feature-base"
echo "ok 5 - status honors explicit --base and --prefix"

# ------------------------------------------------------------------------
# 6. sync --dry-run does NOT invoke git-branchless
# ------------------------------------------------------------------------
: >"$BRANCHLESS_LOG"
run_stack sync --dry-run >/dev/null 2>&1
[[ ! -s "$BRANCHLESS_LOG" ]] || fail "dry-run should NOT call git-branchless, got: $(cat "$BRANCHLESS_LOG")"
echo "ok 6 - sync --dry-run skips git-branchless"

# ------------------------------------------------------------------------
# 7. sync invokes git-branchless sync --pull
# ------------------------------------------------------------------------
: >"$BRANCHLESS_LOG"
run_stack sync >/dev/null 2>&1
grep -q "sync --pull" "$BRANCHLESS_LOG" || fail "expected git-branchless sync --pull, got: $(cat "$BRANCHLESS_LOG")"
echo "ok 7 - sync invokes git-branchless sync --pull"

# ------------------------------------------------------------------------
# 8. status handles missing PR / missing lease gracefully (no errors)
# ------------------------------------------------------------------------
# Run inside a subshell so the empty-PR/empty-lease overrides don't leak
# into later tests.
out=$(
  export STACK_TEST_PR_JSON='[]'
  export STACK_TEST_LEASES_JSON='[]'
  run_stack status 2>&1
)
expect_contains "$out" "mho/feature-base"
expect_not_contains "$out" "error"
expect_not_contains "$out" "null"
echo "ok 8 - missing PR/lease renders without errors"

# ------------------------------------------------------------------------
# 9: stack sync with multi-commit squash-merged parent restacks descendants
#    AND invokes branchless --pull exactly once.
# ------------------------------------------------------------------------

BASE_HEAD_BEFORE_ADOPT=$(git -C "$REPO" rev-parse mho/feature-base)

# Simulate squash-merge: collapse feature-base's 2 commits into one on main.
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git merge --squash mho/feature-base >/dev/null 2>&1
  git -c user.name=Test -c user.email=t@t commit -m "squash-merge feature-base" >/dev/null
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git checkout mho/feature-ui >/dev/null 2>&1
)

api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

: >"$BRANCHLESS_LOG"
sync_out=$(STACK_TEST_MERGED_HEAD=mho/feature-base \
  STACK_TEST_MERGED_PR_JSON="[{\"number\":100,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefOid\":\"$BASE_HEAD_BEFORE_ADOPT\"}]" \
  run_stack sync 2>&1)

expect_contains "$sync_out" "Adopting #100"
api_after=$(git -C "$REPO" rev-parse mho/feature-api)
ui_after=$(git -C "$REPO" rev-parse mho/feature-ui)
[[ "$api_after" != "$api_before" ]] || fail "feature-api tip didn't move"
[[ "$ui_after" != "$ui_before" ]] || fail "feature-ui tip didn't move"
api_ahead=$(git -C "$REPO" rev-list --count main..mho/feature-api)
[[ "$api_ahead" == "1" ]] || fail "expected feature-api 1 ahead of main, got $api_ahead"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not a descendant of new feature-api"
pull_calls=$(grep -c "sync --pull" "$BRANCHLESS_LOG" || true)
[[ "$pull_calls" == "1" ]] \
  || fail "expected git-branchless sync --pull invoked exactly once, got $pull_calls: $(cat "$BRANCHLESS_LOG")"
echo "ok 9 - sync cascades squash-merged parent then invokes branchless once"

# ------------------------------------------------------------------------
# 10: stack push happy path — all branches with PRs + fresh leases get pushed,
#    no-PR branch skipped with agent handoff.
# ------------------------------------------------------------------------

# After test 8's cascade, feature-base is a sibling of main; mho/feature-ui
# has no PR in STACK_TEST_PR_JSON, so it must be skipped during push.
PG_LOG="$TEST_TMP/pg.log"
: >"$PG_LOG"

# Reset to a stable HEAD before stack push (which checks out branches).
git -C "$REPO" checkout main >/dev/null 2>&1

fresh_lease='{"allowed":true,"current":{"anchor_matches_head":true}}'
export STACK_TEST_PG_LOG="$PG_LOG"
export STACK_TEST_PG_CHECK_mho_feature_base="$fresh_lease"
export STACK_TEST_PG_CHECK_mho_feature_api="$fresh_lease"
push_out=$(run_stack push 2>&1)

expect_contains "$push_out" "Done."
# feature-ui has no PR (only #42 + #43 in STACK_TEST_PR_JSON) → skipped.
expect_contains "$push_out" "mho/feature-ui: no PR"
expect_contains "$push_out" "Agent handoff:"
expect_contains "$push_out" "#42 mho/feature-base"
expect_contains "$push_out" "update description: /update-pr-description 42"
expect_contains "$push_out" "mho/feature-ui -> base mho/feature-api"
expect_contains "$push_out" "create draft PR via /commit-push-pr after push-gate approval"
push_calls=$(grep -c "^push " "$PG_LOG" || true)
[[ "$push_calls" == "2" ]] \
  || fail "expected 2 pg push calls (base + api), got $push_calls: $(cat "$PG_LOG")"
force_push_calls=$(grep -c "^push push --force-with-lease" "$PG_LOG" || true)
[[ "$force_push_calls" == "2" ]] \
  || fail "expected pg push --force-with-lease for both pushes, got: $(cat "$PG_LOG")"
prep_calls=$(grep -c "^prepare " "$PG_LOG" || true)
[[ "$prep_calls" == "0" ]] \
  || fail "expected 0 pg prepare calls when leases fresh, got $prep_calls"
echo "ok 10 - stack push runs pg push --force-with-lease for fresh-lease branches, skips no-PR"

# ------------------------------------------------------------------------
# 11: stack push stops at first branch with stale/missing lease, runs
#     pg prepare and prints resume instructions. No further pushes.
# ------------------------------------------------------------------------

: >"$PG_LOG"
git -C "$REPO" checkout main >/dev/null 2>&1

# DFS order from order_tree walks roots in for-each-ref order (alphabetical):
# feature-api first → expect stop on feature-api.
unset STACK_TEST_PG_CHECK_mho_feature_base STACK_TEST_PG_CHECK_mho_feature_api
export STACK_TEST_PG_CHECK_DEFAULT='{"allowed":false}'
stop_out=$(run_stack push --prefix mho/feature- 2>&1)

expect_contains "$stop_out" "needs approval, preparing brief"
expect_contains "$stop_out" "Run: pg -C"
expect_contains "$stop_out" "Re-run: stack push --prefix mho/feature-"
expect_contains "$stop_out" "Agent handoff:"
expect_contains "$stop_out" "Re-run this stack: stack push --prefix mho/feature-"
prep_calls=$(grep -c "^prepare " "$PG_LOG" || true)
[[ "$prep_calls" == "1" ]] \
  || fail "expected exactly 1 pg prepare call (stop on first), got $prep_calls: $(cat "$PG_LOG")"
push_calls=$(grep -c "^push " "$PG_LOG" || true)
[[ "$push_calls" == "0" ]] \
  || fail "expected 0 pg push calls when first lease stale, got $push_calls"
echo "ok 11 - stack push stops at first stale lease with resume instructions"

# ------------------------------------------------------------------------
# 12: sync conflict preflight leaves real refs unchanged and auto-cleans
#     scratch on failure.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

set +e
conflict_out=$(STACK_TEST_BRANCHLESS_MODE=fail run_stack sync 2>&1)
conflict_rc=$?
set -e
[[ "$conflict_rc" != "0" ]] || fail "expected sync preflight failure"
expect_contains "$conflict_out" "scratch sync preflight failed"
expect_contains "$conflict_out" "CONFLICT conflict.txt"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$base_before" ]] || fail "feature-base moved after failed preflight"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "feature-api moved after failed preflight"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "feature-ui moved after failed preflight"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after failed sync: $scratch_left"
REPO="$OLD_REPO"
echo "ok 12 - sync preflight failure leaves refs unchanged and cleans scratch"

# ------------------------------------------------------------------------
# 13: successful sync imports scratch objects and applies all changed branch
#     refs, with scratch auto-cleanup on success.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

sync_apply_out=$(STACK_TEST_BRANCHLESS_MODE=advance-all run_stack sync 2>&1)
expect_contains "$sync_apply_out" "tip moved: mho/feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" != "$base_before" ]] || fail "feature-base did not move after successful sync"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api did not move after successful sync"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui did not move after successful sync"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after successful sync: $scratch_left"
REPO="$OLD_REPO"
echo "ok 13 - successful sync atomically applies branch updates and cleans scratch"

# ------------------------------------------------------------------------
# 14: stale real tips between preflight and apply abort the transaction
#     without applying other scratch updates.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

set +e
stale_out=$(STACK_TEST_BRANCHLESS_MODE=advance-all \
  STACK_TEST_STALE_REAL_REPO="$REPO" \
  run_stack sync 2>&1)
stale_rc=$?
set -e
[[ "$stale_rc" != "0" ]] || fail "expected stale-tip apply failure"
expect_contains "$stale_out" "aborted without partial updates"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$api_before" ]] || fail "test hook did not move feature-base to stale tip"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "feature-api should not receive scratch update after transaction abort"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "feature-ui should not receive scratch update after transaction abort"
[[ "$base_before" != "$api_before" ]] || fail "test setup invalid: base/api tips should differ"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after stale apply abort: $scratch_left"
REPO="$OLD_REPO"
echo "ok 14 - stale tips abort sync apply without partial updates"

# ------------------------------------------------------------------------
# 15: --keep-scratch preserves the scratch clone and prints a debug command.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)

set +e
keep_out=$(STACK_TEST_BRANCHLESS_MODE=fail run_stack sync --keep-scratch 2>&1)
keep_rc=$?
set -e
[[ "$keep_rc" != "0" ]] || fail "expected kept-scratch failure"
expect_contains "$keep_out" "Scratch kept:"
expect_contains "$keep_out" "Debug command:"
kept_repo=$(echo "$keep_out" | awk '/Scratch kept:/ {print $3; exit}')
[[ -d "$kept_repo/.git" ]] || fail "expected kept scratch repo at $kept_repo"
rm -rf "$(dirname "$kept_repo")"
REPO="$OLD_REPO"
echo "ok 15 - --keep-scratch preserves clone and prints debug command"

# ------------------------------------------------------------------------
# 16: squash collapses the current branch to one incremental commit and
#     restacks descendants.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)
git -C "$REPO" checkout mho/feature-base >/dev/null 2>&1

squash_out=$(run_stack squash -m "squashed base" 2>&1)
expect_contains "$squash_out" "Squashing 2 commits"
base_count=$(git -C "$REPO" rev-list --count origin/main..mho/feature-base)
[[ "$base_count" == "1" ]] || fail "expected feature-base to have one incremental commit, got $base_count"
subject=$(git -C "$REPO" log -1 --format='%s' mho/feature-base)
[[ "$subject" == "squashed base" ]] || fail "unexpected squash subject: $subject"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api was not restacked"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui was not restacked"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/feature-api \
  || fail "feature-api is not descendant of squashed feature-base"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of restacked feature-api"
REPO="$OLD_REPO"
echo "ok 16 - squash creates one commit and restacks descendants"

# ------------------------------------------------------------------------
# 17: lease lookup works from linked worktrees that share git-common-dir.
# ------------------------------------------------------------------------

LINKED_WT="$TEST_TMP/linked-worktree"
git -C "$REPO" worktree add --detach "$LINKED_WT" mho/feature-ui >/dev/null 2>&1
LINKED_WT=$(cd "$LINKED_WT" && git rev-parse --show-toplevel)
linked_out=$(
  cd "$LINKED_WT"
  PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" status --prefix mho/feature- 2>&1
)
expect_contains "$linked_out" "mho/feature-base"
base_linked_line=$(echo "$linked_out" | grep "mho/feature-base" || true)
expect_contains "$base_linked_line" "allowed"
linked_debug_out=$(
  cd "$LINKED_WT"
  STACK_DEBUG=1 PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" status --prefix mho/feature- 2>&1
)
expect_contains "$linked_debug_out" "stack: debug: status base="
expect_contains "$linked_debug_out" "stack: debug: lease lookup repo_root=$LINKED_WT"
expect_contains "$linked_debug_out" "main_repo_root=$REPO"
git -C "$REPO" worktree remove "$LINKED_WT" --force >/dev/null 2>&1
echo "ok 17 - leases render from linked worktrees"

# ------------------------------------------------------------------------
# 18: help and skill docs match the supported V1 command surface.
# ------------------------------------------------------------------------

help_out=$(run_stack --help 2>&1)
expect_contains "$help_out" "status [--json] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "squash [--dry-run] [-m SUBJECT] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "push [--dry-run] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "STACK_DEBUG=1"
expect_not_contains "$help_out" "prune"
skill_doc=$(cat "$ROOT/llm/skills/stack/SKILL.md")
expect_contains "$skill_doc" "stack squash [--dry-run]"
expect_contains "$skill_doc" "--keep-scratch"
expect_contains "$skill_doc" "STACK_DEBUG=1"
expect_not_contains "$skill_doc" "## Deferred"
echo "ok 18 - help and stack skill docs match supported commands"
