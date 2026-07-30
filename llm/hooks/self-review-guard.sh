#!/usr/bin/env bash
# Stop-event guard: prompt once, on the diffs that actually warrant review.
#
# Design constraint, learned the hard way from the no-mistakes gate: a check that
# fires on *every* change and cannot be escaped stops being a safety net and
# becomes something you route around. So this one is deliberately weak in two
# ways, and both are features:
#
#   1. Proportional - it stays silent unless the diff earns attention (sensitive
#      surface, or wide enough that eyeballing it is unreliable). Editing
#      branches (wip/, scratch/, gnhf/, tmp/, experiment/, and any *yolo/) are
#      exempt outright.
#   2. Escapable - it blocks at most once per distinct diff, and its own message
#      tells the agent that "skipping review: <reason>" is a legitimate answer.
#      It can prompt; it can never trap.
#
# The hard safety controls are elsewhere and are NOT like this: protected-branch
# pushes, force-pushes, and --no-verify stay blocked by bash-safety-guard.sh and
# the git-level pre-push hook. This hook only ever asks for a code review.
#
# Contract:
#   stdin  : Claude Code Stop-hook JSON payload
#   stdout : {"decision":"block","reason":"..."} to refuse the stop, else nothing
#   exit   : 0 for every outcome including a normal block. The single exception
#            is the jq-less fallback, which blocks via exit 2 (the documented
#            stderr mechanism) *after* the once-only claim is already recorded.
#            No error path exits non-zero, so a guard bug cannot wedge a session.
#
# Subcommands (for the review workflow itself, not the hook event):
#   --mark-reviewed   record the current diff as reviewed
#   --status          print the current diff, its state, and whether it triggers
#
# Tunables: FBA_REVIEW_MAX_FILES (15), FBA_REVIEW_MAX_LINES (400),
# FBA_SELF_REVIEW_GUARD=0 to disable entirely.

set -uo pipefail

STATE_BASENAME='fba-self-review.log'
STATE_KEEP_LINES=200

log_path() {
    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    [ -n "$git_dir" ] || return 1
    printf '%s/%s\n' "$git_dir" "$STATE_BASENAME"
}

# Run everything from the repository root. `git ls-files --others` is scoped to
# the current prefix, so fingerprinting from a subdirectory would both miss
# untracked files elsewhere in the tree and make the hash depend on which
# directory the session happened to be in - breaking "once per distinct diff"
# and stopping `--mark-reviewed` from ever matching a hash recorded elsewhere.
cd_repo_root() {
    local top
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$top" ] || return 1
    cd "$top" 2>/dev/null
}

# Untracked files, NUL-separated. -z matters as much as --others: without it git
# c-quotes paths containing newlines, tabs, or high-bit bytes, and a quoted path
# fails the -f test and gets silently skipped.
untracked_files0() {
    git ls-files -z --others --exclude-standard 2>/dev/null
}

# Per-file read cap for fingerprinting. Untracked build artifacts would
# otherwise be read in full on every Stop - the same per-invocation cost problem
# this change removes from the completions.
UNTRACKED_HASH_BYTES=65536

# A stable fingerprint of everything a reviewer would look at: staged and
# unstaged tracked changes, untracked file *contents*, and any commits this
# branch has that its upstream / default base does not.
#
# Hashing untracked contents (not just names) is load-bearing: without it,
# editing an already-untracked file leaves the fingerprint unchanged, so a diff
# that was already prompted about would never re-arm the guard. Size and mtime
# go in alongside the capped content so an edit past the cap still registers.
diff_hash() {
    local base f meta
    {
        git status --porcelain=v1 --untracked-files=all 2>/dev/null
        git diff HEAD 2>/dev/null
        if base="$(base_ref)"; then
            git log --format='%H' "$base..HEAD" 2>/dev/null
        fi
        untracked_files0 | while IFS= read -r -d '' f; do
            [ -f "$f" ] || continue
            meta="$(stat -f '%z %m' -- "$f" 2>/dev/null \
                    || stat -c '%s %Y' -- "$f" 2>/dev/null)"
            printf '=== %s %s\n' "$f" "$meta"
            head -c "$UNTRACKED_HASH_BYTES" -- "$f" 2>/dev/null
        done
    } | shasum -a 256 2>/dev/null | cut -d' ' -f1
}

