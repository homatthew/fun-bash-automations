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

echo "1..31"

# ------------------------------------------------------------------------
# 1. status renders all three branches
# ------------------------------------------------------------------------
out=$(run_stack status 2>&1)
expect_contains "$out" "mho/feature-base"
expect_contains "$out" "mho/feature-api"
expect_contains "$out" "mho/feature-ui"
expect_contains "$out" "#42"
expect_contains "$out" "#43"
expect_contains "$out" "Next step:"
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
expect_not_contains "$json_out" "Next step:"
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
sync_dry_out=$(run_stack sync --dry-run 2>&1)
[[ ! -s "$BRANCHLESS_LOG" ]] || fail "dry-run should NOT call git-branchless, got: $(cat "$BRANCHLESS_LOG")"
expect_contains "$sync_dry_out" "Next step:"
expect_contains "$sync_dry_out" "Run the preflight and apply refs: stack sync"
echo "ok 6 - sync --dry-run skips git-branchless"

# ------------------------------------------------------------------------
# 7. sync invokes git-branchless sync --pull
# ------------------------------------------------------------------------
: >"$BRANCHLESS_LOG"
sync_normal_out=$(run_stack sync 2>&1)
grep -q "sync --pull" "$BRANCHLESS_LOG" || fail "expected git-branchless sync --pull, got: $(cat "$BRANCHLESS_LOG")"
expect_contains "$sync_normal_out" "Next step:"
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
# 10: stack push happy path — branches with PRs get updated and no-PR
#     branches with fresh leases get pushed for PR creation.
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
export STACK_TEST_PG_CHECK_mho_feature_ui="$fresh_lease"
push_out=$(run_stack push 2>&1)

expect_contains "$push_out" "Done."
# feature-ui has no PR (only #42 + #43 in STACK_TEST_PR_JSON), but a
# fresh lease lets stack push publish the branch for later PR creation.
expect_contains "$push_out" "mho/feature-ui: pushing branch for new stacked PR"
expect_contains "$push_out" "Agent handoff:"
expect_contains "$push_out" "Next step:"
expect_contains "$push_out" "Phase: needs PR description update"
expect_contains "$push_out" "#42 mho/feature-base"
expect_contains "$push_out" "update description: /update-pr-description 42"
expect_contains "$push_out" "mho/feature-ui -> base mho/feature-api"
expect_contains "$push_out" "create draft PR via /commit-push-pr after push-gate approval"
push_calls=$(grep -c "^push " "$PG_LOG" || true)
[[ "$push_calls" == "3" ]] \
  || fail "expected 3 pg push calls (base + api + ui), got $push_calls: $(cat "$PG_LOG")"
force_push_calls=$(grep -c "^push push --force-with-lease" "$PG_LOG" || true)
[[ "$force_push_calls" == "3" ]] \
  || fail "expected pg push --force-with-lease for all pushes, got: $(cat "$PG_LOG")"
set_upstream_calls=$(grep -c -- "--set-upstream" "$PG_LOG" || true)
[[ "$set_upstream_calls" == "1" ]] \
  || fail "expected --set-upstream for no-PR branch push, got: $(cat "$PG_LOG")"
prep_calls=$(grep -c "^prepare " "$PG_LOG" || true)
[[ "$prep_calls" == "0" ]] \
  || fail "expected 0 pg prepare calls when leases fresh, got $prep_calls"
echo "ok 10 - stack push runs pg push --force-with-lease for fresh leases including no-PR branches"

# ------------------------------------------------------------------------
# 11: stack push stops at first branch with stale/missing lease, runs
#     pg prepare and prints resume instructions. No further pushes.
# ------------------------------------------------------------------------

: >"$PG_LOG"
git -C "$REPO" checkout main >/dev/null 2>&1

# DFS order from order_tree walks roots in for-each-ref order (alphabetical):
# feature-api first → expect stop on feature-api.
unset STACK_TEST_PG_CHECK_mho_feature_base STACK_TEST_PG_CHECK_mho_feature_api STACK_TEST_PG_CHECK_mho_feature_ui
export STACK_TEST_PG_CHECK_DEFAULT='{"allowed":false}'
stop_out=$(run_stack push --prefix mho/feature- 2>&1)

