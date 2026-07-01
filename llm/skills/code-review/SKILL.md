---
name: code-review
description: Use when reviewing a PR, branch diff, or staged changes. Use when the user says "review", "code review", "/code-review", or "review this PR".
---

# Multi-Agent Code Review

An orchestrated review that gathers context, then spawns two independent sub-agent reviews in parallel (Claude and Codex) with fresh context. Consolidates findings into a unified report. Each reviewer forms its own hypothesis independently — no shared bias.

**This is a RIGID skill. Follow the phases in exact order. Do not skip or reorder.**

## Scope: the one deep-review entrypoint (q9v.19)

This skill is the **single sanctioned deep-review entrypoint**, run **pre-gate**
(before `no-mistakes`). Review has exactly two layers:

1. **This `code-review` skill** — the deep, human-triggered review (dual
   Claude+Codex). Reach all deep review through here.
2. **The `no-mistakes` gate** — the automated review step that runs on every ship.

Deprecated as standalone entrypoints (reach them only *via* this skill): the
`code-review` plugin, the standalone `pr-review-toolkit` commands, and the
`test-code-reviewer` agent. This skill may still draw on the
`pr-review-toolkit:code-reviewer` agent type internally (see below).

`simplify`, `ai-slop-removal`, and `/security-review` are pre-gate cleanup
passes that complement review, not separate review surfaces — run them before
shipping to the gate.

## Phase 1: Context Gathering

### 1a: Detect review scope

Try in order:

1. If user provides a PR number: `gh pr view <N> --json files,body,title,commits` and `gh pr diff <N>`
2. If on a feature branch: `git log main..HEAD --oneline` and `git diff main...HEAD`
3. If staged changes exist: `git diff --cached`
4. Otherwise: ask the user what to review

Collect the list of changed files. Partition into:
- **test files** (paths containing `test_`, `_test`, `tests/`, `spec/`, `.test.`)
- **implementation files** (everything else)

### 1b: Gather author context

- PR description / title
- Commit messages (`git log --format="%s%n%n%b" main..HEAD`)
- Any linked issues

### 1c: Gather domain context

Search these sources for relevant background:
- Second-brain topics: `~/repos/dump/second-brain/topics/` — glob for keywords from the PR
- Project memory: `.claude/projects/*/memory/` — check MEMORY.md
- Project AGENTS.md and CLAUDE.md files
- Architecture docs in the repo (`ARCHITECTURE.md`, `docs/`, `design/`)

### 1d: Form and present hypothesis

Output to user before proceeding:

```
## Phase 1: Problem Hypothesis

**Business invariant:** [restate in your own words what must be true]
**What a wrong solution looks like:** [describe a plausible implementation that appears correct but solves the wrong problem]
**Domain edge cases:** [list 2-4 edge cases that a correct solution must handle]
```

**Wait for user acknowledgment or correction before proceeding.**

### 1e: Build context package

After user confirms hypothesis, assemble a **context package** string containing:
- The full diff
- List of changed files (test vs implementation)
- PR description and commit messages
- The confirmed business hypothesis
- Relevant domain context found in 1c

This package will be passed verbatim to both sub-agents.

## Phase 2: Parallel Sub-Agent Reviews

Use the runtime-specific launch path below. In both paths, reviewers get the same context package and should not see each other's intermediate findings.

### Claude Runtime Launch Path

When running inside Claude Code, spawn **both agents in a single message** so they run in parallel. Each gets fresh context — no carry-over from the main conversation.

- Agent A: `pr-review-toolkit:code-reviewer`
- Agent B: `codex:codex-rescue`

### Codex Runtime Launch Path

When running inside Codex, there is no native `pr-review-toolkit:code-reviewer` subagent. Invoke Claude as a local external reviewer with `claude --print`, and run the Codex review locally or via a Codex subagent. Do not use cloud review commands such as `ultrareview`; this workflow must be reproducible from local repo context.

