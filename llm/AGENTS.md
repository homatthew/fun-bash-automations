# Shared LLM Agent Policy

This file is the shared instruction source for Claude, Codex, and future agent
harnesses. Keep shared policy here; keep harness-specific runtime behavior in
adapter files.

## Mode Priority

Agent work modes control git side effects. If another instruction says to
stage, commit, sync, push, or finish automatically, the active mode wins unless
the user explicitly asked for that git action in the current task.

The default mode is **Local Mode**.

## Agent Work Modes

### Local Mode

Local Mode keeps work uncommitted and local for human review.

- Agents may edit files, run verification, and summarize changes.
- Agents must not run `git add`, `git commit`, `bd sync`, or `git push`.
- Agents should leave the worktree review-ready for VS Code, command-line diff,
  or another local review surface.
- The user must explicitly say `commit`, `push`, or invoke an explicit finish
  workflow before delivery actions happen.

### Remote Scratch Mode

Remote Scratch Mode allows backup commits and pushes to non-delivery scratch
branches.

- The user selects Remote Scratch Mode with phrases such as `remote mode`,
  `scratch backup`, `push scratch checkpoints`, or `handoff mode`.
- Agents may create checkpoint commits and push only configured scratch
  branches such as `wip/agent/<topic>` or `scratch/agent/<topic>`.
- Scratch branches must not have an open PR, must not be the base of an open
  PR, and must not be treated as delivery branches.
- Promoting scratch work to a delivery or PR branch requires the normal
  delivery approval flow.

### Mentor Mode

Mentor Mode optimizes for learning and reviewability over speed.

- The user selects Mentor Mode with phrases such as `mentor mode`,
  `walkthrough mode`, `teach me`, or `show the journey`.
- Agents must make small atomic changes and explain each step before or as the
  code changes.
- Agents should build features incrementally instead of making one large
  one-shot implementation.
- Agents must stop and ask before crossing a design decision with real
  ambiguity, such as API shape, data model, persistence behavior, migration
  strategy, user-visible workflow, or test strategy.
- Agents must not commit or push automatically in Mentor Mode.
- Mentor Mode defaults to Local Mode unless the user also selects Remote
  Scratch Mode.

### Yolo Mode

Yolo Mode is the raw push + PR fast path on `mho-yolo/*` branches: no push-gate,
no editor review, no lease. It is the pre-push-gate workflow on a sanctioned,
structurally-fenced branch class.

- Yolo branches use the prefix `mho-yolo/` (e.g. `mho-yolo/quick-fix`) on any
  repo, and are defined by the `yolo_branches` class in
  `llm/agent-push-policy.json`.
- The branch prefix **alone** mechanically allows an explicit branch push such
  as `git push origin mho-yolo/<topic>` and `gh pr create`; no session toggle is
  needed to unblock the push. Bare `git push` is always blocked because the
  target branch must be visible in the command text. Unlike scratch branches,
  yolo branches are PR-eligible and allow `--force-with-lease` and delete.
- A yolo branch can never target a base ref (`main`/`master`/`develop`/`trunk`)
  nor acquire one as upstream. Create one from a base only with `--no-track`,
  e.g. `git switch --no-track -c mho-yolo/<topic> origin/main`.
- Autonomy default is still soft: only push or open the PR after the user
  explicitly asks. Fully autonomous yolo push/PR is opt-in via
  `AGENT_WORK_MODE=yolo`.
- See the `yolo-pr` skill for the full workflow.

## Delivery And Push Policy

- Keep `fun-bash-automations` history linear on branch `mh-netflix`.
- Do not create, reopen, or mark ready PRs from `fun-bash-automations`
  `mh-netflix` to `main`; `mh-netflix` is the delivery branch.
- `fun-bash-automations` and `dotfiles` do not use push-gate. After the user
  explicitly asks to push, or invokes an explicit finish workflow, push these
  repos directly with an explicit branch target such as
  `git push origin mh-netflix` or `git push origin main`.
- Do not push delivery or PR-eligible branches unless the user explicitly asks.
- Explicit finish workflows such as `/go`, `/commit-push-pr`, `/push-review`,
  and `/stacked-pr` count as an explicit ask for their delivery actions.