expect_contains "$stop_out" "needs approval, preparing brief"
expect_contains "$stop_out" "Next step:"
expect_contains "$stop_out" "Human approval: pg -C"
expect_contains "$stop_out" "Agent re-run: stack push --prefix mho/feature-"
expect_contains "$stop_out" "Agent handoff:"
expect_contains "$stop_out" "Phase: needs approval"
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
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')
git -C "$REPO" checkout mho/feature-base >/dev/null 2>&1

squash_out=$(run_stack squash -m "squashed base" 2>&1)
expect_contains "$squash_out" "Squashing 2 commits"
expect_contains "$squash_out" "Next step:"
expect_contains "$squash_out" "Stale push-gate leases: mho/feature-api"
expect_contains "$squash_out" "approve/push with: stack push"
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
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
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
# 18: --pr --children scopes to the GitHub PR DAG and warns when local
#     ancestry disagrees.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/redundant-parent >/dev/null 2>&1
  printf 'redundant\n' >redundant.txt
  git add redundant.txt
  git commit -m "redundant parent" >/dev/null

  git checkout -b mho/pr266 >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/no-pr-child >/dev/null 2>&1
  printf 'no pr child\n' >no-pr-child.txt
  git add no-pr-child.txt
  git commit -m "no-pr child change" >/dev/null

  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr267 >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout main >/dev/null 2>&1
  git checkout -b mho/unrelated >/dev/null 2>&1
  printf 'unrelated\n' >unrelated.txt
  git add unrelated.txt
  git commit -m "unrelated change" >/dev/null
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"},
  {"number":271,"headRefName":"mho/unrelated","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/271","title":"unrelated"}
]')

scoped_status=$(run_stack status --pr 266 --children 2>&1)
expect_contains "$scoped_status" "Topology mismatch: PR #266 base is main, but local nearest parent is mho/redundant-parent"
expect_contains "$scoped_status" "GitHub PR base wins; local ancestry is stale/diagnostic"
expect_contains "$scoped_status" "Topology mismatch: PR #267 base is mho/pr266"
expect_contains "$scoped_status" "mho/pr266"
expect_contains "$scoped_status" "mho/pr267"
expect_contains "$scoped_status" "Next step:"
expect_contains "$scoped_status" "stack checkout --pr 266"
expect_contains "$scoped_status" "stack squash --pr 266 --onto-pr-base"
expect_contains "$scoped_status" "stack push --pr 266 --children"
expect_not_contains "$scoped_status" "stack push --dry-run"
expect_not_contains "$scoped_status" "mho/no-pr-child"
expect_not_contains "$scoped_status" "mho/unrelated"

scoped_push=$(run_stack push --dry-run --pr 266 --children 2>&1)
expect_contains "$scoped_push" "Push order:"
expect_contains "$scoped_push" "[1/2] mho/pr266"
expect_contains "$scoped_push" "[2/2] mho/pr267"
expect_contains "$scoped_push" "Next step:"
expect_contains "$scoped_push" "First live push action: stack push --pr 266 --children will prepare mho/pr266"
expect_contains "$scoped_push" "Downstream approvals wait: mho/pr267"
expect_contains "$scoped_push" "Re-run this stack: stack push --pr 266 --children"
expect_not_contains "$scoped_push" "mho/no-pr-child"
expect_not_contains "$scoped_push" "mho/unrelated"
echo "ok 18 - PR-scoped DAG filters unrelated branches and warns on local mismatches"

# ------------------------------------------------------------------------
# 19: squash can use an explicit PR base instead of the detected local parent.
# ------------------------------------------------------------------------

git -C "$REPO" checkout mho/pr266 >/dev/null 2>&1
scoped_squash=$(run_stack squash --dry-run --pr 266 --onto-pr-base -m "Fix Cassandra memory sizing and resource counts" 2>&1)
expect_contains "$scoped_squash" "Squashing 2 commits on mho/pr266 relative to origin/main"
expect_contains "$scoped_squash" "Next step:"
expect_not_contains "$scoped_squash" "relative to mho/redundant-parent"
REPO="$OLD_REPO"
echo "ok 19 - squash --pr --onto-pr-base ignores redundant local parent"

