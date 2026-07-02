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

- Block `git push --force`; allow `--force-with-lease` only where the push
  policy permits it. Scratch branches never allow force pushes; yolo
  branches allow `--force-with-lease` and delete (see the yolo branch class
  below).
- Block `git reset --hard`
- Block broad discard commands like `git checkout .`, `git checkout -- .`,
  `git restore .`, `git clean -f`, `git branch -D` (the `git branch -D` block
  is exempt only when **every** deleted branch name is yolo-prefixed — local
  cleanup of unmerged yolo branches)
- Block stash destruction (`git stash drop`, `git stash clear`)

### Push approval

- Block bare `git push` and remote-only `git push origin`. The command must
  name the target branch or refspec explicitly, e.g. `git push origin <branch>`,
  so guard classification never depends on hidden current-branch/upstream state.
- Require explicit user approval before any delivery or PR-eligible push.
  Non-delivery scratch branch pushes are governed by the scratch branch class
  below.
- Block direct pushes to `origin/main`, `origin/master`, `upstream/main`, and
  `upstream/master`. The git-level main pre-push hook enforces this even for
  external binaries (gnhf, no-mistakes); the agent-layer guard is
  defense-in-depth.
- Deliver feature branches through the **no-mistakes** gate: it runs automated
  review/tests/lint/docs, then pushes to the configured target and opens or
  updates the PR. Drive it with the `/ship` skill or the `no-mistakes` skill;
  for breadth, firstmate ships each crew task through the same no-mistakes
  policy with separate per-worktree `NM_HOME` state.
- Do not hand-roll `git push` + `gh pr create` for delivery work — let the gate
  own the push so the pipeline runs.

### Gate and guard bypass prohibition

The no-mistakes gate and the safety guard are load-bearing. Agents MUST NOT
suggest, run, or document any of the following to get a blocked push through:

- `--no-verify` on `git commit` / `git push` (bypasses hooks)
- Piping `yes`, `echo y`, or any non-interactive confirmation into a gate or
  approval prompt
- `no-mistakes --skip <step>` to skip a step that actually failed (skip is only
  for genuinely inapplicable steps, never to fake a green run)
- Editing guard or gate internal state by hand to force a push
- Calling `git push` to a protected branch after the guard blocks, expecting an
  env override to unblock it — there is none

### Scratch branch class

`llm/agent-push-policy.json` defines a non-delivery scratch branch class for
agent remote backup, resumability, and cross-workspace handoff. Scratch
branches are explicitly non-PR work surfaces — they are not a delivery bypass.

Agents may commit and push matching scratch branches only after the user selects
Remote Scratch Mode. The guard allows those pushes only when the shell declares
`AGENT_WORK_MODE=remote_scratch` or `LLM_AGENT_WORK_MODE=remote_scratch`, the
target branch matches a configured scratch prefix, targets a configured scratch
remote, is not a force/delete push, has no open PR as its head, and is not the
base of an open PR. If any of those checks fails or cannot be verified, the
branch is treated as delivery scope.

The machine-readable cadence is `regular_milestones`: in Remote Scratch Mode,
commit and push after a coherent checkpoint worth preserving, after verification
passes, before long-running or interruptible work, and before handoff or context
compaction. That cadence is for scratch branches only; delivery branches ship
through the no-mistakes gate.

Promoting scratch work means creating or updating a delivery/PR branch from the
scratch commits. That promotion ships through the no-mistakes gate exactly like
any other delivery change.

### Yolo branch class

`llm/agent-push-policy.json` also defines a `yolo_branches` class (prefix
`mho-yolo/`) for a raw explicit-branch push + PR fast path on any repo: no gate,
no editor review, no lease. Unlike scratch branches, yolo branches **are**
PR-eligible and allow `--force-with-lease` and delete. This is a separate
sanctioned class, not a delivery bypass.

The allow is keyed on the resolved push **target** matching a yolo prefix, so the
class is structurally incapable of pushing to a base ref:

- Base refs (`main`/`master`/`develop`/`trunk`) never match `mho-yolo/`, so
  `git push origin mho-yolo/x:main`, `HEAD:main`, etc. resolve their target to a
  base and are hard-blocked before any yolo allow can run.
- The universal `check_branch_tracking` guard means a yolo branch can never
  acquire `origin/main` (or any non-mirrored ref) as upstream: creating one from
  a base requires `--no-track`.
- Plain `git push --force` stays blocked; yolo "force" is `--force-with-lease`.
- Bare `git push` stays blocked; yolo pushes must name the branch in the
  command, e.g. `git push origin mho-yolo/x`.
- `git branch -D` is exempt only for yolo-prefixed names (local cleanup); remote
  deletes are allowed only for yolo targets on a configured remote.

