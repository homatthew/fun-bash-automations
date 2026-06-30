# Fleet registry

Checked-in baseline for firstmate's `data/projects.md`. `bin/fm` seeds it into
the firstmate home (`data/` is local and gitignored there). This is a thin
navigation registry only, not a knowledge dump: durable per-project detail
belongs in each repo's own AGENTS.md.

Line format parsed by `bin/fm-project-mode.sh`:

    - <name> [<mode>] - <one-line description> (added <date>)

`<mode>` is one of `no-mistakes` | `direct-PR` | `local-only`; an optional
`+yolo` flag (e.g. `[no-mistakes +yolo]`) turns on firstmate self-approval and
is off here on purpose. A missing `[...]` defaults to `no-mistakes off`.
Delivery branch is project-intrinsic and is not part of this format; it is
recorded in captain.md and each repo's AGENTS.md.

- fun-bash-automations [no-mistakes] - shared base layer of agent tooling, skills, and shell automations; delivery branch mh-netflix (added 2026-06-30)
- dotfiles [no-mistakes] - private final-install layer for Netflix workspace and MacBook overlays; delivery branch main (added 2026-06-30)