# ------------------------------------------------------------------------
# 20: checkout --pr resolves an open PR to its local branch and prints the
#     middle-stack edit workflow.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr266 >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/pr267 >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout main >/dev/null 2>&1
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"}
]')

checkout_out=$(run_stack checkout --pr 266 2>&1)
current_branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[[ "$current_branch" == "mho/pr266" ]] || fail "expected checkout to move to mho/pr266, got $current_branch"
expect_contains "$checkout_out" "Checked out PR #266: mho/pr266"
expect_contains "$checkout_out" "=== Stack context ==="
expect_contains "$checkout_out" "mho/pr267"
expect_contains "$checkout_out" "Next step:"
expect_contains "$checkout_out" "Commit changes: git add <files> && git commit -m \"<subject>\""
expect_contains "$checkout_out" "stack squash --pr 266 --onto-pr-base"
expect_contains "$checkout_out" "stack push --dry-run --pr 266 --children"
expect_contains "$checkout_out" "stack push --pr 266 --children"
echo "ok 20 - checkout --pr switches to PR branch and prints edit workflow"

# ------------------------------------------------------------------------
# 21: checkout --pr refuses dirty worktrees.
# ------------------------------------------------------------------------

printf 'dirty\n' >"$REPO/dirty.tmp"
set +e
dirty_checkout_out=$(run_stack checkout --pr 266 2>&1)
dirty_checkout_rc=$?
set -e
[[ "$dirty_checkout_rc" != "0" ]] || fail "expected dirty checkout refusal"
expect_contains "$dirty_checkout_out" "working tree dirty"
rm -f "$REPO/dirty.tmp"
echo "ok 21 - checkout --pr refuses dirty worktrees"

# ------------------------------------------------------------------------
# 22: checkout --pr fails clearly when the PR is missing.
# ------------------------------------------------------------------------

set +e
missing_pr_out=$(run_stack checkout --pr 999 2>&1)
missing_pr_rc=$?
set -e
[[ "$missing_pr_rc" != "0" ]] || fail "expected missing PR failure"
expect_contains "$missing_pr_out" "open PR not found in stack data: #999"
echo "ok 22 - checkout --pr reports missing PRs"

# ------------------------------------------------------------------------
# 23: checkout --pr fails clearly when the PR branch is not local.
# ------------------------------------------------------------------------

STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":299,"headRefName":"mho/missing-local","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/299","title":"missing local"}
]')
set +e
missing_branch_out=$(run_stack checkout --pr 299 2>&1)
missing_branch_rc=$?
set -e
[[ "$missing_branch_rc" != "0" ]] || fail "expected missing local branch failure"
expect_contains "$missing_branch_out" "PR #299 branch not found locally: mho/missing-local"
REPO="$OLD_REPO"
echo "ok 23 - checkout --pr reports missing local branches"

# ------------------------------------------------------------------------
# 24: insert --dry-run prints the planned inserted-branch and descendant
#     rebases without moving refs.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout mho/feature-base >/dev/null 2>&1
  git checkout -b mho/inserted --no-track >/dev/null 2>&1
  printf 'inserted\n' >inserted.txt
  git add inserted.txt
  git commit -m "inserted change" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/inserted)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

insert_dry=$(run_stack insert --dry-run --branch mho/inserted --after mho/feature-base 2>&1)
expect_contains "$insert_dry" "Insert plan:"
expect_contains "$insert_dry" "Scope:         local descendants under mho/"
expect_contains "$insert_dry" "(dry-run) git rebase --onto mho/feature-base"
expect_contains "$insert_dry" "(dry-run) git rebase --onto mho/inserted"
expect_contains "$insert_dry" "Run the preflight and apply refs: stack insert --branch mho/inserted --after mho/feature-base"
[[ "$(git -C "$REPO" rev-parse mho/inserted)" == "$insert_before" ]] || fail "dry-run moved inserted branch"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "dry-run moved feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "dry-run moved feature-ui"
REPO="$OLD_REPO"
echo "ok 24 - insert --dry-run prints planned rebases without moving refs"

