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
- Codex:
  - Native enforcement via `codex/hooks.json`
  - Current Codex runtime support is experimental and currently Bash-focused
  - Codex and Claude both call the same shared guard script implementations

## Shared Guard Categories

### Git history and branch safety

- Block force-update pushes, including `git push --force`, `git push -f`, and
  leading-plus refspecs such as `+branch:branch`. The portable policy grants no
  force-with-lease exception.
- Block `git reset --hard`
- Block broad discard commands like `git checkout .`, `git checkout -- .`,
  `git restore .`, `git clean -f`, and `git branch -D`.
- Block stash destruction (`git stash drop`, `git stash clear`)

### Push approval

- Block bare `git push` and remote-only `git push origin`. The command must
  name the target branch or refspec explicitly, e.g. `git push origin <branch>`,
  so guard classification never depends on hidden current-branch/upstream state.
- Reject push-time Git configuration injection through `-c`, `--config-env`,
  `GIT_CONFIG_*`, `HOME`, or `XDG_CONFIG_HOME`. A push cannot replace the
  enrolled hook path through direct or included configuration.
- Normalize known process wrappers and command-string interpreters before
  classifying a command. Unknown executor-shaped wrappers fail closed, while
  arguments to data-only commands such as `echo` are not promoted to
  executables.
- Require explicit user approval before any delivery or PR-eligible push.
  Non-delivery scratch branch pushes are governed by the scratch branch class
  below.
- Block direct pushes to protected base refs. The one exception is an exact
  configured direct-delivery push, after explicit user approval.
  `direct_push_exceptions` in `llm/agent-push-policy.json` names the repository,
  its `delivery_branch`, and its `delivery_remote`; the guard reads that entry
  and permits **only** that combination. It refuses:
  - any other protected ref, even in a direct-delivery repository;
  - any other remote for the delivery branch;
  - force, `--force-with-lease`, leading-plus, and delete forms;
  - bare, multi-ref, and expansion-bearing pushes;
  - unresolved repository redirects (`--git-dir`, `--work-tree`,
    `--namespace`); `-C <repo>` is allowed only after the guard resolves that
    repository and applies its own policy entry.
  Private installations may add direct-delivery repositories through
  `~/.config/fba/agent-push-policy-overlay.json`; the shared policy remains the
  source of truth for every other branch class.
- **Enforcement note.** The agent-layer guard is the only layer actually
  enforcing this in a checkout with no installed `pre-push` hook. Earlier wording
  here claimed a git-level main pre-push hook enforced it "even for external
  binaries"; that hook is a separate, privately-owned asset and is not
  necessarily installed. Do not rely on a second layer existing.
- Deliver feature branches through the `/ship` skill at the validation tier the
  change warrants; see Gate Selection in `llm/AGENTS.md`. Validation ceremony is
  proportional to risk and an agent may decline a review leg with a stated
  one-line reason. The `no-mistakes` gate is an opt-in tier-3 tool, not a
  precondition for pushing.
- While a no-mistakes run owns a branch, let it own the push: do not hand-roll
  `git push` + `gh pr create` alongside an active run.

### Guard bypass prohibition

Review ceremony is negotiable. The **safety guard is not** — that distinction is
the point of this section. Agents MUST NOT suggest, run, or document any of the
following to get a blocked push through:

- `--no-verify` on `git commit` / `git push` (bypasses hooks)
- Piping `yes`, `echo y`, or any non-interactive confirmation into a gate or
  approval prompt
- `no-mistakes --skip <step>` to skip a step that actually failed (skip is only
  for genuinely inapplicable steps, never to fake a green run)
- Editing guard or gate internal state by hand to force a push
- Calling `git push` to a protected branch after the guard blocks, expecting an
  env override to unblock it — there is none

The installed pre-push boundary runs from `/bin/sh`, fixes `PATH`, removes shell
startup injection variables, and launches the enrolled Bash scanner with a
minimal environment. `fba-deploy` does not update that boundary. A maintainer
must explicitly re-enroll audited scanner and allow-list digests when those
assets change.

### Scratch branch class

`llm/agent-push-policy.json` defines a non-delivery scratch branch class for
agent remote backup, resumability, and cross-workspace handoff. Scratch
branches are explicitly non-PR work surfaces — they are not a delivery bypass.

Agents may commit and push matching scratch branches only after the user selects
Remote Scratch Mode. The guard allows those pushes only when the shell declares
`AGENT_WORK_MODE=remote_scratch` or `LLM_AGENT_WORK_MODE=remote_scratch`, the
target branch matches a configured scratch prefix, targets a configured scratch
remote, is not a force/delete push, does not use `--force-with-lease` or a
leading-plus refspec, has no open PR as its head, and is not the base of an open
PR. If any of those checks fails or cannot be verified, the branch is treated as
delivery scope.

