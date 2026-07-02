# no-mistakes upstream report draft: failed axi run poisons gate ref

## Summary

Within a single `NM_HOME`, a failed `no-mistakes axi run` can leave gate state
behind that blocks or contaminates a later run for the same repo/branch. Using a
separate `NM_HOME` per worktree avoids cross-worktree impact, but the underlying
single-home cleanup bug remains.

## Environment

- no-mistakes observed on `v1.31.2`; local stack target is now `v1.32.x`
- macOS, zsh, git worktrees via treehouse
- agent path: `no-mistakes axi run --intent "..."`

## Expected

After an `axi run` reaches a terminal `failed` or `cancelled` state, the next
run in the same `NM_HOME` should either:

- cleanly reattach only when it is the same active run at the same `HEAD`, or
- start a fresh run without stale gate refs/state affecting it.

## Actual

A failed `axi run` can poison the gate ref/state for the repo in that `NM_HOME`.
Subsequent runs can appear blocked by state from the failed run until the home is
manually cleaned or a separate `NM_HOME` is used.

## Why it matters

`NM_HOME` isolation is a good operational workaround for parallel agents because
each treehouse worktree can use its own database, socket, daemon, and gate repos.
It should not be required for serial recovery in one home, though: a failed run
should not make the gate require manual state surgery.

## Suggested fix direction

On terminal run outcomes and on `axi rerun`/fresh-run setup, audit any per-branch
gate refs or active-run indexes that can survive a failed run. Cleanup should be
idempotent and scoped to the repo/branch/run id so it cannot delete a genuinely
active monitor for a different run.

## Local integration workaround

The local Kun-stack integration now derives per-worktree homes with `nm-home`
and launches firstmate crewmates with `NM_HOME=<per-worktree-home>`, so parallel
runs do not share the poisoned state.
