# llm/hooks

Hook scripts shared across Claude and Codex. `bin/fba-deploy` copies each
`*.sh` here into `~/.claude/hooks/` and `~/.codex/hooks/`.

## Scripts

| Script | Event(s) | What it does |
|---|---|---|
| `notify.sh` | UserPromptSubmit, Stop, Notification | macOS notification only. Used when Slack is disabled. |
| `notify-dispatch.sh` | (helper) | Detached `alerter --json` runner. Owns click handling so hooks return quickly. |
| `notify-working-summary.sh` | (helper) | Detached Codex summarizer for `UserPromptSubmit`; replaces the initial local task label with a shorter generated label only if the same task is still active. |
| `notify-final-summary.sh` | (helper) | Detached Codex summarizer for `Stop`; replaces generic or verbose final text with a concise completion summary only if the same task is still final. |
| `notify-slack.sh` | Stop, Notification | macOS banner + Slack `chat.postMessage`. Threads by (repo, branch). |
| `notify-push-event.sh` | UserPromptSubmit | Quiet acknowledgement on `pg push` / push-gate lease approval. |
| `pre-bash.sh`, `pre-bash-log.sh`, `pre-write.sh` | PreTool | Safety rails + logging. |
| `slack-push-event.sh` | (off by default) | Slack variant of notify-push-event; disabled pending explicit opt-in. |
| `push-gate.sh` | (CLI impl) | Backs the `pg` / `push-gate` shell function. Not a hook. |
| `stack.sh` | (CLI impl) | Backs `bin/stack` — local-first stacked-PR view (`status`) and cascade rebase (`sync`). Not a hook. |

Only one of `notify.sh` / `notify-slack.sh` is referenced from
`settings.json` at a time — don't route both at once.

## Current Notify Architecture

`notify.sh` has three separate jobs. Keep them separate:

1. Scrape message context from the Claude/Codex payload and transcript JSON.
2. Scrape terminal focus context from the hook process tree into ancestor PIDs.
3. Send the macOS notification through `alerter`, then route clicks to the forked VS Code extension.

The main hook must not wait on `alerter --json`; that can keep the hook alive until timeout. Instead, `notify.sh` writes a small JSON job and starts `notify-dispatch.sh` through launchd. The detached helper waits for `alerter` activation, then opens the focus URI. Agent notifications are persistent alert-style notifications: `UserPromptSubmit` creates a quiet task-summary alert, `Stop` replaces it with a `Show` alert, and `Notification` replaces it with a `Respond` alert. All alert notifications use `--timeout 0`.

## Backend Strategy

`notify.sh` chooses exactly one backend per invocation:

```
pick_backend()
  NOTIFY_SUPPRESS=1           → suppressed
  Ghostty frontmost           → suppressed
  TERM_PROGRAM=vscode         → vscode    (PID scrape + alerter)
  alerter in $PATH            → alerter
  else                        → suppressed
```

| Backend | Signature | Notes |
|---|---|---|
| `backend_vscode` | `(title, subtitle, message, group, sender, style, action_label, sound)` | Rings the terminal bell for audible notifications, captures ancestor PIDs, then calls `backend_alerter` with a URL pointing at the forked extension's URI handler. |
| `backend_alerter` | `(title, subtitle, message, group, sender, open_url, style, action_label, sound)` | Dispatches `notify-dispatch.sh` via launchd; the detached helper uses `alerter --json`, then opens `open_url` on `contentsClicked` / `actionClicked`. |
| `backend_suppressed` | – | no-op |

`notify-slack.sh` predates the launchd-detached helper and may lag this shape. Do not copy behavior from it back into `notify.sh` without rechecking this section.

## Event Semantics

`UserPromptSubmit` is the task-start signal. It should be quiet but specific: no sound, no terminal bell, no raw prompt text, and no generic `Task running` / `Working` display. Display shape starts as an emoji-prefixed repo title (`⏳ repo` while running, `🏁 repo` when done), a concise subtitle such as the branch, and a message containing the AI-generated task/result summary. A detached `notify-working-summary.sh` process asks Codex for a 3-8 word running-task summary and replaces the same grouped alert. A detached `notify-final-summary.sh` process does the same for `Stop`, so the final notification does not need to say `Finished` when a real result summary can be generated. Both updates are guarded by `/tmp/fba-notify-state-*` markers so late summaries cannot overwrite a newer task state. The latest summary is also persisted in `/tmp/fba-notify-summary-*`, so `Stop` can reuse it when the runtime sends no useful final assistant text.

`Stop` and `Notification` are audible final states. They use the same group so they replace any active `Working` alert rather than stacking another notification.

## VS Code coupling

The `vscode` backend talks to a private fork of
`vscode-terminal-osc-notifier` at
<https://github.com/homatthew/vscode-terminal-osc-notifier>.

Three strings must agree across the hook scripts **and** the extension
source:

| Constant (in hooks) | Matches in extension |
|---|---|
| `VSCODE_EXT_PUBLISHER` | `publisher` field in `package.json` |
| `VSCODE_EXT_NAME` | `name` field in `package.json` |
| `VSCODE_EXT_URI_PATH` | `uri.path === '…'` in `registerUriHandler` |

If you edit any of them in either notify script, update
`~/repos/vscode-terminal-osc-notifier/package.json` and
`~/repos/vscode-terminal-osc-notifier/src/extension.ts` to match, then
rebuild + reinstall via `bin/install-osc-notifier`.

Why the fork: the hook-created macOS banner needs a click target that
can focus the originating VS Code terminal. Current hooks pass ancestor
PIDs in the `vscode://homatthew.vscode-terminal-osc-notifier/focus?...`
URL. The extension matches those against `terminal.processId`, updates
the status bar, and focuses the matching terminal. Older OSC 777 binding
code is intentionally not used because direct `/dev/tty` writes from a
hook do not reach the extension parser.

Expected click flow:

```
alerter click
  -> notify-dispatch.sh gets JSON activation
  -> open vscode://homatthew.vscode-terminal-osc-notifier/focus?cwd=...&pids=...&event=...&label=...
  -> code <cwd>
  -> open the same URI again
  -> extension rejects wrong workspaces by cwd, then matches terminal.processId against pids
```

Upstream's own UI (OS banner via node-notifier + in-editor toast) is
silenced by two settings flipped from their defaults — the installer
patches these idempotently:

```
terminalNotification.preferOsNotifications = false
terminalNotification.showVsCodeNotification = false
```

## See also

- `bin/install-osc-notifier` — build / install / settings patch flow.
- `bin/fba-deploy` — projects these hooks into `~/.claude` and `~/.codex`.
- `setupPermissions.sh` — new-machine bootstrap (clones the fork, installs `@vscode/vsce`).
