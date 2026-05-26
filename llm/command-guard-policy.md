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
- `PG_ALLOW_INFERENCE=1` (legacy inference bypass; agents must run
  `pg prepare` instead)
- Piping `yes`, `echo y`, or any non-interactive confirmation into the
  approval prompt
- Manually editing `~/.push-gate/` lease state, the Dolt stack-trunk store, or
  `/tmp/pg-approve-*.json` outside the intended editor flow
- Calling `git push` after the hook blocks, expecting the bypass envs above
  to unblock it

When push-gate blocks and no interactive terminal is available, the correct
response has two parts:

1. Agent runs `pg prepare --what ... --why ... --approach ...` to hand off
   the rationale (see `push-gate-prepare` skill).
2. Agent asks the user to run `pg` (or `pg -C <path>`) in their own
   terminal, and waits.

The `--assert-flow TEXT` argument on `pg push` is the semantic-scope
assertion checked against the approved template — it is NOT a bypass.

For async branch work, the human-approved prepare brief becomes an
`approved_scope.work_package`. Descendant commits may add expected files that
match the reviewed package path hints or text tokens, but unrelated paths,
unmatched commit subjects, expired leases, exhausted budgets, and unapproved
rewrites still block. Agents must treat those block reasons as requiring a new
prepare and human review.

For local pre-push review, use `pg review-diff`. It opens the exact
push-gate `base..HEAD` comparison in Neovim Diffview and does not create,
approve, mutate, or consume leases. `pg review-comments --json` may be used by
agents to read exported local review comments for the current head when a
review artifact exists; stale comments must not be treated as approval.
`pg queue` is inspection only. `pg approve-all -C ...` is only sequencing
sugar: each repo still gets the normal editor review and approval flow.

Stack trunks use the same policy at stack scope. `stack trunk init/add` writes
the manifest to push-gate's Dolt store, `stack trunk materialize --stack <name>`
records the generated trunk tip and item commits, the agent runs
`pg prepare-trunk --stack <name> ...`, the human reviews with
`pg trunk --stack <name>`, and the agent pushes approved item commits with
`pg push --trunk-stack <name> --branch <branch> --source-ref <commit>
--assert-flow "..."`.

### Semantic self-check: `pg check`

Before any `pg push`, agents should run `pg check [branch]` to validate the
current HEAD against the active lease's `approved_scope`. Output is JSON:

- `allowed` (bool) — would the push pass scope validation?
- `reason` (string, present when `allowed: false`) — actionable block reason
- `approved_scope` — full scope record (base_ref, paths, subjects, caps,
  optional async work package)
- `current` — head, approved_anchor, `anchor_matches_head`, commits,
  added_lines, changed_files, subjects

If `allowed: false` or `anchor_matches_head: false`, stop, run
`pg prepare` again with the updated rationale, then ask the user to run
`pg` to regenerate the lease. Never push on a stale or scope-violating
lease, and never bypass the failure with an override env.

### Git config and bypasses

- Block `git config` mutations from agents except repo-local rerere enablement:
  `git config --local rerere.enabled true` and
  `git config --local rerere.autoupdate true`, with or without `git -C <repo>`.
  Read-only queries such as `git config --get ...` and `git config --list` are
  allowed.
- Block `--no-verify`
- Allow `git commit --amend` on feature/stack branches; it only rewrites local
  history and push-gate requires a fresh approval before any rewritten tip can
  be pushed
- Block `git commit --amend` on protected branches (`main`/`master`)
- Block disabling signing or pre-commit checks
- Block feature/stack branches from tracking `origin/main` or
  `upstream/main`; a plain `git push` from such a branch could target the
  protected integration branch under some git push modes.

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

- Block `GH_HOST=github.netflix.net`; agents must use
  `GH_HOST=git.netflix.net` for Netflix GHE
- Block `gh api` gist creation unless the command explicitly targets Netflix
  GHE via `GH_HOST=git.netflix.net` or `--hostname git.netflix.net`
- Block gist uploads unless uploaded filenames or gist payload keys use
  contiguous ordered prefixes like `01_...`, `02_...`, `03_...`

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