1. Write the Claude prompt to a temp file:

   ```bash
   claude_prompt="$(mktemp -t code-review-claude-prompt)"
   # write Agent A prompt into "$claude_prompt"
   ```

2. Start Claude from the repository root in a detached `tmux` session. Claude
   must write stream JSON, stderr, the extracted final result, and the exit code
   to files. Do **not** stream Claude's JSONL into the Codex transcript.

   **Codex exec runtimes must not launch Claude with shell backgrounding (`&`)
   from a one-shot command.** The exec harness can clean up the process tree as
   soon as the shell command returns, leaving zero-byte JSONL/stderr files.
   `nohup` and `setsid` are not reliable here either. Use `tmux`, then poll tiny
   file status from Codex.

   ```bash
   review_dir="$(mktemp -d -t code-review-claude)"
   claude_jsonl="$review_dir/claude.jsonl"
   claude_err="$review_dir/claude.err"
   claude_result="$review_dir/claude.result.md"
   claude_rc="$review_dir/claude.rc"
   claude_runner="$review_dir/run-claude-review.sh"
   claude_session="code-review-claude-$(date +%s)-$RANDOM"

   cat > "$claude_runner" <<'EOF'
   #!/usr/bin/env bash
   set -o pipefail

   claude_cmd="$(command -v t3-claude || command -v claude)"
   "$claude_cmd" --version >/dev/null
   claude_effort="${CODE_REVIEW_CLAUDE_EFFORT:-max}"

   NOTIFY_SUPPRESS=1 "$claude_cmd" -p \
     --agent pr-review-toolkit:code-reviewer \
     --permission-mode plan \
     --tools "Read,Grep,Glob,Bash" \
     --no-session-persistence \
     --effort "$claude_effort" \
     --output-format stream-json \
     --include-partial-messages \
     --include-hook-events \
     --verbose \
     < "$CLAUDE_PROMPT" > "$CLAUDE_JSONL" 2> "$CLAUDE_ERR"
   rc=$?

   jq -r 'select(.type == "result") | .result // empty' "$CLAUDE_JSONL" | tail -1 > "$CLAUDE_RESULT" || true
   if [ ! -s "$CLAUDE_RESULT" ]; then
     jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$CLAUDE_JSONL" > "$CLAUDE_RESULT" || true
   fi
   printf '%s\n' "$rc" > "$CLAUDE_RC"
   exit "$rc"
   EOF
   chmod +x "$claude_runner"

   tmux new-session -d -s "$claude_session" \
     "cd '$PWD' && CLAUDE_PROMPT='$claude_prompt' CLAUDE_JSONL='$claude_jsonl' CLAUDE_ERR='$claude_err' CLAUDE_RESULT='$claude_result' CLAUDE_RC='$claude_rc' '$claude_runner'"

   printf 'Claude review session: %s\nreview_dir=%s\n' "$claude_session" "$review_dir"
   ```

3. While Claude runs, perform Agent B's Codex review independently in the current Codex session, using the Agent B prompt below.

