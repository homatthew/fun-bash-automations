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
