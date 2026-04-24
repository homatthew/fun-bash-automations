# llm/hooks

Hook scripts shared across Claude and Codex. `bin/fba-deploy` copies each
`*.sh` here into `~/.claude/hooks/` and `~/.codex/hooks/`.

## Scripts

| Script | Event(s) | What it does |
|---|---|---|
| `notify.sh` | Stop, Notification | macOS banner only. Used when Slack is disabled. |
| `notify-slack.sh` | Stop, Notification | macOS banner + Slack `chat.postMessage`. Threads by (repo, branch). |
| `notify-push-event.sh` | UserPromptSubmit | Quiet acknowledgement on `pg push` / push-gate lease approval. |
| `pre-bash.sh`, `pre-bash-log.sh`, `pre-write.sh` | PreTool | Safety rails + logging. |
| `slack-push-event.sh` | (off by default) | Slack variant of notify-push-event; disabled pending explicit opt-in. |
| `push-gate.sh` | (CLI impl) | Backs the `pg` / `push-gate` shell function. Not a hook. |
| `stack.sh` | (CLI impl) | Backs `bin/stack` — local-first stacked-PR view (`status`) and cascade rebase (`sync`). Not a hook. |

Only one of `notify.sh` / `notify-slack.sh` is referenced from
`settings.json` at a time — don't route both at once.

## Backend strategy pattern

Both notify scripts share the same internal structure. A single
dispatcher chooses exactly one backend per invocation:

```
pick_backend()
  NOTIFY_SUPPRESS=1           → suppressed
  Ghostty frontmost           → suppressed
  TERM_PROGRAM=vscode         → vscode    (OSC bind + alerter)
  alerter in $PATH            → alerter
  terminal-notifier in $PATH  → terminal_notifier
  else                        → suppressed
```

| Backend | Signature | Notes |
|---|---|---|
| `backend_vscode` | `(title, subtitle, message, group, sender)` | Emits OSC 777 carrying a stable `tid`, then calls `backend_alerter` with a URL pointing at the forked extension's URI handler. |
| `backend_alerter` | `(title, subtitle, message, group, sender, open_url)` | Uses `alerter --json`, opens `open_url` on `contentsClicked`. |
| `backend_terminal_notifier` | `(title, subtitle, message, group, sender, open_url)` | Passes `-open "$open_url"` through to `terminal-notifier`. |
| `backend_suppressed` | – | no-op |

Adding a new backend = one new `backend_foo()` + one arm in
`pick_backend`. Keep both notify scripts in sync by hand — duplication
is cheaper than a shared lib here.

## OSC coupling with the forked VS Code extension

The `vscode` backend talks to a private fork of
`vscode-terminal-osc-notifier` at
<https://github.com/homatthew/vscode-terminal-osc-notifier>.

Four strings must agree across the hook scripts **and** the extension
source:

| Constant (in hooks) | Matches in extension |
|---|---|
| `OSC_EXT_PUBLISHER` | `publisher` field in `package.json` |
| `OSC_EXT_NAME` | `name` field in `package.json` |
| `OSC_EXT_URI_PATH` | `uri.path === '…'` in `registerUriHandler` |
| `OSC_NOTIFY_FORMAT` | Parser arms in `OscParser.tryParseOsc` |

If you edit any of them in either notify script, update
`~/repos/vscode-terminal-osc-notifier/package.json` and
`~/repos/vscode-terminal-osc-notifier/src/extension.ts` to match, then
rebuild + reinstall via `bin/install-osc-notifier`.

Why the fork: upstream auto-assigns terminal ids per
`vscode.Terminal`, so external banners can't target a specific tab. The
fork adds a 5-field OSC shape (`777;notify;tid=<id>;<title>;<body>`)
that binds a caller-supplied id to the emitting terminal. The banner's
click URL (`vscode://homatthew.vscode-terminal-osc-notifier/focus?tid=<id>`)
then lands the user on the originating tab.

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