4. Wait for Claude before consolidation. **Do not proceed to consolidation
   just because Claude is slow.** Poll only low-volume status from Codex:
   never `cat` the JSONL, never tail large output, and do not paste Claude's
   reasoning stream into the chat. Use a heartbeat that detects both progress
   and stalls.

   ```bash
   heartbeat_interval_seconds="${CODE_REVIEW_HEARTBEAT_SECONDS:-30}"
   stuck_after_heartbeats="${CODE_REVIEW_STUCK_HEARTBEATS:-6}"
   last_events=-1
   last_bytes=-1
   unchanged_heartbeats=0

   while tmux has-session -t "$claude_session" 2>/dev/null; do
     events="$(wc -l < "$claude_jsonl" 2>/dev/null || echo 0)"
     bytes="$(wc -c < "$claude_jsonl" 2>/dev/null || echo 0)"
     stderr_bytes="$(wc -c < "$claude_err" 2>/dev/null || echo 0)"
     echo "Claude reviewer heartbeat; events=$events bytes=$bytes stderr=$stderr_bytes unchanged=$unchanged_heartbeats" >&2

     if [ "$events" = "$last_events" ] && [ "$bytes" = "$last_bytes" ]; then
       unchanged_heartbeats=$((unchanged_heartbeats + 1))
     else
       unchanged_heartbeats=0
       last_events="$events"
       last_bytes="$bytes"
     fi

     if [ "$unchanged_heartbeats" -ge "$stuck_after_heartbeats" ]; then
       echo "Claude reviewer appears stuck: no JSONL progress for $unchanged_heartbeats heartbeat intervals." >&2
       echo "Inspect or restart the Claude reviewer; do not consolidate without either a Claude result or an explicit note that this leg was unavailable." >&2
       tail -80 "$claude_err" >&2
       exit 124
     fi

     sleep "$heartbeat_interval_seconds"
   done

   echo "Claude reviewer finished; rc=$(cat "$claude_rc" 2>/dev/null || echo unknown) result_bytes=$(wc -c < "$claude_result" 2>/dev/null || echo 0) stderr=$(wc -c < "$claude_err" 2>/dev/null || echo 0)" >&2
   ```

   After Claude finishes, read only the final extracted result:

   ```bash
   claude_rc_value="$(cat "$claude_rc" 2>/dev/null || echo 1)"
   claude_findings="$(cat "$claude_result" 2>/dev/null || true)"
   if [ "$claude_rc_value" != "0" ] || [ -z "$claude_findings" ]; then
     echo "Claude reviewer failed or produced no result; stderr follows:" >&2
     tail -80 "$claude_err" >&2
   fi
   ```

5. If `claude` is unavailable, exits non-zero, produces no findings, or the
   heartbeat exits `124` for a no-progress stall, first try to fix the local
   issue and rerun the Claude leg once. Continue with the Codex review only
   after that retry also fails, and explicitly report that the Claude leg was
   unavailable. Do not invent `[Claude]` findings.

Prefer `t3-claude` when available; it bypasses slow Netflix wrapper startup paths that can trip short health-check or command timeouts. Use the strongest local effort mode the installed CLI actually supports. Default to `max`; if a local wrapper supports `ultracode`, set `CODE_REVIEW_CLAUDE_EFFORT=ultracode` after confirming the CLI does not print `Unknown --effort value`. Do not pass write tools to Claude for review. Use `NOTIFY_SUPPRESS=1` so the nested Claude review does not create duplicate desktop notifications. Keep the JSONL file until after consolidation when debugging a long or empty Claude run; otherwise remove the temp prompt/output/error files after consolidation.

If wrapping the Claude invocation in zsh, store command return codes in a
variable such as `rc`; do not assign to `status`, which is a read-only zsh
special parameter.

### Agent A: Claude Code Reviewer

Use the `pr-review-toolkit:code-reviewer` agent type. Prompt template:

