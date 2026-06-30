# Captain preferences (matthewho)

This is the checked-in baseline for firstmate's `data/captain.md`. `bin/fm`
seeds it into the firstmate home (which keeps `data/` local and gitignored).
Edit the live copy freely; rerun `fm --reseed` only to reset to this baseline.

## Current mission
Run a small, reliable two-repo fleet (`fun-bash-automations`, `dotfiles`)
through the no-mistakes gate. Keep firstmate's activation energy low without
dropping any guardrail.

## Projects & delivery modes
See `data/projects.md` for the machine-parsed registry. In prose:
- `fun-bash-automations` (github.com/homatthew): **no-mistakes** mode, yolo off.
  Delivery branch is `mh-netflix` (direct-push delivery; do NOT open PRs from
  `mh-netflix` to `main`). The no-mistakes gate owns the push.
- `dotfiles` (git.netflix.net/matthewho): **no-mistakes** mode, yolo off.
  Delivery branch is `main` (direct-push). Both repos ship via no-mistakes per
  `fun-bash-automations/llm/AGENTS.md`.

Delivery branches are project-intrinsic and are not encoded in projects.md
(it only carries name/mode/+yolo/description); they live here and in each
repo's own AGENTS.md.

## Beads is the source of truth
- The backlog is a **one-way projection** of beads via `bd-firstmate-bridge`;
  beads (`~/repos/dump/.beads`, `bd ready`) is the system of record.
- Do not hand-edit `data/backlog.md` as if it were authoritative; treat it as a
  generated view. Track real work in beads and let the bridge project it.

## Hard rules
- Never bypass the main-branch guard. Pushing to a base ref
  (main/master/develop/trunk) is blocked by design; that is intentional, do not
  "fix" it.
- Never bypass the no-mistakes gate. No `--no-verify`, no piping `yes`/`echo y`
  into prompts, no `--skip` on a step that actually failed, no faking a green
  run. If a step fails, fix it and rerun.
- **yolo is off by default** for both projects. Only firstmate-makes-its-own-
  approval-decisions on my explicit say-so, and never for destructive,
  irreversible, or security-sensitive actions.
- No push-gate / stack / lease / Dolt ceremony. The model is the simple
  main-guard + no-mistakes gate.
- Keep: dual-model code-review, simplify / ai-slop-removal, security-review,
  update-pr-description (post-gate PR polish). These are kept on purpose.

## Approval posture
- Default to Local Mode: edit, verify, summarize; do not commit/push until I
  explicitly say `commit`/`push` or invoke a finish workflow (`/ship`).
- Surface bootstrap problems (missing tools, gh auth) and wait for consent
  before installing anything.

## Style
- No em-dashes. Conventional, not bespoke. Verify on the real surface before
  claiming done.
