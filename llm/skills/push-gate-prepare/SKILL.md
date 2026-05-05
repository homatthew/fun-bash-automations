---
name: push-gate-prepare
description: "MANDATORY handoff step for agents (Claude, Codex) at the END of an implementation, BEFORE asking the user to approve a push. Invoke when you have finished making changes and want the user to run `pg`, or when `pg` failed with 'NO PREPARED BRIEF'. Captures what/why/approach in an agent-authored brief that grounds the semantic contract the user will approve."
---

# push-gate-prepare

> **When to use.** You're an agent (Claude, Codex, etc.) who just
> finished an implementation and needs the user to approve a push.
> BEFORE telling the user to run `pg`, run `pg prepare` with your
> own rationale. If `pg` already blocked with "NO PREPARED BRIEF",
> run `pg prepare` now.

## Why this matters

The push-gate semantic check compares future commits against the
user's approved `user_intent`. If the intent is inferred from commit
subjects alone, the agent's original ask, chosen approach, and
known caveats are lost. The check then has a weak contract to
enforce — new commits just get compared to old commits.

You have the real context (the conversation that led to the change,
the ask from the user, options considered). `pg prepare` captures
that context BEFORE the user approves, so the LLM semantic check
at push time has something meaningful to compare against.

## The command

```bash
pg prepare \
  --what     'one line: what changes on this branch' \
  --why      'one line: motivating reason (bug, request, ticket)' \
  --approach 'one line: strategy and trade-offs considered' \
  --risks    'one line: known caveats or concerns, if any' \
  --scope    'tests | prod | docs | deps | config | mixed' \
  --beads    'comma-separated bead IDs, if any'
```

`--what`, `--why`, `--approach` are **required**. The others are optional.

All fields should be one line each, concise, factual.

## When to invoke

**Right before you tell the user to run `pg`.** That's the exact
moment — after your last commit, before handoff. Don't prepare too
early (the brief will be stale) or too late (the user will hit
"NO PREPARED BRIEF" first).

## Cross-repo pattern

If you're preparing for a different repo than where you're running,
pass through the repo with `-C`:

```bash
pg -C /Users/matthewho/repos/<repo> prepare \
  --what '...' --why '...' --approach '...'
```

## What to write in each field

- **--what**: what the user will SEE in the diff. Not the story of
  how you got there, just the observable result. Examples:
  - `add LZ4 chunked-value repro test`
  - `fix null-pointer in auth middleware when session is expired`
  - `migrate compression library from Snappy to LZ4 for kv-server`

- **--why**: the motivating reason you did this work. Pull from the
  user's original ask or the bug you were fixing. If it's truly
  unstated (e.g. pure cleanup), say `unstated` — don't invent.
  Examples:
  - `reproduce prod size-mismatch bug reported in dump-64q`
  - `customer-reported 500 when session expires mid-request`
  - `preparatory refactor; actual behavior change in follow-up PR`

- **--approach**: the strategy you took, and what you considered but
  rejected. This is where the semantic check gets its teeth —
  subsequent commits must fit the approach you stated.
  Examples:
  - `standalone test with captured hex fixtures; no prod code changes`
  - `null-guard in middleware; rejected refactoring session store as too broad`
  - `in-place library swap with dep-lock regeneration; tested via smokeTest only`

- **--risks**: one line on anything the user should know before
  approving. Dep-lock churn, size of change, behavior at edge cases.
  If nothing, use `none apparent`.

## If the user didn't ask you to push

Don't prepare speculatively. `pg prepare` is a handoff — it should
only run when the user has asked you to get something pushed, or
when `pg` has blocked and you need to unblock them.

## After prepare

Tell the user, with an explicit path:

> Run in your terminal: `pg -C <absolute-repo-path>`

They will see the brief you wrote rendered as the top-level
PR-description-style `description` block inside the approval YAML.
They can edit it, accept it, or reject it. Trust their edits — they
are authoritative.

## Stale prepare

If you prepare, then add more commits before the user runs `pg`, the
prefill will be flagged as stale (its `prepared_at_head` no longer
matches `git HEAD`). Re-run `pg prepare` to refresh.

## Do NOT

- Don't run `PG_ALLOW_INFERENCE=1 pg`. That's an escape hatch for
  humans working without an agent; agents must always prepare.
- Don't run `pg` yourself. Approval requires a human on the
  interactive terminal.
- Don't skip prepare because the change is "small". The semantic
  check runs regardless; a prepared brief with `scope: docs` and
  a one-line `what` is still stronger than inference.
- Don't bundle unrelated changes into one prepare. If the agent
  did two different things, either split into two branches, or
  restate both in the brief so the semantic check accepts both.