```
You are reviewing code changes. Here is the full context:

## Changed Files
{file list, partitioned into test/implementation}

## PR Description & Commits
{PR title, body, commit messages}

## Business Hypothesis (confirmed by author)
{hypothesis from Phase 1d}

## Domain Context
{relevant findings from 1c}

## Diff
{full diff content}

Review this code for:
1. **Correctness**: Does the implementation match the stated business invariant?
2. **False-pass bugs**: Describe at least one plausible bug that would pass all existing tests
3. **Test quality**: Classify tests as behavioral/mechanical/tautological. Identify missing coverage.
4. **Assumptions**: List every assumption the code makes. What breaks if each is wrong?
5. **Magic values**: Flag any literals/defaults without justification
6. **Simplicity**: Could this be done with less code? Unnecessary indirection?
   Watch especially for validations that enforce one business invariant but are
   scattered across generic control flow; prefer one named policy/validation
   helper that owns the invariant and its failure modes.
7. **Hidden state machines**: Flag nested helpers or closures that combine lazy loading, caching, sentinel flags, `nonlocal` mutation, and swallowed failures. Prefer an explicit state object, clear return contract, or simpler phase ordering.
8. **Silent failures**: What could break elsewhere with no test failing?
9. **Unrelated diff churn**: Flag cosmetic edits to code the change didn't need to touch — dropped/reworded docstrings or comments that still applied, conditionals reflowed with identical behavior (e.g. `if/else` → ternary), casing-only changes, or local-variable renames. Each looks harmless but together they bury the real change and risk silent regressions; they belong in a separate cleanup commit, not this one.

Output findings in this format:

### Critical
N. **[title]** — file:line
   Evidence: [what you observed]
   Fix: [specific action]

### Important
N. **[title]** — file:line
   Evidence: [what you observed]
   Fix: [specific action]

### Observation
N. **[title]** — file:line
   Note: [what you observed]

### Mandatory
- **False-pass bug:** [description]
- **Test compression:** [N lines → ~M lines, how]
```

### Agent B: Codex Code Reviewer

Use the `codex:codex-rescue` agent type. Prompt template:

```
Perform an independent code review of the following changes. Do NOT just validate — actively look for problems.

## Changed Files
{file list}

## PR Description & Commits
{PR title, body, commit messages}

## Business Hypothesis
{hypothesis from Phase 1d}

## Domain Context
{relevant findings from 1c}

## Diff
{full diff content}

Focus your review on:
1. **Correctness bugs**: Logic errors, off-by-ones, missed edge cases
2. **Assumption violations**: What does this code assume that could be wrong?
3. **Integration risks**: What could break in callers, consumers, or downstream systems?
4. **Error handling**: Silent swallows, inappropriate fallbacks, missing error paths
5. **Race conditions or ordering issues** (if concurrent code)
6. **API contract violations**: Does this change any observable behavior for callers?
7. **Hidden state machines**: Look for functions that are hard to reason about because they mix lazy loading, caching, sentinel flags, `nonlocal` state, and error swallowing. Suggest a concrete refactor, such as an explicit result object or moving the load/resolve phase out of the inner loop.
8. **Unrelated diff churn**: Cosmetic edits to code the change didn't need to touch — reworded comments/docstrings, conditionals reformatted with identical logic, casing changes, or local-variable renames. Call these out so they can be reverted or split into a separate cleanup commit.

For each finding, provide:
- Severity: Critical / Important / Observation
- File and line reference
- What you observed (evidence)
- Specific fix suggestion

Output as a numbered list grouped by severity.
```

## Phase 3: Consolidation

After both agents return their findings:

1. **Deduplicate**: If both reviewers flag the same issue at the same file:line (or clearly the same logical issue), merge into one finding tagged `[Both]`
2. **Elevate**: Findings flagged by both reviewers are higher confidence — if one called it Important and the other Critical, use Critical
3. **Preserve unique findings**: Keep findings only one reviewer caught, tagged `[Claude]` or `[Codex]`
4. **Classify**: Group all findings as Critical > Important > Observation
5. **Include mandatory items**: False-pass bug and test compression from the Claude reviewer

## Phase 4: Targeted Deep Dives

Do not stop after the first-pass consolidation. Run a second review iteration
for the riskiest areas before presenting final findings.

1. Select up to 3 targets for deeper review:
   - any Critical finding
   - any finding tagged `[Both]`
   - any touched implementation file with non-trivial branching, state,
     persistence, network calls, concurrency, migrations, auth, or API contracts
   - any test that appears to assert mocked/stubbed behavior instead of caller
     visible behavior
2. For each target, create a small drill-down package containing only:
   - the relevant finding or risk hypothesis
   - the relevant diff hunk(s)
   - nearby caller/callee snippets needed to reason about the contract
   - relevant tests
