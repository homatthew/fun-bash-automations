# Ralph Python Package — DEPRECATED

This Python package (TUI, engine.py, prompt.py, cli.py, PRD mode) is **deprecated**.

## Replacements

| Old | New | Location |
|-----|-----|----------|
| `ralph run plan.md` | `simple-ralph plan.md` | `bin/simple-ralph` |
| `ralph-watch` (via package) | `ralph-watch` (standalone) | `bin/ralph-watch` |
| `ralph init` | Manual `.ralphrc` creation | N/A |
| `ralph status` | `ralph-status` shell function | `zsh/personal.zsh` |
| `ralph logs` | `rt` shell function | `zsh/personal.zsh` |
| `ralph inject` | `echo "directive" > .ralph/directives.md` | Built into simple-ralph |
| PRD mode (story-by-story) | Plan steps via simple-ralph | `bin/simple-ralph` |

## Why

`simple-ralph` (bash, zero deps) proved to be the workhorse. The full Python package
added TUI complexity, PRD mode, and engine abstractions without proportional value.

## Code kept for reference

The code in `src/ralph/` contains useful patterns:
- `watch.py` — Rich live tail (extracted to `bin/ralph-watch`)
- `prompt.py` — Prompt engineering patterns (folded into `bin/simple-ralph`)
- `engine.py` — Iteration loop with failure tracking

Do not maintain or install this package. Use `bin/simple-ralph` instead.
