#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: run-review.sh --prompt FILE --model MODEL [options]

Options:
  --workspace DIR       Repository root (default: current directory)
  --output-dir DIR      Preserve results here (default: temporary directory)
  --config-dir DIR      Isolated zero-MCP Cursor state (default: user state)
  --heartbeat-seconds N Progress heartbeat interval (default: 15)
  --stall-seconds N     Stop after no JSONL progress (default: 300)
  --timeout-seconds N   Hard runtime limit (default: 900)
EOF
}

prepare_zero_mcp() {  # prepare_zero_mcp <config-dir> <workspace>
  local cfg="$1" workspace="$2" tmp listing line id after
  mkdir -p "$cfg" 2>/dev/null || return 1
  tmp="$(mktemp "$cfg/mcp.json.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '{"mcpServers":{}}\n' > "$tmp" || ! mv "$tmp" "$cfg/mcp.json"; then
    rm -f "$tmp"
    return 1
  fi
  [[ "$(cat "$cfg/mcp.json" 2>/dev/null)" == '{"mcpServers":{}}' ]] || return 1
  listing="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$listing" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      *": disabled") continue ;;
      *:*) id="${line%%:*}" ;;
      *) return 1 ;;
    esac
    [[ -n "$id" ]] || return 1
    (cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" \
      "$cursor_cmd" mcp disable "$id" >/dev/null 2>&1) || return 1
  done <<< "$listing"
  after="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$after" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -z "$line" ]] || case "$line" in *": disabled") ;; *) return 1 ;; esac
  done <<< "$after"
}

prompt_file=""
model=""
workspace="$PWD"
output_dir=""
config_dir="${CURSOR_REVIEW_CONFIG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cursor-sub-review/config}"
heartbeat_seconds=15
stall_seconds=300
timeout_seconds=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      prompt_file="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
      shift 2
      ;;
    --config-dir)
      config_dir="${2:-}"
      shift 2
      ;;
    --heartbeat-seconds)
      heartbeat_seconds="${2:-}"
      shift 2
      ;;
    --stall-seconds)
      stall_seconds="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      timeout_seconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$prompt_file" || -z "$model" ]]; then
  usage >&2
  exit 2
fi
if [[ ! -f "$prompt_file" ]]; then
  echo "Prompt file does not exist: $prompt_file" >&2
  exit 2
fi
if [[ ! -d "$workspace" ]]; then
  echo "Workspace does not exist: $workspace" >&2
  exit 2
