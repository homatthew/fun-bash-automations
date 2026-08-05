#!/usr/bin/env bash

# PreToolUse hook on Bash: stops Cursor subagents being launched in a mode that
# will stall on a permission prompt nobody is watching.
#
# Docs did not fix this. An agent spawning a Cursor pane writes
# `herdr agent start review --kind cursor --pane w1:pX` or plain `cursor-agent
# --model X`, Cursor comes up interactive, asks to approve its first shell
# command, and the pane sits there until a human notices. `~/.cursor/cli-config.json`
# pre-allows only Shell(ls), Shell(git -C) and Shell(echo), so the first `git diff`
# is enough to trigger it. Nothing errors, so nothing reports.
#
# The guard denies the launch and names the fix. It only ever refuses to START a
# Cursor agent; it never touches an already-running one, and read-only
# subcommands (--list-models, --help, status, mcp list) pass through.
#
# Deliberately separate from bash-safety-guard.sh: that file is a hard safety
# control and this is an ergonomics gate. Keeping them apart means a change here
# can never weaken a push or destructive-command rule.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  # Fail open: a missing jq must not block every Bash call in the session.
  exit 0
fi

payload="$(cat)"
command_string="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null)"
[[ -n "$command_string" ]] || exit 0

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# Read-only Cursor calls never prompt, so never block them.
if grep -qE '(^|[[:space:];&|])cursor-agent[[:space:]]+(--list-models|--version|-v|--help|-h|status|whoami|about|models|mcp|plugin|login|logout)([[:space:]]|$)' <<<"$command_string"; then
  exit 0
fi

# Command position only. A bare space before the word is not enough: `echo
# cursor-agent …` or `grep cursor-agent …` passes the name as an argument and
# must not be blocked. Require the start of the string or a shell separator,
# allowing leading environment assignments.
cmd_start='(^|[;&|(]|&&|\|\|)[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'

launches_cursor=false
# Direct CLI launch: `cursor-agent …` as the command being run.
if grep -qE "${cmd_start}cursor-agent([[:space:]]|$)" <<<"$command_string"; then
  launches_cursor=true
fi
# Herdr pane launch: `herdr agent start … --kind cursor`.
if grep -qE "${cmd_start}herdr[[:space:]]+agent[[:space:]]+start" <<<"$command_string" &&
   grep -qE -- '--kind[[:space:]=]+cursor([[:space:]]|$)' <<<"$command_string"; then
  launches_cursor=true
fi

$launches_cursor || exit 0

# --force / --yolo is the flag that removes per-command approval. --trust only
# answers workspace trust and is not a substitute.
if grep -qE -- '(^|[[:space:]])(-f|--force|--yolo)([[:space:]]|$)' <<<"$command_string"; then
  exit 0
fi

deny "Blocked: this starts a Cursor agent without --force, so it will stop at its first permission prompt with nobody to answer it (only Shell(ls), Shell(git -C) and Shell(echo) are pre-allowed).

Use the spawner, which sets the flags and verifies the pane actually reached Run Everything mode:
  \$cursor-sub-review/scripts/spawn-cursor-pane.sh --model MODEL --prompt 'TASK' [--plan]

Or pass the flags yourself:
  herdr agent start NAME --kind cursor --pane PANE -- --force --approve-mcps --trust --model MODEL
  cursor-agent -p --mode ask --force --approve-mcps --trust --model MODEL 'PROMPT'

Keep --mode ask (or --plan) for review legs: --force removes prompting, ask mode removes write access."