# Prefer the tracked upstream; fall back to the first default branch that exists.
base_ref() {
    local up b
    if up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" \
       && [ -n "$up" ]; then
        printf '%s\n' "$up"
        return 0
    fi
    for b in origin/HEAD origin/main origin/master main master develop trunk; do
        if git rev-parse --verify --quiet "$b" >/dev/null 2>&1; then
            printf '%s\n' "$b"
            return 0
        fi
    done
    return 1
}

has_changes() {
    [ -n "$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null)" ] && return 0
    local base
    base="$(base_ref)" || return 1
    [ -n "$(git log --format='%H' -1 "$base..HEAD" 2>/dev/null)" ]
}

# ---- proportionality ---------------------------------------------------------
# A gate that fires on every change is a gate you learn to route around. This
# one fires only when the diff earns it: risky surface, or wide enough that
# reading it yourself stops being reliable. Everything else just ships.

# Editing branches are exempt outright - review is a delivery concern, not an
# editing concern. `*yolo/` (including `mho-yolo/`) is deliberately in here: the
# point of a yolo branch is to move fast and review the end state once, on
# request, rather than being asked on every stop.
EXEMPT_BRANCH_RE='^(wip|scratch|gnhf|tmp|experiment)/|(^|-)yolo/'

# Paths where a subtle mistake is expensive and hard to notice later.
RISK_PATH_RE='(^|/)(hooks?|\.github/workflows|migrations?)/|guard|polic(y|ies)|auth|credential|secret|token|password|crypt|security|settings\.json$|Dockerfile|entrypoint'

# Three dots, not two: `git diff a..b` compares endpoints, so on a diverged
# branch an upstream-only change to a sensitive file would be attributed to this
# branch. `a...b` diffs from the merge base, which is what "what did I change"
# means.
changed_paths() {
    local base
    git status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c4-
    if base="$(base_ref)"; then
        git diff --name-only "$base...HEAD" 2>/dev/null
    fi
    untracked_files0 | tr '\0' '\n'
}

# Why this diff needs review, or nothing if it does not.
review_trigger() {
    local branch paths risky files lines base
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
    if printf '%s' "$branch" | grep -Eq "$EXEMPT_BRANCH_RE"; then
        return 1
    fi

    paths="$(changed_paths | sed '/^$/d' | sort -u)"
    [ -n "$paths" ] || return 1

    # Documentation-only diffs are never "risky", whatever the filename says.
    risky="$(printf '%s\n' "$paths" | grep -Ev '\.(md|markdown|txt|rst)$' \
             | grep -Ei "$RISK_PATH_RE" | head -3)"
    if [ -n "$risky" ]; then
        printf 'touches sensitive surface: %s\n' \
            "$(printf '%s' "$risky" | tr '\n' ' ' | sed 's/ $//')"
        return 0
    fi

    files="$(printf '%s\n' "$paths" | wc -l | tr -d ' ')"
    if [ "$files" -gt "${FBA_REVIEW_MAX_FILES:-15}" ]; then
        printf 'wide diff: %s files changed\n' "$files"
        return 0
    fi

    # Size has three independent parts, and all three count:
    #   1. committed churn since the merge base (three dots, not two - see above)
    #   2. the working tree, staged and unstaged, against HEAD
    #   3. untracked files, which no `git diff` can see at all
    lines=0
    if base="$(base_ref)"; then
        lines=$(( lines + $(shortstat_sum "$base...HEAD") ))
    fi
    lines=$(( lines + $(shortstat_sum HEAD) ))
    lines=$(( lines + $(untracked_line_count) ))

    if [ "$lines" -gt "${FBA_REVIEW_MAX_LINES:-400}" ]; then
        printf 'wide diff: %s changed lines\n' "$lines"
        return 0
    fi

    return 1
}

