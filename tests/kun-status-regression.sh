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

echo "kun status regression passed"
