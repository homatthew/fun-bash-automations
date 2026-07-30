#!/usr/bin/env bash
# Covers the Stop-event self-review guard: it must block exactly once per
# distinct diff, re-arm when the diff changes, stay silent once a review is
# recorded, and never wedge a session (no recursion, always exit 0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/llm/hooks/self-review-guard.sh"
TMP="$(mktemp -d -t fba-self-review-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
UPSTREAM="$TMP/upstream.git"
git init -q --bare --initial-branch=main "$UPSTREAM"
git init -q --initial-branch=main "$REPO"
cd "$REPO"
git config user.email t@t
git config user.name t
git remote add origin "$UPSTREAM"
printf 'one\n' > file.txt
git add file.txt
git commit -qm init
git push -q origin main
git branch --set-upstream-to=origin/main main >/dev/null 2>&1

payload() { printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":%s}' "$REPO" "${1:-false}"; }

run_guard() {
    local active="${1:-false}" out rc
    set +e
    out="$(payload "$active" | "$GUARD" 2>&1)"
    rc=$?
    set -e
    printf '%s\n' "$out"
    if [ "$rc" -ne 0 ]; then
        echo "guard exited $rc (must always exit 0 on the Stop path)" >&2
        exit 1
    fi
}

# --- clean tree: must not block -----------------------------------------------
out="$(run_guard)"
[ -z "$out" ] || { echo "expected silence on a clean tree, got: $out" >&2; exit 1; }

# --- PROPORTIONALITY: an ordinary small change must NOT block -----------------
# This is the whole point. A gate that fires every time gets routed around.
printf 'two\n' >> file.txt
out="$(run_guard)"
[ -z "$out" ] || { echo "a small ordinary diff must not prompt for review, got: $out" >&2; exit 1; }
git checkout -q -- file.txt

# --- sensitive surface blocks once -------------------------------------------
mkdir -p hooks
printf 'echo guard\n' > hooks/some-guard.sh
git add hooks/some-guard.sh
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a block on a sensitive path, got: $out" >&2; exit 1; }
grep -q 'sensitive surface' <<<"$out" || { echo "expected the trigger to be named: $out" >&2; exit 1; }
grep -q 'self-review-guard.sh --mark-reviewed' <<<"$out" || { echo "block reason must name the mark command: $out" >&2; exit 1; }
grep -q 'gpt-5.6-sol' <<<"$out" || { echo "block reason must name the reviewer roster: $out" >&2; exit 1; }
grep -q 'skipping review' <<<"$out" || { echo "block reason must bless the opt-out: $out" >&2; exit 1; }

# --- same diff again: must not block twice -----------------------------------
out="$(run_guard)"
[ -z "$out" ] || { echo "expected the guard to block only once per diff, got: $out" >&2; exit 1; }

# --- a new edit re-arms it ---------------------------------------------------
printf 'echo more\n' >> hooks/some-guard.sh
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a fresh block after a new edit, got: $out" >&2; exit 1; }

# --- stop_hook_active must short-circuit (no recursion) ----------------------
printf 'echo again\n' >> hooks/some-guard.sh
out="$(run_guard true)"
[ -z "$out" ] || { echo "expected silence when stop_hook_active=true, got: $out" >&2; exit 1; }

# --- --mark-reviewed suppresses the block for that exact diff ----------------
printf 'echo five\n' >> hooks/some-guard.sh
"$GUARD" --mark-reviewed >/dev/null
out="$(run_guard)"
[ -z "$out" ] || { echo "expected silence after --mark-reviewed, got: $out" >&2; exit 1; }

# ...but not for the next change.
printf 'echo six\n' >> hooks/some-guard.sh
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a block after changing a reviewed diff, got: $out" >&2; exit 1; }

# --- docs-only diffs are never "sensitive", whatever they are called ---------
git add -A && git commit -qm "sensitive baseline" && git push -q origin main
git branch --set-upstream-to=origin/main main >/dev/null 2>&1
printf '# auth and secret policy\n' > security-policy.md
git add security-policy.md
out="$(run_guard)"
[ -z "$out" ] || { echo "a docs-only diff must not count as sensitive, got: $out" >&2; exit 1; }
git rm -q --cached security-policy.md && rm -f security-policy.md

# --- wide diffs block on file count ------------------------------------------
for i in $(seq 1 20); do printf 'x\n' > "wide-$i.txt"; done
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a wide file-count diff to block, got: $out" >&2; exit 1; }
grep -q 'wide diff' <<<"$out" || { echo "expected the wide-diff trigger to be named: $out" >&2; exit 1; }
rm -f wide-*.txt

# --- wide diffs block on line count ------------------------------------------
seq 1 600 > big.txt
git add big.txt
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a wide line-count diff to block, got: $out" >&2; exit 1; }
git rm -q --cached big.txt && rm -f big.txt

# --- thresholds are tunable ---------------------------------------------------
printf 'small\n' >> file.txt
set +e
out="$(payload | FBA_REVIEW_MAX_LINES=0 "$GUARD" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "tunable path must exit 0, got $rc" >&2; exit 1; }
grep -q '"decision":"block"' <<<"$out" || { echo "FBA_REVIEW_MAX_LINES=0 should make everything block, got: $out" >&2; exit 1; }
git checkout -q -- file.txt

# --- editing branches are exempt outright ------------------------------------
git switch -q -c wip/experiment
mkdir -p hooks && printf 'echo scratch guard\n' > hooks/scratch-guard.sh
git add hooks/scratch-guard.sh
out="$(run_guard)"
[ -z "$out" ] || { echo "wip/ branches must be exempt, got: $out" >&2; exit 1; }
for b in scratch/x gnhf/y tmp/z experiment/w mho-yolo/fast yolo/fast other-yolo/fast; do
    git switch -q -c "$b"
    out="$(run_guard)"
    [ -z "$out" ] || { echo "$b must be exempt, got: $out" >&2; exit 1; }
done
# ...but a lookalike that is not actually a yolo/editing branch is NOT exempt.
git switch -q -c feature/yolo-rename
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "feature/yolo-rename must not be exempt, got: $out" >&2; exit 1; }
git switch -q main
git reset -q --hard HEAD
git clean -qfd