# Insertions + deletions for a `git diff` revision spec, or 0.
shortstat_sum() {
    local n
    n="$(git diff --shortstat "$@" 2>/dev/null \
         | grep -oE '[0-9]+ (insertion|deletion)' \
         | grep -oE '^[0-9]+' | paste -sd+ - | bc 2>/dev/null)"
    case "$n" in
        ''|*[!0-9]*) printf '0\n' ;;
        *)           printf '%s\n' "$n" ;;
    esac
}

# Concatenate and count once, rather than reading `wc -l`'s per-file output.
# `xargs -0 wc -l` emits one "total" line *per batch*, so with enough untracked
# files to split the batch, taking the last total undercounts and summing every
# line double-counts. Piping through cat sidesteps the whole ambiguity.
untracked_line_count() {
    local n
    n="$(untracked_files0 | xargs -0 cat 2>/dev/null | wc -l 2>/dev/null | tr -d ' ')"
    case "$n" in
        ''|*[!0-9]*) printf '0\n' ;;
        *)           printf '%s\n' "$n" ;;
    esac
}

state_of() {
    local hash="$1" path
    path="$(log_path)" || return 1
    [ -f "$path" ] || return 1
    # Last recorded state wins; reviewed beats notified.
    if grep -q "^reviewed $hash\$" "$path" 2>/dev/null; then
        printf 'reviewed\n'
        return 0
    fi
    if grep -q "^notified $hash\$" "$path" 2>/dev/null; then
        printf 'notified\n'
        return 0
    fi
    return 1
}

record() {
    local state="$1" hash="$2" path tmp
    path="$(log_path)" || return 1
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
    printf '%s %s\n' "$state" "$hash" >> "$path" 2>/dev/null || return 1
    # Bound the file instead of pruning per-entry files.
    if [ "$(wc -l < "$path" 2>/dev/null || echo 0)" -gt "$STATE_KEEP_LINES" ]; then
        tmp="$path.tmp.$$"
        if tail -n "$STATE_KEEP_LINES" "$path" > "$tmp" 2>/dev/null; then
            mv -f "$tmp" "$path" 2>/dev/null || true
        fi
    fi
    return 0
}

# Serialize state mutation across concurrent sessions in the same repo.
# `state_of` + `record` as separate steps let two Stop hooks both see
# "unreviewed" and both block; concurrent prunes could also drop a
# just-appended record. mkdir is atomic on every filesystem we care about.
#
# Every caller fails OPEN if the lock cannot be taken: staying quiet is always
# preferable to risking a duplicate prompt or a wedged session.
lock_acquire() {
    local path lock waited=0
    path="$(log_path)" || return 1
    lock="$path.lock"
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 1

    # Reap a lock orphaned by a killed session. `find -mmin +1` rounds down, so
    # this triggers at roughly two minutes, far above the critical section
    # (two greps and an append).
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$lock" 2>/dev/null
    fi

    while ! mkdir "$lock" 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -ge 20 ] && return 1
        sleep 0.1 2>/dev/null || return 1
    done
    return 0
}

lock_release() {
    local path
    path="$(log_path)" || return 0
    rmdir "$path.lock" 2>/dev/null || true
}

# Claim the right to prompt about $1, exactly once. Returns 0 if we own it.
claim_notify() {
    local hash="$1" claimed=1
    lock_acquire || return 1
    if state_of "$hash" >/dev/null 2>&1; then
        claimed=1              # somebody already handled this diff
    elif record notified "$hash"; then
        claimed=0              # we own the prompt
    fi
    lock_release
    return "$claimed"
}

# Record a completed review under the same lock, so its prune cannot race a
# concurrent claim_notify and drop a just-appended entry.
record_reviewed() {
    local hash="$1" rc
    lock_acquire || return 1
    record reviewed "$hash"
    rc=$?
    lock_release
    return "$rc"
}

