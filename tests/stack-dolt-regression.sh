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

  materializations=$(cd "$PG_STORE_DIR" && dolt sql -r csv -q "SELECT COUNT(*) FROM trunk_materializations;" | tail -n +2)
  [[ "$materializations" == "1" ]] || fail "expected one trunk materialization row, got $materializations"
)

echo "ok 1 - real Dolt stack store supports init add status materialize and check-trunk"
