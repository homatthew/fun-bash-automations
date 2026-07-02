#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/llm/hooks/dgw-write-guard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain [$needle], got: $haystack"
  fi
}

run_guard() {
  local command="$1"
  jq -n --arg command "$command" '{tool_input:{command:$command}}' | bash "$GUARD"
}

echo "1..12"

prod_delete_block=$(run_guard "dgw-cli kv -e prod -s shard delete ns id key")
expect_contains "$prod_delete_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 1 - prod delete is blocked without same-command authorization"

prod_delete_allow=$(run_guard "DGW_PROD_WRITE_AUTHORIZED=1 dgw-cli kv -e prod -s shard delete ns id key")
[[ -z "$prod_delete_allow" ]] || fail "expected authorized prod delete to be allowed, got: $prod_delete_allow"
echo "ok 2 - prod delete is allowed with matching same-command authorization"

prior_segment_flag_block=$(run_guard "echo DGW_PROD_WRITE_AUTHORIZED=1; dgw-cli kv -e prod -s shard delete ns id key")
expect_contains "$prior_segment_flag_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 3 - prior segment text does not authorize prod delete"

test_wrong_flag_block=$(run_guard "DGW_PROD_WRITE_AUTHORIZED=1 dgw-cli kv -e test -s shard put ns id key --data /tmp/value")
expect_contains "$test_wrong_flag_block" "DGW_TEST_WRITE_AUTHORIZED=1"
echo "ok 4 - wrong environment authorization flag is blocked"

test_put_allow=$(run_guard "DGW_TEST_WRITE_AUTHORIZED=1 dgw-cli kv -e test -s shard put ns id key --data /tmp/value")
[[ -z "$test_put_allow" ]] || fail "expected authorized test put to be allowed, got: $test_put_allow"
echo "ok 5 - test put is allowed with matching same-command authorization"

env_equals_block=$(run_guard "dgw-cli kv --env=prod -s shard put ns id key --data /tmp/value")
expect_contains "$env_equals_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 6 - --env=prod put is blocked without authorization"

read_allow=$(run_guard "dgw-cli kv -e prod -s shard get ns id key")
[[ -z "$read_allow" ]] || fail "expected read-only get to be allowed, got: $read_allow"
echo "ok 7 - read-only dgw-cli kv get is allowed"

chained_good_then_bad_block=$(run_guard "DGW_PROD_WRITE_AUTHORIZED=1 dgw-cli kv -e prod -s shard delete ns id key; dgw-cli kv -e prod -s shard delete ns id key2")
expect_contains "$chained_good_then_bad_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 8 - authorization does not leak across chained dgw-cli writes"

wrapped_prod_delete_block=$(run_guard "env dgw-cli kv -e prod -s shard delete ns id key")
expect_contains "$wrapped_prod_delete_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 9 - env-wrapped prod delete is blocked without authorization"

wrapped_command_delete_block=$(run_guard "command dgw-cli kv -e prod -s shard delete ns id key")
expect_contains "$wrapped_command_delete_block" "DGW_PROD_WRITE_AUTHORIZED=1"
echo "ok 10 - command-wrapped prod delete is blocked without authorization"

wrapped_prod_delete_allow=$(run_guard "env DGW_PROD_WRITE_AUTHORIZED=1 dgw-cli kv -e prod -s shard delete ns id key")
[[ -z "$wrapped_prod_delete_allow" ]] || fail "expected authorized env-wrapped prod delete to be allowed, got: $wrapped_prod_delete_allow"
echo "ok 11 - env-wrapped prod delete is allowed with authorization"

wrapped_read_allow=$(run_guard "command dgw-cli kv -e prod -s shard get ns id key")
[[ -z "$wrapped_read_allow" ]] || fail "expected command-wrapped read-only get to be allowed, got: $wrapped_read_allow"
echo "ok 12 - command-wrapped read-only dgw-cli kv get is allowed"