fi
for numeric_value in "$heartbeat_seconds" "$stall_seconds" "$timeout_seconds"; do
  if [[ ! "$numeric_value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Heartbeat, stall, and timeout values must be positive integers" >&2
    exit 2
  fi
done

cursor_cmd="$(command -v cursor-agent || true)"
if [[ -z "$cursor_cmd" ]]; then
  echo "cursor-agent is not installed" >&2
  exit 127
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to extract the final Cursor result" >&2
  exit 127
fi

lock_dir="${TMPDIR:-/tmp}/cursor-sub-review-${UID}.lock"
lock_acquired=false
if mkdir "$lock_dir" 2>/dev/null; then
  lock_acquired=true
else
  lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
      lock_acquired=true
    fi
  fi
fi
if [[ "$lock_acquired" != true ]]; then
  echo "Another cursor-sub-review is active; run Cursor reviewers sequentially" >&2
  exit 75
fi
printf '%s\n' "$$" > "$lock_dir/pid"

child_pid=""
cleanup() {
  if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -INT "$child_pid" 2>/dev/null || true
    sleep 1
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! "$cursor_cmd" --list-models | awk '{print $1}' | grep -Fxq "$model"; then
  echo "Cursor model is unavailable: $model" >&2
  exit 2
fi

if [[ -z "$output_dir" ]]; then
  output_dir="$(mktemp -d -t cursor-sub-review)"
else
  mkdir -p "$output_dir"
fi

jsonl_file="$output_dir/cursor.jsonl"
stderr_file="$output_dir/cursor.err"
result_file="$output_dir/cursor.result.md"
rc_file="$output_dir/cursor.rc"

absolute_prompt="$(cd "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")"
instruction="Read the complete review instructions and context from $absolute_prompt. Follow them exactly. This is a read-only review: do not edit files or perform git writes."
if ! prepare_zero_mcp "$config_dir" "$workspace"; then
  echo "Could not verify zero effective Cursor MCP servers" >&2
  exit 2
fi

# Headless means nobody can answer a permission prompt, so every approval path
# has to be closed before launch or the reviewer stalls until --stall-seconds
# fires and the leg is lost.
#
#   --force        allow commands unless explicitly denied. `~/.cursor/cli-config.json`
#                  pre-allows only Shell(ls), Shell(git -C) and Shell(echo), so
#                  without this a reviewer blocks on its first `git diff`, `rg`, or
#                  file read. --trust alone does NOT cover this: it only answers
#                  "do you trust this workspace", not per-command approval.
#   CURSOR_CONFIG_DIR holds isolated disable state for every effective workspace
#                  and user MCP server, verified before launch.
#   --mode ask     read-only. This, not the absence of --force, is what keeps the
#                  reviewer from editing: --force removes PROMPTING, ask mode
#                  removes WRITE ACCESS. Keep both -- dropping ask mode turns a
#                  review leg into an unattended agent with write and shell.
(
  cd "$workspace" || exit 2
  CURSOR_CONFIG_DIR="$config_dir" "$cursor_cmd" -p \
    --mode ask \
    --model "$model" \
    --force \
    --trust \
    --output-format stream-json \
    --stream-partial-output \
    "$instruction"
) >"$jsonl_file" 2>"$stderr_file" &
child_pid=$!

start_seconds=$SECONDS
last_progress_seconds=$SECONDS
last_bytes=0
runner_rc=0

while kill -0 "$child_pid" 2>/dev/null; do
  sleep "$heartbeat_seconds"
  current_bytes="$(wc -c < "$jsonl_file" 2>/dev/null || echo 0)"
  if [[ "$current_bytes" -gt "$last_bytes" ]]; then
    last_bytes="$current_bytes"
    last_progress_seconds=$SECONDS
  fi

  elapsed_seconds=$((SECONDS - start_seconds))
  quiet_seconds=$((SECONDS - last_progress_seconds))
  echo "Cursor reviewer heartbeat; model=$model bytes=$current_bytes elapsed=${elapsed_seconds}s quiet=${quiet_seconds}s" >&2

  if [[ "$quiet_seconds" -ge "$stall_seconds" ]]; then
    echo "Cursor reviewer stalled: no JSONL progress for ${quiet_seconds}s" >&2
    runner_rc=124
    kill -INT "$child_pid" 2>/dev/null || true
    sleep 1
    kill -TERM "$child_pid" 2>/dev/null || true
    break
  fi
  if [[ "$elapsed_seconds" -ge "$timeout_seconds" ]]; then
    echo "Cursor reviewer exceeded hard timeout of ${timeout_seconds}s" >&2
    runner_rc=124
    kill -INT "$child_pid" 2>/dev/null || true
    sleep 1
    kill -TERM "$child_pid" 2>/dev/null || true
    break
  fi
done

wait "$child_pid" 2>/dev/null
child_rc=$?
child_pid=""
if [[ "$runner_rc" -eq 0 ]]; then
  runner_rc=$child_rc
fi

jq -rs '[.[] | select(.type == "result") | .result // empty] | last // empty' \
  "$jsonl_file" > "$result_file" || true
printf '%s\n' "$runner_rc" > "$rc_file"

echo "review_dir=$output_dir"
echo "result=$result_file"
echo "stderr=$stderr_file"
echo "rc=$runner_rc"

if [[ "$runner_rc" -ne 0 ]]; then
  tail -40 "$stderr_file" >&2 || true
  exit "$runner_rc"
fi
if [[ ! -s "$result_file" ]]; then
  echo "Cursor reviewer produced no final result" >&2
  tail -40 "$stderr_file" >&2 || true
  exit 1
fi
