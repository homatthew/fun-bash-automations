#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$ROOT/llm/hooks/notify-dispatch.sh"
TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d -t fba-notify-dispatch-metrics)"
FAKE_BIN="$WORKDIR/bin"
METRICS_DEFAULT="$WORKDIR/metrics-default.jsonl"
METRICS_SYNC="$WORKDIR/metrics-sync.jsonl"
METRICS_ASYNC="$WORKDIR/metrics-async.jsonl"
FOCUS_REQUESTS="$WORKDIR/focus-requests"
LOG="$WORKDIR/notify.log"
SPEC_DEFAULT="$WORKDIR/spec-default.json"
SPEC_SYNC="$WORKDIR/spec-sync.json"
SPEC_ASYNC="$WORKDIR/spec-async.json"
CALLS_DEFAULT="$WORKDIR/calls-default.log"
CALLS_SYNC="$WORKDIR/calls-sync.log"
CALLS_ASYNC="$WORKDIR/calls-async.log"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/alerter" <<'SH'
#!/usr/bin/env bash
printf 'alerter %s\n' "$*" >> "$NOTIFY_TEST_CALLS"
printf '{"activationType":"actionClicked"}\n'
SH
chmod +x "$FAKE_BIN/alerter"

cat > "$FAKE_BIN/open" <<'SH'
#!/usr/bin/env bash
printf 'open %s\n' "$*" >> "$NOTIFY_TEST_CALLS"
SH
chmod +x "$FAKE_BIN/open"

cat > "$FAKE_BIN/osascript" <<'SH'
#!/usr/bin/env bash
printf 'osascript %s\n' "$*" >> "$NOTIFY_TEST_CALLS"
SH
chmod +x "$FAKE_BIN/osascript"

write_spec() {
  local spec="$1" state_id="$2"
  jq -n \
  --arg title "fun-bash-automations" \
  --arg subtitle "Test" \
  --arg message "Click metrics" \
  --arg group "codex-fun-bash-automations-test" \
  --arg open_url "vscode://homatthew.vscode-terminal-osc-notifier/focus?cwd=/tmp&event=done" \
  --arg cwd "$WORKDIR" \
  --arg log "$LOG" \
  --arg state_id "$state_id" \
  '{
    title:$title,
    subtitle:$subtitle,
    message:$message,
    group:$group,
    sender:"",
    open_url:$open_url,
    style:"alert",
    action_label:"Show",
    sound:"Pop",
    cwd:$cwd,
    log:$log,
    state_file:"",
    state_id:$state_id,
    sticky_after_click:"0"
  }' > "$spec"
}

write_spec "$SPEC_DEFAULT" "final:test-default"

PATH="$FAKE_BIN:$PATH" \
  NOTIFY_PATH_PREFIX="$FAKE_BIN" \
  NOTIFY_METRICS_LOG="$METRICS_DEFAULT" \
  NOTIFY_TEST_CALLS="$CALLS_DEFAULT" \
  NOTIFY_VSCODE_RECOVERY=0 \
  bash "$DISPATCH" "$SPEC_DEFAULT"

[[ -s "$METRICS_DEFAULT" ]] || fail "expected default metrics log"
[[ -s "$CALLS_DEFAULT" ]] || fail "expected default open call"
grep -q -- 'alerter .*--timeout 14400' "$CALLS_DEFAULT" || fail "expected default bounded alert timeout: $(cat "$CALLS_DEFAULT")"

jq -e '
  .event == "notification_click_open"
  and .source == "dispatch"
  and .action == "Show"
  and .activation == "actionClicked"
  and .open_url_scheme == "vscode"
  and .vscode_recovery_enabled == false
  and .folder_open_done_ms == null
  and .second_open_done_ms == null
  and (.notification_to_click_ms | type == "number")
  and (.click_to_open_done_ms | type == "number")
' "$METRICS_DEFAULT" >/dev/null || fail "default metrics payload missing expected fields: $(cat "$METRICS_DEFAULT")"

grep -q '^open vscode://' "$CALLS_DEFAULT" || fail "expected default open vscode call"
if grep -q '^-b com.microsoft.VSCode' "$CALLS_DEFAULT"; then
  fail "disabled recovery path should not open VS Code bundle: $(cat "$CALLS_DEFAULT")"
fi

echo "ok 1 - notification click writes vscode open timing metrics without code recovery"

write_spec "$SPEC_SYNC" "final:test-sync-recovery"