# ------------------------------------------------------------------------
# 25: insert applies a scratch-preflighted local restack atomically and
#     reports stale leases for moved branches.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/inserted --no-track >/dev/null 2>&1
  printf 'inserted\n' >inserted.txt
  git add inserted.txt
  git commit -m "inserted change" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/inserted)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

insert_live=$(run_stack insert --branch mho/inserted --after mho/feature-base 2>&1)
expect_contains "$insert_live" "Preflighting insert in scratch"
expect_contains "$insert_live" "Applying"
expect_contains "$insert_live" "Inserted mho/inserted after mho/feature-base"
expect_contains "$insert_live" "Stale push-gate leases: mho/feature-api"
[[ "$(git -C "$REPO" rev-parse mho/inserted)" != "$insert_before" ]] || fail "inserted branch did not move onto feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api did not move after insert"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui did not move after insert"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/inserted \
  || fail "inserted branch is not descendant of feature-base"
git -C "$REPO" merge-base --is-ancestor mho/inserted mho/feature-api \
  || fail "feature-api is not descendant of inserted branch"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of feature-api after insert"
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
REPO="$OLD_REPO"
echo "ok 25 - insert preflights and applies local restack with stale lease reporting"

# ------------------------------------------------------------------------
# 26: insert conflict preflight leaves real refs unchanged and auto-cleans
#     scratch on failure.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/conflict-after --no-track >/dev/null 2>&1
  printf 'after\n' >after.txt
  git add after.txt
  git commit -m "conflict after" >/dev/null

  git checkout -b mho/conflict-child --no-track >/dev/null 2>&1
  printf 'child\n' >conflict.txt
  git add conflict.txt
  git commit -m "conflict child" >/dev/null

  git checkout mho/conflict-after >/dev/null 2>&1
  git checkout -b mho/conflict-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >conflict.txt
  git add conflict.txt
  git commit -m "conflict insert" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/conflict-insert)
child_before=$(git -C "$REPO" rev-parse mho/conflict-child)

set +e
conflict_insert=$(run_stack insert --prefix mho/conflict- --branch mho/conflict-insert --after mho/conflict-after 2>&1)
conflict_insert_rc=$?
set -e
[[ "$conflict_insert_rc" != "0" ]] || fail "expected insert preflight conflict"
expect_contains "$conflict_insert" "scratch insert preflight failed"
expect_contains "$conflict_insert" "Real branch refs were not changed"
[[ "$(git -C "$REPO" rev-parse mho/conflict-insert)" == "$insert_before" ]] || fail "conflict insert moved inserted branch"
[[ "$(git -C "$REPO" rev-parse mho/conflict-child)" == "$child_before" ]] || fail "conflict insert moved child branch"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-insert.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "insert scratch dirs should be removed after failed preflight: $scratch_left"
REPO="$OLD_REPO"
echo "ok 26 - insert preflight conflict leaves refs unchanged and cleans scratch"

# ------------------------------------------------------------------------
# 27: insert --after-pr scopes descendants through GitHub PR baseRefName,
#     excluding no-PR local children.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr266 --no-track >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/pr267 --no-track >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout mho/pr266 >/dev/null 2>&1
  git checkout -b mho/no-pr-child --no-track >/dev/null 2>&1
  printf 'no pr child\n' >no-pr-child.txt
  git add no-pr-child.txt
  git commit -m "no-pr child change" >/dev/null

  git checkout mho/pr266 >/dev/null 2>&1
  git checkout -b mho/pr-insert --no-track >/dev/null 2>&1
  printf 'pr insert\n' >pr-insert.txt
  git add pr-insert.txt
  git commit -m "pr insert change" >/dev/null
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"}
]')
pr267_before=$(git -C "$REPO" rev-parse mho/pr267)
no_pr_before=$(git -C "$REPO" rev-parse mho/no-pr-child)