The machine-readable cadence is `regular_milestones`: in Remote Scratch Mode,
commit and push after a coherent checkpoint worth preserving, after verification
passes, before long-running or interruptible work, and before handoff or context
compaction. That cadence is for scratch branches only; delivery branches ship
through the no-mistakes gate.

Promoting scratch work means creating or updating a delivery/PR branch from the
scratch commits. That promotion ships through the no-mistakes gate exactly like
any other delivery change.

### Optional private branch classes

The public `yolo_branches` policy entry is disabled and fails closed to the
delivery default-deny. Environments that need an additional branch class must
provide it through their private policy layer; the portable baseline does not
grant ungated PR, force-with-lease, or deletion privileges.

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
- Require explicit SSH lease / approval model for remote access. Every `ssh`
  segment in a compound command must independently satisfy host lease checks.
- Block interactive SSH from agents; SSH must include an explicit remote
  command.
- Block obvious dangerous remote SSH commands such as `sudo`, `su`,
  `systemctl`, `service`, process kills, broad file mutation commands,
  `cqlsh`, and shell/code wrappers such as `bash -c` or `python -c`.
- Allow a pure SSH command to an exact host listed in
  `BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS` (colon separated) or the file named
  by `BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS_FILE`. When the file variable is
  unset, read `bash-safety-guard.playground-ssh-hosts` next to the installed
  guard. Playground hosts bypass the SSH lease and remote-command restrictions;
  private guard extensions still run. Do not grant the exception when `-o
  HostName=...` redirects the exact host, or when SSH is part of a compound
  local command.
- Allow the narrow command `kill <numeric-pid>` for a single PID greater than 1,
  and only on hosts listed in `BASH_SAFETY_GUARD_PID_KILL_HOSTS` (colon
  separated). That variable is **empty in this shared baseline**, so no host is
  permitted until the private install overlay supplies one; the hostnames are
  private configuration and are not named here. The normal SSH host lease is
  still required. Keep signals, multiple PIDs, compound remote commands,
  `pkill`, `killall`, and every unlisted host blocked.
- Block mutating `nodetool` verbs over SSH, including `repair`,
  `compact`, `cleanup`, `scrub`, `drain`, topology changes, `disable*`, and
  `set*`.
- Require an exact command lease, in addition to the host lease, for
  production-sensitive diagnostics such as `nodetool toppartitions`, `jcmd`,
  `jstack`, `jmap`, remote `tar`, large remote `tail`, full database log
  grep, or `find` under `/var/lib/cassandra`. This also applies independently
  to every `ssh` segment in a compound command. Use `ssh-command-gate <host> --
  <remote-command...>` to grant one exact command hash.
- Allow lower-risk read-only diagnostics such as `tpstats`,
  `proxyhistograms`, `tablestats`, `tablehistograms`, `gcstats`, and
  `compactionstats` with only a valid SSH host lease.

### Package publishing

- Block publishing commands such as `npm publish`, `twine upload`,
  `cargo publish`, `gem push`

### GitHub destructive actions

- Block agent-initiated merge/close/delete actions that require human judgment
- When `gh pr` relies on the current repository, block an explicitly prefixed
  `GH_HOST` if it differs from the repository's `origin` host. Omit the
  override and let `gh` derive the host from the repository remote. Host-scoped
  commands such as cross-host `gh api` and `gh gist` remain allowed.

### fun-bash-automations PR safety

- Block `gh pr create`, `gh pr ready`, and `gh pr reopen` for
  `homatthew/fun-bash-automations`. That repo delivers directly on `main`;
  agents must not create or ready PRs for it.

### GitHub gist safety

- Block gist uploads that rely on the `gh` CLI's implicit default host. Require
  every `gh gist create` and gist-creation `gh api` call to select a host
  explicitly with `GH_HOST=...` or `--hostname ...`.
- Block gist uploads unless uploaded filenames or gist payload keys use
  contiguous ordered prefixes like `01_...`, `02_...`, `03_...`
- Keep company-specific host allowlists and routing in dotfiles-owned guard
  extensions. The portable explicit-host check is defense in depth when a
  private extension has not been projected.

### Process killing

- Allow local process cleanup commands (`kill`, `pkill`, `killall`) so agents
  can stop tools they started or clean up stuck local subprocesses.
- Remote SSH command safety remains governed by the SSH lease and remote-command
  guard rules.

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
