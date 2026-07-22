# Captain defaults

This portable baseline seeds firstmate's local `data/captain.md`. Keep project
and delivery details in each repository's `AGENTS.md`; keep personal fleet
registries and private workspace policy in a local overlay.

## Operating model

- Read `data/projects.md` for the local project registry.
- Use each project's declared delivery workflow and branch policy.
- Treat beads as the source of truth when `bd` is configured. Honor `BD_DB`
  when set; otherwise use normal project-local discovery.
- Keep firstmate's generated backlog as a one-way view of `bd ready`.

## Guardrails

- Default to Local Mode until the user explicitly requests delivery.
- Never bypass repository guards or validation gates.
- Keep yolo behavior off unless the user explicitly selects it.
- Surface missing tools or authentication instead of installing or mutating
  global state without consent.

## Style

- Keep decisions conventional and reviewable.
- Verify on the real surface before reporting completion.