pr_insert=$(run_stack insert --branch mho/pr-insert --after-pr 266 2>&1)
expect_contains "$pr_insert" "Scope:         GitHub PR DAG rooted at #266"
expect_contains "$pr_insert" "PR bases:      not changed by this command"
expect_contains "$pr_insert" "Inserted mho/pr-insert after mho/pr266"
[[ "$(git -C "$REPO" rev-parse mho/pr267)" != "$pr267_before" ]] || fail "PR child did not move after PR-scoped insert"
[[ "$(git -C "$REPO" rev-parse mho/no-pr-child)" == "$no_pr_before" ]] || fail "no-PR child should not move in PR-scoped insert"
git -C "$REPO" merge-base --is-ancestor mho/pr-insert mho/pr267 \
  || fail "PR child is not descendant of inserted branch"
REPO="$OLD_REPO"
echo "ok 27 - insert --after-pr restacks PR children but excludes no-PR local children"

# ------------------------------------------------------------------------
# 28: trunk materialize --dry-run reads a private stack manifest and does
#     not create or move refs.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "demo",
    base: "origin/main",
    trunk: "mho/demo.trunk",
    items: [
      {id: "base", branch: "mho/feature-base"},
      {id: "api", branch: "mho/feature-api"},
      {id: "ui", branch: "mho/feature-ui"}
    ]
  }' >.stack/demo.json
  git add .stack/demo.json
  git commit -m "add stack manifest" >/dev/null
)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

trunk_dry=$(run_stack trunk materialize --dry-run --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_dry" "Stack trunk: demo"
expect_contains "$trunk_dry" "Trunk: mho/demo.trunk"
expect_contains "$trunk_dry" "Refs unchanged in dry-run"
git -C "$REPO" rev-parse --verify mho/demo.trunk >/dev/null 2>&1 \
  && fail "dry-run should not create private trunk"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$base_before" ]] || fail "dry-run moved feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "dry-run moved feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "dry-run moved feature-ui"
REPO="$OLD_REPO"
echo "ok 28 - trunk materialize --dry-run leaves refs unchanged"

# ------------------------------------------------------------------------
# 29: trunk materialize constructs a private trunk and hard-points each stack
#     branch to its corresponding commit, including a manifest insertion.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout mho/feature-base >/dev/null 2>&1
  git checkout -b mho/feature-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >insert.txt
  git add insert.txt
  git commit -m "insert middle feature" >/dev/null

  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "demo",
    base: "origin/main",
    trunk: "mho/demo.trunk",
    items: [
      {id: "base", branch: "mho/feature-base"},
      {id: "insert", branch: "mho/feature-insert"},
      {id: "api", branch: "mho/feature-api"},
      {id: "ui", branch: "mho/feature-ui"}
    ]
  }' >.stack/demo.json
  git add .stack/demo.json
  git commit -m "add stack manifest" >/dev/null
)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

trunk_live=$(run_stack trunk materialize --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_live" "Preflighting private trunk materialization in scratch"
expect_contains "$trunk_live" "Materialized private trunk: mho/demo.trunk"
expect_contains "$trunk_live" "Stale push-gate leases: mho/feature-api"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/feature-insert \
  || fail "insert branch is not descendant of feature-base"
git -C "$REPO" merge-base --is-ancestor mho/feature-insert mho/feature-api \
  || fail "feature-api is not descendant of inserted branch"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$(git -C "$REPO" rev-parse mho/demo.trunk)" ]] \
  || fail "private trunk should point to final stack commit"
trunk_status=$(run_stack trunk status --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_status" "Pointer"
expect_contains "$trunk_status" "mho/demo.trunk"
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
REPO="$OLD_REPO"
echo "ok 29 - trunk materialize builds private trunk and pointer branches"

# ------------------------------------------------------------------------
# 30: trunk materialize conflict preflight leaves all real refs unchanged.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/trunk-after --no-track >/dev/null 2>&1
  printf 'after\n' >after.txt
  git add after.txt
  git commit -m "trunk after" >/dev/null

  git checkout -b mho/trunk-child --no-track >/dev/null 2>&1
  printf 'child\n' >conflict.txt
  git add conflict.txt
  git commit -m "trunk child" >/dev/null

  git checkout mho/trunk-after >/dev/null 2>&1
  git checkout -b mho/trunk-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >conflict.txt
  git add conflict.txt
  git commit -m "trunk insert" >/dev/null

  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "conflict",
    base: "origin/main",
    trunk: "mho/conflict.trunk",
    items: [
      {id: "after", branch: "mho/trunk-after"},
      {id: "insert", branch: "mho/trunk-insert"},
      {id: "child", branch: "mho/trunk-child"}
    ]
  }' >.stack/conflict.json
  git add .stack/conflict.json
  git commit -m "add conflict stack manifest" >/dev/null
)
after_before=$(git -C "$REPO" rev-parse mho/trunk-after)
insert_before=$(git -C "$REPO" rev-parse mho/trunk-insert)
child_before=$(git -C "$REPO" rev-parse mho/trunk-child)

