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
- Promoting scratch work to a delivery or PR branch ships through the
  no-mistakes gate like any other delivery change.

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

## Delivery And Push Policy

- Keep `fun-bash-automations` history linear on branch `main`.
- Before adding history to its public `main`, audit both the outgoing snapshot
  and every newly introduced commit for confidential or internal-only material.
  If old local history is not suitable for publication, rebuild the intended
  snapshot on the current public `main` and keep private content in `dotfiles`.
- Do not create, reopen, or mark ready PRs for `fun-bash-automations`; `main`
  is its direct-push delivery branch. Fix forward on `main` rather than opening a
  long-lived branch: `git push origin main` is the sanctioned command, and the
  guard permits exactly that repo/branch/remote combination from
  `direct_push_exceptions`. For parallel work, give each agent a `treehouse`
  worktree landing small commits on `main`, rather than a shared branch.
- Ship feature work through the `/ship` skill, at the ceremony level the change
  warrants (see [Gate Selection](#gate-selection-match-ceremony-to-risk)). For
  breadth across many tasks use `firstmate`; for a long-run single-objective
  loop use `gnhf`.
- `fun-bash-automations` is a direct-push delivery repo on `main`: after the user
  explicitly asks to push or invokes a finish workflow, push directly with an
  explicit branch target such as `git push origin main`.
- Do not push delivery or PR-eligible branches unless the user explicitly asks.
  `/ship` (and firstmate ship tasks) count as that explicit ask for their
  delivery actions.
- Agents may commit and push matching scratch branches only in Remote Scratch
  Mode, only to configured scratch remotes, and never with force-update forms
  such as `--force`, `--force-with-lease`, or leading-plus refspecs. Scratch
  branches are not PR-eligible and must not have an open PR or be the base of an
  open PR. Promoting scratch work to a delivery branch ships through the
  no-mistakes gate.
- The portable public policy disables the yolo branch class. A private overlay
  may define additional branch classes, but they are not part of this shared
  baseline and cannot weaken protected-branch delivery rules.

## Gate Selection: Match Ceremony To Risk

Validation is proportional. A check that runs on every change regardless of
stakes stops being a safety net and becomes something to route around, so pick
the cheapest tier that actually covers the risk. **Escalate on risk, not on
habit.**

| Tier | When | What runs |
| --- | --- | --- |
| **0 — none** | Editing branches (`wip/`, `scratch/`, `gnhf/`, `tmp/`, `experiment/`, `*yolo/`), local-only work, throwaway spikes | Make it run. Nothing else. |
| **1 — self-review** *(default for delivery)* | Ordinary feature/fix branch headed for a PR | Repo's own tests + lint, then **one** independent-model review leg |
| **2 — multi-model review** | High-risk surface or wide diff (below), or on request | Three review legs: Codex `gpt-5.6-sol`, Cursor `claude-opus-5-thinking-high`, Cursor `kimi-k3-high` |
| **3 — no-mistakes gate** | **Only** when the user explicitly asks for it, or a repo's own policy requires it | Full pipeline: intent, rebase, review, test, document, lint, push, PR, CI monitoring |

Tier 3 is opt-in. It is a good tool for a large or unfamiliar change you want
babysat end to end; it is the wrong default because its cost does not scale down.
Do not route ordinary work through it, and do not treat it as a precondition for
pushing. A repo needs `no-mistakes init` before it can be used at all.

**Escalate to tier 2** when the diff:

- touches security guards, hooks, auth, credentials, secrets, crypto, or
  push/delivery policy;
- can lose or corrupt data, or is hard to reverse;
- is wide — roughly >400 changed lines or >15 files;
- changes behaviour the user cannot easily re-verify themselves.

**Declining review is a legitimate answer.** If review does not fit — throwaway
work, the user asked you to stop, it is already reviewed, or it plainly is not
worth it — say so in one line (`skipping review: <reason>`) and move on. State it
plainly; do not fake a review, and do not silently skip one either.

The `self-review-guard.sh` Stop hook prompts for review when a diff hits the
tier-2 triggers. It asks **once** per diff and never blocks twice, so it can
prompt but cannot trap. Record a completed review with
`self-review-guard.sh --mark-reviewed` — because you did the review, never to
silence the prompt.

### Yolo branches

`*yolo/` branches (including `mho-yolo/`) exist to move fast. Do not review
continuously on them. Review the **end state** once — before promoting the work
to a delivery branch, before handing it off, or whenever the user asks. Between
those points, just keep the code running.

## Scope And PR Sizing

Keep changes reviewable. Size is the cheapest risk control available, and it is
worth more than any amount of gate ceremony.

- Aim for **under ~400 changed lines and ~15 files** per PR. Past that, split it.
- One PR should support **one reviewable claim**. If the description needs
  "and also", it is two PRs.
- Land refactors separately from behaviour changes. Mixing them hides the
  behaviour change inside the noise.
- Sequence large work as a stack of small branches rather than one wide diff.
- If a change cannot be split, say so explicitly and escalate to tier 2 — a wide
  diff is exactly the case where a second model earns its cost.

## Hard Safety Controls

These are not proportional and are never weakened, whatever tier is in play:

- The git-level main pre-push hook and `bash-safety-guard.sh` block unconfigured
  protected-branch pushes and bare/ambiguous pushes.
- No `--no-verify`, no force-pushes on shared branches, no piping `yes` /
  `echo y` into a prompt, no `core.hooksPath` or config injection.
- No manual edits to guard state, and nothing that fakes a green run.
- Before adding history to a public `main`, audit it for confidential material.

The distinction matters: **review ceremony is negotiable; these are not.**

## Using no-mistakes (Tier 3)

Only on an explicit user ask. Once a run is under way, drive it properly — a
half-driven pipeline is worse than none. Details live in the `no-mistakes` skill.

- The gate owns the push for that run. Do not hand-roll `git push` +
  `gh pr create` alongside an active run, and do not edit files to fix findings
  yourself while it holds the branch.
- If a step fails, fix it and `no-mistakes rerun`. Do not `--skip` a step that
  actually failed. `--skip` is for a step that does not apply.
- When the gate needs an interactive approval and no terminal is available, stop
  and ask the user.
- To stop using it in a repo, use the `disable-no-mistakes` skill — it recovers
  gate-held commits first. Ejecting can destroy pipeline commits that exist
  nowhere else.

For parallel agents on the same repository, treehouse worktrees are necessary
but not sufficient: each concurrent no-mistakes run must also have its own
`NM_HOME` before `no-mistakes init`, `no-mistakes axi run`, or `/no-mistakes`.
`NM_HOME` is the isolation boundary for no-mistakes state, socket, gate repos,
database, and daemon, and `nm-home --activate` writes the `no-mistakes` git
remote into worktree-local config so concurrent worktrees do not race on a
shared gate remote. firstmate sets a per-worktree `NM_HOME` for crewmates and
records it as `nm_home=` in task metadata; manual treehouse shells are
auto-scoped by the zsh hook under `~/.treehouse`, or can be made explicit with
`eval "$(nm-home --for "$PWD" --mkdir --activate --export)"`. Do not unset a
crewmate's inherited `NM_HOME`. Also keep branch names unique per concurrent
task: separate homes isolate local gate state, but the remote branch and PR
namespace are still shared by the git host.

Guard details live in `llm/command-guard-policy.md`.

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
- Before committing or pushing, use `$reduce-churn` to audit the complete change
  against its actual merge target. Use the merge-base/three-dot diff for PR
  scope, separate required behavior and contract tests from unrelated cleanup,
  and remove accidental churn before delivery. Do not use a two-dot diff as the
  PR-scope comparison, and do not push while the final diff classification is
  unresolved.
- Final status must state what changed, what ran, and what remains blocked or
  unverified.

## Runtime Assumptions

- Repositories live under `~/repos/*`.
- When the user names a repo or gives identifying keywords, agents may inspect
  sibling repos under `~/repos/*`. Prefer targeted discovery over broad scans.
- Beads uses normal project-local discovery unless the user configures
  `BD_DB`; resume after compaction with `bd ready`.
- Second-brain storage is optional and configured with `SECOND_BRAIN_DIR`.
- Lavish (`lavish-axi`) runs ONE shared local server and watches each artifact
  file (chokidar) to auto-reload the browser; there is no flag to disable the
  watcher. To avoid disruptive reloads, lost annotations, and an EventEmitter
  listener leak:
  - Open a session once. Do NOT re-run `lavish-axi <file>` to push updates —
    editing the file already triggers a reload. Repeated re-opens leak
    `reload`/`agent-reply`/`agent-presence` listeners and trip Node's 10-listener
    cap (`MaxListenersExceededWarning`).
  - Don't edit the artifact while the user is actively annotating; batch edits
    between review rounds so a reload can't drop in-progress (unsent) annotations.
  - For heavy multi-agent use, raise the cap once via
    `~/.lavish-axi/raise-listeners.cjs` + `NODE_OPTIONS=--require ...` on the
    server (see the `reference-lavish-max-listeners` memory).

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
