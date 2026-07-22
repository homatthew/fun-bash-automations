#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/llm/hooks/notify-slack.sh"
TMPDIR="${TMPDIR:-/tmp}"
WORKSPACE="$TMPDIR/fba-notify-slack-regression-workspace"
FAKE_BIN="$TMPDIR/fba-notify-slack-regression-bin"

cleanup() {
  rm -rf "$WORKSPACE" "$FAKE_BIN"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain [$needle], got: $haystack"
}

assert_empty() {
  local value="$1"
  [[ -z "$value" ]] || fail "expected empty output, got: $value"
}

notification_group() {
  local out="$1"
  printf '%s' "$out" | sed -n -E 's/.* group=([^ ]+) open=.*/\1/p' | tail -n 1
}

run_notify_slack() {
  local payload="$1"
  PATH="$FAKE_BIN:$PATH" \
    NOTIFY_SLACK_DRY_RUN=1 \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_SLACK_TOKEN_KEYCHAIN_SERVICE=token-service \
    NOTIFY_SLACK_CHANNEL_KEYCHAIN_SERVICE=channel-service \
    NOTIFY_SLACK_USER_KEYCHAIN_SERVICE=user-service \
    bash "$HOOK" <<<"$payload" 2>&1
}

cleanup
mkdir -p "$WORKSPACE" "$FAKE_BIN"
git -C "$WORKSPACE" init -q

cat > "$FAKE_BIN/security" <<'SH'
#!/usr/bin/env bash
service=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -s) service="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
case "$service" in
  token-service) printf '%s%s' 'xoxb-' 'fake-token' ;;
  channel-service) printf 'CFAKECHAN' ;;
  user-service) printf 'UFAKEUSER' ;;
  *) exit 44 ;;
esac
SH
chmod +x "$FAKE_BIN/security"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Notification",
  session_id: "normal-claude",
  cwd: $cwd,
  title: "Needs input",
  message: "Claude needs your attention"
}')"

out="$(run_notify_slack "$payload")"
assert_contains "$out" "macos backend="
assert_contains "$out" '"channel": "CFAKECHAN"'
assert_contains "$out" "Claude needs your attention"
assert_contains "$(notification_group "$out")" "claude-$(basename "$WORKSPACE")-session_normal-claude"
echo "ok 1 - normal Claude notification reaches Slack dry-run"

payload_b="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Notification",
  session_id: "other-claude",
  cwd: $cwd,
  title: "Needs input",
  message: "Claude needs your attention"
}')"
out_b="$(run_notify_slack "$payload_b")"
[[ "$(notification_group "$out")" != "$(notification_group "$out_b")" ]] || fail "expected Slack macOS groups to differ by session"
echo "ok 1b - Slack macOS fallback groups are session scoped"
