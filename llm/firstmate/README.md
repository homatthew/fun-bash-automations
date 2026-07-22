# firstmate preset

A thin portable preset for [firstmate](https://github.com/kunchenguid/firstmate).
It lowers firstmate's activation energy without shipping a personal fleet.

## What this is

firstmate is **not a CLI**. It is an agent home: you run your coding-agent
harness (claude) *inside* a firstmate checkout and its `AGENTS.md` becomes the
operating manual. firstmate exposes ~40 `FM_*` knobs, but nearly all are
watcher / daemon / timing internals. This preset:

- `bin/fm` — a one-command launcher that sets the few knobs that matter, seeds
  this baseline into the firstmate home, and launches the harness.
- `captain.md` / `projects.md` — checked-in baselines for the firstmate home's
  `data/captain.md` and `data/projects.md` (which are local + gitignored in the
  firstmate checkout, so they cannot be committed there).

## Usage

    fm            # seed (if absent) + launch claude inside the firstmate home
    fm --reseed   # overwrite live captain.md/projects.md/crew-harness from baseline
                  # (the old files are backed up to *.bak first)
    fm --help

`fm` resolves the firstmate home from `$FM_HOME` (default `~/repos/firstmate`).
If the home is missing it prints clone instructions and exits non-zero.

## Knobs `fm` sets (and what it leaves alone)

It sets **only** the few that matter for a captain's own main firstmate
session, and leaves every watcher/daemon/timing knob at firstmate's defaults:

| Knob | Set to | Why |
|---|---|---|
| `FM_HOME` | `~/repos/firstmate` (or `$FM_HOME`) | Picks the operational home for `data/`, `config/`, `projects/`, `state/`. Exported so firstmate's own `bin/fm-*.sh` resolve the same home. |
| `config/crew-harness` | `claude` | The one documented switch for the harness firstmate dispatches crewmates on (AGENTS.md section 4). |
| launch harness | `claude` | The captain's own firstmate session runs the `claude` harness; AGENTS.md then drives. |

Everything else (`FM_POLL`, `FM_HEARTBEAT`, `FM_CRASH_*`, `FM_FLEET_*`,
`FM_INJECT_*`, the watcher/daemon internals, ...) is intentionally left unset so
firstmate's own defaults apply. Override any of them in the environment if you
ever need to; `fm` does not get in the way.

Launcher-only escape hatches (not firstmate knobs):
`FM_PRESET_CREW_HARNESS` and `FM_PRESET_HARNESS_CMD` override the crew-harness
value written and the harness binary launched, respectively.

## The baselines

- **`captain.md`** — portable captain charter with the hard rules (main guard,
  no-mistakes gate, yolo off by default), and beads as the source of truth with
  the backlog as a one-way projection via `bd-firstmate-bridge`.
- **`projects.md`** — the thin fleet registry in the exact format
  `bin/fm-project-mode.sh` parses: `- <name> [<mode>] - <desc> (added <date>)`.
  The shared baseline is empty; local overlays own project membership and each
  repo's AGENTS.md owns its delivery policy.

## Customizing

Edit the live copies in the firstmate home (`data/captain.md`,
`data/projects.md`, `config/crew-harness`) directly; `fm` never overwrites a
customized file without `--reseed`. To change the shared baseline for everyone,
edit the files here and ship through the no-mistakes gate. Adding a project:
add a registry line in the format above with the chosen mode, then have
firstmate clone and (for `no-mistakes`) initialize it per AGENTS.md section 6.

For parallel `no-mistakes` work, firstmate spawns each crewmate with a
per-worktree `NM_HOME` derived by `nm-home`, so every gate run gets isolated
state, socket, gate repos, database, and daemon. `nm-home --activate` also
scopes the `no-mistakes` git remote into worktree-local config, because linked
worktrees otherwise share remotes. Manual `treehouse get` shells are auto-scoped
by the zsh hook when they live under `~/.treehouse`; explicit `NM_HOME` values
are left alone. Branch names must still be unique per task because the remote
git host and PR namespace are shared.
