#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STACK="$ROOT/llm/hooks/stack.sh"
PG="$ROOT/llm/hooks/push-gate.sh"

if ! command -v dolt >/dev/null 2>&1; then
  echo "1..0 # SKIP dolt not installed"
  exit 0
fi
REAL_DOLT=$(command -v dolt)

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stack-dolt-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export PG_STORE_DIR="$TEST_TMP/dolt-store"
export PG_EVENTS_DIR="$TEST_TMP/events"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected [$needle] in: $haystack"
}

expect_no_trailing_whitespace() {
  local file="$1" matches
  matches=$(grep -nE '[[:blank:]]$' "$file" || true)
  [[ -z "$matches" ]] || fail "expected no trailing whitespace in $file: $matches"
}

event_count() {
  [[ -d "$PG_EVENTS_DIR" ]] || { printf '0\n'; return 0; }
  find "$PG_EVENTS_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

last_event() {
  find "$PG_EVENTS_DIR" -type f -name '*.json' 2>/dev/null | sort | tail -1 | xargs cat
}

expect_event() {
  local before="$1" event_type="$2" changed_surface="$3"
  local after event_json
  after=$(event_count)
  [[ "$after" == "$((before + 1))" ]] || fail "expected one new $event_type event, count $before -> $after"
  event_json=$(last_event)
  [[ "$(jq -r '.event_type' <<<"$event_json")" == "$event_type" ]] \
    || fail "expected last event type $event_type: $event_json"
  [[ "$(jq -r '.changed_surface' <<<"$event_json")" == "$changed_surface" ]] \
    || fail "expected last event surface $changed_surface: $event_json"
  [[ "$(jq -r '.cache_key.stack_name' <<<"$event_json")" == "demo" ]] \
    || fail "expected last event cache key stack demo: $event_json"
}

sql_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

git_commit() {
  GIT_AUTHOR_NAME=Test \
  GIT_AUTHOR_EMAIL=test@example.com \
  GIT_COMMITTER_NAME=Test \
  GIT_COMMITTER_EMAIL=test@example.com \
    git commit -m "$1" >/dev/null
}

echo "1..1"

REPO="$TEST_TMP/repo-$$"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -b main >/dev/null

  printf 'base\n' >README.md
  git add README.md
  git_commit "base"
  git update-ref refs/remotes/origin/main main

  git checkout -b mho/feature-base --no-track >/dev/null 2>&1
  printf 'feature base\n' >base.txt
  git add base.txt
  git_commit "feature base"

  git checkout -b mho/feature-api --no-track >/dev/null 2>&1
  printf 'feature api\n' >api.txt
  git add api.txt
  git_commit "feature api"

  git checkout -b mho/remove-me --no-track >/dev/null 2>&1
  printf 'remove me\n' >remove-me.txt
  git add remove-me.txt
  git_commit "temporary removable stack item"

  git checkout main >/dev/null 2>&1

  before_events=$(event_count)
  init_out=$(bash "$STACK" trunk init --name demo --base origin/main --trunk mho/demo.trunk 2>&1)
  expect_contains "$init_out" "Stack stored: demo"
  expect_event "$before_events" "stack_manifest_changed" "manifest"

  before_events=$(event_count)
  add_base_out=$(bash "$STACK" trunk add --stack demo --id base --branch mho/feature-base 2>&1)
  expect_contains "$add_base_out" "Stack item stored: demo/base"
  expect_event "$before_events" "stack_manifest_changed" "manifest"

  before_events=$(event_count)
  add_api_out=$(bash "$STACK" trunk add --stack demo --id api --branch mho/feature-api --after base 2>&1)
  expect_contains "$add_api_out" "Stack item stored: demo/api"
  expect_event "$before_events" "stack_manifest_changed" "manifest"

  before_events=$(event_count)
  add_remove_out=$(bash "$STACK" trunk add --stack demo --id remove-me --branch mho/remove-me --after api 2>&1)
  expect_contains "$add_remove_out" "Stack item stored: demo/remove-me"
  expect_event "$before_events" "stack_manifest_changed" "manifest"

  before_events=$(event_count)
  move_first_out=$(bash "$STACK" trunk move --stack demo --id api --first 2>&1)
  expect_contains "$move_first_out" "Stack item moved: demo/api"
  expect_event "$before_events" "stack_manifest_changed" "manifest"
  moved_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '.manifest.items[0].id' <<<"$moved_manifest")" == "api" ]] \
    || fail "expected api to move first in real Dolt manifest: $moved_manifest"

  before_events=$(event_count)
  move_restore_out=$(bash "$STACK" trunk move --stack demo --id api --after base 2>&1)
  expect_contains "$move_restore_out" "Stack item moved: demo/api"
  expect_event "$before_events" "stack_manifest_changed" "manifest"
  restored_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '.manifest.items[1].id' <<<"$restored_manifest")" == "api" ]] \
    || fail "expected api restored after base in real Dolt manifest: $restored_manifest"

  before_events=$(event_count)
  remove_out=$(bash "$STACK" trunk remove --stack demo --id remove-me 2>&1)
  expect_contains "$remove_out" "Stack item removed: demo/remove-me"
  expect_event "$before_events" "stack_manifest_changed" "manifest"
  removed_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '[.manifest.items[].id] | index("remove-me") == null' <<<"$removed_manifest")" == "true" ]] \
    || fail "expected remove-me removed in real Dolt manifest: $removed_manifest"

  status_out=$(bash "$STACK" trunk status --stack demo 2>&1)
  expect_contains "$status_out" "Source: Dolt stack demo"
  expect_contains "$status_out" "mho/demo.trunk"

  before_events=$(event_count)
  materialize_out=$(bash "$STACK" trunk materialize --stack demo 2>&1)
  expect_contains "$materialize_out" "Materialized private trunk: mho/demo.trunk"
  expect_event "$before_events" "materialized" "materialization"

  git checkout -b mho/loose --no-track main >/dev/null 2>&1
  printf 'loose\n' >loose.txt
  git add loose.txt
  git_commit "loose branch outside materialized stack"
  git checkout main >/dev/null 2>&1

  trunk_list=$(bash "$STACK" trunk list --json)
  fast_trunk_list=$(bash "$STACK" trunk list --json --fast)
  repo_physical=$(pwd -P)
  [[ "$(jq -r '.repo' <<<"$trunk_list")" == "$repo_physical" ]] \
    || fail "expected trunk list repo to be current repo: $trunk_list"
  [[ "$(jq -r '.repo' <<<"$fast_trunk_list")" == "$repo_physical" ]] \
    || fail "expected fast trunk list repo to be current repo: $fast_trunk_list"
  [[ "$(jq -r '.stacks | length' <<<"$trunk_list")" == "1" ]] \
    || fail "expected one Dolt-backed stack in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks | length' <<<"$fast_trunk_list")" == "1" ]] \
    || fail "expected one Dolt-backed stack in fast trunk list: $fast_trunk_list"
  [[ "$(jq -r '.stacks[0].name' <<<"$trunk_list")" == "demo" ]] \
    || fail "expected demo stack in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks[0].name' <<<"$fast_trunk_list")" == "demo" ]] \
    || fail "expected demo stack in fast trunk list: $fast_trunk_list"
  [[ "$(jq -r '.stacks[0].alignment_state' <<<"$trunk_list")" == "up_to_date" ]] \
    || fail "expected materialized stack to be up to date: $trunk_list"
  [[ "$(jq -r '.stacks[0].materialization.manifest_hash | length > 0' <<<"$trunk_list")" == "true" ]] \
    || fail "expected latest materialization in trunk list: $trunk_list"
  [[ "$(jq -r '.store_repo | length > 0' <<<"$trunk_list")" == "true" ]] \
    || fail "expected trunk list to include backing store repo path: $trunk_list"
  [[ "$(jq -r '.stacks[0].approval.state' <<<"$trunk_list")" == "needs_prepare" ]] \
    || fail "expected missing trunk prepare to be explicit: $trunk_list"
  [[ "$(jq -r '.stacks[0].approval.state' <<<"$fast_trunk_list")" == "needs_prepare" ]] \
    || fail "expected fast trunk list to preserve approval state: $fast_trunk_list"
  [[ "$(jq -r '.stacks[0].approval.prepare_state' <<<"$trunk_list")" == "missing" ]] \
    || fail "expected missing trunk prepare state: $trunk_list"
  expect_contains "$(jq -r '.stacks[0].approval.next_action.command' <<<"$trunk_list")" "pg -C $repo_physical prepare-trunk --stack demo"
  [[ "$(jq -r '.stacks[0].workflow.current_step' <<<"$trunk_list")" == "prepare" ]] \
    || fail "expected workflow stepper to point at prepare: $trunk_list"
  [[ "$(jq -r '.stacks[0].workflow.steps[] | select(.id == "materialize") | .state' <<<"$trunk_list")" == "complete" ]] \
    || fail "expected materialize step complete: $trunk_list"
  [[ "$(jq -r '.stacks[0].workflow.steps[] | select(.id == "prepare") | .actor' <<<"$trunk_list")" == "agent" ]] \
    || fail "expected prepare step to identify agent actor: $trunk_list"
  expect_contains "$(jq -r '.stacks[0].commands.materialize' <<<"$trunk_list")" "stack -C $repo_physical trunk materialize --stack"
  [[ "$(jq -r '.stacks[0].items | map(.id) | join(",")' <<<"$trunk_list")" == "base,api" ]] \
    || fail "expected manifest order in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks[0].items | map(.id) | join(",")' <<<"$fast_trunk_list")" == "base,api" ]] \
    || fail "expected manifest order in fast trunk list: $fast_trunk_list"
  [[ "$(jq -r '[.stacks[].items[].branch] | index("mho/loose") == null' <<<"$trunk_list")" == "true" ]] \
    || fail "expected trunk list to omit loose inferred branches: $trunk_list"
  [[ "$(jq -r '.stacks[0].items[0].remote_state' <<<"$trunk_list")" == "not_pushed" ]] \
    || fail "expected item remote state in trunk list: $trunk_list"
  targeted_list=$(cd "$TEST_TMP" && bash "$STACK" -C "$REPO" trunk list --json)
  [[ "$(jq -r '.repo' <<<"$targeted_list")" == "$repo_physical" ]] \
    || fail "expected stack -C to target repo from outside worktree: $targeted_list"

  json_stderr="$TEST_TMP/json-stderr.txt"
  readonly_events_before=$(event_count)
  readonly_bin="$TEST_TMP/readonly-dolt-bin"
  mkdir -p "$readonly_bin"
  cat >"$readonly_bin/dolt" <<'SH'