3. Send each target to a fresh local reviewer when possible. Prefer a new
   `t3-claude -p` invocation with read-only tools and the strongest supported
   local effort mode (`CODE_REVIEW_CLAUDE_EFFORT=ultracode` only if supported;
   otherwise `max`). Otherwise do a fresh local pass with the same narrow
   package. These are challenge reviews: ask the reviewer to prove or disprove
   the risk, find the next layer of failure, and name the smallest confirming
   test.
4. Merge drill-down results back into the findings:
   - promote confirmed risks
   - demote or remove disproven findings
   - add any new concrete bug found one layer deeper
   - keep speculative concerns only as Observations with clear uncertainty

Deep-dive prompt:

```
You are doing a targeted second-pass review, not a broad review.

Risk hypothesis:
{finding or suspected risk}

Relevant diff/context:
{small focused package}

Tasks:
1. Try to disprove the risk first. If it is false, explain why with code evidence.
2. If true, identify the exact failing path and the smallest code fix.
3. Name the smallest behavioral test that would fail before the fix.
4. Look one layer deeper: what adjacent caller, callee, or invariant could still
   break after the obvious fix?

Return only confirmed findings and explicit non-findings.
```

Preferred local Claude deep-dive invocation:

```bash
deep_prompt="$(mktemp -t code-review-deep-prompt)"
# write the deep-dive prompt and focused package into "$deep_prompt"
deep_dir="$(mktemp -d -t code-review-deep)"
deep_jsonl="$deep_dir/claude.jsonl"
deep_err="$deep_dir/claude.err"
deep_result="$deep_dir/claude.result.md"
deep_rc="$deep_dir/claude.rc"
deep_runner="$deep_dir/run-claude-deep-review.sh"
deep_session="code-review-deep-$(date +%s)-$RANDOM"

cat > "$deep_runner" <<'EOF'
#!/usr/bin/env bash
set -o pipefail

claude_cmd="$(command -v t3-claude || command -v claude)"
claude_effort="${CODE_REVIEW_CLAUDE_EFFORT:-max}"
NOTIFY_SUPPRESS=1 "$claude_cmd" -p \
  --agent pr-review-toolkit:code-reviewer \
  --permission-mode plan \
  --tools "Read,Grep,Glob,Bash" \
  --no-session-persistence \
  --effort "$claude_effort" \
  --output-format stream-json \
  --include-partial-messages \
  --include-hook-events \
  --verbose \
  < "$DEEP_PROMPT" > "$DEEP_JSONL" 2> "$DEEP_ERR"
rc=$?
jq -r 'select(.type == "result") | .result // empty' "$DEEP_JSONL" | tail -1 > "$DEEP_RESULT" || true
if [ ! -s "$DEEP_RESULT" ]; then
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$DEEP_JSONL" > "$DEEP_RESULT" || true
fi
printf '%s\n' "$rc" > "$DEEP_RC"
exit "$rc"
EOF
chmod +x "$deep_runner"

tmux new-session -d -s "$deep_session" \
  "cd '$PWD' && DEEP_PROMPT='$deep_prompt' DEEP_JSONL='$deep_jsonl' DEEP_ERR='$deep_err' DEEP_RESULT='$deep_result' DEEP_RC='$deep_rc' '$deep_runner'"
printf 'Claude deep-review session: %s\ndeep_dir=%s\n' "$deep_session" "$deep_dir"
```

If the command emits `Unknown --effort value`, rerun with
`CODE_REVIEW_CLAUDE_EFFORT=max` and mention the fallback in the review notes.
Use the same heartbeat loop from the broad review, replacing `claude_*` variable
names with `deep_*` and `claude_session` with `deep_session`. Wait for the
deep-review session to finish before merging drill-down results. If the
heartbeat reports a no-progress stall, inspect or restart the deep-review leg;
do not silently skip it. Read only `"$deep_result"` after completion.

