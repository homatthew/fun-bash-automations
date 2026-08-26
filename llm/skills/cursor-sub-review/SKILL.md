---
name: cursor-sub-review
description: Run an independent, read-only Cursor Agent code-review leg reliably. Use when a review needs a Cursor model such as Kimi K3 or Claude Opus, especially from Codex or another headless harness where buffered output, concurrent Cursor configuration races, or stalled reviewers must be handled safely.
---

# Cursor Sub-Review

Run one Cursor reviewer at a time with `scripts/run-review.sh`. Keep business-hypothesis formation and final finding consolidation in the parent review workflow.

## Prepare the review

Write one self-contained prompt file containing:

- the confirmed business invariant and wrong-solution boundary;
- the full diff or an absolute path to a review bundle containing it;
- changed files, PR context, and relevant domain context;
- instructions to report only introduced defects with file/line evidence;
- known verification and an explicit ban on edits and git writes.

Do not ask Cursor to reconstruct a diff from current files when the distinction between introduced and pre-existing behavior matters.

## Run one reviewer

```bash
review_skill="/absolute/path/to/cursor-sub-review"
"$review_skill/scripts/run-review.sh" \
  --workspace "$PWD" \
  --prompt /absolute/path/to/review-prompt.md \
  --model kimi-k3-high
```

The runner:

- uses read-only `ask` mode;
- closes command/workspace approval paths before launch (`--force --trust`) and
  disables every effective MCP server in isolated CLI state;
- enables `stream-json` and partial output so progress is observable;
- writes JSONL, stderr, exit status, and the extracted final result to a temporary result directory;
- rejects concurrent wrapper launches to avoid the shared `~/.cursor/cli-config.json` race;
- stops after a real no-progress stall or hard timeout;
- preserves failed-run diagnostics.

Read only the reported `result` file for review findings. Do not paste reasoning JSONL into the user transcript.

## Agent surface and model names

When the parent process is running inside a Herdr-managed pane
(`HERDR_ENV=1`), prefer using Herdr for Cursor reviewers. It preserves the
persistent session and makes the agent's lifecycle and final response
inspectable.

**Spawn Herdr Cursor panes with `scripts/spawn-cursor-pane.sh`, not by hand.**

```bash
"$review_skill/scripts/spawn-cursor-pane.sh" \
  --model kimi-k3-high --plan \
  --cwd "$PWD" \
  --prompt-file /absolute/path/to/review-prompt.md \
  --result-file /absolute/path/to/result.md
```

Hand-rolled `herdr agent start … --kind cursor` is where these sessions go to
die, in three measured ways. The spawner exists because each one is silent:

1. **Wrong mode.** Without `--force` Cursor waits for approval on its first
   shell command and never proceeds. The spawner verifies the pane actually
   reached Run Everything mode — Cursor prints that in its own footer — and
   tears the pane down rather than leaving one that will stall.
2. **Prompt never sent.** `herdr agent prompt` fills Cursor's input box without
   submitting it. The pane looks healthy and is doing nothing. The spawner
   presses Enter and confirms the box drained.
3. **Pane not ready.** `herdr agent start` returns `agent_pane_busy` against a
   tab whose shell is still sourcing a profile. The spawner retries instead of
   reporting a spawn that did not happen.

## Ephemeral sessions are owned end to end

Creating an ephemeral review session makes you responsible for finishing it and
for cleaning it up. A session left composing forever, or a pane left open after
its answer was read, is the same waste as one stuck on a prompt.

The spawner defaults to that contract: submit, wait for the turn to end, write
the transcript to a result file, close the pane. `--no-wait` and `--keep` opt
out, and then the caller owns what is left behind. Exit `3` means the session
timed out and its pane is still open — drive it or close it, do not walk away.

Do not use `herdr agent wait` as the completion signal for Cursor. Herdr reports
a composing Cursor as `idle` and a finished one as `blocked`, so waiting on
agent status returns immediately and captures a half-finished transcript. The
spawner watches Cursor's footer instead (`ctrl+c to stop` present means the turn
is still running).

Sessions the spawner creates are labelled `cursor-ephemeral:<name>`, so anything
abandoned can be found and closed later:

```bash
"$review_skill/scripts/spawn-cursor-pane.sh" --sweep      # skips ones still working
```

If Herdr is unavailable or a Cursor pane is not usable, the review runner (or a
background `cursor-agent` invocation using the headless flag set below) is a
suitable fallback. Preserve the final result and diagnostics in files rather
than streaming a large reasoning transcript into the parent conversation.

## Calling Cursor headlessly

