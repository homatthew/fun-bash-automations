#!/usr/bin/env bash

derive_label() {
  local repo summary n
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo '?')")"

  # 1. An open PR title: human-written, already reviewed for clarity.
  summary="$(gh pr view --json title -q .title 2>/dev/null | head -1 || true)"

  # 2. Commit subjects against the base.
  if [ -z "$summary" ] && [ "$resolved_base" != "HEAD" ]; then
    n="$(git rev-list --count "$resolved_base"..HEAD 2>/dev/null || echo 0)"
    if [ "${n:-0}" -eq 1 ]; then
      summary="$(git log -1 --format=%s 2>/dev/null || true)"
    elif [ "${n:-0}" -gt 1 ]; then
      summary="$(git log -1 --format=%s 2>/dev/null || true)"
      [ -z "$summary" ] || summary="$summary (+$((n - 1)))"
    fi
  fi

  # 3. Uncommitted work has no subject; name the area it touches instead.
  if [ -z "$summary" ]; then
    local changed top nfiles
    changed="$(git diff --name-only "$( [ "$resolved_base" = HEAD ] && echo HEAD || echo "$resolved_base...HEAD" )" 2>/dev/null || true)"
    [ -n "$changed" ] || changed="$(git diff --name-only HEAD 2>/dev/null || true)"
    changed="$(printf '%s\n' "$changed"; git ls-files --others --exclude-standard 2>/dev/null)"
    changed="$(printf '%s\n' "$changed" | sort -u | grep -v '^$' || true)"
    nfiles="$(printf '%s\n' "$changed" | grep -c . || true)"
    top="$(printf '%s\n' "$changed" | awk -F/ 'NF>1{print $1"/"$2; next}{print $1}' \
           | sort | uniq -c | sort -rn | awk 'NR==1{$1="";sub(/^ /,"");print}')"
    summary="uncommitted in ${top:-working tree} (${nfiles:-?} files)"
  fi

  summary="$(printf '%s' "$summary" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [ "${#summary}" -le 52 ] || summary="${summary:0:49}..."
  printf 'review: %s · %s' "$repo" "$summary"
}

# ------------------------------------------------------ pack and prompt ----

pack="$dir/pack.md"; diff="$dir/diff.patch"; prompt="$dir/prompt.md"

write_review_diff() {  # write_review_diff <base>
  local review_base="$1" f
  if [ "$review_base" = HEAD ]; then
    git diff HEAD 2>/dev/null
  else
    # The first patch is the branch's three-dot delivery scope. The second is
    # the tracked working-tree overlay reviewers/tests currently see.
    git diff "$review_base"...HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Text is included in full. Binary content is represented by git's explicit
    # "Binary files differ" marker. The prompt-size cap below handles oversized
    # text by refusing the round, never by silently dropping a file.
    git diff --no-index -- /dev/null "$f" 2>/dev/null || true
  done < <(git ls-files --others --exclude-standard 2>/dev/null)
}

say "building context pack"
if [ -n "$base" ]; then ctxpack build --base "$base" --out "$pack" || die "ctxpack build failed"
else ctxpack build --out "$pack" || die "ctxpack build failed"; fi

resolved_base="$(awk -F'`' '/Diff base/{print $2; exit}' "$pack")"
[ -n "$resolved_base" ] || resolved_base="HEAD"
write_review_diff "$resolved_base" > "$diff"
[ -s "$diff" ] || die "empty diff against $resolved_base — nothing to review"

