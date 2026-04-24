---
name: push-gate
description: "Current push-gate approval policy. ALWAYS invoke BEFORE suggesting or running any `pg`, `push-gate`, lease approval, or bypass flag. Forces re-read of live policy so stale sessions catch bypass prohibitions and the canonical three-command flow (pg / pg push / pg leases)."
---

# push-gate

> **Purpose.** Earlier sessions may have cached an older push-gate policy
> (pre-YAML, pre-scope, pre-bypass-prohibition). This skill re-grounds the
> session in the current rules before anything is suggested or run.

## Step 1 — Re-read live policy before anything else

Before suggesting *any* `pg` command, read these files fresh. They are the
source of truth; memory or prior outputs may be stale.

- `~/.claude/AGENTS.md` — Core Rules, especially the "Never bypass push-gate"
  bullet. This is a symlink to `~/repos/fun-bash-automations/llm/AGENTS.md`,
  so it is always current on disk.
- `~/repos/fun-bash-automations/llm/command-guard-policy.md` — detailed
  bypass prohibition wording.
- `~/repos/fun-bash-automations/llm/hooks/push-gate.sh` — authoritative
  command list and approval flow. When in doubt about a flag or subcommand,
  Read the file or run `pg --help`-style inspection; do not guess.

If a rule below conflicts with those files, those files win and this skill
is out of date — update it.

## Step 2 — Hard rules (do not violate)

**Never bypass push-gate.** Do not suggest, run, document, or reproduce in
examples:

- `PG_SKIP_EDIT=1` — skips the vim review step, which IS the policy.
- `PG_ALLOW_DESCENDANT=1` — bypasses anchor-exact on legacy leases.
- `PG_SCOPE_OVERRIDE=1` — bypasses semantic scope validation.
- `yes | …`, `<<<y`, here-strings, or any other pattern that pipes an
  automated confirmation into the approval prompt.
- Running `/tmp/pg-approve-*.sh` directly with env overrides when bare `pg`
  would work.

If you find yourself about to type any of those, STOP.

## Step 3 — Sanctioned flow (three commands, nothing else)

```
1. pg [-C <path>]                   ← human in their terminal: approve
2. pg push --assert-flow "..."      ← agent: push under the active lease
3. pg leases                        ← (optional) list active leases
```

**Step 1** runs a single flow:
- LLM interviews the commits → fills `what / why / approach / scope / risks`
- vim opens on `/tmp/pg-approve-<repo>-<branch>.yaml`
- user edits or leaves the LLM-filled values, `:wq`
- script renders preview, prompts `Proceed? [y/N]`
- `y` → lease written at `<repo>/.git/push-gate/leases/refs/heads/<branch>.json`
- sentinel at `/tmp/pg-approved/<repo>__<branch>` + macOS banner fire

**Step 2** (agent) invokes guard layers automatically: anchor → scope → semantic
intent match. Scope drift or intent drift → blocked with a specific reason.
Re-pushing the same already-published commits makes 0 LLM calls (instant pass).

Never suggest `pg compose`, `pg draft-approve`, or `pg approve --draft F` to
the user — those are internal plumbing called BY `pg`. If you see a user
output referencing them, re-read `pg --help` to re-ground.

## Step 4 — When the agent has no tty

`pg` requires an interactive terminal. If the agent is running in a
non-interactive harness (Bash tool, CI, background) and push-gate blocks:

- **STOP.** Do not attempt to bypass.
- Tell the user: "push-gate requires your terminal — please run `pg` in
  `<repo-root>` and tell me when approved."
- Wait for the user to come back with approval confirmation (or the
  sentinel file appearing).

Do **not** suggest workarounds like piping `y`, setting `PG_SKIP_EDIT=1`,
or running the approval script yourself with env overrides.

## Step 5 — Semantic scope reminders

`pg` now captures an `approved_scope`. Each `pg push` re-validates the
current diff against it:

- new file outside `approved_scope.paths` → blocked
- commit subject with no keyword overlap with `approved_scope.subjects`
  → blocked
- commit count over `max_commits` → blocked
- added lines over `max_added_lines` → blocked

When a push is blocked, the correct response is **not** to override —
it is to ask the user to re-run `pg` (which re-populates scope from the
current branch state) and approve again.

## Step 6 — Checking for existing approvals

**Start with the cross-repo index, not the sentinel.** Check in this
order:

1. **Central lease DB (cross-repo)** — SQLite at `~/.push-gate/leases.db`.
   Cheap and covers every repo without guessing paths:

   ```bash
   bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh leases
   # or filter:
   bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh leases --repo <repo_root>
   # or JSON for programmatic use:
   bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh leases --json
   ```

   Shows `repo | branch | status | pr | updated` for every lease.
   If a row exists with `status=active` for your (repo, branch), proceed
   to step 2.

2. **Durable lease file (authoritative)** — always under the repo's
   `.git/push-gate/leases/refs/heads/<branch>.json`:

   ```bash
   lease=$(git -C <repo_root> rev-parse --git-common-dir)/push-gate/leases/refs/heads/<branch>.json
   test -f "$lease" && jq '{status, approved_anchor, pr_number, updated_at, approved_scope}' "$lease"
   ```

   Validate with `pg check`:

   ```bash
   bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh -C <repo_root> check <branch>
   ```

   If `allowed: true`, proceed with `pg -C <repo_root> push …`. If
   `allowed: false`, read `reason` — scope drift, anchor mismatch,
   missing pending-assertion, etc.

3. **Sentinel file (hint only)** — `/tmp/pg-approved/<repo>__<branch>`
   only exists for approvals created after the notify-approved change
   landed. **Missing sentinel does NOT mean missing lease** — older
   leases never had one. Do not stop on this signal alone.

Do **not** rely on `pg` being on PATH to check lease state. The hook
script is always at `~/repos/fun-bash-automations/llm/hooks/push-gate.sh`
and can be invoked directly via `bash`.

## Step 7 — Asking the user to approve (one-line command)

When approval is genuinely needed, give the user a single paste-and-run
command using `-C` — no `cd &&` chain, no copy-paste dance. Pick the
shortest viable form in this priority:

1. **`pgr <shortname>`** — if a `pgr` alias is available (defined in
   `zsh/personal.zsh`), this is the lightest. User types
   `pgr skm` (for service-capacity-modeling), fzf resolves, pg runs.
   You don't need to know if pgr is loaded in their shell — just suggest
   it and fall back gracefully.

2. **`pg -C <absolute-path>`** — universal. Works from anywhere, no
   shell state required:

   ```
   pg -C /Users/matthewho/repos/service-capacity-modeling/.claude/worktrees/new-gpu-instances
   ```

   Always use the absolute path; tilde may not expand in all contexts.

Never instruct the user to `cd` first. That adds a step for no gain.

## Common mistakes to avoid

- **Don't** generate long copy-paste blocks for the user to run. The
  single correct instruction is: "run `pg` in your terminal."
- **Don't** regenerate a draft with a different `--intent` and tell the
  user to approve it — just let them run `pg` and edit the YAML in vim.
- **Don't** assume a prior lease is still valid for a new push. Scope
  may block it; let push-gate do its job.
- **Don't** quote bypass commands even in explanatory output. The skill
  treats bypass flags as "do not document" — mentioning them trains
  future sessions to try them.

## Rollback escape hatch

If push-gate itself is broken (not blocking a legitimate scope, or
blocking a legitimate one incorrectly), **fix the hook**, don't bypass
it. The source is `~/repos/fun-bash-automations/llm/hooks/push-gate.sh`.
Edit, run `fba-deploy`, retry.