Nobody can answer a permission prompt in a scripted run, so an unclosed approval
path does not fail — it hangs until something times out. Close them all at
launch. These two shapes are the supported ways to call a Cursor subagent.

Read-only reviewer (what the runner does; use directly only when the runner does
not fit):

```bash
CURSOR_CONFIG_DIR="$HOME/.local/state/cursor-sub-review/config" \
  cursor-agent -p --mode ask --force --trust \
  --model claude-opus-5-thinking-high --output-format text \
  "Read /absolute/path/to/prompt.md and follow it exactly."
```

Unattended worker that may edit:

```bash
CURSOR_CONFIG_DIR="$HOME/.local/state/cursor-sub-review/config" \
  cursor-agent -p --force --trust \
  --model composer-2.5 --output-format text \
  --worktree cursor-task \
  "…task…"
```

| flag | why it is there |
| --- | --- |
| `-p` / `--print` | non-interactive; the only mode with no TTY UI to block on |
| `--force` (`--yolo`) | the actual dangerous-mode switch: allow commands unless explicitly denied |
| `CURSOR_CONFIG_DIR` | holds isolated disable state; the wrappers enumerate user and workspace MCP definitions and verify every effective server is disabled before launch |
| `--trust` | answers workspace trust **only** — not per-command approval |
| `--mode ask` | read-only. Omit for a working agent; keep for any review leg |
| `--worktree` | isolate edits from the parent's working tree when the agent can write |
| `--output-format` | `text` for one-shots, `stream-json` when progress must be observable |

Two traps worth naming:

- **`--trust` is not enough on its own.** It answers "do you trust this
  workspace" and nothing else. `~/.cursor/cli-config.json` pre-allows only
  `Shell(ls)`, `Shell(git -C)` and `Shell(echo)`, so without `--force` a
  reviewer blocks on its first `git diff`, `rg`, or file read.
- **`--force` removes prompting, not write access.** `--mode ask` is what keeps
  a reviewer read-only. Dropping ask mode while keeping `--force` turns a review
  leg into an unattended agent with write and shell. Both flags, every time.

Because `permissions.deny` in `~/.cursor/cli-config.json` is empty, `--force`
really does mean everything. Put a floor in `deny` rather than removing
`--force`; removing it just reintroduces the hang.

Resolve model identifiers with `cursor-agent --list-models`. “Grok” refers to
Cursor-hosted models such as `cursor-grok-4.6-high`; there is no standalone
`grok` executable to invoke. Likewise, use the exact Cursor-hosted identifier
for Kimi, Claude, or other requested models. Do not count a reviewer leg until
its complete findings have been captured; an idle or stalled pane is not a
review result.

## Model choice and retry

Resolve exact model identifiers with `cursor-agent --list-models`. Prefer the requested model and do not silently downgrade it.

If the runner exits `124`:

1. Inspect the small stderr file and the last few JSONL event types.
2. Retry the same model once if the failure looks local or transient.
3. Use another tier only when the user permits it, and report the substitution.
4. If both attempts fail, mark that review leg unavailable; never invent findings.

Run multiple Cursor opinions sequentially. Worktrees isolate repository files but do not isolate Cursor's user-level CLI configuration.

**For a whole multi-model pass, use `ctxreview` rather than driving this by hand.**
It is the tier-2 entrypoint (see `llm/AGENTS.md` → Multi-model review): it builds a
context pack, opens a dedicated Herdr review workspace, and runs four legs at once
— and it respects the
constraint above by sending **only two** legs through Cursor (`kimi-k3-high`,
`cursor-grok-4.6-high`), with Sol on the Codex CLI and Opus on the Claude CLI so
nothing contends for `~/.cursor/cli-config.json`. It calls
`scripts/spawn-cursor-pane.sh` for the Cursor legs, so the mode-verification and
prompt-submission guarantees documented here still apply.

Reach for this skill directly when you want *one* Cursor opinion, or when you are
outside Herdr and need the `-p` runner instead of a pane.

Two notes from `ctxreview`'s first live run, both relevant to callers of
`spawn-cursor-pane.sh`:

- **Pass a pointer, not a large prompt.** A 36 KB prompt through the agent input
  box tripped the "prompt may not have been submitted" warning — failure mode #2
  in the spawner's own header. Write the prompt to a file and submit two lines
  telling the agent to read it.
- **Give each leg its own pane.** Spawning a second agent into a pane that already
  owns one fails with `agent did not start in pane <id> within 60s`, which reads
  like a model problem and is not.

## Consolidate

Treat Cursor output as dissent, not authority. Verify every proposed finding against the actual diff and the confirmed business invariant. Reject style-only churn, pre-existing issues, and behavior the user explicitly chose.
