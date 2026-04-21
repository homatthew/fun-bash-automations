# Shared Command Guard Policy

This file is the canonical policy for command-safety guardrails across Claude,
Codex, and future harnesses.

## Purpose

- Keep destructive or privilege-escalating commands behind explicit approval.
- Keep repo and runtime safety policy in one place instead of re-encoding it
  separately per harness.
- Let harness adapters enforce the same intent using harness-specific
  mechanisms.

## Current Enforcement Model

- Claude:
  - Native enforcement via `claude/hooks/bash-safety-guard.sh`
  - Native enforcement via `claude/hooks/dgw-write-guard.sh`
- Codex:
  - Native enforcement via `codex/hooks.json`
  - Current Codex runtime support is experimental and currently Bash-focused
  - Codex and Claude both call the same shared guard script implementations

## Shared Guard Categories

### Git history and branch safety

- Block `git push --force`; allow `--force-with-lease`
- Block `git reset --hard`
- Block broad discard commands like `git checkout .`, `git checkout -- .`,
  `git restore .`, `git clean -f`, `git branch -D`
- Block stash destruction (`git stash drop`, `git stash clear`)

### Push approval

- Require explicit user approval before any push
- Block direct pushes to `origin/main`, `origin/master`, `upstream/main`, and
  `upstream/master`
- Allow feature-branch pushes to `upstream/*` only when the branch has a
  matching durable lease
- Use `push-gate` / `pg` durable branch leases when the harness supports the
  shared lease model
- Require a fresh self-assertion via `pg push --assert-flow ...` for each agent
  push, even when the durable lease is still valid

### Push-gate bypass prohibition

The `push-gate` approval flow is load-bearing: `pg` generates a draft, the
user edits the draft in `$EDITOR` (scope, caps, paths, subjects), saves to
activate the lease, then `pg push --assert-flow ...` performs the push. The
edit-before-approve step is the policy; skipping it turns `pg` into a rubber
stamp.

Agents MUST NOT suggest, run, or document any of the following as a
workaround when a push is blocked:

- `PG_SKIP_EDIT=1` (bypasses the editor review step)
- `PG_ALLOW_DESCENDANT=1` (overrides lease-anchor drift)
- `PG_SCOPE_OVERRIDE=1` (overrides the approved_scope path/commit/line caps)
- Piping `yes`, `echo y`, or any non-interactive confirmation into the
  approval prompt
- Manually editing `~/.push-gate/` lease state or `/tmp/pg-approve-*.json`
  outside the intended editor flow
- Calling `git push` after the hook blocks, expecting the bypass envs above
  to unblock it

When push-gate blocks and no interactive terminal is available, the correct
response is: stop, tell the user to run `pg compose` (or
`bash /tmp/pg-approve-<repo>-<branch>.sh` without env overrides) in their own
terminal, and wait. The `--assert-flow TEXT` argument on `pg push` is the
semantic-scope assertion checked against the approved template — it is NOT a
bypass.

### Semantic self-check: `pg check`

Before any `pg push`, agents should run `pg check [branch]` to validate the
current HEAD against the active lease's `approved_scope`. Output is JSON:

- `allowed` (bool) — would the push pass scope validation?
- `reason` (string, present when `allowed: false`) — actionable block reason
- `approved_scope` — full scope record (base_ref, paths, subjects, caps)
- `current` — head, approved_anchor, `anchor_matches_head`, commits,
  added_lines, changed_files, subjects

If `allowed: false` or `anchor_matches_head: false`, stop and ask the user to
regenerate the lease with `pg compose`. Never push on a stale or
scope-violating lease, and never bypass the failure with an override env.

### Git config and bypasses

- Block `git config` mutations from agents
- Block `--no-verify`
- Block `git commit --amend`
- Block disabling signing or pre-commit checks

### Broad staging

- Block `git add .`, `git add -A`, `git add --all`
- Block staging obvious secret/key material

### Rebase safety

- Block interactive rebases
- Block bare `git rebase` without an explicit target
- Allow safe continuation commands and explicit-target rebases

### Filesystem destruction

- Block broad `rm -r` / `rm -rf`
- Block deletes aimed at critical paths

### Elevated privileges

- Block `sudo`
- Block `chmod 777`
- Block `chown`

### Remote execution and access

- Block pipe-to-shell (`curl | bash`, `wget | sh`)
- Block `eval`
- Require explicit SSH lease / approval model for remote access

### Package publishing

- Block publishing commands such as `npm publish`, `twine upload`,
  `cargo publish`, `gem push`

### GitHub destructive actions

- Block agent-initiated merge/close/delete actions that require human judgment

### Process killing

- Block broad/destructive kill patterns (`kill -9`, `killall`)
- Allow scoped port-targeted process cleanup when necessary

### DGW KV writes

- Block `dgw-cli kv put` and `dgw-cli kv delete` by default
- Require explicit write-authorization flags for `test` or `prod`

## Maintenance Rules

- Update this file first when command guard policy changes.
- Keep Claude hook implementations aligned with this document.
- Keep Codex hook wiring aligned with the same shared guard scripts.