{
  cat <<'HDR'
You are one of four INDEPENDENT code reviewers. You cannot see the others and
you must not try to; the value of this exercise is that the opinions are
uncorrelated. Look for correctness problems, then try to disprove each
candidate. A clean review is valid; do not invent a finding to fill a section.

Inspect the repository freely to check any claim. Do not commit or push, and do
not "fix" what you find — you are reviewing, and the author decides. Editing the
tree under review also invalidates the other three legs' snapshot.
Keep inspection inside the repository root. Never run `find`, `grep`, or another
recursive search from `/`, HOME, or a broad parent directory; use repo-local
`rg`, file globs, or a narrowly resolved dependency path.

**Write your finished report to the path given in your first message**, then say
so in the pane. Write the file even if you also print the report: the pane only
retains about one screenful, so the file is the durable copy.

After that, stay up and stay conversational. Expect follow-ups — "defend finding
2", "what would the test look like", "keep going". Hold your context.

**If the review tooling itself gets in your way, file it.** You are the best
reporter of a defect in this harness because you just hit it in anger:

Use the attributed `ctxreview --bug` command in your first message. It carries
this run, leg, and parent session so the defect can be traced to its outcome.

Worth filing: the pack was missing something you needed, a section was wrong or
truncated, an instruction contradicted itself, your report path was unwritable,
the diff looked stale. This is a separate channel from your findings — do not put
tooling complaints in the report, and do not let them replace reviewing the code.
One line each, then carry on.

The context pack below is the evidence this diff is being judged against: the
repo's own written conventions, sibling-file precedent, per-file history, domain
notes, previously adjudicated findings, and review lenses. Use it — a finding
that cites a convention with its call sites lands in one round; a finding that
cites your taste is churn.

Rules that come from this corpus and are not negotiable:

1. Never state a convention without the count. "Other services do this" is an
   opinion; "9 of 11 sibling factories call setupAuthInterceptor, at these
   lines" is evidence. The pack's Sibling precedent section computes this, but
   it is a LEAD, not a finding — open two of the cited siblings before writing
   the comment.
2. If you assert a consequence, cite the code that produces it (the consumer, by
   file and line) or narrow the finding to the asymmetry alone. An overstated
   consequence is what gets a correct finding dismissed.
3. Check the pack's code-bible section first. A rule marked `rejected` is a
   finding already turned down with a reason. Re-raising it without addressing
   that reason wastes a round.
4. Prefer a check you can settle with a command over an argument in prose.
5. Say "I could not verify X" rather than guessing. Do not invent line numbers.
6. Check actual scale, callers, rollout, and existing guarantees. Trace the path
   through the downstream consumer before stating the consequence.
7. Keep design preferences and future prerequisites separate from current
   correctness failures. Recommend the smallest invariant the failure needs.

Report findings as:

### Critical / Important / Observation
N. **[title]** — file:line
   Evidence: [what you observed, with the command or excerpt that shows it]
   Fix: [specific action]

Then report:
- **Uncovered failure path:** name one only if it is reachable under the stated
  constraints; otherwise say that none survived review.
- **Weakest test:** identify one only when a concrete implementation break would
  leave it green; otherwise say that none survived review.
- **Unverified:** anything you asserted but could not check.

HDR
  # A focused round states its scope before the pack, so the reviewer reads the
  # pack in service of one question instead of sweeping.
  if [ -n "$focus" ]; then
    printf '\n===== THIS ROUND IS FOCUSED: %s =====\n\n' "$focus"
    cat <<FOC
Report only findings in this class. Other problems you happen to notice go in a
single short "outside this round's scope" list at the end — one line each, no
evidence, no fixes. Do not let them crowd out the focused work.

If you find nothing in this class, say so explicitly and say what you checked.
"No findings" and "I did not look" must not read the same, and a focused round
that returns silence is worthless.

The full checks for this round follow. They are the accumulated evidence for this
class in this codebase, not general advice — cite them.

FOC
    # No `local` here: this block runs at top level inside a command group, not
    # in a function, and bash rejects `local` there.
    for lf in $focus_files; do
      printf '\n----- lens: %s -----\n\n' "$(basename "$lf")"; cat "$lf"
    done
    printf '\n===== END FOCUS =====\n'
  fi

  printf '\n===== CONTEXT PACK =====\n\n'; cat "$pack"
  printf '\n===== DIFF (base %s) =====\n\n' "$resolved_base"; cat "$diff"
} > "$prompt"

# Fingerprint the tree the legs are about to review.
#
# Legs are no longer sandboxed read-only — that is what lets them write their own
# report — which also means any of them CAN edit the tree under review. One Cursor
# pane reported "2 files edited" during a round; no mtime changed in the window so
# nothing was proven, but the capability is real and the consequence is severe: if
# the tree moves, every leg's findings refer to a diff that no longer exists, and
# the other legs were reviewing a different snapshot than the one you now hold.
#
# Cheaper and more reliable than trying to prevent it per-runtime: record what the
# tree looked like, and have --consolidate refuse to present findings silently if
# it changed.
{ git status --porcelain 2>/dev/null; git rev-parse HEAD 2>/dev/null; } \
  | shasum 2>/dev/null | awk '{print $1}' > "$dir/.tree-fingerprint" || true

bytes="$(wc -c < "$prompt" | tr -d ' ')"
say "pack $(wc -l < "$pack" | tr -d ' ') lines, diff $(wc -l < "$diff" | tr -d ' ') lines, prompt $bytes bytes"

# Derived here, not earlier: it needs the resolved base and the changed files.
[ -n "$label" ] || label="$(derive_label)"

# Keep review labels visually distinct inside the isolated session. Ownership
# and cleanup come from the persisted Herdr session name, never label scanning.
case "$label" in
  "review: "*) ;;
  *) label="review: $label" ;;
esac
say "label: $label"

