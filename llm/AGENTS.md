# Shared LLM Agent Policy

This file is the canonical shared instruction source for personal agent
workflows across Claude, Codex, and future harnesses.

## Core Rules

- Keep history linear in `fun-bash-automations` on branch `mh-netflix`.
- Do not push unless explicitly asked.
- Explicit finish-workflow invocations such as `/go`, `/commit-push-pr`,
  `/push-review`, and `/stacked-pr` count as an explicit ask for the
  corresponding delivery actions.
- Treat that as a hard workflow rule even if a shell path or harness would
  technically allow `git push`.
- Use `push-gate` before any push operation that requires approval.
- Keep shared behavior harness-agnostic in this file and in `llm/skills`.

## Default Execution Standard

- For multi-step work, make or repair a short plan before substantial edits.
- Break work into small steps with explicit verification, then execute one step
  at a time.
- Prefer the strongest realistic verification surface available:
  - end-to-end CLI or API flow
  - browser or computer-use flow
  - focused automated tests
  - build, typecheck, or lint
- Do not claim code works unless the relevant verification actually ran.
- After code works, run a simplification pass:
  - remove dead code
  - reduce unnecessary complexity
  - remove redundant tests and comments
- Re-run the affected verification after simplifying.
- For long-running work, keep the plan resumable with per-step verification and
  clear progress state.
- Do not present a task as done until you can state what was executed, what was
  verified, and what remains blocked.

## Shared Runtime Assumptions

- Repositories live under `~/repos/*`.
- When the user provides a repo name or identifying keywords, agents may look
  across sibling repos under `~/repos/*` for relevant implementations or
  context. Prefer targeted discovery from those user hints over broad scanning
  of unrelated repos.
- Beads is the persistent task tracker:
  - DB: `~/repos/dump/.beads/beads.db`
  - Resume after compaction with `bd ready`.
- Second-brain knowledge lives at:
  - Index: `~/repos/dump/second-brain/README.md`
  - Topics: `~/repos/dump/second-brain/topics/<topic>/README.md`

## Shared Skills

- Canonical skills directory: `llm/skills/`.
- Skill file name is always `SKILL.md`.
- Harness adapters may project these skills into `~/.claude/skills` or
  `~/.codex/skills`, but source-of-truth remains `llm/skills`.

## Harness-Specific Files

- Claude-only runtime files live under `claude/`:
  - `claude/settings.json`
  - `claude/hooks/*.sh`
  - `claude/statusline.sh`
  - `claude/agents/*.md`
- `claude/CLAUDE.md` is a Claude adapter and should not duplicate shared policy.

## LLM Config Maintenance

- Structural source of truth: `llm/manifest.json`
- Human maintainer guide: `llm/README.md`
- Integration parity + MCP mapping: `llm/integrations.md`
- Shared command guard policy: `llm/command-guard-policy.md`
- Use `fba-deploy` after editing repo-owned runtime files so `~/.claude` and
  `~/.codex` stay in sync with this repo.