changed_summary() {
    local base n
    n="$(git status --porcelain=v1 --untracked-files=normal 2>/dev/null | wc -l | tr -d ' ')"
    printf 'uncommitted files: %s' "$n"
    if base="$(base_ref)"; then
        printf '; commits ahead of %s: %s' "$base" \
            "$(git log --format='%H' "$base..HEAD" 2>/dev/null | wc -l | tr -d ' ')"
    fi
    printf '\n'
}

# ---- subcommands -------------------------------------------------------------

case "${1:-}" in
    --mark-reviewed)
        cd_repo_root || { echo "not a git repository" >&2; exit 1; }
        h="$(diff_hash)"
        [ -n "$h" ] || { echo "could not fingerprint the working tree" >&2; exit 1; }
        record_reviewed "$h" || { echo "could not write review state" >&2; exit 1; }
        printf 'self-review recorded for %s\n' "${h:0:12}"
        exit 0
        ;;
    --status)
        cd_repo_root || { echo "not a git repository" >&2; exit 1; }
        h="$(diff_hash)"
        printf 'branch:  %s\n' "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        printf 'diff:    %s\n' "${h:0:12}"
        printf 'state:   %s\n' "$(state_of "$h" || echo unreviewed)"
        printf 'changes: %s\n' "$(changed_summary)"
        if t="$(review_trigger)"; then
            printf 'trigger: %s\n' "$t"
        else
            printf 'trigger: none - would not prompt for review\n'
        fi
        exit 0
        ;;
    -h|--help)
        sed -n '2,29p' "$0"
        exit 0
        ;;
esac

# ---- Stop-hook path ----------------------------------------------------------

[ "${FBA_SELF_REVIEW_GUARD:-1}" = "0" ] && exit 0

payload=''
if [ ! -t 0 ]; then
    payload="$(cat 2>/dev/null || true)"
fi

# Never block a stop that is itself the result of this hook blocking.
if [ -n "$payload" ] && command -v jq >/dev/null 2>&1; then
    if [ "$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
        exit 0
    fi
    cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)"
    [ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null
fi

# Anchor at the repository root so the fingerprint does not depend on which
# subdirectory this session happened to be sitting in.
cd_repo_root || exit 0
has_changes || exit 0

# Proportional: most diffs never reach the block below.
trigger="$(review_trigger)" || exit 0

hash="$(diff_hash)"
[ -n "$hash" ] || exit 0

# Atomically claim the single prompt for this diff. Records before emitting, so
# a crash between the two fails open (no prompt) rather than closed (a loop).
claim_notify "$hash" || exit 0

reason="This diff looks worth a second pair of eyes before you finish - $trigger ($(changed_summary | tr -d '\n')), in $(git rev-parse --show-toplevel 2>/dev/null || pwd).

Send the diff to an independent reviewer model (Codex gpt-5.6-sol, or Cursor claude-opus-5-thinking-high / kimi-k3-high via the cursor-sub-review skill - see the \`ship\` skill), act on anything real it finds, then record it:

  ~/.claude/hooks/self-review-guard.sh --mark-reviewed

Skipping is a legitimate answer. If review does not fit here - the user asked you to stop, it is a throwaway experiment, you already had this reviewed, or it is simply not worth it - tell the user in one line (\"skipping review: <reason>\") and stop again. This is a prompt, not a gate: it fires once per diff and will not ask again about this one."

if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$reason" '{decision:"block", reason:$r}' 2>/dev/null && exit 0
fi

# jq-less fallback. Exit 2 is the documented non-JSON way to hand a Stop hook's
# stderr back to the model; it is a deliberate block, not a crash. It is safe
# here because the once-only claim above is already recorded, so the next Stop
# passes regardless. Everything that is *not* a deliberate block exits 0.
printf '%s\n' "$reason" >&2
exit 2
