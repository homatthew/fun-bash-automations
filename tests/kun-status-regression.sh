#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-kun-status-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [[ "${KUN_TREEHOUSE_CASE:-}" == "quoting" ]]; then
  printf '%s\n' 'true' '05' 'name: value' 'path\segment' 'value{nested}' '-item' 'quote:"value'
  printf 'tab:\tvalue\ncontrol:\001value\n'
  exit 0
fi
echo "transport failed while reading pool" >&2
exit 7
SH
cat > "$TMP/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
echo "database failed while reading gate" >&2
exit 9
SH
chmod +x "$TMP/bin/treehouse" "$TMP/bin/no-mistakes"

cat > "$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == --session ]]; then
  session="$2"; shift 2
fi
case "$1 $2" in
  "session list") printf '%s\n' '{"sessions":[{"name":"ctxreview-fixture","running":true}]}' ;;
  "agent list") printf '%s\n' '{"result":{"agents":[{"name":"ctxreview-sol-w1p1","agent_status":"working"}]}}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP/bin/herdr"

pool_out="$(PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" --pool 2>"$TMP/pool.err")" ||
  fail "kun-status pool probe crashed"
[[ "$pool_out" == *$'status: unavailable'* ]] ||
  fail "nonzero treehouse output was treated as an active pool: $pool_out"
grep -Fq "transport failed while reading pool" "$TMP/pool.err" ||
  fail "treehouse failure diagnostics were discarded"

quoted_pool_out="$(KUN_TREEHOUSE_CASE=quoting PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" --pool 2>"$TMP/quoted-pool.err")" ||
  fail "kun-status quoting probe crashed"
for expected in \
  '  "true"' \
  '  "05"' \
  '  "name: value"' \
  '  "path\\segment"' \
  '  "value{nested}"' \
  '  "-item"' \
  '  "quote:\"value"' \
  '  "tab:\tvalue"' \
  '  "control:\u0001value"'; do
  grep -Fq "$expected" <<<"$quoted_pool_out" ||
    fail "TOON value was not quoted or escaped correctly: $expected in $quoted_pool_out"
done

gate_out="$(PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" --gate 2>"$TMP/gate.err")" ||
  fail "kun-status gate probe crashed"
[[ "$gate_out" == *$'status: unavailable'* ]] ||
  fail "nonzero no-mistakes output was treated as reported gate state: $gate_out"
grep -Fq "database failed while reading gate" "$TMP/gate.err" ||
  fail "no-mistakes failure diagnostics were discarded"

status_file="$TMP/status.toon"
PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" --pool > "$status_file" 2> "$TMP/status.err" ||
  fail "kun-status file output crashed"
grep -Fq 'description: "One-glance Kun stack state (pool, gate, crew, wake, review) as TOON."' "$status_file" ||
  fail "fixed description scalar was not TOON-encoded"
python3 - "$status_file" <<'PY' || fail "kun-status output ended with a line terminator"
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
raise SystemExit(0 if data and not data.endswith((b"\n", b"\r")) else 1)
PY

set +e
PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" --unknown > "$TMP/usage.toon" 2> "$TMP/usage.err"
usage_rc=$?
set -e
[[ "$usage_rc" -eq 2 ]] || fail "kun-status usage error returned $usage_rc instead of 2"
grep -Fq 'error: "unknown flag: --unknown"' "$TMP/usage.toon" ||
  fail "usage error scalar was not TOON-encoded"
grep -Fq 'help: "kun-status [--pool] [--gate] [--crew] [--wake] [--review] | --help"' "$TMP/usage.toon" ||
  fail "usage help scalar was not TOON-encoded"
python3 - "$TMP/usage.toon" <<'PY' || fail "kun-status usage output ended with a line terminator"
import pathlib
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
raise SystemExit(0 if data and not data.endswith((b"\n", b"\r")) else 1)
PY

set +e
PATH="$TMP/bin:/usr/bin:/bin" "$ROOT/bin/kun-status" -- unexpected > "$TMP/double-dash.toon" 2> "$TMP/double-dash.err"
double_dash_rc=$?
set -e
[[ "$double_dash_rc" -eq 2 ]] || fail "kun-status accepted an operand after --"
grep -Fq 'error: "unexpected argument: unexpected"' "$TMP/double-dash.toon" ||
  fail "operand after -- did not produce a structured usage error"

mkdir -p "$TMP/review-state/runs"
jq -n '{run_id:"review-fixture",owner_session:"owner",status:"open",
  herdr_session_name:"ctxreview-fixture",label:"review: fixture",
  legs:{sol:{agent_name:"ctxreview-sol-w1p1"}}}' \
  > "$TMP/review-state/runs/review-fixture.json"
review_out="$(CTXREVIEW_SESSION_STATE_DIR="$TMP/review-state" \
  PATH="$TMP/bin:$PATH" "$ROOT/bin/kun-status" --review 2>"$TMP/review.err")" ||
  fail "kun-status named review probe crashed"
for expected in \
  'status: working' \
  'running_sessions: 1' \
  'ctxreview-fixture' \
  'strategy: named_herdr_session_socket' \
  'default_session_mutations: 0'; do
  grep -Fq "$expected" <<<"$review_out" ||
    fail "named review status omitted: $expected in $review_out"
done

echo "kun status regression passed"
