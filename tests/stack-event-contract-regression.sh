#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/llm/hooks/push-gate.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected [$needle] in: $haystack"
}

echo "1..2"

for event_type in stack_manifest_changed materialized prepare_context_written prepare_trunk_written trunk_approved lease_changed push_plan_changed; do
  event_json=$(bash "$HELPER" stack-event-contract \
    --type "$event_type" \
    --stack demo \
    --repo-key /repo/.git \
    --repo-root /repo \
    --materialization-id mat-1 \
    --manifest-hash hash-1 \
    --trunk-tip tip-1 \
    --sequence 7 \
    --created-at 2026-05-20T00:00:00Z \
    --changed-surface materialization)
  [[ "$(jq -r '.schema_version' <<<"$event_json")" == "1" ]] \
    || fail "expected stack event schema_version 1: $event_json"
  [[ "$(jq -r '.event_type' <<<"$event_json")" == "$event_type" ]] \
    || fail "expected event type $event_type: $event_json"
  [[ "$(jq -r '.cache_key.repo_key' <<<"$event_json")" == "/repo/.git" ]] \
    || fail "expected event cache key repo: $event_json"
  [[ "$(jq -r '.cache_key.stack_name' <<<"$event_json")" == "demo" ]] \
    || fail "expected event cache key stack demo: $event_json"
  [[ "$(jq -r '.materialization_key.manifest_hash' <<<"$event_json")" == "hash-1" ]] \
    || fail "expected materialization key manifest hash: $event_json"
  [[ "$(jq -r '.sequence' <<<"$event_json")" == "7" ]] \
    || fail "expected event sequence 7: $event_json"
done
echo "ok 1 - stack event contract exposes exact cache invalidation keys"

set +e
bad_event_output=$(bash "$HELPER" stack-event-contract \
  --type unknown \
  --stack demo \
  --repo-key /repo/.git \
  --repo-root /repo \
  --materialization-id mat-1 \
  --manifest-hash hash-1 \
  --trunk-tip tip-1 \
  --changed-surface materialization 2>&1)
bad_event_rc=$?
set -e
[[ "$bad_event_rc" != "0" ]] || fail "expected unknown stack event type to fail"
expect_contains "$bad_event_output" "known --type"
echo "ok 2 - stack event contract rejects unknown event types"