- Agents may commit and push matching scratch branches only in Remote Scratch
  Mode. Scratch branches are not PR-eligible, are not subject to push-gate, and
  must not have an open PR or be the base of an open PR. Promoting scratch work
  to delivery or PR branches requires the normal push-gate flow.
- Yolo branches (`mho-yolo/*`) get a raw explicit-branch push + PR fast path:
  `git push origin mho-yolo/<topic>` plus `gh pr create`, no push-gate,
  force-with-lease and delete allowed. They are keyed on the branch prefix and
  can never target or track a base ref. Bare `git push` is never allowed. The
  push itself is allowed by prefix alone, but the autonomy default is still to
  push only after the user explicitly asks (or under `AGENT_WORK_MODE=yolo`).
  See Yolo Mode above and the `yolo-pr` skill.

## Push-Gate Policy

Use push-gate before any push operation that requires approval. The two
direct-push repos named above are the only standing exception.

Never bypass push-gate. Do not suggest, run, or document `PG_SKIP_EDIT=1`,
`PG_ALLOW_DESCENDANT=1`, `PG_SCOPE_OVERRIDE=1`, `PG_ALLOW_INFERENCE=1`, or any
pattern that pipes automated confirmations into approval prompts.

Canonical push-gate flow:

1. Agent: `pg prepare --what ... --why ... --approach ...` at end of
   implementation. See the `push-gate-prepare` skill.
2. Human: `pg` or `pg -C <path>` in their interactive terminal.
3. Agent: `pg push --assert-flow "..."`.

When push-gate blocks and no interactive terminal is available, stop and ask
the user to run `pg`. Do not ask for `pg compose`; that command is removed.
Details live in `llm/command-guard-policy.md`.

## Planning And Verification

- For multi-step or risky work, make or repair a short plan before substantial
  edits. Keep the plan current when new facts change the approach.
- If the user asks a question, asks for review, or asks to brainstorm, answer
  in that mode. Otherwise, assume the user wants the change carried through
  implementation and verification.
- Inspect the existing code and local patterns before editing. Prefer repo
  conventions over new abstractions.
- Work in small steps, verify each risky step, and keep progress resumable.
- Prefer the strongest practical verification surface: end-to-end CLI/API flow,
  browser/computer-use flow, focused automated tests, build, typecheck, or lint.
- Do not claim code works unless relevant verification actually ran.
- If verification cannot run because it needs credentials, interactive access,
  external state, or unavailable local tooling, state the blocker and give the
  user the exact command to run plus the expected pass/fail signal.
- After code works, simplify: remove dead code, reduce unnecessary complexity,
  and remove redundant tests or comments.
- Treat style-only rewrites as churn by default. Do not change established
  control-flow, formatting, naming, or idioms merely because a reviewer or agent
  finds an alternative more stylistically pleasing; make such changes only when
  the user explicitly asks, the local codebase already requires that pattern, or
  the change reduces real complexity, risk, or duplication.
- Re-run affected verification after simplifying.
- Final status must state what changed, what ran, and what remains blocked or
  unverified.

## Runtime Assumptions

- Repositories live under `~/repos/*`.
- When the user names a repo or gives identifying keywords, agents may inspect
  sibling repos under `~/repos/*`. Prefer targeted discovery over broad scans.
- Beads is the persistent task tracker:
  - DB: `~/repos/dump/.beads/beads.db`
  - Resume after compaction with `bd ready`.
- Second-brain knowledge lives at:
  - Index: `~/repos/dump/second-brain/README.md`
  - Topics: `~/repos/dump/second-brain/topics/<topic>/README.md`
- If Sourcegraph MCP returns `502`, especially `downstream` or
  `ngp-mcp-sourcegraph`, treat it as likely auth expiry. Ask the user to open
  `http://go/authorize-sourcegraph`, then retry the Sourcegraph query.

## Shared Skills

- Canonical skills directory: `llm/skills/`.
- Skill file name is always `SKILL.md`.
- Harness adapters may project skills into `~/.claude/skills` or
  `~/.codex/skills`, but source of truth remains `llm/skills`.

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
- Integration parity and MCP mapping: `llm/integrations.md`
- Shared command guard policy: `llm/command-guard-policy.md`
- Use `fba-deploy` after editing repo-owned runtime files so `~/.claude` and
  `~/.codex` stay in sync with this repo.
