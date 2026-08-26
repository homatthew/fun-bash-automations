---
name: herdr
description: "Run isolated coding-agent sessions in Herdr with a controlled plan-first workflow. Use when the user asks to start, monitor, or coordinate Claude/Cursor/Codex in a Herdr pane, especially for implementation work that needs an independent model and a reviewable plan."
---

# Herdr

Use Herdr to create or reuse a sibling pane, start the requested coding agent, and observe its lifecycle without stealing the user's focus. For Claude implementation work, begin in plan mode, verify the default model is Opus 5 with a 1M context window, obtain explicit plan approval, then continue in the same session with permission prompts disabled if the user requested that mode.

## Preconditions and layout

Before any Herdr command, verify the caller is inside a managed pane:

```bash
test "${HERDR_ENV:-}" = 1
```

If it fails, stop and report that Herdr is unavailable. Do not inspect or control a focused Herdr session from outside Herdr.

Read IDs from Herdr's JSON responses; never infer them from pane order. Preserve the user's focus and working directory. A “horizontal pane” means a top/bottom split, so use `--direction down`; `--direction right` creates a vertical divider.

```bash
herdr pane split --current --direction down --cwd "$PWD" --no-focus
```

Use `--direction right` only when the user explicitly asks for a side-by-side pane. Do not close or reuse panes owned by unrelated work.

## Claude plan-first implementation

Start Claude without a model override so the managed default is used. Do not silently substitute a smaller context model:

```bash
herdr agent start implementer --kind claude --pane <pane-id> -- \
  --permission-mode plan --dangerously-skip-permissions
```

The two flags are intentionally orthogonal:

- `--permission-mode plan` makes the initial session read-only and plan-first.
- `--dangerously-skip-permissions` applies after the plan is approved, so implementation does not stop for edit confirmations.

Immediately inspect the startup banner or `/model`. Proceed only if it identifies the default as Opus 5 with a 1M context window. If it does not, stop and report the actual model/context; never silently pass `--model opus`, a Cursor model identifier, or a smaller fallback as equivalent.

Prompt the agent to inspect first and return an implementation plan. Do not ask it to edit in that first prompt. Review the plan, then explicitly approve it through the same agent session. Keep the agent in the same pane/session so the plan and edits share context.

```bash
herdr agent prompt implementer "Inspect the requested change and return a concise plan. Do not edit yet." --wait --timeout 120000
herdr agent read implementer --source recent-unwrapped --lines 160
herdr agent prompt implementer "Plan approved. Implement only that scoped plan; preserve unrelated work; do not commit or push." --wait --timeout 120000
```

If the prompt appears pasted but the lifecycle does not change, send an explicit Enter once and inspect the pane. Do not duplicate the request while the first turn may still be running.

## Monitoring and handoff

Use agent lifecycle commands rather than guessing from terminal output:

```bash
herdr agent get implementer
herdr agent wait implementer --timeout 120000
herdr agent read implementer --source recent-unwrapped --lines 160
```

Treat `blocked` as a request for input, `done`/`idle` as settled, and `unknown` as unverified. If output is hidden on the alternate screen, ask the agent to write the complete response to a temporary Markdown file and return its path, then read that file directly.

The implementation agent must not commit or push unless the user explicitly requests delivery. After it finishes, the parent agent reviews the actual diff, runs relevant tests, applies `$reduce-churn`, and reports any unverified model/context or verification state.