The **trigger is the prefix alone** — no session toggle is needed to mechanically
allow a yolo push. The autonomy default is still a soft "only after the user
explicitly asks" (`requires_explicit_user_ask: true`, like the direct-push
exceptions). Fully autonomous yolo push/PR is opt-in via `AGENT_WORK_MODE=yolo`.
A malformed or disabled `yolo_branches` policy fails closed: the push falls
through to the delivery default-deny.

### Git config and bypasses

- Block `git config` mutations from agents except repo-local rerere enablement:
  `git config --local rerere.enabled true` and
  `git config --local rerere.autoupdate true`, with or without `git -C <repo>`.
  Read-only queries such as `git config --get ...` and `git config --list` are
  allowed.
- Block `--no-verify`
- Allow `git commit --amend` on feature branches; it only rewrites local
  history, and the no-mistakes gate re-validates any rewritten tip before it is
  pushed
- Block `git commit --amend` on protected branches (`main`/`master`)
- Block disabling signing or pre-commit checks
- Block feature/stack branches from tracking any non-mirrored remote branch.
  A local branch may track `origin/<same-branch-name>` or
  `upstream/<same-branch-name>` after its first approved push, but must not
  track integration/base refs such as `origin/main`, `upstream/main`, or
  `origin/release/main`. When creating a feature branch from a base ref, use
  `--no-track`, including `git worktree add --no-track -b <branch> <path>
  <base-ref>`.

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
- Block interactive SSH from agents; SSH must include an explicit remote
  command.
- Block obvious dangerous remote SSH commands such as `sudo`, `su`,
  `systemctl`, `service`, process kills, broad file mutation commands,
  `cqlsh`, and shell/code wrappers such as `bash -c` or `python -c`.
- Block mutating Cassandra `nodetool` verbs over SSH, including `repair`,
  `compact`, `cleanup`, `scrub`, `drain`, topology changes, `disable*`, and
  `set*`.
- Require an exact command lease, in addition to the host lease, for
  production-sensitive diagnostics such as `nodetool toppartitions`, `jcmd`,
  `jstack`, `jmap`, remote `tar`, large remote `tail`, full Cassandra log
  grep, or `find` under `/mnt/data/cassandra`. Use `ssh-command-gate <host>
  -- <remote-command...>` to grant one exact command hash.
- Allow lower-risk read-only diagnostics such as `tpstats`,
  `proxyhistograms`, `tablestats`, `tablehistograms`, `gcstats`, and
  `compactionstats` with only a valid SSH host lease.

### Package publishing

- Block publishing commands such as `npm publish`, `twine upload`,
  `cargo publish`, `gem push`

### GitHub destructive actions

- Block agent-initiated merge/close/delete actions that require human judgment

### fun-bash-automations PR safety

- Block `gh pr create`, `gh pr ready`, and `gh pr reopen` for
  `homatthew/fun-bash-automations`. That repo delivers on `mh-netflix`; agents
  must not create or ready PRs from `mh-netflix` to `main`.

### GitHub host safety

- Block `GH_HOST=github.netflix.net` and `gh --hostname github.netflix.net`;
  agents must use `GH_HOST=git.netflix.net` for Netflix GHE.
- Block `gh --repo` or `gh -R` values that include `github.netflix.net` or
  `git.netflix.net`; `gh` repo arguments must be plain `owner/repo`, for
  example `GH_HOST=git.netflix.net gh pr view 123 --repo org/repo`.
- Block `gh api` gist creation unless the command explicitly targets Netflix
  GHE via `GH_HOST=git.netflix.net` or `--hostname git.netflix.net`
- Block gist uploads unless uploaded filenames or gist payload keys use
  contiguous ordered prefixes like `01_...`, `02_...`, `03_...`

### Process killing

- Allow local process cleanup commands (`kill`, `pkill`, `killall`) so agents
  can stop tools they started or clean up stuck local subprocesses.
- Remote SSH command safety remains governed by the SSH lease and remote-command
  guard rules.

### DGW KV writes

- Block `dgw-cli kv put` and `dgw-cli kv delete` by default
- Require explicit write-authorization flags for `test` or `prod`

### Private guard extensions

- `bash-safety-guard.sh` runs optional private extensions from
  `bash-safety-guard.d/*.sh` next to the projected hook, or from the
  colon-separated `BASH_SAFETY_GUARD_EXTENSION_DIRS` override used by tests.
- Extensions receive the original hook JSON on stdin. Empty stdout means allow.
  To block, print normal hook denial JSON with
  `hookSpecificOutput.permissionDecision == "deny"`.
- Extensions are fail-closed: nonzero exit status, stderr output, or any nonempty
  output that is not valid denial JSON blocks the command with an extension
  failure message.
- Confidential hostnames, private API topology, team-specific allowlists, and
  lease files belong in dotfiles-owned extension scripts, not in this shared
  repository.

## Maintenance Rules

- Update this file first when command guard policy changes.
- Keep Claude hook implementations aligned with this document.
- Keep Codex hook wiring aligned with the same shared guard scripts.
