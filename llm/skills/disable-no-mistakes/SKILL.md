---
name: disable-no-mistakes
description: Safely disable, eject, uninstall, reinstall, or re-enable no-mistakes for a repository while preserving intermediate work and respecting delivery policy. Use when the user asks to remove, disable, eject, uninstall, restore, reinstall, re-enable, or opt a repository out of or back into no-mistakes. Never use this skill to bypass an active or failed gate, force a blocked push, or weaken protected-branch delivery rules.
---

# Disable or Re-enable No-Mistakes

Treat removal as a repository policy migration, not as a push workaround.

## Classify the request

- If the user only wants to keep working locally, use Local Mode. Do not eject anything.
- If the user wants remote backup or handoff, offer configured Remote Scratch Mode. Do not eject anything.
- If one pipeline stage does not apply, use the no-mistakes runtime `--skip` option for that stage. Never skip a stage that failed.
- If a repository genuinely should become local-only or stop using no-mistakes for delivery, continue with this workflow.
- If the request follows a blocked, active, or failed delivery run, do not eject. Explain that removal cannot be used as a gate bypass and address or conclude the existing run instead.

## Inspect before changing state

1. Resolve the repository root with `git rev-parse --show-toplevel` and inspect `git status --short`.
2. Read the applicable `AGENTS.md` files and repository push/delivery policy.
3. Check whether the `no-mistakes` remote exists with `git remote get-url no-mistakes`.
4. Inspect `no-mistakes axi` and, when a run exists, `no-mistakes axi status`.
5. Read the structured `branch_sync.next_action` state. Do not discard active runs, preserved gate fixes, or pipeline-owned commits.

If `NO_MISTAKES_GATE` is set or a command reports `nested_gate_context`, stop. A validation-step agent must never control or remove the outer pipeline.

## Recover custody before ejection

Assume the gate may contain the only copy of intermediate fix commits. A clean source worktree does not prove that all work is safe.

Follow `branch_sync.next_action` exactly:

- `sync`: run `no-mistakes axi sync --check`, review the offered plan, then run `no-mistakes axi sync` when authorized.
- `recover_custody`: run `no-mistakes axi sync --recover`. If it refuses because the source worktree is dirty or divergent, stop and present its exact recovery choices; do not reset, stash, or rewrite the branch.
- `continue_active_run`: do not eject. Continue the run or ask the user how to conclude it.
- No synchronization action: record the current branch and HEAD and verify there are no gate-owned commits or recovery refs reported by the supported status surfaces.

Show the user the current HEAD, worktree status, active-run state, and any preserved pipeline head before removal. If supported recovery cannot return all intermediate work, identify the exact commits or run state at risk. Proceed only after the user explicitly accepts that specific loss. Never infer acceptance from a general request to disable the integration.

Uncommitted source-worktree changes normally remain outside the gate, but offer a separate local safety checkpoint when they are material. Do not stage or commit them without explicit authorization.

## Decide whether ejection is allowed

Eject only when all of these are true:

- The user explicitly wants the repository integration removed.
- No active run owns the branch and no preserved work needs synchronization or recovery.
- Applicable repository policy permits operation without no-mistakes.
- Removal will not be used to force through a currently blocked delivery push.

The shared baseline requires no-mistakes for delivery and PR-eligible branches. Local-only work and configured scratch branches do not require it. If the user wants ordinary PR delivery without no-mistakes, report that a sanctioned policy and guard migration is required before ejection; do not weaken those controls inside this skill.

## Eject a repository

Immediately before ejection, tell the user that `no-mistakes eject` removes the repository's `no-mistakes` Git remote, internal bare gate repository and worktrees, and database record. Ask for explicit confirmation because this deletes gate-managed state.

After confirmation, run from the repository root:

```bash
no-mistakes eject
```

Do not manually edit Git configuration, gate state, refs, hooks, databases, or internal worktrees.

## Verify ejection

Verify all of the following:

- `git remote get-url no-mistakes` no longer resolves.
- `no-mistakes status` reports that the repository is not initialized.
- `git status --short` has not gained source-worktree changes.
- The user's local branches and source commits remain intact.

Report what was removed, that gate-managed state is not recovered automatically, and whether delivery policy still blocks pushes.

## Re-enable a repository

Re-enabling creates a fresh gate integration; it does not resurrect state deleted by an earlier ejection.

1. Confirm that repository delivery policy should require or permit no-mistakes again.
2. Install the pinned binary when it is absent:

   ```bash
   ~/repos/fun-bash-automations/bin/kun-stack-install no-mistakes
   ```

3. In a treehouse or other isolated worktree, activate the worktree's intended `NM_HOME` before initialization. Do not unset or replace an inherited crewmate `NM_HOME`.
4. From the repository root, run:

   ```bash
   no-mistakes init
   ```

5. Verify `git remote get-url no-mistakes`, `no-mistakes doctor`, and `no-mistakes status`.
6. Restore and deploy any repository policy that was intentionally changed during opt-out only after the gate integration is healthy, so delivery never enters a required-but-missing state.

Report the selected `NM_HOME`, newly initialized repository, and whether previous gate history remains unavailable.

## Uninstall globally

Only perform a global uninstall when the user explicitly requests it. First ensure every affected repository has an intentional replacement policy and no active or recoverable run. Then stop the daemon and use the stack-owned uninstaller:

```bash
no-mistakes daemon stop
~/repos/fun-bash-automations/bin/kun-stack-uninstall no-mistakes
```

Warn that installed push guards may fail closed until their policy is migrated and redeployed. Do not delete `~/.no-mistakes`, `$NM_HOME`, logs, or databases without a separate explicit request and an exact, reviewed deletion plan.

## Never bypass safeguards

Never use or suggest `--no-verify`, force pushes, confirmation piping, environment/config injection, manual guard edits, or manual gate-state surgery. Never abort an active run solely to eject the repository. If policy and requested behavior conflict, stop and explain the migration needed.
