#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STACK="$ROOT/llm/hooks/stack.sh"
PG="$ROOT/llm/hooks/push-gate.sh"

if ! command -v dolt >/dev/null 2>&1; then
  echo "1..0 # SKIP dolt not installed"
  exit 0
fi

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stack-dolt-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

export PG_STORE_DIR="$TEST_TMP/dolt-store"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected [$needle] in: $haystack"
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

REPO="$TEST_TMP/repo"
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

  init_out=$(bash "$STACK" trunk init --name demo --base origin/main --trunk mho/demo.trunk 2>&1)
  expect_contains "$init_out" "Stack stored: demo"

  add_base_out=$(bash "$STACK" trunk add --stack demo --id base --branch mho/feature-base 2>&1)
  expect_contains "$add_base_out" "Stack item stored: demo/base"

  add_api_out=$(bash "$STACK" trunk add --stack demo --id api --branch mho/feature-api --after base 2>&1)
  expect_contains "$add_api_out" "Stack item stored: demo/api"

  add_remove_out=$(bash "$STACK" trunk add --stack demo --id remove-me --branch mho/remove-me --after api 2>&1)
  expect_contains "$add_remove_out" "Stack item stored: demo/remove-me"

  move_first_out=$(bash "$STACK" trunk move --stack demo --id api --first 2>&1)
  expect_contains "$move_first_out" "Stack item moved: demo/api"
  moved_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '.manifest.items[0].id' <<<"$moved_manifest")" == "api" ]] \
    || fail "expected api to move first in real Dolt manifest: $moved_manifest"

  move_restore_out=$(bash "$STACK" trunk move --stack demo --id api --after base 2>&1)
  expect_contains "$move_restore_out" "Stack item moved: demo/api"
  restored_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '.manifest.items[1].id' <<<"$restored_manifest")" == "api" ]] \
    || fail "expected api restored after base in real Dolt manifest: $restored_manifest"

  remove_out=$(bash "$STACK" trunk remove --stack demo --id remove-me 2>&1)
  expect_contains "$remove_out" "Stack item removed: demo/remove-me"
  removed_manifest=$(bash "$STACK" trunk status --stack demo --json)
  [[ "$(jq -r '[.manifest.items[].id] | index("remove-me") == null' <<<"$removed_manifest")" == "true" ]] \
    || fail "expected remove-me removed in real Dolt manifest: $removed_manifest"

  status_out=$(bash "$STACK" trunk status --stack demo 2>&1)
  expect_contains "$status_out" "Source: Dolt stack demo"
  expect_contains "$status_out" "mho/demo.trunk"

  materialize_out=$(bash "$STACK" trunk materialize --stack demo 2>&1)
  expect_contains "$materialize_out" "Materialized private trunk: mho/demo.trunk"

  git checkout -b mho/loose --no-track main >/dev/null 2>&1
  printf 'loose\n' >loose.txt
  git add loose.txt
  git_commit "loose branch outside materialized stack"
  git checkout main >/dev/null 2>&1

  trunk_list=$(bash "$STACK" trunk list --json)
  repo_physical=$(pwd -P)
  [[ "$(jq -r '.repo' <<<"$trunk_list")" == "$repo_physical" ]] \
    || fail "expected trunk list repo to be current repo: $trunk_list"
  [[ "$(jq -r '.stacks | length' <<<"$trunk_list")" == "1" ]] \
    || fail "expected one Dolt-backed stack in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks[0].name' <<<"$trunk_list")" == "demo" ]] \
    || fail "expected demo stack in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks[0].alignment_state' <<<"$trunk_list")" == "up_to_date" ]] \
    || fail "expected materialized stack to be up to date: $trunk_list"
  [[ "$(jq -r '.stacks[0].materialization.manifest_hash | length > 0' <<<"$trunk_list")" == "true" ]] \
    || fail "expected latest materialization in trunk list: $trunk_list"
  [[ "$(jq -r '.stacks[0].approval.state' <<<"$trunk_list")" == "needs_approval" ]] \
    || fail "expected missing trunk lease to need approval: $trunk_list"
  [[ "$(jq -r '.stacks[0].items | map(.id) | join(",")' <<<"$trunk_list")" == "base,api" ]] \
    || fail "expected manifest order in trunk list: $trunk_list"
  [[ "$(jq -r '[.stacks[].items[].branch] | index("mho/loose") == null' <<<"$trunk_list")" == "true" ]] \
    || fail "expected trunk list to omit loose inferred branches: $trunk_list"
  [[ "$(jq -r '.stacks[0].items[0].remote_state' <<<"$trunk_list")" == "not_pushed" ]] \
    || fail "expected item remote state in trunk list: $trunk_list"

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
  trunk_out=$(PG_AUTO_RUN_APPROVAL=0 bash "$PG" trunk --stack demo 2>&1)
  expect_contains "$trunk_out" "Draft file:"
  draft_file=$(printf '%s\n' "$trunk_out" | awk -F': ' '/Draft file:/ {print $2; exit}')
  [[ -f "$draft_file" ]] || fail "expected trunk draft file: $trunk_out"
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
  jq '.stack_items[0].description.summary = ["Edited base item description."] | .stack_items[0].brief.what = ["stale brief field"]' \
    "$draft_file" >"$draft_file.tmp"
  mv "$draft_file.tmp" "$draft_file"
  set +e
  approve_trunk_out=$(bash "$PG" approve-trunk --draft "$draft_file" 2>&1)
  approve_trunk_rc=$?
  set -e
  [[ "$approve_trunk_rc" != "0" ]] || fail "expected noninteractive trunk approval to fail"
  expect_contains "$approve_trunk_out" "requires an interactive terminal"
  expect_contains "$(jq -r '.stack_items[0].brief.what[0]' "$draft_file")" "Edited base item description."

  trunk_draft_out=$(bash "$PG" trunk-draft --stack demo --format yaml)
  [[ "$(jq -r '.stack' <<<"$trunk_draft_out")" == "demo" ]] \
    || fail "expected trunk-draft JSON to name demo stack: $trunk_draft_out"
  [[ "$(jq -r '.format' <<<"$trunk_draft_out")" == "yaml" ]] \
    || fail "expected trunk-draft JSON to report yaml format: $trunk_draft_out"
  yaml_draft_file=$(jq -r '.draft_file' <<<"$trunk_draft_out")
  json_draft_file=$(jq -r '.json_draft_file' <<<"$trunk_draft_out")
  [[ -f "$yaml_draft_file" ]] || fail "expected YAML trunk draft file: $trunk_draft_out"
  [[ -f "$json_draft_file" ]] || fail "expected JSON trunk draft file: $trunk_draft_out"
  expect_contains "$(head -n 1 "$yaml_draft_file")" "pg trunk approval draft"
  yq eval '.stack' "$yaml_draft_file" | grep -qx 'demo' \
    || fail "expected YAML trunk draft to parse as stack demo"

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

  vscode_approve_out=$(bash "$PG" approve-trunk --draft "$yaml_draft_file" --reviewed-in-vscode 2>&1)
  expect_contains "$vscode_approve_out" "Trunk lease approved: demo"
  vscode_check_out=$(bash "$PG" check-trunk --stack demo 2>&1)
  [[ "$(jq -r '.allowed' <<<"$vscode_check_out")" == "true" ]] \
    || fail "expected VS Code-reviewed YAML approval to allow trunk: $vscode_check_out"

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
  [[ "$materializations" == "1" ]] || fail "expected one trunk materialization row, got $materializations"
)

echo "ok 1 - real Dolt stack store supports init add status materialize and check-trunk"
