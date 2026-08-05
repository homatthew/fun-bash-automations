# llm/hooks

Hook scripts shared across Claude and Codex. `bin/fba-deploy` copies each
`*.sh` here into `~/.claude/hooks/` and `~/.codex/hooks/`.
Custom Claude and Codex alert hooks are currently disabled in
`claude/settings.json` and `codex/hooks.json`; the scripts remain for manual use
or future opt-in.

## Scripts

| Script | Event(s) | What it does |
|---|---|---|
| `notify.sh` | UserPromptSubmit, Stop, Notification | macOS notification only. Used when Slack is disabled. |
| `notify-dispatch.sh` | (helper) | Detached `alerter --json` runner. Owns click handling so hooks return quickly. |
| `notify-metrics.sh` | (helper) | Shared JSONL timing helpers for notification click-to-editor-open paths. |
| `notify-working-summary.sh` | (helper) | Detached Codex summarizer for `UserPromptSubmit`; replaces the initial local context/message with generated text only if the same task is still active. |
| `notify-final-summary.sh` | (helper) | Detached Codex summarizer for `Stop`; replaces generic or verbose final context/message with generated text only if the same task is still final. |
| `notify-input-summary.sh` | (helper) | Detached Codex classifier for input-needed notifications; replaces provisional question alerts with generated kind/context/summary only if the same input state is still active. |
| `notify-slack.sh` | Stop, Notification | macOS banner + Slack `chat.postMessage`. Threads by (repo, branch). |
| `notify-push-event.sh` | UserPromptSubmit | Quiet acknowledgement on a push/delivery event. |
| `beads-prime.sh` | SessionStart, PreCompact | Emits `bd prime` task context when the shared Beads DB exists. This is context plumbing, not a style/personality hook. |
| `self-review-guard.sh` | Stop | Prompts for an independent-model code review when the pending diff warrants one. See below. |
| `cursor-mode-guard.sh` | PreToolUse (Bash) | Denies a Cursor agent launch that omits `--force`, because it would stall on an approval prompt nobody is watching. Names the spawner in the denial. Read-only Cursor calls pass through. Separate from `bash-safety-guard.sh` on purpose: ergonomics gate, not a hard safety control. |
| `pre-bash.sh`, `pre-bash-log.sh`, `pre-write.sh` | PreTool | Safety rails + logging. |
| `slack-push-event.sh` | (off by default) | Slack variant of notify-push-event; disabled pending explicit opt-in. |

## self-review-guard.sh

Registered on `Stop` in `claude/settings.json`. It asks the agent to send the
pending diff to an independent reviewer model before finishing.

It is deliberately weak in three ways, and all three are the point — a check that fires
on every change and cannot be escaped stops being a safety net and becomes
something to route around:

- **Proportional.** Silent unless the diff earns attention: a sensitive surface
  (hooks, guards, auth, credentials, crypto, workflows, migrations, policy), or a
  wide diff (`FBA_REVIEW_MAX_FILES`, default 15; `FBA_REVIEW_MAX_LINES`, default
  400). Editing branches — `wip/`, `scratch/`, `gnhf/`, `tmp/`, `experiment/`,
  and any `*yolo/` — are exempt outright. Documentation-only diffs never count as
  sensitive.
- **Escapable.** Blocks at most once per distinct diff, and its own message tells
  the agent that `skipping review: <reason>` is a legitimate answer. Any further
  edit changes the diff fingerprint and re-arms it.
