---
name: code-review
description: Use when reviewing a PR, branch diff, or staged changes. Use when the user says "review", "code review", "/code-review", or "review this PR". Use INSTEAD of the superpowers code-reviewer agent.
---

# Hypothesis-First Code Review

A phased review that reads tests before implementation and requires independent hypothesis formation. This catches false-pass bugs, premise errors, and test bloat that verification-oriented reviews miss.

**This is a RIGID skill. Follow the phases in exact order. Do not skip or reorder.**

## Input Detection

Detect review scope automatically. Try in order:

1. If user provides a PR number: `gh pr view <N> --json files,body,title,commits` and `gh pr diff <N>`
2. If on a feature branch: `git log main..HEAD --oneline` and `git diff main...HEAD`
3. If staged changes exist: `git diff --cached`
4. Otherwise: ask the user what to review

Collect the list of changed files. Partition into:
- **test files** (paths containing `test_`, `_test`, `tests/`, `spec/`, `.test.`)
- **implementation files** (everything else)

## Phase 1: Problem Understanding

**RULE: Do NOT read implementation files or test files yet.**

### Step 1a: Read what the author explains

- PR description / title
- Commit messages (`git log --format="%s%n%n%b" main..HEAD`)
- Any linked issues

### Step 1b: Search for domain context

Search these sources for relevant background:
- Second-brain topics: `~/repos/dump/second-brain/topics/` — glob for keywords from the PR
- Project memory: `.claude/projects/*/memory/` — check MEMORY.md
- Project CLAUDE.md files
- Architecture docs in the repo (look for `ARCHITECTURE.md`, `docs/`, `design/`)

### Step 1c: Ask the user (if still unclear)

If after 1a-1b the business problem is ambiguous, ask:
- "What problem does this solve for the end user?"
- "What breaks if a default value or assumption is wrong?"
- "What entities are involved and what are the constraints?"

Do NOT proceed past Phase 1 if you cannot state the business invariant.

### Step 1d: State hypothesis

Output to user before proceeding:

```
## Phase 1: Problem Hypothesis

**Business invariant:** [restate in your own words what must be true]
**What a wrong solution looks like:** [describe a plausible implementation that appears correct but solves the wrong problem or misses the key constraint]
**Domain edge cases:** [list 2-4 edge cases that a correct solution must handle]
```

Wait for user acknowledgment or correction before proceeding.

## Phase 2: Test Audit

**RULE: Read ONLY test files. Do NOT open implementation files.**

For each test file, read it fully and analyze:

### 2a: Test classification

Classify every test function as one of:
- **Behavioral**: tests an observable outcome from the user/caller perspective
- **Mechanical**: tests internal wiring (mock interactions, call counts)
- **Tautological**: test that cannot fail (asserts what was just set up, mocks returning mocks)

### 2b: False-pass bug (MANDATORY)

Describe at least one **plausible bug in the implementation** that would pass all existing tests. This is the most important output of the review. Format:

```
**False-pass bug:** [describe the bug]
**Why it passes:** [which tests fail to catch it and why]
```

If you cannot find one, you haven't looked hard enough. Common sources:
- Tests only check the happy path
- Tests check structure but not values
- Tests share setup that masks a specific edge case
- Off-by-one in boundary conditions
- Default values never exercised with non-default input

### 2c: Missing tests

What behaviors from Phase 1 hypothesis have no test coverage?

### 2d: Test economics

Evaluate and report:
- **Deletion test**: if two tests would catch the same bug, one is redundant. Identify pairs.
- **Parameterization opportunities**: tests that differ only in input/expected values should be parameterized
- **Setup-to-assertion ratio**: if >60% of a test is setup, it's testing infrastructure not behavior
- **Fixture duplication**: shared setup that could be a fixture or helper
- **Concrete compression target**: "This N-line test file should be ~M lines" with explanation

## Phase 3: Implementation Review

**NOW read implementation files**, carrying Phase 1-2 skepticism.

### 3a: Problem alignment

Does the implementation actually solve the Phase 1 hypothesis? Or does it solve a different (possibly easier) problem?

### 3b: Magic numbers and defaults

For every literal number, string constant, or default value:
- What data or reasoning supports this value?
- What happens if it's wrong by 2x? 10x?
- Flag any that lack justification with: "What data supports [value]?"

### 3c: Assumption inventory

List every assumption the code makes (implicit or explicit). For each:
- Is it documented?
- Is it tested?
- What breaks if it's wrong?

### 3d: Simplicity check

- Could this be done with less code?
- Are there unnecessary layers of indirection?
- Does complexity serve a purpose?

### 3e: AI slop patterns

Check for these specific patterns (subsumed from ai-slop-removal):

| Pattern | Detection |
|---------|-----------|
| Dead code | Unused variables, parameters, imports |
| Verbose intermediates | Unnecessary temp variables, explicit loops replaceable by comprehensions |
| Comments restating code | "Initialize counter to zero", "Loop through items" |
| Pattern deviation | Different naming/style than existing codebase |
| Premature abstraction | Classes/helpers used only once |
| Error handling hiding problems | Bare `except`, silent `return None/{}` |
| Mock-heavy tests | Testing mock behavior instead of real behavior |

## Phase 4: Integration & Silent Failures

- What could break **elsewhere in the codebase** with no test failing?
- What is the blast radius if the assumptions from 3c are wrong?
- Are there feature interactions (other callers, config combinations) not covered by tests?
- Could a future change silently undo what this PR accomplishes?

## Output: Numbered Findings

Present findings in this exact format:

```
## Review Findings

### Critical
1. **[title]** — [file:line]
   Evidence: [what you observed]
   Fix: [specific action, including compressed test code if relevant]

### Important
2. **[title]** — [file:line]
   Evidence: [what you observed]
   Fix: [specific action]

### Observation
3. **[title]** — [file:line]
   Note: [what you observed]

### Mandatory Findings
- **False-pass bug:** [from Phase 2b]
- **Test compression:** [N-line file → ~M lines, via parameterization/dedup]

---

Which findings should I fix? (e.g., "1,3" or "all" or "none")
```

After user selects findings to fix:
- Implement fixes one at a time
- Run tests after each fix
- Report results

## Anti-Rationalization Rules

### Banned phrases (without concrete evidence)
Using any of these means your review is shallow. Replace with specific observations:
- "well-tested" → instead say "N tests covering X,Y but missing Z"
- "well-calibrated" → instead say "value is N, supported by [data] / unsupported"
- "comprehensive" → instead say "covers A,B,C; misses D,E"
- "clean" → instead say "follows project pattern X consistently"
- "reasonable" → instead say "value N works because [reason]; breaks if [condition]"

### Red flags that you're doing it wrong
- You opened implementation files before finishing Phase 2
- You found zero issues (every PR has issues)
- All findings are Minor/Observation (if nothing is Important, you aren't looking hard enough)
- Your false-pass bug is contrived rather than plausible
- Your Phase 1 hypothesis just restates the PR title
