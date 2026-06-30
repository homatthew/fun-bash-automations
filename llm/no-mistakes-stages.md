# no-mistakes Stage Reference

The no-mistakes gate runs a fixed-order pipeline on the current branch and only
pushes once the change clears it. Stages, in execution order:

```
intent -> rebase -> review -> test -> document -> lint -> push -> pr -> ci
```

The order is fixed and not configurable. Per-repo settings live in
`.no-mistakes.yaml` (the sanctioned baseline at the repo root); global settings
live in `~/.no-mistakes/config.yaml`. There is **no** per-stage `enabled: false`
key — you cannot delete a stage from config. You only skip a stage at runtime.

## Stages

| Stage | What it does | When it runs |
| --- | --- | --- |
| `intent` | Reads recent local agent transcripts, picks the session that produced the change, and summarizes user intent so later stages judge against what you meant, not just the diff. | First, before review. Skipped automatically when there is no diff. |
| `rebase` | Syncs the pushed branch with the configured push target and the latest upstream default branch; resolves conflicts. | After intent. If the diff is empty post-rebase, remaining stages are skipped. |
| `review` | Automated code review; surfaces findings. | After rebase. |
| `test` | Runs the test command and captures evidence. | After review. |
| `document` | Updates docs/comments to match the change. | After test. |
| `lint` | Runs the lint command and fixes violations. | After document. |
| `push` | Formats (if a `format` command is set) and pushes to the configured target. | After lint. |
| `pr` | Opens or updates the PR. | After push. |
| `ci` | Monitors CI to a decision point or timeout (`ci_timeout`, global). | Last. |

## Configure / skip a stage

Stages are tuned, not toggled. Two levers:

- **auto_fix (per stage, in `.no-mistakes.yaml`)** — max follow-up fix attempts.
  `0` means the stage does **not** auto-fix; it stops at a manual approval gate
  instead. `0` does not disable the stage — it still runs and still gates.
  `review` defaults to `0` (findings are a human decision). Keys: `rebase`,
  `review`, `test`, `document`, `lint`, `ci`.

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