## Phase 5: Present Unified Findings

```
## Review Findings

### Critical
1. **[title]** [Both] — file:line
   Evidence: ...
   Fix: ...

### Important
2. **[title]** [Claude] — file:line
   Evidence: ...
   Fix: ...

### Observation
3. **[title]** [Codex] — file:line
   Note: ...

### Mandatory Findings
- **False-pass bug:** [from Claude reviewer]
- **Test compression:** [from Claude reviewer]

---

Which findings should I fix? (e.g., "1,3" or "all" or "none")
```

After user selects findings to fix:
- Implement fixes one at a time using the Minimal-Diff Fix Protocol below
- Apply the Simplification heuristics and (for any test finding) the Test
  compression rubric below
- Run tests after each fix
- Report results

If the diff is large, also produce a reviewer's guide per the Large-PR review
aids below and offer to post it as a PR comment.

## Minimal-Diff Fix Protocol

When changing code after review, bias hard toward the smallest reviewable diff
that fixes the selected finding.

1. Before editing, state the selected finding and the exact behavioral change.
2. Touch only files needed for that finding. Do not opportunistically refactor,
   rename, reformat, reorder imports, or broaden abstractions.
3. Preserve public APIs, data shapes, defaults, error types, and call ordering
   unless the selected finding requires changing them.
4. Prefer deleting unnecessary new code over adding compensating code.
5. Add or adjust the smallest behavioral test that would have failed before the
   fix. Avoid tests that only assert mocks, implementation details, or the
   code path you just hard-coded.
6. After editing, inspect `git diff`. If the diff contains unrelated cleanup,
   split it out or revert it.
7. Re-run the narrowest meaningful verification, then broaden only if the blast
   radius justifies it.
8. If multiple fixes touch the same area, combine them only when that reduces
   review complexity. Otherwise keep them separate and explain the boundary.

## Simplification heuristics

Apply to the code *under change* (consistent with the Minimal-Diff Fix Protocol —
do not sprawl into untouched code), and flag violations in review dimension #6.
Bias toward less code that reads like its surroundings.

- **Fewer helper methods.** Inline a single-use, one-line wrapper. Collapse a
  chain of thin helpers that each just forward to the next. A helper earns its
  place only if it removes real duplication or names a non-obvious step.
- **A new class must earn its keep.** Justify a type by behavior or by removing
  repeated multi-argument threading (a window/config bundle passed through ~10
  functions beats threading 4 args everywhere). A pure data bag passed once is
  not worth a class — inline it. If the type already exists, fold related free
  helpers into it as named constructors/methods instead of leaving parallel
  module-level functions.
- **Delete dead branches.** A code path no caller exercises (e.g. a generic
  resolver branch when every call site passes one form) is dead — remove it,
  don't keep it "for generality."
- **Dedup repeated incantations.** A default re-spelled at every call site
  (`now=datetime.now(UTC)` at 9 callers) → default it once inside the
  constructor/helper; pass the explicit value only where it must be shared.
- **Prove behavior is identical.** Re-run the existing suite; for value-producing
  changes, spot-check that outputs are byte-identical before/after.

## Test compression rubric

The "Test compression" mandatory finding is not a vibe — produce it with this
method, and apply it when the user asks to compress tests. **Hard rule: no
coverage loss.** Every behavior asserted before must still be asserted after.

1. **Map first.** One line per test: `test_name → behavior it locks`. The map is
   itself a deliverable for large suites (it compresses the *cognitive* cost of
   reading 1k+ test lines) and exposes duplication.
2. **Cut strict subsets.** A test exercising the same path as another, differing
   only in an incidental parameter (a different enum, account, or source key that
   routes through identical code), is redundant — remove it. (e.g. an "empty
   result" test for `max_disk` when the `cpu` fetcher test already covers the
   empty-`SignalResult` path.)
