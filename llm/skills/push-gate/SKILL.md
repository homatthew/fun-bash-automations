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

For stale stack/push-gate context in an already-running agent, ask it to run
`agent-stack-refresh` directly first. `stack-latest` is a human zsh alias for
the same helper and may not exist in non-interactive agent shells. The helper
prints the live stack and push-gate skill paths, current Dolt-backed trunk
approval flow, and Dolt install/verification guidance. Fresh sessions get skill
updates through `fba-deploy` symlinks; running sessions still need this explicit
reset.

## Step 2 — Hard rules (do not violate)

**Never bypass push-gate.** Do not suggest, run, document, or reproduce in
examples:

- `PG_SKIP_EDIT=1` — skips the vim review step, which IS the policy.
- `PG_ALLOW_DESCENDANT=1` — bypasses anchor-exact on legacy leases.
- `PG_SCOPE_OVERRIDE=1` — bypasses semantic scope validation.
- `PG_ALLOW_INFERENCE=1` — legacy inference bypass. It is disabled in the
  approval path; agents must call `pg prepare` instead.
- `yes | …`, `<<<y`, here-strings, or any other pattern that pipes an
  automated confirmation into the approval prompt.
- Running `/tmp/pg-approve-*.sh` directly with env overrides when bare `pg`
  would work.

If you find yourself about to type any of those, STOP.

Scratch branches are a separate, explicit non-delivery branch class configured
in `llm/agent-push-policy.json`. Agents may commit and push configured scratch
branches at their discretion for backup/resume/handoff without push-gate. This
is not a bypass: if a scratch branch has an open PR, is the base of an open PR,
targets an unconfigured remote, or otherwise fails classification, it becomes
delivery scope and must use push-gate.

## Step 3 — Sanctioned flow

```
1. pg prepare --what ... --why ... --approach ...
2. pg [-C <path>] [--yes]           ← human in their terminal: Diffview review + YAML approve
3. pg push --assert-flow "..."      ← agent: push under the active lease
4. pg leases                        ← (optional) list active leases
```

Local review behavior:

- Normal `pg` approval opens the exact pending-push `base..HEAD` comparison in
  Neovim Diffview before the approval YAML. Press `q`, `Space q r`, or run
  `:PgReviewDone` to close the whole Diffview review and continue into the
  editable YAML and final approval prompt. `Space q` is intentionally unmapped
  so a stray leader key does not close review.
- `pg review-diff` opens that same comparison directly when you want to inspect
  or debug the diff outside the approval flow. It does not mutate leases or
  approvals.
- `pg review-comments --json` reads exported local review comments for the
  current head when a review artifact exists. Treat stale comments as context,
  not as approval.
- `pg review-comments status` summarizes unresolved/resolved/stale local
  review comments and groups them by branch or stack item when that metadata
  exists. `pg check` includes the same local-review status so agents cannot
  miss comments before pushing.
- Inside Diffview, `Space g c` opens a 99-style local review thread prompt.
  Write a rough note and save with `:w`; pg asks Codex in fast mode to break
  down exactly what the reviewer is asking for, even when the note is vague,
  and records an agent-actionable comment with the interpreted ask, intent,
  target, requested change, acceptance criteria, ambiguity, and next step.
  The response panel supports `a` accept/save, `r` reply/refine, `e` edit/save,
  and `q` cancel; accepted comments include the local thread transcript for
  agents consuming `pg review-comments --json`. `:PgReviewComment <comment
  text>` records direct text without the AI clarification step. This is a JSON
  handoff, not a GitHub-style inline comment thread UI. The review session also
  maps plain `gc` to the same prompt so Neovim's native comment operator does
  not try to edit read-only Diffview buffers.
- Inside Diffview visual mode, `Space 9 v` asks Codex for a suggested edit for
  the selected lines and records the response as a `suggested_edit` comment.
  This does not mutate the reviewed buffer; a later agent pass consumes
  `pg review-comments --json` and makes real edits.
- Inside Diffview, press `Space r l` to cycle Diffview split layouts such as
  side-by-side and stacked views. Press `Space r u` to open a unified
  inline-style `git diff base..head` buffer when you want patch-style review.