- **Attributable.** Silent when the session wrote none of the diff. A `Stop`
  fires on every turn, including read-only ones — answering a question, reading
  code, producing a plan — and telling those to go review work that was already
  in the tree is noise; it is worst in a delegated planning window whose repo
  carries unrelated uncommitted work. The check reads the transcript named in the
  `Stop` payload: a write tool (`Edit`, `Write`, `NotebookEdit`, …), delegation to
  a subagent (`Agent`, `Task`, `Workflow` — whose own transcript the parent cannot
  see), or a writing shell command (`git commit/apply/rebase/…` including the
  `git -C dir …` and `git -c k=v …` forms, `sed -i`, `patch`, `tee`) all count as
  writing. Two deliberate limits: it is scoped to the session rather than the
  turn, so once a session has written something its later turns count as authors
  too; and a write through a shell form or MCP tool not listed above is a known
  blind spot. Anything unknown — no `transcript_path`, an unreadable transcript, a
  `grep` that failed rather than found nothing, no `jq` — falls back to prompting;
  only "no match" counts as proof.

State lives in `<git-dir>/fba-self-review.log`, capped at 200 lines. The Stop
path always exits 0, so a bug here cannot wedge a session.

```sh
self-review-guard.sh --status          # diff fingerprint, state, and trigger
self-review-guard.sh --mark-reviewed   # record a review you actually ran
FBA_SELF_REVIEW_GUARD=0                # disable for a session
```

This hook only ever asks for a code review. The hard controls —
protected-branch pushes, force-pushes, `--no-verify` — stay with
`bash-safety-guard.sh` and the git-level pre-push hook, and are not proportional.

`bash-safety-guard.sh` also runs optional private extensions from
`bash-safety-guard.d/*.sh` next to the projected hook. Keep confidential
hostnames, service-specific allowlists, and private lease policy in those
dotfiles-owned extensions rather than in this shared repository.

Only one of `notify.sh` / `notify-slack.sh` is referenced from
`settings.json` at a time — don't route both at once.

## Current Notify Architecture

`notify.sh` has three separate jobs. Keep them separate:

1. Scrape message context from the Claude/Codex payload and transcript JSON.
2. Scrape terminal focus context from the hook process tree into ancestor PIDs.
3. Send the notification through the selected terminal/backend. VS Code uses `alerter` plus the forked VS Code extension for click routing; Ghostty uses native terminal notifications.

The main hook must not wait on `alerter --json`; that can keep the hook alive until timeout. Instead, `notify.sh` writes a small JSON job and starts `notify-dispatch.sh` through launchd. The detached helper waits for `alerter` activation, then opens the focus URI. Agent notifications are alert-style notifications: `UserPromptSubmit` creates a quiet task-summary alert, `Stop` replaces it with a `Show` alert, and `Notification` replaces it with a `Respond` alert. Alert notifications use a long bounded timeout, defaulting to 14400 seconds and overrideable with `NOTIFY_ALERT_TIMEOUT_SECONDS`; avoid `--timeout 0` because each unclicked alert can keep an `alerter` process alive forever. Running notifications also re-post themselves after `Show` is clicked if the task's `/tmp/fba-notify-state-*` marker still says that run is active; this makes the alert act like a persistent focus link while work is still running without resurrecting final notifications. Notification groups and state files are scoped by runtime, repo, and terminal/session key so concurrent Claude/Codex sessions in the same repo do not overwrite each other.

## Backend Strategy

`notify.sh` chooses exactly one backend per invocation:

```
pick_backend()
  NOTIFY_SUPPRESS=1           → suppressed
  Codex GUI without tty       → suppressed
  TERM_PROGRAM=ghostty + tty  → ghostty   (native OSC 9)
  TERM_PROGRAM=vscode         → vscode    (PID scrape + alerter)
  else                        → suppressed
```

| Backend | Signature | Notes |
|---|---|---|
| `backend_ghostty` | `(title, subtitle, message, sound)` | Emits Ghostty's native `OSC 9` desktop notification to `/dev/tty`, plus a terminal bell for audible final/input states. It does not build or open a VS Code URI. Async AI summary re-posts are skipped because detached launchd helpers do not reliably keep the originating TTY. |
| `backend_vscode` | `(title, subtitle, message, group, sender, style, action_label, sound)` | Rings the terminal bell for audible notifications, captures ancestor PIDs, then calls `backend_alerter` with a URL pointing at the forked extension's URI handler. |
| `backend_alerter` | `(title, subtitle, message, group, sender, open_url, style, action_label, sound)` | VS Code helper backend only. Dispatches `notify-dispatch.sh` via launchd; the detached helper uses `alerter --json`, then opens `open_url` on `contentsClicked` / `actionClicked`. |
| `backend_suppressed` | – | no-op |

