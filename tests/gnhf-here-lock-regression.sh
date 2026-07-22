#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-gnhf-lock-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/npm/bin" "$TMP/home/.gnhf" "$TMP/one" "$TMP/two"
printf 'base: original\n' > "$TMP/home/.gnhf/config.yml"
printf 'run: one\n' > "$TMP/one/.gnhf.yml"
printf 'run: two\n' > "$TMP/two/.gnhf.yml"

cat > "$TMP/bin/node" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 4 ]; then
  [[ -z "${EXPECT_GNHF_REAL:-}" || "$3" == "$EXPECT_GNHF_REAL" ]] || exit 42
  printf '%s\n' '---FLAGS---' '---CONFIG---'
  cat "$4"
  exit 0
fi
printf '%s\n' "$5" > "$4"
SH
chmod +x "$TMP/bin/node"

cat > "$TMP/bin/gnhf" <<'SH'
#!/usr/bin/env bash
value=$(cat "$HOME/.gnhf/config.yml")
printf 'start:%s\n' "$value" >> "$GNHF_TEST_LOG"
[[ -z "${GNHF_TEST_STARTED:-}" ]] || : > "$GNHF_TEST_STARTED"
[[ -z "${GNHF_TEST_CHILD_PID:-}" ]] || printf '%s\n' "$$" > "$GNHF_TEST_CHILD_PID"
sleep "${GNHF_TEST_SLEEP:-0.2}"
printf 'end:%s\n' "$(cat "$HOME/.gnhf/config.yml")" >> "$GNHF_TEST_LOG"
SH
chmod +x "$TMP/bin/gnhf"
ln -s ../../bin/gnhf "$TMP/npm/bin/gnhf"
GNHF_TARGET_REAL="$(cd -P "$TMP/bin" && pwd)/gnhf"

run_one() {
  (
    cd "$1"
    HOME="$TMP/home" NODE_BIN="$TMP/bin/node" GNHF_BIN="$TMP/npm/bin/gnhf" \
      EXPECT_GNHF_REAL="$GNHF_TARGET_REAL" \
      GNHF_TEST_LOG="$TMP/runs.log" "$ROOT/bin/gnhf-here" >/dev/null 2>&1
  )
}

run_one "$TMP/one" &
pid_one=$!
run_one "$TMP/two" &
pid_two=$!
wait "$pid_one"
wait "$pid_two"

[[ "$(cat "$TMP/home/.gnhf/config.yml")" == 'base: original' ]] ||
  fail "global config was not restored"
python3 - "$TMP/runs.log" <<'PY' || fail "concurrent runs observed overlapping config"
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
if len(lines) != 4:
    raise SystemExit(1)
for start, end in (lines[:2], lines[2:]):
    if not start.startswith("start:run: ") or end != start.replace("start:", "end:", 1):
        raise SystemExit(1)
if lines[0] == lines[2]:
    raise SystemExit(1)
PY

: > "$TMP/runs.log"
(
  cd "$TMP/one"
  exec env HOME="$TMP/home" NODE_BIN="$TMP/bin/node" GNHF_BIN="$TMP/npm/bin/gnhf" \
    EXPECT_GNHF_REAL="$GNHF_TARGET_REAL" \
    GNHF_TEST_LOG="$TMP/runs.log" GNHF_TEST_SLEEP=30 \
    GNHF_TEST_STARTED="$TMP/started" GNHF_TEST_CHILD_PID="$TMP/child-pid" \
    "$ROOT/bin/gnhf-here"
) >/dev/null 2>&1 &
crashed_pid=$!
for _ in {1..100}; do
  [[ -f "$TMP/started" && -f "$TMP/child-pid" ]] && break
  sleep 0.02
done
[[ -f "$TMP/started" && -f "$TMP/child-pid" ]] || fail "crash fixture did not start"
kill -9 "$crashed_pid"
kill -9 "$(cat "$TMP/child-pid")" 2>/dev/null || true
wait "$crashed_pid" 2>/dev/null || true

run_one "$TMP/two" &
recover_one=$!
run_one "$TMP/one" &
recover_two=$!
wait "$recover_one"
wait "$recover_two"
[[ "$(cat "$TMP/home/.gnhf/config.yml")" == 'base: original' ]] ||
  fail "stale-lock recovery did not restore the pre-crash config"
python3 - "$TMP/runs.log" <<'PY' || fail "concurrent stale-lock recovery overlapped configs"
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()[-4:]
if len(lines) != 4:
    raise SystemExit(1)
for start, end in (lines[:2], lines[2:]):
    if not start.startswith("start:run: ") or end != start.replace("start:", "end:", 1):
        raise SystemExit(1)
PY

echo "gnhf lock regression passed"
