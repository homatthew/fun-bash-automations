---
name: push-gate
description: "Current push-gate approval policy. ALWAYS invoke BEFORE suggesting or running any `pg`, `push-gate`, lease approval, or bypass flag — before touching `PG_SKIP_EDIT`, `PG_ALLOW_DESCENDANT`, `PG_SCOPE_OVERRIDE`, `/tmp/pg-approve-*.sh`, or `pg draft-approve`. Also when user asks about pushing, approval flow, leases, `compose`, or 'how do I push'. Forces re-read of live policy so stale sessions catch bypass prohibitions and YAML flow changes."
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

## Step 3 — Sanctioned flow

The only correct way to approve is a human running `pg` (no args) in their
own interactive terminal.

```
cd <repo-root>
pg
```

What happens:

1. Vim opens on `/tmp/pg-approve-<repo>-<branch>.yaml` — the full draft in
   YAML (intent, agent_assertion_template, approved_scope: paths /
   subjects / max_commits / max_added_lines).
2. User edits. `:wq` to continue. `:cq` or empty-save to abort.
3. Script converts YAML → JSON, validates, renders preview.
4. `Proceed? [y/N]` — human types `y`.
5. Lease written; sentinel at `/tmp/pg-approved/<repo>__<branch>` + macOS
   notification fire.

After approval, the agent may push with:

```
pg push --assert-flow $'update pr #<N>\nbranch <branch>\n<summary>\nno rewrite'
```

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

Before asking the user to approve, check whether a lease already
exists. **The durable lease file is the source of truth, not the
sentinel.** Check both in order:

1. **Lease file (authoritative)** — lives in the repo's `.git/push-gate/`:

   ```bash
   lease=$(git rev-parse --git-common-dir)/push-gate/leases/refs/heads/<branch>.json
   test -f "$lease" && jq '{status, approved_anchor, pr_number, updated_at, approved_scope}' "$lease"
   ```

   If `status == "active"` and the file exists, a lease is live. Validate
   it with:

   ```bash
   bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh check <branch>
   ```

   If `allowed: true`, you can proceed with `pg push …`. If
   `allowed: false`, read the `reason` — it tells you what to do (scope
   drift, anchor mismatch, missing pending-assertion, etc.).

2. **Sentinel file (hint only)** — `/tmp/pg-approved/<repo>__<branch>`
   exists only for approvals created after the notify-approved change
   landed. **Missing sentinel does NOT mean missing lease** — older
   leases won't have one. Do not stop on this alone.

Do **not** rely on `pg` being on PATH to check lease state. The hook
script is always at `~/repos/fun-bash-automations/llm/hooks/push-gate.sh`
and can be invoked directly via `bash`.

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
