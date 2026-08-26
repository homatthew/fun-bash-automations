#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/herdr-helpers-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
LOG="$TMP/herdr.log"

cat > "$TMP/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$HERDR_TEST_LOG"
case "${1:-} ${2:-}" in
  "agent list")
    printf '%s\n' '{"result":{"agents":[
      {"name":"one","workspace_id":"w1","pane_id":"w1:p1"},
      {"name":"two","workspace_id":"w1","pane_id":"w1:p2"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[
      {"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","cwd":"/tmp","focused":true},
      {"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t1","cwd":"/tmp","focused":false}]}}'
    ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[
      {"tab_id":"w1:t1","workspace_id":"w1","focused":true},
      {"tab_id":"w1:t2","workspace_id":"w1","focused":false}]}}'
    ;;
  "pane create") printf '%s\n' '{"result":{"pane_id":"w1:p3"}}' ;;
  "agent focus"|"tab focus"|"pane label"|"pane close"|"agent start") ;;
  *) exit 2 ;;
esac
FAKE

cat > "$TMP/bin/nc" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"layout":{"root":{
  "type":"split","direction":"horizontal","ratio":0.5,
  "first":{"type":"pane","pane_id":"w1:p1"},
  "second":{"type":"pane","pane_id":"w1:p2"}}}}}'
FAKE
chmod +x "$TMP/bin/herdr" "$TMP/bin/nc"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

helpers=(
  herdr-close-pane herdr-confirm-close herdr-confirm-close-pane herdr-confirm-close-tab
  herdr-cycle-agent herdr-cycle-tab herdr-pane-snapshot herdr-reopen-pane
)
for helper in "${helpers[@]}"; do
  bash -n "$ROOT/bin/$helper" || fail "$helper does not parse"
done

export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export HERDR_BIN_PATH="$TMP/bin/herdr"
export HERDR_TEST_LOG="$LOG"
export HERDR_CLOSED_PANES_FILE="$TMP/home/state/closed-panes.jsonl"

HERDR_ACTIVE_WORKSPACE_ID=w1 HERDR_ACTIVE_PANE_ID=w1:p1 \
  "$ROOT/bin/herdr-cycle-agent" next
rg -q '^agent focus w1:p2$' "$LOG" || fail "agent cycling chose the wrong pane"

"$ROOT/bin/herdr-cycle-tab" next
rg -q '^tab focus w1:t2$' "$LOG" || fail "tab cycling chose the wrong tab"

printf '\033[C\n' | HERDR_ACTIVE_PANE_ID=w1:p1 \
  "$ROOT/bin/herdr-confirm-close" pane >/dev/null
rg -q '^pane close w1:p1$' "$LOG" \
  || fail "right arrow did not select and confirm pane close"

"$ROOT/bin/herdr-pane-snapshot" w1:p1
[ "$(mode "$(dirname "$HERDR_CLOSED_PANES_FILE")")" = 700 ] \
  || fail "snapshot directory is not private"
[ "$(mode "$HERDR_CLOSED_PANES_FILE")" = 600 ] \
  || fail "snapshot file is not private"

printf '%s\n' '{"pane_id":"old","tab_id":"w1:t1","workspace_id":"w1","cwd":"/tmp","label":"Kimi","agent":"kimi","session_kind":"id","session_value":"kimi-session","parent":{"direction":"horizontal","ratio":0.33,"side":"first","anchor":"w1:p2","exact":true}}' \
  > "$HERDR_CLOSED_PANES_FILE"
"$ROOT/bin/herdr-reopen-pane" >/dev/null
rg -q '^pane create --tab w1:t1 --direction left --percent 67 --focus --cwd /tmp --pane w1:p2$' "$LOG" \
  || fail "split reconstruction did not preserve side, ratio, and anchor"
rg -q '^agent start kimi --kind kimi --pane w1:p3 -- --yolo --session kimi-session$' "$LOG" \
  || fail "Kimi did not resume through its native session interface"

rg -q -- '--dangerously-skip-permissions' "$ROOT/bin/herdr-reopen-pane" \
  || fail "Claude bypass flag was lost"
rg -q -- '--dangerously-bypass-approvals-and-sandbox resume' "$ROOT/bin/herdr-reopen-pane" \
  || fail "Codex bypass flag was lost"

printf 'herdr helper regression: ok\n'