- Inside Diffview, press `Space 9 s` to ask the optional 99/Codex review
  helper to search the current repo/diff. This is advisory only; durable
  review handoff goes through `Space g c`, `Space 9 v`, and
  `pg review-comments --json`.
- `pg queue` shows prepared briefs and active leases.
- `pg approve-all -C repo1 -C repo2` sequentially runs normal `pg` approval
  for each repo. It still opens the editor for each approval and is not a
  bypass.

**Step 1** runs a single flow:
- LLM interviews the commits → fills `what / why / approach / scope / risks`
- Neovim Diffview opens on the exact pending-push diff; user reviews and
  presses `q`, `Space q r`, or runs `:PgReviewDone`
- vim opens on `/tmp/pg-approve-<repo>-<branch>.yaml`
- user edits or leaves the human approval memo, `:wq`
- script renders preview, prompts `Proceed? [y/N]`
- `y` → lease written at `<repo>/.git/push-gate/leases/refs/heads/<branch>.json`
- sentinel at `/tmp/pg-approved/<repo>__<branch>` + macOS banner fire

`--yes` / `-y` is allowed only on the human approval command. It still opens the
editor first and renders the preview; it only skips the final `Proceed? [Y/n]`
prompt after the editor exits.

**Step 2** (agent) invokes guard layers automatically: anchor → scope → semantic
intent match. Scope drift or intent drift → blocked with a specific reason.
Re-pushing the same already-published commits makes 0 LLM calls (instant pass).

Never suggest `pg draft-approve`, `pg approve --draft F`, or `pg compose`
(removed) to the user — those are internal plumbing called BY `pg`. If
you see a user output referencing them, re-read `pg --help` to re-ground.

**Before telling the user to run `pg`, always run `pg prepare` first.**
See the `push-gate-prepare` skill for the required arguments. If `pg`
blocks with "NO PREPARED BRIEF", your fix is `pg prepare`, not a bypass.

### Async iteration mode

Async is opt-in and still uses the same human editor review. It lets one human
approval cover repeated pushes for the same branch or stack while the lease is
unexpired, under budget, and still inside the approved semantic scope.
For low-stakes iteration, `--low-stakes` is shorthand on `pg prepare` and
`pg prepare-trunk` for a reviewed async lease with `--expires 1h` and
`--max-pushes 5`.

For unattended branch work, the reviewed `--what`, `--why`, `--approach`,
`--scope`, and `--risks` form an async work package in
`approved_scope.work_package`. That package can cover future descendant commits
that add expected implementation/test/doc files even when those files did not
exist at approval time. It is still narrow: path prefixes, reviewed text
tokens, commit-subject tokens, expiry, push budget, and rewrite policy are all
checked. Unrelated paths or subjects require a new `pg prepare` and human
review.

Branch flow:

```bash
pg prepare --async --expires 8h --max-pushes 20 \
  --what "..." --why "..." --approach "..."
pg -C <repo-root>          # human
pg push --assert-flow "..."
```

Use `--allow-rewrite` only when the reviewed workflow includes intentional
rebases/squashes/force-with-lease updates. Otherwise async permits only
descendant commits. Normal non-async approvals are exact-tip approvals; if
`HEAD` changes after review, re-run `pg prepare` and ask for review again.

For stacked child branches with no PR and no upstream, branch approval chooses
the closest local ancestor branch that already has an open PR before falling
back to `origin/main` or `origin/master`. The chosen base is shown in the YAML
context and preview as `approved_scope.base_ref`; if it is surprising, stop and
set the branch upstream or re-prepare with the intended stack state.

`pg check`, `pg check-trunk`, and `pg leases --json` expose
`async_iteration.enabled`, expiry, push budget, remaining pushes, scope, and a
block reason. Treat a block reason as final until the agent re-prepares and the
human reviews again.

For stack trunks, the same split applies at trunk scope:

```
1. Agent: stack trunk context write --stack S --file context.yaml
2. Agent: pg prepare-trunk --stack S --from-context
3. Human: pg trunk --stack S
4. Agent: pg push --trunk-stack S --branch B --source-ref REF --assert-flow "..."
```

