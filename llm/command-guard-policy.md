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
  - No documented equivalent to Claude `PreToolUse` hooks in this repo's
    portable config model
  - Follow this policy through shared `AGENTS.md` guidance and tool-approval
    behavior

## Shared Guard Categories

### Git history and branch safety

- Block `git push --force`; allow `--force-with-lease`
- Block `git reset --hard`
- Block broad discard commands like `git checkout .`, `git checkout -- .`,
  `git restore .`, `git clean -f`, `git branch -D`
- Block stash destruction (`git stash drop`, `git stash clear`)

### Push approval

- Require explicit user approval before any push
- Block pushes to `upstream`
- Block direct pushes to `main` or `master`
- Use `push-gate` when the harness supports the Claude-compatible lease model

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
- If Codex gains a documented native pre-command hook surface, map it to this
  policy instead of introducing a second source of truth.
