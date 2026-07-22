# Per-repo gnhf tuning (`.gnhf.yml` + `bin/gnhf-here`)

`gnhf` (the bound autonomous depth loop) reads its settings from **one place
only**: the global `~/.gnhf/config.yml`. Its `loadConfig()` joins
`homedir()/.gnhf/config.yml`, then merges `DEFAULT_CONFIG < that file < CLI
flags`. There is **no native per-repo config** and no env-var override for the
loop tuning — verified by reading the installed gnhf bundle
(`gnhf@0.1.41`, `dist/cli.mjs`).

So this is a **convention plus a thin shim**, not a gnhf feature:

- **Convention:** a project may commit a `.gnhf.yml` at its repo root.
- **Shim:** `bin/gnhf-here` applies that file for a single invocation, then
  execs real `gnhf`. With no `.gnhf.yml` present it behaves exactly like plain
  `gnhf "$@"`.

## Why two application paths

Not every gnhf config key has a CLI flag, and the shim never patches the global
config permanently. `bin/gnhf-here` therefore applies repo keys two ways:

1. **Keys with a real gnhf CLI flag** are prepended as flags (repo defaults).
   Anything you also type on the command line still wins — gnhf/commander uses
   the *last* value for value options, and the shim skips a boolean switch you
   already passed so it is never duplicated.
2. **Keys gnhf reads only from `config.yml`** (no flag exists) are merged into
   `~/.gnhf/config.yml` for the duration of the run, then the original file is
   restored (or removed if there was none). A trap guarantees restore even on
   failure or Ctrl-C; the run's exit code is propagated unchanged.

## Supported keys

| `.gnhf.yml` key      | Applied via                       | gnhf surface (verified) |
| -------------------- | --------------------------------- | ----------------------- |
| `agent`              | `--agent <v>` flag                | config key **and** flag |
| `maxIterations`      | `--max-iterations <n>` flag       | flag (per-run limit)    |
| `maxTokens`          | `--max-tokens <n>` flag           | flag (per-run limit)    |
| `stopWhen`           | `--stop-when <v>` flag            | flag (per-run limit)    |
| `meteorFrequency`    | `--meteor-frequency <n>` flag     | flag                    |
| `preventSleep`       | `--prevent-sleep on\|off` flag    | config key **and** flag |
| `worktree: true`     | `--worktree` flag                 | flag                    |
| `currentBranch: true`| `--current-branch` flag           | flag                    |
| `push: true`         | `--push` flag                     | flag                    |
| `agentArgsOverride`  | merged into `~/.gnhf/config.yml`  | config-only key (no flag) |
| `commitMessage.preset` | merged into `~/.gnhf/config.yml` | config-only key (no flag) |

Notes on the config-only keys (these are the ones that *cannot* be set any
other way per-invocation, which is the whole reason the merge path exists):

- `agentArgsOverride` is a map of agent name → array of extra args appended to
  that agent's invocation. Valid agent names: `claude`, `codex`, `rovodev`,
  `opencode`, `copilot`, `pi`. gnhf rejects args it manages itself
  (e.g. for `claude`: `-p`, `--print`, `--verbose`, `--output-format`).
- `commitMessage.preset` must be exactly `conventional` — gnhf rejects any
  other value or extra key under `commitMessage`.

Keys gnhf supports in the global config but that are intentionally **not**
surfaced per-repo by the shim: `agentPathOverride`, `acpRegistryOverrides`,
`maxConsecutiveFailures` (these are machine/installation-level, not loop
tuning, and `maxConsecutiveFailures` has no flag — add it to the merge path if
a project actually needs it).

## Example `.gnhf.yml`

This is the **example only** — do not drop a live `.gnhf.yml` into a repo
unless these values are genuinely right for it.

```yaml
# .gnhf.yml — per-repo defaults for the gnhf loop (applied by bin/gnhf-here).
# gnhf itself does not read this file; the shim translates/merges it.

# Loop tuning (each maps to a real gnhf CLI flag):
agent: codex                 # --agent codex
maxIterations: 50            # --max-iterations 50
maxTokens: 2000000           # --max-tokens 2000000
stopWhen: ALL_TESTS_PASS     # --stop-when "ALL_TESTS_PASS"
worktree: true               # --worktree (run in an isolated git worktree)
preventSleep: true           # --prevent-sleep on

# Config-only keys (no gnhf flag exists — merged into ~/.gnhf/config.yml
# for the run, then reverted):
commitMessage:
  preset: conventional       # gnhf only accepts "conventional"
agentArgsOverride:
  codex:
    - "--profile"
    - "fast"
```

## Usage

```sh
# Instead of:  gnhf "ship the feature"
gnhf-here "ship the feature"

# Your flags still win over the repo defaults:
gnhf-here --agent claude --max-iterations 5 "ship the feature"
```

`bin/gnhf-here` prints what it resolved to stderr (lines prefixed
`gnhf-here:`) so a run log shows exactly which repo defaults were injected and
whether the global config was temporarily merged.

### How it finds the file

It looks for `.gnhf.yml` at the git repo root (`git rev-parse
--show-toplevel`), falling back to the current directory. It parses YAML using
the same `js-yaml` that ships with gnhf (resolved from the gnhf install), so
parsing matches gnhf exactly. Override the gnhf binary with `GNHF_BIN=...` if
needed.