Use `pg -C <repo> prepare-trunk status --stack S --json` when a UI or script
needs prepare state. It reports `missing`, `ready`, or detectable `stale`
state plus the repo/worktree target and exact next commands; consumers must not
parse `pg trunk` stderr or inspect `/tmp/pg-prepare-trunk-*` directly.
Use `stack -C <repo> trunk context --stack S --json` when a UI or agent needs
the durable handoff packet, generated review hints, completeness, or stale
prior materialization context. Context can be partial, but
`pg prepare-trunk --from-context` blocks until the top-level brief and every
current stack item have what, why, and approach. Explicit `--what`, `--why`,
`--approach`, and `--item-briefs` remain available for one-off prepares, but
durable Stack Review handoff should prefer the context store.

Async stack trunk flow:

```bash
stack trunk context write --stack S --file context.yaml
pg prepare-trunk --stack S --from-context --async --expires 8h --max-pushes 30 --allow-rewrite
pg trunk --stack S         # human
stack trunk push --stack S # agent
```

Trunk async scope is intentionally narrow: same stack name, same private trunk
ref, same manifest hash, same item ids, and same item branch names. The draft
will still show SHA-specific materialization details because those are the
initial reviewed/audited commits. Future async materializations may move those
commit SHAs only inside the unchanged scope and only when rewrite was approved.

The stack manifest and trunk materialization live in the Dolt store under
`~/.push-gate/dolt-store` by default. Use `stack trunk init/add/status/materialize
--stack S`; repo `.stack/*.json` files are compatibility/import inputs, not the
source of truth.

Trunk approval drafts use this vocabulary:

- Human-facing YAML is split into a top approval memo and a bottom
  `machine:` contract. The top memo is what the human should read first:
  summary, review unit, changed-file/stat summaries, local review comment
  status, and approve/deny guidance. Branch refs, SHAs, anchors, async
  internals, and materialization details live under `machine:`.
- For stacks, Diffview review comments are scoped to the stack item being
  reviewed. Whole-stack text answers "is this direction okay"; item diffs
  answer "is this layer's patch okay"; pending push answers "what exact bytes
  move now."
- `description`: PR-description-style human review text shown first in YAML.
- `stack_items`: ordered review/push units in the stack.
- `stack_items[].description`: item-level PR-description-style summary,
  motivation, approach, scope, risks, and testing.
- `stack_items[].brief`: required item-level `what`, `why`, and `approach`.
  Kept for compatibility; approval derives it from `description`.
- `pointer_commit`: exact branch tip approved for that stack item.
- `base_commit`: effective review base for that stack item.
- `contained_commits`: commits included in the item patch range.
- `changed_files`: changed paths grouped by readable labels such as `added`
  and `modified`, not raw git status letters.

The agent-authored `prepare-trunk` brief should explain the cross-item `what`,
`why`, and `approach` in human terms. For multi-item stacks, agents should pass
`--item-briefs FILE`; approval blocks until every stack item has item-level
`what`, `why`, and `approach`.

The item briefs file may be JSON or YAML:

```yaml
item_briefs:
  - id: pr266
    summary:
      - Fix Cassandra page-cache memory attribution.
    motivation:
      - Avoid false memory-driven node-count explanations.
    approach:
      - Keep the attribution behavior in PR266.
    risks:
      - Baseline churn needs review.
    testing:
      - tox -e py312 -- tests/netflix/test_cassandra_memory.py
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
- async branch file outside `approved_scope.work_package` path hints or text
  tokens → blocked
- commit subject with no keyword overlap with `approved_scope.subjects`
  → blocked
- commit count over `max_commits` → blocked
- added lines over `max_added_lines` → blocked

When a push is blocked, the correct response is **not** to override —
it is to ask the user to re-run `pg` (which re-populates scope from the
current branch state) and approve again.

For async leases, first read the `async_iteration.block_reason`. Expired or
budget-exhausted leases require a fresh prepare and human review. Use
`pg revoke <branch>` or `pg revoke-trunk --stack <name>` as the kill switch if
the user wants to end an async authorization early.

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

For stack-trunk approvals, inspect the Dolt lease directly through:

```bash
bash ~/repos/fun-bash-automations/llm/hooks/push-gate.sh -C <repo_root> check-trunk --stack <name>
```

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