Notification delivery is allowlist-only: outside `TERM_PROGRAM=vscode` or
`TERM_PROGRAM=ghostty`, the hook exits successfully without updating state,
posting Slack, or invoking macOS notification binaries. `notify-slack.sh`
predates the launchd-detached helper and may lag this shape. Do not copy
behavior from it back into `notify.sh` without rechecking this section.

Codex Desktop/App-originated turns already have native Codex app
notifications. When a hook invocation is identifiable as Codex GUI without a
controlling TTY, `notify.sh` exits successfully without posting a custom
notification. That avoids duplicate banners and prevents GUI notifications from
opening VS Code. Tests can set `NOTIFY_ASSUME_TTY=1` to exercise the Ghostty
branch from non-interactive shells.

## Event Semantics

Agent notifications are a state machine, not independent banners:

| State | Title | Subtitle | Message | Action | Sound | Sticky after click |
|---|---|---|---|---|---|---|
| `running` | `⏳ <repo>` | concise task context | concise current work summary | Show | none | yes, while state marker still matches |
| `input` | `❓ <repo>` | `<input kind> · <task context>` | what the user needs to answer or do | Respond | Pop | yes, while state marker still matches |
| `done` | `🏁 <repo>` | concise result context | concise completed result | Show | Pop | no |

Allowed transitions are `running -> input | done`, `input -> running | done`, and `done -> running`. Runtime mapping is:

| Runtime event | Display state |
|---|---|
| Claude `UserPromptSubmit` | `running` |
| Claude `Notification` | `input` |
| Claude `Stop` | `done` |
| Codex `UserPromptSubmit` | `running` |
| Codex `Stop` with a direct question/blocker | `input` |
| Codex `Stop` with a result | `done` |

`UserPromptSubmit` is the task-start signal. It should be quiet but specific: no sound, no terminal bell, no raw prompt text, and no generic `Task running` / `Working` display. Branch, open PR metadata, recent commit subjects, repo, cwd, and prompt are inputs to the context generator; broad branch names like `main` should not be shown when PR or commit context is more useful. A detached `notify-working-summary.sh` process asks Codex for both context and a 3-8 word running-task summary, then replaces the same grouped alert.

`Stop` and `Notification` replace the same runtime/repo group instead of stacking another notification. Claude has a native `Notification` event for input-needed prompts; Codex currently only has `Stop`, so `notify.sh` uses a cheap candidate check on Codex `Stop` messages that ask for a concrete user action or explicit blocker and immediately posts an input-needed alert (`❓ repo`, `Respond`) instead of done (`🏁 repo`, `Show`). A bare trailing question mark is intentionally not enough, because result summaries can end with rhetorical or diagnostic questions. A detached `notify-input-summary.sh` Codex call may refine the input kind/context/summary, such as `Permission · Git workflow` / `Approve a protected push`. A detached `notify-final-summary.sh` process refines only `done` state, so final-summary AI cannot rewrite an input-needed prompt into a completed result.

All async refinements and sticky re-post loops are guarded by `/tmp/fba-notify-state-*` markers keyed by runtime, repo, and terminal/session. `running` uses the raw run id, `input` uses `input:<run id>`, and `done` uses `final:<run id>`, so late summaries cannot overwrite a newer state and running/input re-posts stop when the marker changes. The latest summary/context are also persisted in matching `/tmp/fba-notify-summary-*` and `/tmp/fba-notify-context-*` files, so `Stop` can reuse them when the runtime sends no useful final assistant text without leaking across another terminal session.

## Click Metrics