PATH="$FAKE_BIN:$PATH" \
  NOTIFY_PATH_PREFIX="$FAKE_BIN" \
  NOTIFY_METRICS_LOG="$METRICS_SYNC" \
  NOTIFY_VSCODE_FOCUS_REQUEST_DIR="$FOCUS_REQUESTS" \
  NOTIFY_TEST_CALLS="$CALLS_SYNC" \
  bash "$DISPATCH" "$SPEC_SYNC"

[[ -s "$METRICS_SYNC" ]] || fail "expected sync recovery metrics log"
[[ -s "$CALLS_SYNC" ]] || fail "expected sync recovery open/code calls"

jq -e '
  .event == "notification_click_open"
  and .source == "dispatch"
  and .vscode_recovery_enabled == true
  and .vscode_recovery_mode == "folder-first"
  and (.folder_open_started_ms | type == "number")
  and (.folder_open_done_ms | type == "number")
  and (.folder_open_duration_ms | type == "number")
  and (.activate_started_ms | type == "number")
  and (.activate_done_ms | type == "number")
  and (.app_activate_duration_ms | type == "number")
  and (.sleep_duration_ms | type == "number")
  and (.second_open_done_ms | type == "number")
' "$METRICS_SYNC" >/dev/null || fail "sync recovery metrics payload missing expected fields: $(cat "$METRICS_SYNC")"

grep -q '^open -b com.microsoft.VSCode ' "$CALLS_SYNC" || fail "expected sync recovery VS Code bundle open call"
grep -q '^osascript .*com.microsoft.VSCode' "$CALLS_SYNC" || fail "expected sync recovery app activation call"
grep -q '^open vscode://' "$CALLS_SYNC" || fail "expected sync recovery open vscode call"
first_sync_call="$(grep '^open ' "$CALLS_SYNC" | head -n 1)"
[[ "$first_sync_call" == open\ -b\ com.microsoft.VSCode* ]] || fail "expected folder-first recovery to open VS Code workspace first: $(cat "$CALLS_SYNC")"
find "$FOCUS_REQUESTS" -name '*.json' -print -quit | grep -q . || fail "expected folder-first recovery to write focus request"

echo "ok 2 - default folder-first vscode recovery records folder-open and second-open timing metrics"

write_spec "$SPEC_ASYNC" "final:test-async-recovery"

PATH="$FAKE_BIN:$PATH" \
  NOTIFY_PATH_PREFIX="$FAKE_BIN" \
  NOTIFY_METRICS_LOG="$METRICS_ASYNC" \
  NOTIFY_VSCODE_FOCUS_REQUEST_DIR="$FOCUS_REQUESTS" \
  NOTIFY_TEST_CALLS="$CALLS_ASYNC" \
  NOTIFY_VSCODE_RECOVERY=async \
  bash "$DISPATCH" "$SPEC_ASYNC"

for _ in {1..20}; do
  jq -e 'select(.event == "notification_vscode_recovery")' "$METRICS_ASYNC" >/dev/null 2>&1 && break
  sleep 0.1
done

[[ -s "$METRICS_ASYNC" ]] || fail "expected async recovery metrics log"
[[ -s "$CALLS_ASYNC" ]] || fail "expected async recovery open/code calls"

jq -s -e '
  any(.[]; .event == "notification_click_open"
    and .source == "dispatch"
    and .vscode_recovery_enabled == true)
' "$METRICS_ASYNC" >/dev/null || fail "async click metrics payload missing expected fields: $(cat "$METRICS_ASYNC")"

jq -s -e '
  any(.[]; .event == "notification_vscode_recovery"
    and .source == "dispatch"
    and .vscode_recovery_enabled == true
    and .vscode_recovery_mode == "async"
    and (.folder_open_started_ms | type == "number")
    and (.folder_open_done_ms | type == "number")
    and (.folder_open_duration_ms | type == "number")
    and (.activate_started_ms | type == "number")
    and (.activate_done_ms | type == "number")
    and (.app_activate_duration_ms | type == "number")
    and (.sleep_duration_ms | type == "number")
    and (.second_open_done_ms | type == "number"))
' "$METRICS_ASYNC" >/dev/null || fail "async recovery metrics payload missing expected fields: $(cat "$METRICS_ASYNC")"

grep -q '^open vscode://' "$CALLS_ASYNC" || fail "expected async recovery open vscode call"
grep -q '^open -b com.microsoft.VSCode ' "$CALLS_ASYNC" || fail "expected async recovery VS Code bundle open call"
grep -q '^osascript .*com.microsoft.VSCode' "$CALLS_ASYNC" || fail "expected async recovery app activation call"

echo "ok 3 - explicit async vscode recovery records folder-open and second-open timing metrics"
