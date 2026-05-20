# Stack Review Command Surface

This matrix classifies the Stack Review workflow surfaces across `stack`,
push-gate, and Gitless. The ownership boundary is:

- `stack` and `pg` own stack semantics, materialization state, approval state,
  review payloads, push plans, and exact repo-pinned commands.
- Gitless owns presentation, native VS Code diffs, saved-draft editing, and
  labeled workflow actions.

## Canonical User Workflow

| Step | User-visible surface | Owner | Classification | Notes |
| --- | --- | --- | --- | --- |
| Select | `stack -C <repo> trunk list --json` | stack | Canonical UI contract | Lists Dolt-backed materialized stacks only; no loose-branch inference. |
| Materialize | `stack -C <repo> trunk materialize --stack <name>` | stack | Canonical action | Writes materialization records to the Dolt store. |
| Prepare context | `stack -C <repo> trunk context --stack <name> --json` / `stack -C <repo> trunk context write --stack <name> --file context.yaml` | stack | Canonical UI contract/action | Reads/writes durable handoff context for the exact materialization. |
| Prepare | `pg -C <repo> prepare-trunk --stack <name> --from-context` | pg | Agent action | Creates the reviewed prepare brief from durable context; agents must run this before asking for approval. |
| Prepare status | `pg -C <repo> prepare-trunk status --stack <name> --json` | pg | Canonical UI contract | Reports `missing`, `ready`, or detectable `stale` state plus next commands. |
| Review payload | `stack -C <repo> trunk review --stack <name> --json` | stack | Canonical UI contract | Full-stack, item-only, and cumulative diff payload. Gitless must not recompute this. |
| Draft review | `pg -C <repo> trunk-draft --stack <name> --format yaml` | pg | UI support contract | Produces the same approval draft without opening a terminal editor. |
| Approve saved draft | `pg -C <repo> approve-trunk --draft <file> --reviewed-in-vscode` | pg | UI support contract | Only valid for a draft reviewed and submitted from Gitless. |
| Terminal approval | `pg -C <repo> trunk --stack <name>` | pg | Human terminal action | Opens editor and writes a trunk lease after human review. |
| Push plan | `stack -C <repo> trunk push-plan --stack <name> --json` | stack | Canonical UI contract | Checklist and ordered push units. Gitless renders; stack decides. |
| Push | `stack -C <repo> trunk push --stack <name>` | stack | Agent action | Walks approved item pushes through push-gate. |

## Stack Review Event Contract

`stack` and `pg` writers publish v1 JSONL event records so Gitless can
invalidate exactly one repo/stack cache entry without scraping command stderr or
polling all stacks. The stable event types are:

- `stack_manifest_changed`
- `materialized`
- `prepare_context_written`
- `prepare_trunk_written`
- `trunk_approved`
- `lease_changed`
- `push_plan_changed`

Every record includes:

| Field | Purpose |
| --- | --- |
| `schema_version` | Currently `1`; consumers must ignore newer versions they do not understand. |
| `event_type` | One of the stable event types above. |
| `repo_key` | Canonical store key for the source repository, usually the absolute git common dir. |
| `repo_root` | User-facing source worktree path. |
| `stack_name` | Stack Review stack name. |
| `materialization_id` | Current materialization identity for stale detection. |
| `manifest_hash` | Current stack manifest hash for stale detection. |
| `trunk_tip` | Private trunk tip commit for stale detection. |
| `sequence` | Monotonic integer in the event stream. |
| `created_at` | UTC timestamp. |
| `changed_surface` | Surface changed by this event, such as `manifest`, `materialization`, `prepare_context`, `prepare_trunk`, `approval`, `lease`, or `push_plan`. |
| `cache_key` | `{repo_key, stack_name}`; the exact Stack Review cache entry to invalidate. |
| `materialization_key` | `{repo_key, stack_name, materialization_id, manifest_hash, trunk_tip}`; the precise materialized state touched by the event. |

The plumbing command `pg stack-event-contract ...` emits this shape for tests and
writer integration. It does not write an event file by itself.

## Advanced and Compatibility Surfaces

