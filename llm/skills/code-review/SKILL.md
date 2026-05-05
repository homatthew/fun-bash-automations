---
name: code-review
description: Use when reviewing a PR, branch diff, or staged changes. Use when the user says "review", "code review", "/code-review", or "review this PR". Use INSTEAD of the superpowers code-reviewer agent.
---

# Multi-Agent Code Review

An orchestrated review that gathers context, then spawns two independent sub-agent reviews in parallel (Claude and Codex) with fresh context. Consolidates findings into a unified report. Each reviewer forms its own hypothesis independently — no shared bias.

**This is a RIGID skill. Follow the phases in exact order. Do not skip or reorder.**

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

When running inside Codex, there is no native `pr-review-toolkit:code-reviewer` subagent. Invoke Claude as an external reviewer with `claude --print`, and run the Codex review locally or via a Codex subagent.

1. Write the Claude prompt to a temp file:

   ```bash
   claude_prompt="$(mktemp -t code-review-claude-prompt)"
   # write Agent A prompt into "$claude_prompt"
   ```

2. Start Claude in the background from the repository root:

   ```bash
   claude_out="$(mktemp -t code-review-claude-out)"
   claude_err="$(mktemp -t code-review-claude-err)"
   NOTIFY_SUPPRESS=1 claude -p \
     --agent pr-review-toolkit:code-reviewer \
     --permission-mode plan \
     --tools "Read,Grep,Glob,Bash" \
     --no-session-persistence \
     < "$claude_prompt" > "$claude_out" 2> "$claude_err" &
   claude_pid=$!
   ```

3. While Claude runs, perform Agent B's Codex review independently in the current Codex session, using the Agent B prompt below.

4. Wait for Claude before consolidation:

   ```bash
   if ! wait "$claude_pid"; then
     echo "Claude reviewer failed; stderr follows:" >&2
     tail -80 "$claude_err" >&2
   fi
   claude_findings="$(cat "$claude_out")"
   ```

5. If `claude` is unavailable or fails before producing findings, continue with the Codex review but explicitly report that the Claude leg was unavailable. Do not invent `[Claude]` findings.

Do not pass write tools to Claude for review. Use `NOTIFY_SUPPRESS=1` so the nested Claude review does not create duplicate desktop notifications. Remove the temp prompt/output/error files after consolidation.

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
7. **Silent failures**: What could break elsewhere with no test failing?

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

## Phase 4: Present Unified Findings

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
- Implement fixes one at a time
- Run tests after each fix
- Report results

## Anti-Rationalization Rules

### Banned phrases (without concrete evidence)
- "well-tested" → instead say "N tests covering X,Y but missing Z"
- "well-calibrated" → instead say "value is N, supported by [data] / unsupported"
- "comprehensive" → instead say "covers A,B,C; misses D,E"
- "clean" → instead say "follows project pattern X consistently"
- "reasonable" → instead say "value N works because [reason]; breaks if [condition]"

### Red flags that the review is shallow
- Zero issues found (every PR has issues)
- All findings are Observation (if nothing is Important, reviewers aren't looking hard enough)
- False-pass bug is contrived rather than plausible
- Phase 1 hypothesis just restates the PR title
- Sub-agents returned nearly identical findings (suggests the prompt was too leading)
