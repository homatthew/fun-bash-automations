# no-mistakes Stage Reference

The no-mistakes gate runs a fixed-order pipeline on the current branch and only
pushes once the change clears it. Stages, in execution order:

```
intent -> rebase -> review -> test -> document -> lint -> push -> pr -> ci
```

The order is fixed and not configurable. Per-repo settings live in
`.no-mistakes.yaml` (the sanctioned baseline at the repo root); home-scoped
settings live in `~/.no-mistakes/config.yaml` by default or
`$NM_HOME/config.yaml` when `NM_HOME` is set. For security, upstream
no-mistakes reads
the code-executing fields (`commands.*` and `agent`) from the trusted
default-branch copy of `.no-mistakes.yaml` by default, not from the pushed
feature-branch SHA. `allow_repo_commands: true` opts a trusted single-developer
repo back into pushed-branch command config. There is **no** per-stage
`enabled: false` key — you cannot delete a stage from config. You only skip a
stage at runtime.

## Stages

| Stage | What it does | When it runs |
| --- | --- | --- |
| `intent` | Records the explicit user intent for the change. Agent-driven runs should pass it directly with `no-mistakes axi run --intent "..."` so later stages judge against what the user meant, not just the diff. | First, before review. Skipped automatically when there is no diff. |
| `rebase` | Syncs the pushed branch with the configured push target and the latest upstream default branch; resolves conflicts. | After intent. If the diff is empty post-rebase, remaining stages are skipped. |
| `review` | Automated code review; surfaces findings. | After rebase. |
| `test` | Runs the test command and captures evidence. | After review. |
| `document` | Updates docs/comments to match the change. | After test. |
| `lint` | Runs the lint command and fixes violations. | After document. |
| `push` | Formats (if a `format` command is set) and pushes to the configured target. | After lint. |
| `pr` | Opens or updates the PR when the configured target uses PR delivery; otherwise it is a no-op. | After push. |
| `ci` | Monitors CI to a decision point or timeout (`ci_timeout`, global). On GitHub/GitLab, the monitor also watches mergeability and can rebase/fix actual merge conflicts while it remains active. | Last. |

## Configure / skip a stage

Stages are tuned, not toggled. Two levers:

- **auto_fix (per stage, in `.no-mistakes.yaml`)** — max follow-up fix attempts.
  `0` means the stage does **not** auto-fix; it stops at a manual approval gate
  instead. `0` does not disable the stage — it still runs and still gates.
  `review` and `document` default to `0` in the Kun-stack baseline: review
  findings and documentation edits are audited, but they park for a decision so
  the gate does not create unrelated churn. Keys: `rebase`, `review`, `test`,
  `document`, `lint`, `ci`.

- **commands (per stage, in `.no-mistakes.yaml`)** — override the `lint`, `test`,
  and `format` commands. Empty string = auto-detect from the repo.

- **`--skip` (runtime only)** — drop a stage for a single run:

  ```bash
  no-mistakes axi run --skip lint
  no-mistakes --skip lint,document     # comma-separated
  ```

  Use this for stages that genuinely do not apply to a change (for example, a
  pure-docs change may not need `test`). Skipping is per-run and never persisted.

## The skip rule

NEVER `--skip` a stage that actually failed. `--skip` is for stages that do not
apply, not for silencing a real failure. If a stage fails, fix the underlying
problem and `no-mistakes rerun` (or `axi respond --action fix`). Skipping a
failed stage fakes a green run and defeats the entire point of the gate.

## After `checks-passed`

For agent-driven runs, `checks-passed` means the PR is ready for human review
and the CI monitor is still alive in the background. Do not hand-rebase, poll,
or start a second `axi run` just because another PR merged first. If the PR later
hits an actual merge conflict while the monitor is still running, no-mistakes
rebases onto the base, resolves it, and re-pushes the branch itself. Recover
with `no-mistakes rerun` only when that monitor is gone: the PR was closed, the
run was aborted or superseded, it idle-timed-out, or auto-fix attempts were
exhausted.