| Surface | Owner | Classification | Replacement or visibility |
| --- | --- | --- | --- |
| `stack status --pr <N> --children`, `stack status --implicit` | stack | Advanced diagnostics | PR-scoped status follows GitHub bases. Broad local-ancestry status requires explicit `--implicit`; Gitless may expose as secondary diagnostics, not the Stack Review primary path. |
| `stack checkout --pr <N>` | stack | Advanced workflow | CLI-only helper for branch editing. |
| `stack push --pr <N> --children` | stack | Advanced workflow | PR-scoped push path for non-Dolt stacks. Plain `stack push` is disabled so broad local ancestry cannot define push scope. |
| `stack sync`, `stack insert`, `stack squash` | stack | Advanced workflow | CLI-only stack maintenance. |
| `stack trunk init/add/move/remove/status` | stack | Advanced stack authoring | Visible in CLI/docs; Gitless can show copyable commands but should not make these primary review buttons. |
| `pg prepare-trunk --what ... --item-briefs FILE` | pg | Compatibility/manual prepare | Prefer durable `stack trunk context write` plus `pg prepare-trunk --from-context` in new Stack Review UX. |
| `stack trunk push --tip` | stack | Advanced validation | Use for composed-stack CI validation before item pushes. |
| `stack trunk --manifest <path>` forms | stack | Compatibility/import | Prefer Dolt-backed `--stack <name>` in all new UX. |
| `pg check`, `pg check-trunk`, `pg leases --json`, `pg show`, `pg revoke`, `pg revoke-trunk` | pg | Advanced diagnostics | Keep out of primary Gitless workflow; can appear in troubleshooting/copy-command sections. |
| `pg --yes` / `pg trunk --yes` | pg | Human terminal convenience | Still opens the editor; never use as an agent bypass. |
| `pg prepare --low-stakes`, `pg prepare-trunk --low-stakes` | pg | Advanced async shortcut | Reviewed async shorthand; not a primary Gitless action. |

## Plumbing-Only Surfaces

| Surface | Owner | Classification | Rule |
| --- | --- | --- | --- |
| `pg draft-approve` | pg | Plumbing | Called by bare `pg`; do not show as a primary command. |
| `pg approve --draft <file>` | pg | Plumbing | Branch approval internals; Gitless Stack Review uses trunk approval only. |
| `pg preview-draft`, `pg preview-trunk` | pg | Plumbing/diagnostics | Rendering helpers for approval scripts and tests. |
| `pg guard-check` | pg | Plumbing | Called by shell guard on `git push`. |
| `pg stack-store-*` | pg | Plumbing | Dolt store internals called by `stack`; Gitless must not call these. |
| `/tmp/pg-prepare-trunk-*`, `/tmp/pg-approve-trunk-*` | pg | Internal files | Gitless may open an explicit draft returned by `trunk-draft`, but must not infer state from path conventions. |
| `PG_ALLOW_INFERENCE=1` | pg | Disabled legacy escape hatch | Do not use, suggest, or document as a workflow; `pg prepare` is required. |

## Gitless Commands

| Command | Classification | Replacement or UX role |
| --- | --- | --- |
| `gitlens.showStackView` | Canonical entry point | Opens the Gitless Stack view. |
| `gitlens.views.stack.openStackReview` | Canonical entry point | Opens the Stack Review surface with labeled actions. |
| `gitlens.views.stack.selectStack` | Canonical selector | Chooses a Dolt-backed materialized stack from `stack trunk list --json`. |
| `gitlens.views.stack.openFileDiff` | Canonical review action | Opens native VS Code diffs from stack-owned review payload refs. |
| `gitlens.views.stack.openApprovalDraft` / `openApprovalYaml` | UI support | Opens the saved trunk draft returned by `pg trunk-draft`; not temp-path inference. |
| `gitlens.views.stack.approveStack` | Canonical approval submission | Calls `pg approve-trunk --reviewed-in-vscode` for the reviewed saved draft. |
| `gitlens.views.stack.rejectApprovalDraft` | Canonical rejection | Deletes/abandons the saved UI draft without writing a lease. |
| `gitlens.views.stack.openRichView` | Compatibility | Replace with Stack Review as the primary surface. |
| `gitlens.views.stack.openStackStatus` | Advanced diagnostics | Secondary action only. |
| `gitlens.views.stack.openPushGate` / `openPushLeases` | Advanced diagnostics | Keep out of the primary workflow. |
| `gitlens.views.stack.copy` / `refresh` | Support | Safe utility actions. |