# --- commits ahead of upstream count, with a clean worktree ------------------
mkdir -p hooks
printf 'echo committed guard\n' > hooks/committed-guard.sh
git add hooks/committed-guard.sh
git commit -qm "ahead of upstream"
[ -z "$(git status --porcelain)" ] || { echo "expected a clean worktree here" >&2; exit 1; }
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected commits-ahead to arm the guard, got: $out" >&2; exit 1; }
grep -q 'commits ahead of' <<<"$out" || { echo "expected the summary to mention commits ahead: $out" >&2; exit 1; }

# --- opt-out ------------------------------------------------------------------
set +e
out="$(payload | FBA_SELF_REVIEW_GUARD=0 "$GUARD" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "opt-out must exit 0, got $rc" >&2; exit 1; }
[ -z "$out" ] || { echo "FBA_SELF_REVIEW_GUARD=0 must silence the guard, got: $out" >&2; exit 1; }

# --- outside a git repo: silent, not an error --------------------------------
set +e
out="$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$TMP" | "$GUARD" 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || { echo "non-repo cwd must exit 0, got $rc" >&2; exit 1; }
[ -z "$out" ] || { echo "non-repo cwd must be silent, got: $out" >&2; exit 1; }

# --- state file stays bounded -------------------------------------------------
state="$REPO/.git/fba-self-review.log"
for i in $(seq 1 260); do printf 'notified deadbeef%s\n' "$i" >> "$state"; done
printf 'eight\n' >> file.txt
run_guard >/dev/null
lines="$(wc -l < "$state" | tr -d ' ')"
[ "$lines" -le 201 ] || { echo "state file grew unbounded: $lines lines" >&2; exit 1; }

# --- regressions found by the independent review leg -------------------------

# Each case starts from a pristine checkout of origin/main so an earlier case's
# leftovers cannot trigger a different rule than the one under test.
reset_clean() {
    git switch -q main
    git reset -q --hard origin/main
    git clean -qfdx >/dev/null
}

# Editing an already-untracked file must re-arm the guard. Hashing only untracked
# *names* left the fingerprint unchanged, so an edited untracked file was never
# prompted about again.
reset_clean
printf 'echo one\n' > hooks/untracked-guard.sh   # untracked, sensitive path
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "expected a block on an untracked sensitive file, got: $out" >&2; exit 1; }
out="$(run_guard)"
[ -z "$out" ] || { echo "expected only one block for the same content, got: $out" >&2; exit 1; }
printf 'echo two\n' >> hooks/untracked-guard.sh  # same path, new content
out="$(run_guard)"
grep -q '"decision":"block"' <<<"$out" || { echo "editing an untracked file must re-arm the guard, got: $out" >&2; exit 1; }

# A large untracked file is a wide diff even though `git diff` cannot see it.
reset_clean
seq 1 900 > untracked-big.txt
out="$(run_guard)"
grep -q 'wide diff' <<<"$out" || { echo "a big untracked file must count as wide, got: $out" >&2; exit 1; }