set +e
trunk_conflict=$(run_stack trunk materialize --manifest .stack/conflict.json 2>&1)
trunk_conflict_rc=$?
set -e
[[ "$trunk_conflict_rc" != "0" ]] || fail "expected trunk materialize conflict"
expect_contains "$trunk_conflict" "stack trunk materialize preflight failed"
expect_contains "$trunk_conflict" "Real branch refs were not changed"
[[ "$(git -C "$REPO" rev-parse mho/trunk-after)" == "$after_before" ]] || fail "trunk conflict moved after branch"
[[ "$(git -C "$REPO" rev-parse mho/trunk-insert)" == "$insert_before" ]] || fail "trunk conflict moved insert branch"
[[ "$(git -C "$REPO" rev-parse mho/trunk-child)" == "$child_before" ]] || fail "trunk conflict moved child branch"
git -C "$REPO" rev-parse --verify mho/conflict.trunk >/dev/null 2>&1 \
  && fail "failed trunk materialize should not create private trunk"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-trunk.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "trunk scratch dirs should be removed after failed preflight: $scratch_left"
REPO="$OLD_REPO"
echo "ok 30 - trunk materialize conflict leaves refs unchanged and cleans scratch"

# Restore default fake PR data for the final help/doc test.
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":42,"headRefName":"mho/feature-base","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"url":"https://x/42","title":"base"},
  {"number":43,"headRefName":"mho/feature-api","baseRefName":"mho/feature-base","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"url":"https://x/43","title":"api"}
]')

# ------------------------------------------------------------------------
# 31: help and skill docs match the supported command surface.
# ------------------------------------------------------------------------

help_out=$(run_stack --help 2>&1)
expect_contains "$help_out" "status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]"
expect_contains "$help_out" "checkout --pr N [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "insert --branch BRANCH (--after BRANCH|--after-pr N)"
expect_contains "$help_out" "trunk materialize --name NAME|--manifest PATH"
expect_contains "$help_out" "squash [--dry-run] [-m SUBJECT] [--branch BRANCH] [--onto REF|--onto-pr-base]"
expect_contains "$help_out" "push [--dry-run] [--base REF] [--prefix PREFIX] [--pr N] [--children]"
expect_contains "$help_out" "STACK_DEBUG=1"
expect_contains "$help_out" "Every human-readable command prints Next step:"
expect_not_contains "$help_out" "prune"
skill_doc=$(cat "$ROOT/llm/skills/stack/SKILL.md")
expect_contains "$skill_doc" "stack squash [--dry-run]"
expect_contains "$skill_doc" "--onto-pr-base"
expect_contains "$skill_doc" "--keep-scratch"
expect_contains "$skill_doc" "stack insert --branch"
expect_contains "$skill_doc" "stack trunk materialize"
expect_contains "$skill_doc" "STACK_DEBUG=1"
expect_contains "$skill_doc" "Next step:"
expect_contains "$skill_doc" "stack checkout --pr <N>"
stack_doc=$(cat "$ROOT/llm/stack/README.md")
expect_contains "$stack_doc" "GitHub PR base wins"
expect_contains "$stack_doc" "stack insert --branch"
expect_contains "$stack_doc" "private trunk"
expect_contains "$stack_doc" "Next step:"
expect_contains "$stack_doc" "stack checkout --pr <N>"
expect_not_contains "$skill_doc" "## Deferred"
echo "ok 31 - help and stack skill docs match supported commands"