#!/bin/bash
set -euo pipefail
real="${REAL_DOLT_FOR_READONLY_TEST:?}"
args=("$@")
case "${1:-}" in
  init|config|add|commit)
    echo "readonly Dolt wrapper blocked: dolt $1" >&2
    exit 97
    ;;
  sql)
    query=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -q)
          query="${2:-}"
          break
          ;;
      esac
      shift
    done
    if grep -Eiq '(^|[[:space:];])(REPLACE|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)[[:space:]]' <<<"$query"; then
      echo "readonly Dolt wrapper blocked write SQL: $query" >&2
      exit 98
    fi
    ;;
esac
exec "$real" "${args[@]}"
SH
  chmod +x "$readonly_bin/dolt"
  readonly_path="$readonly_bin:$PATH"

  readonly_list=$(REAL_DOLT_FOR_READONLY_TEST="$REAL_DOLT" PATH="$readonly_path" bash "$STACK" trunk list --json --fast 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected readonly trunk list stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.stacks[0].name' <<<"$readonly_list")" == "demo" ]] \
    || fail "expected readonly trunk list to work without Dolt writes: $readonly_list"

  readonly_context=$(REAL_DOLT_FOR_READONLY_TEST="$REAL_DOLT" PATH="$readonly_path" bash "$STACK" trunk context --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected readonly stack context stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.stack' <<<"$readonly_context")" == "demo" ]] \
    || fail "expected readonly stack context to work without Dolt writes: $readonly_context"

  readonly_prepare_status=$(REAL_DOLT_FOR_READONLY_TEST="$REAL_DOLT" PATH="$readonly_path" bash "$PG" prepare-trunk status --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected readonly prepare-trunk status stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.state' <<<"$readonly_prepare_status")" == "missing" ]] \
    || fail "expected readonly prepare-trunk status to work without Dolt writes: $readonly_prepare_status"

  readonly_check=$(REAL_DOLT_FOR_READONLY_TEST="$REAL_DOLT" PATH="$readonly_path" bash "$PG" check-trunk --stack demo 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected readonly check-trunk stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.allowed' <<<"$readonly_check")" == "false" ]] \
    || fail "expected readonly check-trunk to report missing approval: $readonly_check"
  [[ "$(event_count)" == "$readonly_events_before" ]] \
    || fail "expected read-only stack and pg commands to emit no events"

  prepare_status_missing=$(bash "$PG" prepare-trunk status --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected prepare-trunk status JSON stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.state' <<<"$prepare_status_missing")" == "missing" ]] \
    || fail "expected missing prepare-trunk status: $prepare_status_missing"
  expect_contains "$(jq -r '.commands.prepare' <<<"$prepare_status_missing")" "pg -C $repo_physical prepare-trunk --stack demo"

  review_payload=$(cd "$TEST_TMP" && bash "$STACK" -C "$REPO" trunk review --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected stack review JSON stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.state' <<<"$review_payload")" == "ready" ]] \
    || fail "expected stack review payload to be ready: $review_payload"
  [[ "$(jq -r '.modes | join(",")' <<<"$review_payload")" == "full_stack,item,cumulative" ]] \
    || fail "expected review modes in payload: $review_payload"
  [[ "$(jq -r '.full_stack.files[] | select(.path == "base.txt") | .change' <<<"$review_payload")" == "added" ]] \
    || fail "expected full-stack review to include base.txt as added: $review_payload"
  [[ "$(jq -r '.items[] | select(.id == "api") | .delta.files[] | select(.path == "api.txt") | .change' <<<"$review_payload")" == "added" ]] \
    || fail "expected api item delta to include api.txt as added: $review_payload"
  [[ "$(jq -r '.items[] | select(.id == "api") | .cumulative.files | map(.path) | index("base.txt") != null' <<<"$review_payload")" == "true" ]] \
    || fail "expected api cumulative review to include base item file: $review_payload"
  expect_contains "$(jq -r '.commands.push_plan' <<<"$review_payload")" "stack -C $repo_physical trunk push-plan --stack"

  push_plan_needs_approval=$(bash "$STACK" trunk push-plan --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected push-plan JSON stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.state' <<<"$push_plan_needs_approval")" == "needs_approval" ]] \
    || fail "expected push-plan to need approval before pg trunk: $push_plan_needs_approval"
  [[ "$(jq -r '.push_units | length' <<<"$push_plan_needs_approval")" == "2" ]] \
    || fail "expected push-plan units for both stack items: $push_plan_needs_approval"
  [[ "$(jq -r '.push_units[0].approval_covered' <<<"$push_plan_needs_approval")" == "false" ]] \
    || fail "expected push-plan units to report missing approval coverage: $push_plan_needs_approval"
  expect_contains "$(jq -r '.push_units[0].command' <<<"$push_plan_needs_approval")" "pg -C $repo_physical push --trunk-stack demo"

  context_initial=$(bash "$STACK" trunk context --stack demo --json 2>"$json_stderr")
  [[ ! -s "$json_stderr" ]] || fail "expected stack context JSON stderr to be clean: $(cat "$json_stderr")"
  [[ "$(jq -r '.materialization.materialization_id | length > 0' <<<"$context_initial")" == "true" ]] \
    || fail "expected stack context to include current materialization: $context_initial"
  [[ "$(jq -r '.completeness.complete' <<<"$context_initial")" == "false" ]] \
    || fail "expected missing context to be incomplete: $context_initial"
  expect_contains "$(jq -r '.completeness.missing | join(",")' <<<"$context_initial")" "brief.what"
  expect_contains "$(jq -r '.completeness.missing | join(",")' <<<"$context_initial")" "item_briefs[base].what"
  expect_contains "$(jq -r '.commands.prepare_from_context' <<<"$context_initial")" "prepare-trunk --stack 'demo' --from-context"
  expect_contains "$(jq -r '.generated_hints.files[] | select(.path == "base.txt") | .path' <<<"$context_initial")" "base.txt"

  partial_context="$TEST_TMP/partial-context.json"
  jq -n '{
    brief:{what:"Partial context"},
    item_briefs:[
      {id:"base", what:"Base only", why:"Partial", approach:"Partial"}
    ],
    source:{kind:"agent", tool:"stack-dolt-regression"}
  }' >"$partial_context"
  partial_write=$(bash "$STACK" trunk context write --stack demo --file "$partial_context" 2>&1)
  expect_contains "$partial_write" "Prepare context stored: demo"
  expect_contains "$partial_write" "Missing:"
  partial_context_status=$(bash "$STACK" trunk context --stack demo --json)
  [[ "$(jq -r '.context.brief.what' <<<"$partial_context_status")" == "Partial context" ]] \
    || fail "expected partial context to round-trip: $partial_context_status"
  [[ "$(jq -r '.completeness.complete' <<<"$partial_context_status")" == "false" ]] \
    || fail "expected partial context to remain incomplete: $partial_context_status"
  set +e
  partial_prepare=$(bash "$PG" prepare-trunk --stack demo --from-context 2>&1)
  partial_prepare_rc=$?
  set -e
  [[ "$partial_prepare_rc" != "0" ]] || fail "expected from-context prepare to reject partial context"
  expect_contains "$partial_prepare" "prepare context incomplete"
  expect_contains "$partial_prepare" "brief.why"

  complete_context="$TEST_TMP/complete-context.json"
  jq -n '{
    brief:{
      what:"ship demo stack from durable context",
      why:"verify shared prepare context storage",
      approach:"write context once and prepare from it"
    },
    item_briefs:[
      {
        id:"base",
        summary:["Add the base stack item from context."],
        motivation:["Provide the first durable context review unit."],
        approach:["Commit base.txt as the item patch from context."],
        testing:["stack-dolt regression"]
      },
      {
        id:"api",
        summary:["Add the API stack item from context."],
        motivation:["Verify child item context handoff."],
        approach:["Commit api.txt after the base item from context."],
        testing:["stack-dolt regression"]
      }
    ],
    references:{beads:["dump-ztf"], sessions:["test-session"], files:["base.txt","api.txt"], commands:["tests/stack-dolt-regression.sh"]},
    source:{kind:"agent", tool:"stack-dolt-regression"}
  }' >"$complete_context"
  before_events=$(event_count)
  complete_write=$(bash "$STACK" trunk context write --stack demo --file "$complete_context" 2>&1)
  expect_contains "$complete_write" "Prepare context stored: demo"
  expect_event "$before_events" "prepare_context_written" "prepare_context"
  complete_context_status=$(bash "$STACK" trunk context --stack demo --json)
  [[ "$(jq -r '.completeness.complete' <<<"$complete_context_status")" == "true" ]] \
    || fail "expected complete context: $complete_context_status"
  [[ "$(jq -r '.current_context.source.kind' <<<"$complete_context_status")" == "agent" ]] \
    || fail "expected context source to round-trip: $complete_context_status"
  before_events=$(event_count)
  context_prepare_out=$(bash "$PG" prepare-trunk --stack demo --from-context 2>&1)
  expect_contains "$context_prepare_out" "Prepared trunk brief written"
  expect_event "$before_events" "prepare_trunk_written" "prepare_trunk"
  context_review_payload=$(bash "$STACK" trunk review --stack demo --json)
  expect_contains "$(jq -r '.items[] | select(.id == "api") | .item_brief.why[0]' <<<"$context_review_payload")" "Verify child item context handoff."

  fake_materialization=$(jq '.materialization_id = (.materialization_id + "-new")' <<<"$(jq -c '.materialization' <<<"$complete_context_status")")
  before_events=$(event_count)
  fake_materialize_out=$(bash "$PG" stack-store-record-materialization --stack demo --json "$fake_materialization" 2>&1)
  expect_contains "$fake_materialize_out" "Materialization stored: demo"
  expect_event "$before_events" "materialized" "materialization"
  stale_context_status=$(bash "$STACK" trunk context --stack demo --json)
  [[ "$(jq -r '.context == null' <<<"$stale_context_status")" == "true" ]] \
    || fail "expected current context to be empty after rematerialization: $stale_context_status"
  [[ "$(jq -r '.stale_contexts | length > 0' <<<"$stale_context_status")" == "true" ]] \
    || fail "expected stale prior context after rematerialization: $stale_context_status"
  expect_contains "$(jq -r '.stale_contexts[0].stale_reason' <<<"$stale_context_status")" "materialization differs"

  mismatched_context="$TEST_TMP/mismatched-context.json"
  jq -n '{
    brief:{what:"mismatch", why:"mismatch", approach:"mismatch"},
    item_briefs:[
      {id:"base", what:"Base", why:"Base", approach:"Base"}
    ],
    source:{kind:"agent", tool:"stack-dolt-regression"}
  }' >"$mismatched_context"
  mismatch_write=$(bash "$STACK" trunk context write --stack demo --file "$mismatched_context" 2>&1)
  expect_contains "$mismatch_write" "Prepare context stored: demo"
  set +e
  mismatch_prepare=$(bash "$PG" prepare-trunk --stack demo --from-context 2>&1)
  mismatch_prepare_rc=$?
  set -e
  [[ "$mismatch_prepare_rc" != "0" ]] || fail "expected item id mismatch prepare to fail"
  expect_contains "$mismatch_prepare" "item_briefs[api].what"

  item_briefs="$TEST_TMP/item-briefs.json"
  jq -n '[
    {
      id: "base",
      what: ["Add the base stack item."],
      why: ["Provide the first review unit."],
      approach: ["Commit base.txt as the item patch."],
      risks: ["low"],
      verification: ["stack-dolt regression"]
    },
    {
      id: "api",
      what: ["Add the API stack item."],
      why: ["Verify child item review context."],
      approach: ["Commit api.txt after the base item."],
      risks: ["low"],
      verification: ["stack-dolt regression"]
    }
  ]' >"$item_briefs"

  before_events=$(event_count)
  prepare_out=$(bash "$PG" prepare-trunk --stack demo \
    --async \
    --expires 8h \
    --max-pushes 30 \
    --allow-rewrite \
    --what "ship demo stack" \
    --why "verify rich trunk review details" \
    --approach "review each materialized item before pushing" \
    --item-briefs "$item_briefs" 2>&1)
  expect_contains "$prepare_out" "Prepared trunk brief written"
  expect_event "$before_events" "prepare_trunk_written" "prepare_trunk"
  prepared_trunk_list=$(bash "$STACK" trunk list --json)
  [[ "$(jq -r '.stacks[0].approval.state' <<<"$prepared_trunk_list")" == "needs_approval" ]] \
    || fail "expected prepared trunk to be ready for approval: $prepared_trunk_list"
  [[ "$(jq -r '.stacks[0].approval.prepare_state' <<<"$prepared_trunk_list")" == "ready" ]] \
    || fail "expected prepared trunk state: $prepared_trunk_list"
  [[ "$(jq -r '.stacks[0].approval.next_action.actor' <<<"$prepared_trunk_list")" == "human" ]] \
    || fail "expected prepared trunk to identify human review action: $prepared_trunk_list"
  expect_contains "$(jq -r '.stacks[0].approval.next_action.command' <<<"$prepared_trunk_list")" "pg -C $repo_physical trunk --stack demo"
  [[ "$(jq -r '.stacks[0].workflow.current_step' <<<"$prepared_trunk_list")" == "approve" ]] \
    || fail "expected prepared workflow to point at approval: $prepared_trunk_list"
  [[ "$(jq -r '.stacks[0].workflow.steps[] | select(.id == "approve") | .writes_lease' <<<"$prepared_trunk_list")" == "true" ]] \
    || fail "expected approve step to disclose lease write: $prepared_trunk_list"
  prepared_review_payload=$(bash "$STACK" trunk review --stack demo --json)
  [[ "$(jq -r '.items[] | select(.id == "base") | .item_brief.state' <<<"$prepared_review_payload")" == "ready" ]] \
    || fail "expected review payload to report ready item brief coverage: $prepared_review_payload"
  expect_contains "$(jq -r '.items[] | select(.id == "api") | .item_brief.why[0]' <<<"$prepared_review_payload")" "Verify child item review context."
  prepare_status_ready=$(bash "$PG" prepare-trunk status --stack demo --json)
  [[ "$(jq -r '.state' <<<"$prepare_status_ready")" == "ready" ]] \
    || fail "expected ready prepare-trunk status: $prepare_status_ready"
  [[ "$(jq -r '.target.worktree_root' <<<"$prepare_status_ready")" == "$repo_physical" ]] \
    || fail "expected prepare-trunk status target worktree: $prepare_status_ready"
  prepare_path=$(jq -r '.path' <<<"$prepare_status_ready")
  cp "$prepare_path" "$prepare_path.good"
  jq '.materialization.manifest_hash = "stale-test-manifest-hash"' "$prepare_path" >"$prepare_path.tmp"
  mv "$prepare_path.tmp" "$prepare_path"
  prepare_status_stale=$(bash "$PG" prepare-trunk status --stack demo --json)
  [[ "$(jq -r '.state' <<<"$prepare_status_stale")" == "stale" ]] \
    || fail "expected stale prepare-trunk status after materialization mismatch: $prepare_status_stale"
  set +e
  stale_trunk_out=$(PG_AUTO_RUN_APPROVAL=0 bash "$PG" trunk --stack demo 2>&1)
  stale_trunk_rc=$?
  stale_trunk_draft_out=$(bash "$PG" trunk-draft --stack demo --format json 2>&1)
  stale_trunk_draft_rc=$?
  set -e
  [[ "$stale_trunk_rc" != "0" ]] || fail "expected pg trunk to reject stale prepare file"
  expect_contains "$stale_trunk_out" "Approval draft blocked"
  expect_contains "$stale_trunk_out" "Stack manifest changed after prepare-trunk"
  expect_contains "$stale_trunk_out" "prepare-trunk --stack demo --from-context"
  [[ "$stale_trunk_draft_rc" != "0" ]] || fail "expected pg trunk-draft to reject stale prepare file"
  expect_contains "$stale_trunk_draft_out" "Approval draft blocked"
  expect_contains "$stale_trunk_draft_out" "Stack manifest changed after prepare-trunk"
  expect_contains "$stale_trunk_draft_out" "prepare-trunk --stack demo --from-context"
  mv "$prepare_path.good" "$prepare_path"
  trunk_out=$(PG_AUTO_RUN_APPROVAL=0 bash "$PG" trunk --stack demo 2>&1)
  expect_contains "$trunk_out" "Draft file:"
  yaml_draft_file=$(printf '%s\n' "$trunk_out" | awk -F': ' '/Draft file:/ {print $2; exit}')
  draft_file=$(printf '%s\n' "$trunk_out" | awk -F': ' '/JSON draft file:/ {print $2; exit}')
  [[ -f "$yaml_draft_file" ]] || fail "expected trunk YAML draft file: $trunk_out"
  [[ -f "$draft_file" ]] || fail "expected trunk draft file: $trunk_out"
  expect_no_trailing_whitespace "$yaml_draft_file"
  yq eval '.stack' "$yaml_draft_file" | grep -qx 'demo' \
    || fail "expected trunk YAML draft to parse as stack demo"
  [[ "$(jq -r 'keys_unsorted[0:4] | join(",")' "$draft_file")" == "schema_version,stack,description,stack_items" ]] \
    || fail "expected human-readable fields at top of trunk draft: $(jq -r 'keys_unsorted[0:6] | join(",")' "$draft_file")"
  expect_contains "$(jq -r '.description.summary' "$draft_file")" "ship demo stack"
  expect_contains "$(jq -r '.description.motivation' "$draft_file")" "verify rich trunk review details"
  [[ "$(jq '.stack_items | length' "$draft_file")" == "2" ]] \
    || fail "expected stack items in trunk draft: $(cat "$draft_file")"
  [[ "$(jq -r '.async_iteration.enabled' "$draft_file")" == "true" ]] \
    || fail "expected async trunk draft metadata"
  [[ "$(jq -r '.async_iteration.max_pushes' "$draft_file")" == "30" ]] \
    || fail "expected async trunk max push budget"
  [[ "$(jq -r '.async_iteration.allow_rewrite' "$draft_file")" == "true" ]] \
    || fail "expected async trunk rewrite approval"
  [[ "$(jq -r '.async_iteration.scope.trunk_ref' "$draft_file")" == "mho/demo.trunk" ]] \
    || fail "expected async trunk scope to include private trunk ref"
  expect_contains "$(jq -r '.stack_items[0].pointer_subject' "$draft_file")" "feature base"
  expect_contains "$(jq -r '.stack_items[0].description.summary[0]' "$draft_file")" "Add the base stack item."
  expect_contains "$(jq -r '.stack_items[0].description.motivation[0]' "$draft_file")" "Provide the first review unit."
  expect_contains "$(jq -r '.stack_items[0].description.approach[0]' "$draft_file")" "Commit base.txt as the item patch."
  expect_contains "$(jq -r '.stack_items[0].brief.what[0]' "$draft_file")" "Add the base stack item."
  expect_contains "$(jq -r '.stack_items[0].brief.why[0]' "$draft_file")" "Provide the first review unit."
  expect_contains "$(jq -r '.stack_items[0].brief.approach[0]' "$draft_file")" "Commit base.txt as the item patch."
  expect_contains "$(jq -r '.stack_items[0].pointer_commit' "$draft_file")" "$(git rev-parse mho/feature-base)"
  expect_contains "$(jq -r '.stack_items[0].shortstat' "$draft_file")" "1 file changed"
  expect_contains "$(jq -r '.stack_items[0].changed_files[0].paths[0]' "$draft_file")" "base.txt"
  expect_contains "$(jq -r '.stack_items[0].changed_files[0].change' "$draft_file")" "added"
  [[ "$(jq -r '.stack_items[0].changed_files[0] | has("status")' "$draft_file")" == "false" ]] \
    || fail "trunk draft should not expose raw git status codes"
  expect_contains "$(jq -r '.stack_items[1].base_commit' "$draft_file")" "$(git rev-parse mho/feature-base)"
  expect_contains "$(jq -r '.stack_items[1].contained_commits[0].subject' "$draft_file")" "feature api"
  preview_out=$(bash "$PG" preview-trunk --draft "$draft_file" 2>&1)
  expect_contains "$preview_out" "Async iteration: enabled"
  expect_contains "$preview_out" "Stack item: base"
  expect_contains "$preview_out" "Description:"
  expect_contains "$preview_out" "Summary:"
  expect_contains "$preview_out" "- Add the base stack item."
  expect_contains "$preview_out" "Motivation:"
  expect_contains "$preview_out" "- Provide the first review unit."
  expect_contains "$preview_out" "Approach:"
  expect_contains "$preview_out" "- Commit base.txt as the item patch."
  expect_contains "$preview_out" "Testing:"
  expect_contains "$preview_out" "Pointer commit:"
  expect_contains "$preview_out" "Contained commits:"
  expect_contains "$preview_out" "Changed files:"
  expect_contains "$preview_out" "added:"
  expect_contains "$preview_out" "api.txt"
  jq '
    .description.summary = "ship demo stack\n\n"
    | .description.motivation = "verify rich trunk review details\n\n"
    | .stack_items[0].description.summary = ["Edited base item description.\n\n"]
    | .stack_items[0].brief.what = ["stale brief field\n\n"]
  ' \
    "$draft_file" >"$draft_file.tmp"
  mv "$draft_file.tmp" "$draft_file"
  set +e
  approve_trunk_out=$(bash "$PG" approve-trunk --draft "$draft_file" 2>&1)
  approve_trunk_rc=$?
  set -e
  [[ "$approve_trunk_rc" != "0" ]] || fail "expected noninteractive trunk approval to fail"
  expect_contains "$approve_trunk_out" "requires an interactive terminal"
  [[ "$(jq -r '.description.summary' "$draft_file")" == "ship demo stack" ]] \
    || fail "expected trunk approval to trim trailing blank lines from description summary"
  [[ "$(jq -r '.description.motivation' "$draft_file")" == "verify rich trunk review details" ]] \
    || fail "expected trunk approval to trim trailing blank lines from description motivation"
  expect_contains "$(jq -r '.stack_items[0].brief.what[0]' "$draft_file")" "Edited base item description."
  [[ "$(jq -r '.stack_items[0].brief.what[0]' "$draft_file")" == "Edited base item description." ]] \
    || fail "expected trunk approval to trim trailing blank lines from item brief"

  trunk_draft_out=$(bash "$PG" trunk-draft --stack demo --format yaml)
  [[ "$(yq eval '.stack' <<<"$trunk_draft_out")" == "demo" ]] \
    || fail "expected trunk-draft YAML to name demo stack: $trunk_draft_out"
  [[ "$(yq eval '.format' <<<"$trunk_draft_out")" == "yaml" ]] \
    || fail "expected trunk-draft YAML to report yaml format: $trunk_draft_out"
  yaml_draft_file=$(yq eval '.draft_file' <<<"$trunk_draft_out")
  json_draft_file=$(yq eval '.json_draft_file' <<<"$trunk_draft_out")
  [[ -f "$yaml_draft_file" ]] || fail "expected YAML trunk draft file: $trunk_draft_out"
  [[ -f "$json_draft_file" ]] || fail "expected JSON trunk draft file: $trunk_draft_out"
  expect_no_trailing_whitespace "$yaml_draft_file"
  expect_contains "$(head -n 1 "$yaml_draft_file")" "pg trunk approval draft"
  yq eval '.stack' "$yaml_draft_file" | grep -qx 'demo' \
    || fail "expected YAML trunk draft to parse as stack demo"
  trunk_draft_json_out=$(bash "$PG" trunk-draft --stack demo --format yaml --json)
  [[ "$(jq -r '.stack' <<<"$trunk_draft_json_out")" == "demo" ]] \
    || fail "expected trunk-draft --json to name demo stack: $trunk_draft_json_out"

  bad_item_briefs="$TEST_TMP/bad-item-briefs.json"
  jq -n '[{id:"base", what:"missing peers", why:"incomplete", approach:"incomplete"}]' >"$bad_item_briefs"
  set +e
  bad_prepare=$(bash "$PG" prepare-trunk --stack demo \
    --what "ship demo stack" \
    --why "verify invalid item brief rejection" \
    --approach "reject incomplete item brief files" \
    --item-briefs "$bad_item_briefs" 2>&1)
  bad_prepare_rc=$?
  set -e
  [[ "$bad_prepare_rc" != "0" ]] || fail "expected incomplete item brief file to fail"
  expect_contains "$bad_prepare" "exactly one entry per stack item"

  branch_materialization=$(bash "$PG" stack-store-branch-materialization --branch mho/feature-api --json 2>&1)
  [[ "$(jq -r '.stack' <<<"$branch_materialization")" == "demo" ]] \
    || fail "expected branch materialization stack demo: $branch_materialization"
  [[ "$(jq -r '.trunk' <<<"$branch_materialization")" == "mho/demo.trunk" ]] \
    || fail "expected branch materialization trunk ref: $branch_materialization"
  [[ "$(jq -r '.commit' <<<"$branch_materialization")" == "$(git rev-parse mho/feature-api)" ]] \
    || fail "expected branch materialization commit to match branch head: $branch_materialization"

  check_out=$(bash "$PG" check-trunk --stack demo 2>&1)
  expect_contains "$check_out" "No active trunk lease for stack demo"

  before_events=$(event_count)
  vscode_approve_out=$(bash "$PG" approve-trunk --draft "$yaml_draft_file" --reviewed-in-vscode 2>&1)
  expect_contains "$vscode_approve_out" "Trunk lease approved: demo"
  expect_event "$before_events" "trunk_approved" "approval"
  vscode_check_out=$(bash "$PG" check-trunk --stack demo 2>&1)
  [[ "$(jq -r '.allowed' <<<"$vscode_check_out")" == "true" ]] \
    || fail "expected VS Code-reviewed YAML approval to allow trunk: $vscode_check_out"
  rm -f "$prepare_path"
  approved_trunk_list=$(bash "$STACK" trunk list --json --fast)
  [[ "$(jq -r '.stacks[0].workflow.current_step' <<<"$approved_trunk_list")" == "push" ]] \
    || fail "expected approved workflow to point at push even if prepare file is missing: $approved_trunk_list"
  [[ "$(jq -r '.stacks[0].workflow.steps[] | select(.id == "prepare") | .state' <<<"$approved_trunk_list")" == "complete" ]] \
    || fail "expected approved workflow to mark prepare complete: $approved_trunk_list"
  push_plan_ready=$(bash "$STACK" trunk push-plan --stack demo --json)
  [[ "$(jq -r '.state' <<<"$push_plan_ready")" == "ready_to_push" ]] \
    || fail "expected push-plan to be ready after approval: $push_plan_ready"
  [[ "$(jq -r '.checklist[] | select(.id == "prepared") | .ok' <<<"$push_plan_ready")" == "true" ]] \
    || fail "expected approved push-plan to satisfy prepare checklist even if prepare file is missing: $push_plan_ready"
  [[ "$(jq -r '.checklist[] | select(.id == "prepared") | .label' <<<"$push_plan_ready")" == "Prepare brief captured by approval" ]] \
    || fail "expected approved push-plan prepare checklist label to explain approval coverage: $push_plan_ready"
  [[ "$(jq -r '.checklist[] | select(.id == "approved") | .ok' <<<"$push_plan_ready")" == "true" ]] \
    || fail "expected push-plan approval checklist to pass: $push_plan_ready"
  [[ "$(jq -r '.push_units[] | select(.id == "api") | .action' <<<"$push_plan_ready")" == "ready_to_push" ]] \
    || fail "expected api push unit ready_to_push: $push_plan_ready"

  repo_key=$(git rev-parse --git-common-dir)
  [[ "$repo_key" == /* ]] || repo_key="$(git rev-parse --show-toplevel)/$repo_key"
  materialization_id=$(jq -r '.materialization.materialization_id' "$draft_file")
  manifest_hash=$(jq -r '.materialization.manifest_hash' "$draft_file")
  trunk_tip=$(jq -r '.materialization.trunk_tip' "$draft_file")
  pretty_async=$(jq '.async_iteration | .expires_at = "2099-01-01T00:00:00Z"' "$draft_file")
  brief_json=$(jq -c '.brief' "$draft_file")
  now="2026-05-06T00:00:00Z"
  cd "$PG_STORE_DIR"
  dolt sql -q "
REPLACE INTO trunk_leases (repo_key, stack_name, manifest_hash, materialization_id, trunk_tip, approved_scope_json, brief_json, async_json, status, created_by, created_at, updated_at)
VALUES ($(sql_quote "$repo_key"), 'demo', $(sql_quote "$manifest_hash"), $(sql_quote "$materialization_id"), $(sql_quote "$trunk_tip"), 'null', $(sql_quote "$brief_json"), $(sql_quote "$pretty_async"), 'active', 'test', $(sql_quote "$now"), $(sql_quote "$now"));
" >/dev/null
  jq -r '.materialization.items[] | [.id, .order_index, .branch, .commit, (.pr // "")] | @tsv' "$draft_file" |
  while IFS=$'\t' read -r item_id order_index branch commit_sha pr_number; do
    pr_sql="NULL"
    [[ -n "$pr_number" ]] && pr_sql="$pr_number"
    dolt sql -q "
REPLACE INTO trunk_lease_items (repo_key, stack_name, item_id, order_index, branch, commit_sha, pr_number)
VALUES ($(sql_quote "$repo_key"), 'demo', $(sql_quote "$item_id"), $order_index, $(sql_quote "$branch"), $(sql_quote "$commit_sha"), $pr_sql);
" >/dev/null
  done
  cd "$REPO"
  pretty_check=$(bash "$PG" check-trunk --stack demo 2>&1)
  [[ "$(jq -r '.allowed' <<<"$pretty_check")" == "true" ]] \
    || fail "expected check-trunk to read pretty async_json from Dolt: $pretty_check"
  [[ "$(jq -r '.async_iteration.enabled' <<<"$pretty_check")" == "true" ]] \
    || fail "expected async status in check-trunk output: $pretty_check"
  set +e
  failed_trunk_push=$(bash "$PG" push \
    --trunk-stack demo \
    --branch mho/feature-api \
    --source-ref mho/feature-api \
    --remote missing \
    --force-with-lease \
    --assert-flow $'push stack trunk demo\nitem api\nbranch mho/feature-api' 2>&1)
  failed_trunk_push_rc=$?
  set -e
  [[ "$failed_trunk_push_rc" != "0" ]] || fail "expected trunk push to fail against missing remote"
  trunk_used_pushes=$(cd "$PG_STORE_DIR" && dolt sql -r json -q "
SELECT async_json
FROM trunk_leases
WHERE repo_key = $(sql_quote "$repo_key") AND stack_name = 'demo';
" | jq -r '.rows[0].async_json' | jq -r '.used_pushes')
  [[ "$trunk_used_pushes" == "0" ]] \
    || fail "failed trunk push consumed async budget: $trunk_used_pushes output: $failed_trunk_push"

  materializations=$(cd "$PG_STORE_DIR" && dolt sql -r csv -q "SELECT COUNT(*) FROM trunk_materializations;" | tail -n +2)
  [[ "$materializations" -ge "2" ]] || fail "expected context stale test to record at least two trunk materializations, got $materializations"
)

echo "ok 1 - real Dolt stack store supports init add status materialize and check-trunk"