# A new untracked *directory* must not hide its nested sensitive paths, which
# --untracked-files=normal would collapse to a single entry.
reset_clean
mkdir -p newdir/hooks
printf 'echo nested\n' > newdir/hooks/nested-guard.sh
out="$(run_guard)"
grep -q 'sensitive surface' <<<"$out" || { echo "a nested sensitive path in a new directory must be seen, got: $out" >&2; exit 1; }

# Staged tracked changes must count toward the width threshold; comparing only
# commit endpoints missed them entirely.
reset_clean
seq 1 900 > staged-big.txt
git add staged-big.txt
out="$(run_guard)"
grep -q 'wide diff' <<<"$out" || { echo "staged changes must count toward width, got: $out" >&2; exit 1; }

# An upstream-only change to a sensitive file must NOT be attributed to this
# branch. Two-dot `git diff base..HEAD` compares endpoints and would blame it.
reset_clean
git switch -q -c feature/diverged
printf 'local\n' > local-note.txt
git add local-note.txt
git commit -qm "local only, nothing sensitive"
# Advance upstream with a sensitive file this branch never touched.
git switch -q main
mkdir -p hooks
printf 'echo upstream\n' > hooks/upstream-guard.sh
git add hooks/upstream-guard.sh
git commit -qm "upstream sensitive change"
git push -q origin main
git switch -q feature/diverged
git branch --set-upstream-to=origin/main feature/diverged >/dev/null 2>&1
out="$(run_guard)"
grep -q 'sensitive surface' <<<"$out" && { echo "an upstream-only sensitive change must not be blamed on this branch, got: $out" >&2; exit 1; }
git switch -q main

# --- regressions found by the second review leg -------------------------------

# The fingerprint must not depend on which subdirectory the session was in.
# `git ls-files --others` is scoped to the current prefix, so without anchoring
# at the repo root the same diff hashed differently per cwd - which both
# re-prompted spuriously and stopped --mark-reviewed from ever matching.
reset_clean
mkdir -p sub/deeper
printf 'echo one\n' > hooks/cwd-guard.sh
printf 'x\n' > sub/deeper/other.txt
root_hash="$(cd "$REPO" && "$GUARD" --status | awk '/^diff:/ {print $2}')"
sub_hash="$(cd "$REPO/sub/deeper" && "$GUARD" --status | awk '/^diff:/ {print $2}')"
[ -n "$root_hash" ] || { echo "expected a fingerprint from the repo root" >&2; exit 1; }
if [ "$root_hash" != "$sub_hash" ]; then
    echo "fingerprint must not vary by cwd: root=$root_hash sub=$sub_hash" >&2
    exit 1
fi

# --mark-reviewed from a subdirectory must silence the guard at the root.
(cd "$REPO/sub/deeper" && "$GUARD" --mark-reviewed >/dev/null)
out="$(run_guard)"
[ -z "$out" ] || { echo "--mark-reviewed from a subdirectory must apply repo-wide, got: $out" >&2; exit 1; }

# An untracked file whose name forces git to c-quote it (a tab) must still be
# fingerprinted; a quoted path fails -f and used to be skipped silently.
reset_clean
weird="$(printf 'hooks/od\td.sh')"
printf 'echo one\n' > "$weird"
h1="$("$GUARD" --status | awk '/^diff:/ {print $2}')"
printf 'echo two\n' >> "$weird"
h2="$("$GUARD" --status | awk '/^diff:/ {print $2}')"
[ -n "$h1" ] || { echo "expected a fingerprint with a tab-named untracked file" >&2; exit 1; }
if [ "$h1" = "$h2" ]; then
    echo "editing a c-quoted untracked path must change the fingerprint" >&2
    exit 1
fi

# Many untracked files must not undercount: `xargs -0 wc -l` emits a per-batch
# total, so batch-splitting made the old last-total logic wrong.
reset_clean
mkdir -p many
i=1
while [ "$i" -le 400 ]; do
    seq 1 5 > "many/f$i.txt"
    i=$((i + 1))
done
out="$(run_guard)"
grep -q 'wide diff' <<<"$out" || { echo "2000 untracked lines must count as wide, got: $out" >&2; exit 1; }

# A large untracked file must not be read in full on every Stop.
reset_clean
seq 1 400000 > big-artifact.txt   # ~2.7MB
start=$(date +%s)
run_guard >/dev/null
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -le 10 ] || { echo "guard took ${elapsed}s with a large untracked file; read is not bounded" >&2; exit 1; }
reset_clean

echo "self-review-guard-regression: ok"