3. **Parametrize near-duplicates.** Two+ tests with identical setup differing
   only in input/expected → one `@pytest.mark.parametrize`. (e.g. separate 404
   and 424 error-path tests sharing a 4-mock setup → one parametrized test.)
4. **Prune fixtures, not coverage.** Shrink verbose builders, share helpers, drop
   assertions duplicated elsewhere — but never drop the one test that locks a
   stated requirement/defect.
5. **Keep happy path + realistic unhappy paths; cut hypothetical edge cases**
   that can't occur given the input contract.
6. **Verify.** Re-run the full suite; confirm green and that the line delta came
   from duplication, not lost assertions. Report `N lines → M lines` and what was
   removed/merged.

## Large-PR review aids

When a PR is large (~1k+ changed lines) or adds a new service plus its tests,
produce a reviewer's guide (post it as a PR comment) so review is navigable, not
linear:

- **Size triage.** Split the diff into source / tests / dep-lock; name the few
  files that need a deep read vs. the bulk that's deletion, generated, or
  mechanical. Squashing never changes net diff size — say so if asked.
- **Review order: lowest-context → highest-weight.** deps/lock (skim) → the
  HTTP/contract layer (frames what the core must provide) → the core logic read
  as a *new file*, top-down → "logic extracted" deletions (confirm nothing was
  silently dropped) → supporting wiring.
- **Requirement/defect-driven verification.** For each stated goal or fixed
  defect, give three anchors: the fix, the test that locks it, and (when
  feasible) live/e2e evidence — not just that a mocked unit test passes.
- **Test map.** One line per test (see the Test compression rubric) so coverage
  is visible at a glance.
- **Scrutinize-hardest callouts.** Name the highest-risk spots explicitly:
  cache-key semantics, aggregation/percentile math, deletions in "move logic to
  a service" refactors, and anything with silent fallbacks.

## Anti-Rationalization Rules

### Banned phrases (without concrete evidence)
- "well-tested" → instead say "N tests covering X,Y but missing Z"
- "well-calibrated" → instead say "value is N, supported by [data] / unsupported"
- "comprehensive" → instead say "covers A,B,C; misses D,E"
- "clean" → instead say "follows project pattern X consistently"
- "reasonable" → instead say "value N works because [reason]; breaks if [condition]"

### Code smells reviewers must call out

- **Hidden state machine in a helper**: Nested helper with `nonlocal` variables,
  a separate `loaded` boolean, cached return values, and exception swallowing.
  Fix by making the state explicit: use a small model/result object, a sentinel
  with one cached variable, or move the load/resolve operation before the loop.
- **Ambiguous helper contract**: Helper name or return value does not make the
  input/output contract obvious. Fix by renaming around concrete examples and
  documenting what representative inputs become.
- **Policy mixed with parsing**: Code both interprets a data format and decides
  user-facing behavior in the same branch. Fix by moving parsing/normalization
  into a domain helper and leaving policy decisions at the caller.
- **Unrelated diff churn**: A focused change also rewrites untouched code
  cosmetically — drops or rewords a docstring/comment that still applied, reflows
  a conditional (`if/else` → ternary) with identical behavior, changes casing, or
  renames a local for style only. Each looks harmless, but together they bury the
  real change and risk silent regressions in code nobody meant to touch. Fix by
  reverting the churn or splitting it into a separate, clearly-labeled cleanup
  commit. (Even a genuine improvement, like renaming a `foo` local, belongs in
  its own commit — not smuggled into an unrelated diff.)

### Red flags that the review is shallow
- Zero issues found (every PR has issues)
- All findings are Observation (if nothing is Important, reviewers aren't looking hard enough)
- False-pass bug is contrived rather than plausible
- Phase 1 hypothesis just restates the PR title
- Sub-agents returned nearly identical findings (suggests the prompt was too leading)