# Refuse to ship a prompt nobody will actually read in full. Four legs each
# silently truncating a 1.6 MB prompt looks exactly like four completed reviews.
# The corpus rule is: never truncate quietly -- so fail with the options instead.
if [ "$bytes" -gt "$MAX_BYTES" ] && [ "$force" -eq 0 ]; then
  cat >&2 <<EOF
$SELF: prompt is $bytes bytes (cap $MAX_BYTES).

A diff this size does not get reviewed, it gets skimmed or truncated -- and a
truncated leg is indistinguishable from a thorough one in its output. Options:

  narrow the base      $SELF --base <later-ref>
  review a subrange    git diff <base>...HEAD -- <dir>   then review that branch
  split the branch     one reviewable claim per PR (see llm/AGENTS.md scope rules)
  override             $SELF --force        (say so when you report the findings)
EOF
  exit 2
fi

if [ "$dry" -eq 1 ]; then
  printf '\nPlan (dry run)\n  dir    %s\n  base   %s\n  legs   %s\n  label  %s\n' \
    "$dir" "$resolved_base" "$legs" "$label"
  exit 0
fi

# --------------------------------------------------------------- panes -----

# Every round gets its own named Herdr 0.8 session and socket. Layout changes
# are therefore incapable of touching the user's default session or focus.
# Session stop hibernates the entire round; restart restores the layout and the
# native agent conversations.
#
# Every create/split still uses `--no-focus` inside the isolated session so a
# later TUI attach opens predictably.
# --again: retire the previous round for this repo, then run a fresh one.
#
# The legs are deliberately NOT told what the last round found. A leg shown prior
# findings drifts toward confirming them, and the corpus rule is that the author
# of a finding is the wrong judge of its fix -- which applies to a sibling model
# reading the same list. If you want a targeted re-check, that is what --focus is
# for.
#
# Closing first matters for a reason beyond tidiness: two generations of findings
# left side by side read as two legs agreeing, which is exactly the false-quorum
# signal --consolidate exists to prevent.
if [ "$again" -eq 1 ]; then
  # Retire only rounds owned by this parent session for this repository. Global
  # cwd/prefix matching can close another agent's review and cannot detect an
  # idle-but-composing Cursor leg.
  repo_name="$(basename "$repo_root")"
  prior_found=0; prior_waiting=0
  for prior_record in "$(session_runs_dir)"/*.json; do
    [ -s "$prior_record" ] || continue
    [ "$(jq -r '.owner_session // empty' "$prior_record")" = "$owner_session" ] || continue
    [ "$(jq -r '.repo_root // empty' "$prior_record")" = "$repo_root" ] || continue
    [ "$(jq -r '.status // empty' "$prior_record")" != closed ] || continue
    prior_found=$((prior_found+1))
    close_session_record "$prior_record"
    if [ "$(jq -r '.status // empty' "$prior_record")" != closed ]; then
      prior_waiting=$((prior_waiting+1))
    fi
  done
  if [ "$prior_found" -eq 0 ]; then
    say "--again: no previous owned review workspace for $repo_name; running a first round"
  elif [ "$prior_waiting" -gt 0 ]; then
    die "--again: $prior_waiting previous owned round(s) are still working, blocked, composing, or unverifiable"
  fi
fi

HERDR_SESSION_NAME="${herdr_session_override:-ctxreview-$(date +%y%m%d-%H%M%S)-$$}"
case "$HERDR_SESSION_NAME" in
  ""|[!a-z]*|*[!a-z0-9_-]*)
    die "invalid --herdr-session name (use lowercase letters, digits, _ or -)" ;;
esac
[ "${#HERDR_SESSION_NAME}" -le 63 ] \
  || die "--herdr-session name must be at most 63 characters"
named_session_exists "$HERDR_SESSION_NAME" \
  && die "Herdr session $HERDR_SESSION_NAME already exists; use --respawn on its persisted run"
start_named_session "$HERDR_SESSION_NAME" \
  || die "could not start isolated Herdr session $HERDR_SESSION_NAME"
say "isolated Herdr session: $HERDR_SESSION_NAME"

ws=""; p1=""
say "creating isolated review workspace"
wjson="$(herdr workspace create --cwd "$PWD" --label "$label" --no-focus 2>&1)"
ws="$(printf '%s' "$wjson" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)"
p1="$(printf '%s' "$wjson" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
[ -n "$ws" ] && [ -n "$p1" ] || die "could not create the isolated review workspace: $wjson"
# (herdr speaks JSON and its ids contain a colon, `w1:p55`, so these are parsed
# with jq — a regex returned `w1` and every pane op then addressed the wrong
# target.)
# Herdr agent names are global, not workspace-scoped. Include this run's first
# pane id so two review workspaces can run the same leg concurrently.
agent_suffix="$(printf '%s' "$p1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[ -n "$agent_suffix" ] || agent_suffix="$$"
