#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-ctxpack-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

git -C "$TMP" init -q
git -C "$TMP" config user.email test@example.com
git -C "$TMP" config user.name "Test User"
printf 'old\n' > "$TMP/example.txt"
git -C "$TMP" add example.txt
git -C "$TMP" commit -qm old
old_commit="$(git -C "$TMP" rev-parse HEAD)"

printf 'current\n' > "$TMP/example.txt"
git -C "$TMP" commit -qam current
current_commit="$(git -C "$TMP" rev-parse HEAD)"

printf 'remote\n' > "$TMP/example.txt"
git -C "$TMP" commit -qam remote
remote_commit="$(git -C "$TMP" rev-parse HEAD)"

doctor_output="$(env -u SECOND_BRAIN_DIR -u CTXPACK_BRAIN_DIR -u CTXPACK_BIBLE_DIR \
  HOME="$TMP/unconfigured-home" "$ROOT/bin/ctxpack" doctor)"
[[ "$doctor_output" == *"(disabled; set CTXPACK_BRAIN_DIR)"* ]] \
  || fail "private topic corpus was not explicit opt-in"
[[ "$doctor_output" == *"(disabled; set CTXPACK_BIBLE_DIR)"* ]] \
  || fail "private review corpus was not explicit opt-in"

# Reproduce a pooled Treehouse: detached work is based on the current remote
# history, while the ordinary local main branch is much older. origin/HEAD is
# deliberately a direct ref because that is the shape that exposed the bug.
git -C "$TMP" update-ref refs/remotes/origin/main "$remote_commit"
git -C "$TMP" update-ref refs/remotes/origin/HEAD "$remote_commit"
git -C "$TMP" branch -f main "$old_commit"
git -C "$TMP" checkout -q --detach "$current_commit"
printf 'working tree\n' > "$TMP/example.txt"

output="$(
  cd "$TMP"
  "$ROOT/bin/ctxpack" build --sections claim
)"

[[ "$output" == *'Diff base `HEAD`, 1 changed files.'* ]] \
  || fail "detached worktree used stale local main instead of the current remote history"

umask 022
(
  cd "$TMP"
  "$ROOT/bin/ctxpack" build --sections claim --out "$TMP/pack.md"
)
mode="$(stat -f '%Lp' "$TMP/pack.md" 2>/dev/null || stat -c '%a' "$TMP/pack.md")"
[[ "$mode" == 600 ]] || fail "context pack artifact mode was $mode, want 600"
rm "$TMP/pack.md"

# Dirty-worktree scope must match the snapshot tests and reviewers can read,
# including non-ignored untracked files. A large untracked implementation alone
# is enough to move the suggested tier to the wide-diff review.
mkdir -p "$TMP/tests" "$TMP/docs"
awk 'BEGIN {for (i=1;i<=412;i++) print "value_" i " = " i}' > "$TMP/snapshot_cache.py"
awk 'BEGIN {for (i=1;i<=451;i++) print "def test_value_" i "(): assert True"}' \
  > "$TMP/tests/test_snapshot_cache.py"
awk 'BEGIN {for (i=1;i<=112;i++) print "snapshot cache specification line " i}' \
  > "$TMP/docs/snapshot-cache.md"

dirty_output="$(
  cd "$TMP"
  "$ROOT/bin/ctxpack" build --base HEAD --sections scope
)"

[[ "$dirty_output" == *'Diff base `HEAD`, 4 changed files.'* ]] \
  || fail "scope header omitted tracked or untracked dirty-worktree files"
[[ "$dirty_output" == *'`snapshot_cache.py`'* ]] \
  || fail "scope ledger omitted an untracked implementation"
[[ "$dirty_output" == *'`tests/test_snapshot_cache.py`'* ]] \
  || fail "scope ledger omitted an untracked test"
[[ "$dirty_output" == *'Suggested tier: **2 — multi-model (wide diff)**'* ]] \
  || fail "untracked lines did not affect tier selection"
adds="$(printf '%s\n' "$dirty_output" | sed -n 's/^- Lines: +\([0-9][0-9]*\).*/\1/p')"
[[ "${adds:-0}" -ge 976 ]] \
  || fail "scope line count omitted untracked text"

printf 'ctxpack regression passed\n'