Notification click paths write JSONL timing events to `/tmp/fba-notify-metrics.jsonl` by default. Override with `NOTIFY_METRICS_LOG=<path>`. Each `notification_click_open` row records the helper source (`dispatch`, `working_summary`, `final_summary`, `input_summary`), action label (`Show` or `Respond`), activation type, group/state id, URL scheme, and timing deltas: `notification_to_click_ms`, `click_to_open_start_ms`, and `click_to_open_done_ms`. The start timestamp is taken immediately before invoking `alerter`, so `notification_to_click_ms` includes `alerter` startup/display latency plus the user's time to click.

The default VS Code click path is folder-first: write a small focus request to
`/tmp/fba-vscode-focus-requests`, run `open -b com.microsoft.VSCode <cwd>`,
wait briefly, then fire the `vscode://...` URI as compatibility fallback. The
folder-open step makes the target workspace window the first visible action, and
the focus request lets the forked extension focus the matching terminal from
the correct workspace even when macOS routes URI handlers to a different VS Code
window. Override the bundle id with `NOTIFY_VSCODE_BUNDLE_ID=<bundle id>` if
needed. Set `NOTIFY_VSCODE_RECOVERY=0` to disable recovery,
`NOTIFY_VSCODE_RECOVERY=async` to test background recovery, or
`NOTIFY_VSCODE_RECOVERY=uri-first` to restore the older URI-first sequence.
Synchronous recovery metrics are included in the `notification_click_open` row;
async recovery writes a separate `notification_vscode_recovery` row. Recovery
rows include `folder_open_duration_ms`, `sleep_duration_ms`, and second-open
timing.

## Slack credentials

Slack delivery is disabled until a private overlay supplies credentials. Set
`NOTIFY_SLACK_TOKEN` and `NOTIFY_SLACK_CHANNEL` directly, with optional
`NOTIFY_SLACK_USER_ID`, or configure Keychain service names through
`NOTIFY_SLACK_TOKEN_KEYCHAIN_SERVICE`,
`NOTIFY_SLACK_CHANNEL_KEYCHAIN_SERVICE`, and optional
`NOTIFY_SLACK_USER_KEYCHAIN_SERVICE`. `NOTIFY_SLACK_KEYCHAIN_ACCOUNT` overrides
the default account name. The public hooks contain no environment-specific
Keychain identifiers.

## VS Code coupling

The `vscode` backend talks to a configured build of
`vscode-terminal-osc-notifier`. Set `OSC_NOTIFIER_REPO_URL` and
`OSC_NOTIFIER_PUBLISHER` in a local overlay to opt into fork installation.

Three strings must agree across the hook scripts **and** the extension
source:

| Constant (in hooks) | Matches in extension |
|---|---|
| `VSCODE_EXT_PUBLISHER` | `publisher` field in `package.json` |
| `VSCODE_EXT_NAME` | `name` field in `package.json` |
| `VSCODE_EXT_URI_PATH` | `uri.path === '…'` in `registerUriHandler` |

If you edit any of them in either notify script, update the configured
extension's `package.json` and `src/extension.ts` to match, then rebuild and
reinstall via `bin/install-osc-notifier`.

Why the fork: the hook-created macOS banner needs a click target that
can focus the originating VS Code terminal. Current hooks pass ancestor
PIDs in the `vscode://<publisher>.vscode-terminal-osc-notifier/focus?...`
URL. The extension matches those against `terminal.processId`, updates
the status bar, and focuses the matching terminal. Older OSC 777 binding
code is intentionally not used because direct `/dev/tty` writes from a
hook do not reach the extension parser.

Expected click flow:

```
alerter click
  -> notify-dispatch.sh gets JSON activation
  -> open vscode://<publisher>.vscode-terminal-osc-notifier/focus?cwd=...&pids=...&event=...&label=...
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
- `setupPermissions.sh` — new-machine bootstrap (installs configured optional OSC dependencies).
