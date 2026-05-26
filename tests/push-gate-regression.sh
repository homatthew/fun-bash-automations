#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER="$ROOT/llm/hooks/push-gate.sh"
GUARD="$ROOT/llm/hooks/bash-safety-guard.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/push-gate-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

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

expect_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "expected file to exist: $path"
}

expect_no_file() {
  local path="$1"
  [[ ! -e "$path" ]] || fail "expected file to be absent: $path"
}

make_fake_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  repo=""
  head=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R)
        repo="$2"
        shift 2
        ;;
      --head|-H)
        head="$2"
        shift 2
        ;;
      --json|--jq|--state)
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  if [[ -n "${PG_TEST_PR_LIST_MAP:-}" ]]; then
    result=$(jq -cn \
      --argjson map "${PG_TEST_PR_LIST_MAP}" \
      --arg key "${repo}|${head}" \
      --arg repo "$repo" \
      --arg head "$head" \
      '$map[$key] // $map[$repo] // $map[$head] // empty')
    if [[ -n "$result" && "$result" != "null" ]]; then
      printf '%s\n' "$result"
      exit 0
    fi
  fi
  printf '%s\n' "${PG_TEST_PR_JSON:-[]}"
  exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
  printf '%s\n' "${PG_TEST_CREATE_URL:-https://example.test/pr/new}"
  exit 0
fi

if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  repo=""
  shift 2
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R|--branch|--json|--jq|--template)
        if [[ "$1" == "--json" || "$1" == "--jq" || "$1" == "--template" || "$1" == "--branch" || "$1" == "--repo" || "$1" == "-R" ]]; then
          if [[ "$1" == "--repo" || "$1" == "-R" ]]; then
            repo="$2"
          fi
          shift 2
        fi
        ;;
      -*)
        shift
        ;;
      *)
        repo="$1"
        shift
        ;;
    esac
  done
  if [[ -n "${PG_TEST_REPO_VIEW_MAP:-}" ]]; then
    result=$(jq -cn --argjson map "${PG_TEST_REPO_VIEW_MAP}" --arg repo "$repo" '$map[$repo] // $map["default"] // {}')
    printf '%s\n' "$result"
    exit 0
  fi
  printf '%s\n' '{"viewerPermission":"READ"}'
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "$bin_dir/gh"
  cat >"$bin_dir/codex" <<'EOF'
#!/bin/bash
set -euo pipefail

output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$output" ]] || { echo "missing --output-last-message" >&2; exit 1; }
printf '%s\n' "${PG_TEST_CODEX_RESPONSE:-MATCH: test semantic check ok}" >"$output"
exit "${PG_TEST_CODEX_RC:-0}"
EOF
  chmod +x "$bin_dir/codex"
}

make_repo() {
  local name="$1"
  local base="$TEST_TMP/$name"
  local origin="$base/origin.git"
  local repo_dir="${2:-repo}"
  local repo="$base/$repo_dir"
  local bin_dir="$base/bin"
  mkdir -p "$base"
  git -c init.defaultBranch=main init --bare "$origin" >/dev/null
  git -c init.defaultBranch=main init "$repo" >/dev/null
  (
    cd "$repo"
    git config user.name "Push Gate Test"
    git config user.email "push-gate@test"
    printf 'base\n' >README.md
    git add README.md
    git commit -m "base" >/dev/null
    git branch -M main
    git remote add origin "$origin"
    git push -u origin main >/dev/null
  )
  make_fake_gh "$bin_dir"
  echo "$repo|$bin_dir|$origin"
}

run_helper() {
  local repo="$1"
  shift
  (
    cd "$repo"
    PATH="$FAKE_BIN:$PATH" bash "$HELPER" "$@"
  )
}

run_guard() {
  local repo="$1"
  local command="$2"
  (
    cd "$repo"
    jq -n --arg command "$command" '{tool_input:{command:$command}}' | PATH="$FAKE_BIN:$PATH" bash "$GUARD"
  )
}

current_common_dir() {
  (
    cd "$1"
    local common_dir repo_root
    common_dir=$(git rev-parse --git-common-dir)
    if [[ "$common_dir" != /* ]]; then
      repo_root=$(git rev-parse --show-toplevel)
      common_dir="$repo_root/$common_dir"
    fi
    printf '%s\n' "$common_dir"
  )
}

current_head() {
  (
    cd "$1"
    git rev-parse HEAD
  )
}

future_utc() {
  printf '2099-01-01T00:00:00Z\n'
}

write_pending() {
  local repo="$1"
  local remote="$2"
  local branch_ref="$3"
  local head="$4"
  local pr_number="$5"
  local common_dir
  common_dir=$(current_common_dir "$repo")
  local pending="$common_dir/push-gate/pending/$branch_ref.json"
  mkdir -p "$(dirname "$pending")"
  jq -n \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg head "$head" \
    --arg assert_flow "update pr line" \
    --arg pr_number "$pr_number" \
    '{
      branch_ref: $branch_ref,
      remote: $remote,
      head: $head,
      assert_flow: $assert_flow,
      agent_asserted_pr: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      agent_asserted_overall_flow: $assert_flow,
      agent_asserted_files: ["README.md"],
      timestamp: "2026-04-21T00:00:00Z"
    }' >"$pending"
}

extract_path() {
  local output="$1"
  local prefix="$2"
  echo "$output" | awk -v prefix="$prefix" '$0 ~ prefix {print $NF}'
}

expect_no_trailing_whitespace() {
  local file="$1" matches
  matches=$(grep -nE '[[:blank:]]$' "$file" || true)
  [[ -z "$matches" ]] || fail "expected no trailing whitespace in $file: $matches"
}

echo "1..40"

legacy_output=$(bash "$HELPER" 5 2>&1 || true)
expect_contains "$legacy_output" "Durable leases replaced minute windows"
echo "ok 1 - legacy numeric syntax rejected"

IFS='|' read -r BEAD_REPO BEAD_BIN BEAD_ORIGIN <<<"$(make_repo bead-detection)"
(
  cd "$BEAD_REPO"
  git checkout -b mho/bead-detection >/dev/null
  printf 'beads\n' >beads.txt
  git add beads.txt
  git commit -m "push-gate prepare docs" \
    -m "mentions push-gate draft-approve child-codex and real ids dump-8kj fba-123" >/dev/null
)
detected_beads=$(
  cd "$BEAD_REPO"
  source "$HELPER"
  pg_detect_beads
)
expect_contains "$detected_beads" "dump-8kj"
expect_contains "$detected_beads" "fba-123"
[[ "$detected_beads" != *"push-gate"* ]] || fail "expected bead detection to ignore push-gate prose token"
[[ "$detected_beads" != *"draft-approve"* ]] || fail "expected bead detection to ignore draft-approve prose token"
[[ "$detected_beads" != *"child-codex"* ]] || fail "expected bead detection to ignore child-codex prose token"
echo "ok 2 - bead detection ignores prose hyphenated terms"

IFS='|' read -r LONG_REPO LONG_BIN LONG_ORIGIN <<<"$(make_repo long-approval-context)"
FAKE_BIN="$LONG_BIN"
(
  cd "$LONG_REPO"
  git checkout -b mho/long-approval-context >/dev/null
  for i in $(seq 1 30); do
    printf 'line %s\n' "$i" >"file-$i.txt"
    git add "file-$i.txt"
    if [[ "$i" == "1" ]]; then
      git commit -m 'long approval context `pg prepare`' -m 'Captures literal backtick context' >/dev/null
    else
      git commit -m "long approval context $i" >/dev/null
    fi
  done
)
run_helper "$LONG_REPO" prepare \
  --what "long approval context" \
  --why "exercise long branch approval context" \
  --approach "generate approval draft without pipefail SIGPIPE" >/dev/null
long_draft_output=$(PG_AUTO_RUN_APPROVAL=0 run_helper "$LONG_REPO")
expect_contains "$long_draft_output" "Approval script:"
long_draft_yaml=$(extract_path "$long_draft_output" "^Draft file:")
expect_file "$long_draft_yaml"
expect_no_trailing_whitespace "$long_draft_yaml"
echo "ok 3 - long approval context draft does not trip pipefail or whitespace"

IFS='|' read -r REPO FAKE_BIN ORIGIN <<<"$(make_repo existing-pr)"
EXISTING_FAKE_BIN="$FAKE_BIN"
(
  cd "$REPO"
  git checkout -b mho/existing-pr >/dev/null
  printf 'one\n' >feature.txt
  git add feature.txt
  git commit -m "feature start" >/dev/null
)
export PG_TEST_PR_JSON='[{"number":123,"url":"https://example.test/pr/123"}]'
run_helper "$REPO" prepare \
  --what "feature start" \
  --why "exercise durable push-gate lease approval" \
  --approach "use prepared semantic brief before approval" >/dev/null
draft_output=$(run_helper "$REPO" draft-approve)
draft_script=$(extract_path "$draft_output" "^Approval script:")
draft_yaml_file=$(extract_path "$draft_output" "^Draft file:")
draft_file=$(extract_path "$draft_output" "^JSON draft file:")
expect_file "$draft_script"
expect_file "$draft_yaml_file"
expect_file "$draft_file"
expect_no_trailing_whitespace "$draft_yaml_file"
[[ "$(yq eval '.summary.what' "$draft_yaml_file")" == "feature start" ]] \
  || fail "expected YAML approval draft to parse"
[[ "$(yq eval '.machine.description.summary' "$draft_yaml_file")" == "feature start" ]] \
  || fail "expected machine approval draft to retain canonical description"
[[ "$(yq eval '.review.unit' "$draft_yaml_file")" == "pending_push" ]] \
  || fail "expected YAML approval draft to label pending-push review unit"
expect_contains "$(cat "$draft_yaml_file")" "# ---- machine contract below; agents/tools use this ----"
expect_contains "$(cat "$draft_yaml_file")" "user_intent: |-"
[[ "$(jq -r 'keys_unsorted[0:4] | join(",")' "$draft_file")" == "schema_version,description,user_intent,agent_assertion_template" ]] \
  || fail "expected human-readable fields at top of lease draft: $(jq -r 'keys_unsorted[0:6] | join(",")' "$draft_file")"
[[ "$(jq -r '.description.summary' "$draft_file")" == "feature start" ]] \
  || fail "expected description summary in draft"
[[ "$(jq -r '.description.motivation' "$draft_file")" == "exercise durable push-gate lease approval" ]] \
  || fail "expected description motivation in draft"
[[ "$(jq -r '.description.approach' "$draft_file")" == "use prepared semantic brief before approval" ]] \
  || fail "expected description approach in draft"
preview_output=$(printf 'n\n' | EDITOR=true bash "$draft_script" 2>&1 || true)
expect_contains "$preview_output" "Push lease approval"
expect_contains "$preview_output" "PR: #123"
expect_contains "$preview_output" "feature start"
echo "ok 4 - draft script renders readable approval summary"

common_dir=$(current_common_dir "$REPO")
lease_path="$common_dir/push-gate/leases/refs/heads/mho/existing-pr.json"
SUMMARY_WITH_TRAILING_BLANKS=$'feature start from edited description\n\n'
INTENT_WITH_TRAILING_BLANKS=$'edited intent\n\n'
ASSERT_WITH_TRAILING_BLANKS=$'edited assertion\n\n'
SUMMARY_WITH_TRAILING_BLANKS="$SUMMARY_WITH_TRAILING_BLANKS" \
  INTENT_WITH_TRAILING_BLANKS="$INTENT_WITH_TRAILING_BLANKS" \
  ASSERT_WITH_TRAILING_BLANKS="$ASSERT_WITH_TRAILING_BLANKS" \
  yq eval '
    .summary.what = strenv(SUMMARY_WITH_TRAILING_BLANKS)
    | .machine.brief.what = "stale brief field\n\n"
    | .machine.user_intent = strenv(INTENT_WITH_TRAILING_BLANKS)
    | .machine.agent_assertion_template = strenv(ASSERT_WITH_TRAILING_BLANKS)
  ' -i "$draft_yaml_file"
approval_block=$(printf 'y\n' | EDITOR=true bash "$draft_script" 2>&1 || true)
expect_contains "$approval_block" "pg approve requires an interactive terminal"
[[ "$(jq -r '.brief.what' "$draft_file")" == "feature start from edited description" ]] \
  || fail "expected approve to normalize brief from edited description"
[[ "$(jq -r '.description.summary' "$draft_file")" == "feature start from edited description" ]] \
  || fail "expected approve to trim trailing blank lines from description"
[[ "$(jq -r '.user_intent' "$draft_file")" == "edited intent" ]] \
  || fail "expected approve to trim trailing blank lines from user intent"
[[ "$(jq -r '.agent_assertion_template' "$draft_file")" == "edited assertion" ]] \
  || fail "expected approve to trim trailing blank lines from assertion template"
mkdir -p "$(dirname "$lease_path")"
jq '.status = "active" | .updated_at = .created_at | .user_intent = ""' "$draft_file" >"$lease_path"
expect_file "$lease_path"
lease_pr=$(jq -r '.pr_number' "$lease_path")
[[ "$lease_pr" == "123" ]] || fail "expected PR number 123 in lease, got $lease_pr"
[[ "$(jq -r '.description.summary' "$lease_path")" == "feature start from edited description" ]] \
  || fail "expected PR-description-style description to be stored in lease"
echo "ok 5 - noninteractive approval is blocked; lease fixture installed"

raw_output=$(run_guard "$REPO" "git push -u origin mho/existing-pr")
expect_contains "$raw_output" "pg push"
echo "ok 6 - raw git push denied without pending assertion"

run_helper "$REPO" push \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nchange guard + docs\nno rewrite' \
  --set-upstream >/dev/null
remote_feature=$(git -C "$REPO" rev-parse refs/remotes/origin/mho/existing-pr)
[[ "$remote_feature" == "$(current_head "$REPO")" ]] || fail "expected pg push to update origin/mho/existing-pr"
expect_no_file "$common_dir/push-gate/pending/refs/heads/mho/existing-pr.json"
echo "ok 7 - pg push succeeds and clears pending assertion"

(
  cd "$REPO"
  printf 'three\n' >>feature.txt
  git add feature.txt
  git commit -m "feature additive" >/dev/null
)
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
descendant_block=$(run_guard "$REPO" "git push -u origin mho/existing-pr")
expect_contains "$descendant_block" "HEAD changed after approval"
echo "ok 8 - non-async lease blocks descendant push"

jq --arg expires_at "$(future_utc)" '
  .async_iteration = {
    enabled: true,
    mode: "branch",
    expires: "8h",
    expires_at: $expires_at,
    max_pushes: 2,
    used_pushes: 0,
    allow_rewrite: false,
    scope: {
      type: "branch",
      branch_name: .branch_name,
      branch_ref: .branch_ref,
      remote: .remote
    },
    audit: []
  }
' "$lease_path" >"$lease_path.tmp"
mv "$lease_path.tmp" "$lease_path"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
allow_output=$(run_guard "$REPO" "git push -u origin mho/existing-pr")
[[ -z "$allow_output" ]] || fail "expected async guarded push to be allowed, got: $allow_output"
echo "ok 9 - async lease allows descendant push under budget"

write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
head_push_output=$(run_guard "$REPO" "git push -u origin HEAD")
[[ -z "$head_push_output" ]] || fail "expected git push -u origin HEAD to be allowed, got: $head_push_output"
echo "ok 10 - attached-branch git push -u origin HEAD is allowed under async lease"

(
  cd "$REPO"
  approved_anchor=$(jq -r '.approved_anchor' "$lease_path")
  git reset --soft "${approved_anchor}^" >/dev/null
  printf 'four\n' >>feature.txt
  git add feature.txt
  git commit -m "feature rewritten" >/dev/null
)
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
rewrite_output=$(run_guard "$REPO" "git push --force-with-lease origin mho/existing-pr")
expect_contains "$rewrite_output" "async rewrite was not approved"
echo "ok 11 - async rewrite denied unless approved"

jq '.async_iteration.allow_rewrite = true | .async_iteration.used_pushes = 2' \
  "$lease_path" >"$lease_path.tmp"
mv "$lease_path.tmp" "$lease_path"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
budget_output=$(run_guard "$REPO" "git push --force-with-lease origin mho/existing-pr")
expect_contains "$budget_output" "budget exhausted"
echo "ok 12 - async budget exhaustion blocks pushes"

jq '.async_iteration.used_pushes = 0 | .async_iteration.expires_at = "2000-01-01T00:00:00Z"' \
  "$lease_path" >"$lease_path.tmp"
mv "$lease_path.tmp" "$lease_path"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
expired_output=$(run_guard "$REPO" "git push --force-with-lease origin mho/existing-pr")
expect_contains "$expired_output" "expired"
echo "ok 13 - async expiry blocks pushes"

jq --arg expires_at "$(future_utc)" '.async_iteration.expires_at = $expires_at' \
  "$lease_path" >"$lease_path.tmp"
mv "$lease_path.tmp" "$lease_path"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
rewrite_allowed=$(run_guard "$REPO" "git push --force-with-lease origin mho/existing-pr")
[[ -z "$rewrite_allowed" ]] || fail "expected async rewrite to be allowed after approval, got: $rewrite_allowed"
stale_lock="$common_dir/push-gate/locks/refs_heads_mho_existing-pr.lock"
mkdir -p "$stale_lock"
printf '999999\n' >"$stale_lock/pid"
git -C "$REPO" remote set-url origin "$TEST_TMP/missing-origin.git"
set +e
failed_push=$(run_helper "$REPO" push \
  --force-with-lease \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nrewrite branch' 2>&1)
failed_push_rc=$?
set -e
git -C "$REPO" remote set-url origin "$ORIGIN"
[[ "$failed_push_rc" != "0" ]] || fail "expected pg push to fail against missing remote"
[[ "$(jq -r '.async_iteration.used_pushes' "$lease_path")" == "0" ]] \
  || fail "failed git push consumed async budget: $(jq -r '.async_iteration.used_pushes' "$lease_path") output: $failed_push"
expect_no_file "$common_dir/push-gate/pending/refs/heads/mho/existing-pr.json"
[[ ! -e "$stale_lock" ]] || fail "stale push lock was not cleared"
echo "ok 14 - async rewrite allowed when approved and failed pushes do not consume budget"

IFS='|' read -r BOOTSTRAP_REPO BOOTSTRAP_BIN BOOTSTRAP_ORIGIN <<<"$(make_repo bootstrap)"
FAKE_BIN="$BOOTSTRAP_BIN"
(
  cd "$BOOTSTRAP_REPO"
  git checkout -b mho/bootstrap >/dev/null
  printf 'bootstrap\n' >bootstrap.txt
  git add bootstrap.txt
  git commit -m "bootstrap start" >/dev/null
)
export PG_TEST_PR_JSON='[]'
run_helper "$BOOTSTRAP_REPO" prepare \
  --what "bootstrap start" \
  --why "exercise new branch push-gate lease flow" \
  --approach "use prepared semantic brief before approval" >/dev/null
bootstrap_output=$(run_helper "$BOOTSTRAP_REPO" draft-approve)
bootstrap_script=$(extract_path "$bootstrap_output" "^Approval script:")
bootstrap_draft=$(extract_path "$bootstrap_output" "^JSON draft file:")
bootstrap_common_dir=$(current_common_dir "$BOOTSTRAP_REPO")
bootstrap_lease="$bootstrap_common_dir/push-gate/leases/refs/heads/mho/bootstrap.json"
bootstrap_block=$(printf 'y\n' | EDITOR=true bash "$bootstrap_script" 2>&1 || true)
expect_contains "$bootstrap_block" "pg approve requires an interactive terminal"
mkdir -p "$(dirname "$bootstrap_lease")"
jq '.status = "active" | .updated_at = .created_at | .user_intent = ""' "$bootstrap_draft" >"$bootstrap_lease"
write_pending "$BOOTSTRAP_REPO" "origin" "refs/heads/mho/bootstrap" "$(current_head "$BOOTSTRAP_REPO")" ""
bootstrap_allow=$(run_guard "$BOOTSTRAP_REPO" "git push -u origin mho/bootstrap")
[[ -z "$bootstrap_allow" ]] || fail "expected bootstrap push to be allowed, got: $bootstrap_allow"
export PG_TEST_PR_JSON='[{"number":55,"url":"https://example.test/pr/55"}]'
run_helper "$BOOTSTRAP_REPO" bind-pr --auto >/dev/null
export PG_TEST_PR_JSON='[{"number":99,"url":"https://example.test/pr/99"}]'
write_pending "$BOOTSTRAP_REPO" "origin" "refs/heads/mho/bootstrap" "$(current_head "$BOOTSTRAP_REPO")" "55"
pr_mismatch=$(run_guard "$BOOTSTRAP_REPO" "git push -u origin mho/bootstrap")
expect_contains "$pr_mismatch" "PR"
echo "ok 15 - bootstrap lease binds PR later and mismatched PR is denied"

export PG_TEST_PR_JSON='[{"number":123,"url":"https://example.test/pr/123"}]'
FAKE_BIN="$EXISTING_FAKE_BIN"
write_pending "$REPO" "origin" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
upstream_block=$(run_guard "$REPO" "git push upstream HEAD:main")
expect_contains "$upstream_block" "upstream/main"
origin_block=$(run_guard "$REPO" "git push origin HEAD:main")
expect_contains "$origin_block" "origin/main"
echo "ok 16 - protected main pushes are blocked on origin and upstream"

(
  cd "$REPO"
  git remote add upstream "$ORIGIN"
  git fetch upstream main >/dev/null 2>&1
  git branch --set-upstream-to=upstream/main mho/existing-pr >/dev/null
)
plain_main_upstream=$(run_guard "$REPO" "git push")
expect_contains "$plain_main_upstream" "tracks upstream/main"
(
  cd "$REPO"
  git branch --set-upstream-to=origin/mho/existing-pr mho/existing-pr >/dev/null
)
echo "ok 17 - plain push is blocked when feature branch tracks upstream main"

upstream_draft=$(run_helper "$REPO" draft-approve \
  --remote upstream \
  --intent $'allow upstream branch push\nsame branch\nsame pr' \
  --assert-flow $'update pr #123\nbranch mho/existing-pr\nremote upstream\nno rewrite')
upstream_script=$(extract_path "$upstream_draft" "^Approval script:")
upstream_draft_file=$(extract_path "$upstream_draft" "^JSON draft file:")
upstream_block=$(printf 'y\n' | EDITOR=true bash "$upstream_script" 2>&1 || true)
expect_contains "$upstream_block" "Approval blocked"
jq '.status = "active" | .updated_at = .created_at | .user_intent = ""' "$upstream_draft_file" >"$lease_path"
write_pending "$REPO" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$REPO")" "123"
upstream_feature=$(run_guard "$REPO" "git push upstream mho/existing-pr")
[[ -z "$upstream_feature" ]] || fail "expected upstream feature push to be allowed, got: $upstream_feature"
echo "ok 18 - upstream feature push allowed with matching lease"

(
  cd "$REPO"
  git branch temp/upstream-source >/dev/null
  git worktree add "$TEST_TMP/upstream-worktree" temp/upstream-source >/dev/null
)
WORKTREE="$TEST_TMP/upstream-worktree"
write_pending "$WORKTREE" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$WORKTREE")" "123"
worktree_refspec=$(run_guard "$WORKTREE" "git push upstream temp/upstream-source:mho/existing-pr")
[[ -z "$worktree_refspec" ]] || fail "expected worktree explicit refspec push to be allowed, got: $worktree_refspec"
echo "ok 19 - worktree explicit refspec push is allowed"

(
  cd "$WORKTREE"
  git checkout --detach >/dev/null
)
write_pending "$WORKTREE" "upstream" "refs/heads/mho/existing-pr" "$(current_head "$WORKTREE")" "123"
detached_refspec=$(run_guard "$WORKTREE" "git push upstream HEAD:mho/existing-pr")
[[ -z "$detached_refspec" ]] || fail "expected detached HEAD explicit refspec push to be allowed, got: $detached_refspec"
echo "ok 20 - detached HEAD explicit refspec push is allowed"

detached_head=$(run_guard "$WORKTREE" "git push upstream HEAD")
expect_contains "$detached_head" "explicit target branch"
[[ "$detached_head" != *"git branch context"* ]] || fail "expected detached HEAD denial to avoid generic branch-context message, got: $detached_head"
echo "ok 21 - detached HEAD without explicit target gets accurate denial"

(
  cd "$REPO"
  git worktree add "$TEST_TMP/existing-pr-view" main >/dev/null
)
shared_view=$(run_helper "$TEST_TMP/existing-pr-view" show mho/existing-pr)
expect_contains "$shared_view" "mho/existing-pr"
expect_contains "$shared_view" "123"
echo "ok 22 - leases are visible across worktrees via git-common-dir"

IFS='|' read -r TOPO_REPO TOPO_BIN TOPO_ORIGIN <<<"$(make_repo topology-write)"
FAKE_BIN="$TOPO_BIN"
(
  cd "$TOPO_REPO"
  git checkout -b mho/topology-write >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-write.git
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-write":{"viewerPermission":"WRITE"}}'
topo_output=$(run_helper "$TOPO_REPO" draft-approve \
  --intent $'allow topology write\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-write\nno rewrite')
topo_draft=$(extract_path "$topo_output" "^JSON draft file:")
[[ "$(jq -r '.remote' "$topo_draft")" == "upstream" ]] || fail "expected writable-upstream default remote to be upstream"
[[ "$(jq -r '.pr_repo' "$topo_draft")" == "example.test/Netflix-Skunkworks/topology-write" ]] || fail "expected pr_repo to default to upstream topology"
echo "ok 23 - topology picks upstream PR repo and upstream push remote when writable"

IFS='|' read -r TOPO_READ_REPO TOPO_READ_BIN TOPO_READ_ORIGIN <<<"$(make_repo topology-read)"
FAKE_BIN="$TOPO_READ_BIN"
(
  cd "$TOPO_READ_REPO"
  git checkout -b mho/topology-read >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-read.git
)
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-read":{"viewerPermission":"READ"}}'
topo_read_output=$(run_helper "$TOPO_READ_REPO" draft-approve \
  --intent $'allow topology read\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-read\nno rewrite')
topo_read_draft=$(extract_path "$topo_read_output" "^JSON draft file:")
[[ "$(jq -r '.remote' "$topo_read_draft")" == "origin" ]] || fail "expected non-writable upstream to fall back to origin push remote"
[[ "$(jq -r '.pr_repo' "$topo_read_draft")" == "example.test/Netflix-Skunkworks/topology-read" ]] || fail "expected pr_repo to stay on upstream even when push remote falls back"
echo "ok 24 - topology falls back to origin push remote when upstream is not writable"

IFS='|' read -r TOPO_TRACK_REPO TOPO_TRACK_BIN TOPO_TRACK_ORIGIN <<<"$(make_repo topology-track)"
FAKE_BIN="$TOPO_TRACK_BIN"
(
  cd "$TOPO_TRACK_REPO"
  git checkout -b mho/topology-track >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git push -u origin mho/topology-track >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-track.git
)
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-track":{"viewerPermission":"WRITE"}}'
topo_track_output=$(run_helper "$TOPO_TRACK_REPO" draft-approve \
  --intent $'allow topology track\nsame branch' \
  --assert-flow $'update pr line\nbranch mho/topology-track\nno rewrite')
topo_track_draft=$(extract_path "$topo_track_output" "^JSON draft file:")
[[ "$(jq -r '.remote' "$topo_track_draft")" == "origin" ]] || fail "expected tracked branch to keep origin remote"
echo "ok 25 - tracked branch keeps existing remote instead of auto-flipping to upstream"

IFS='|' read -r PR_BASE_REPO PR_BASE_BIN PR_BASE_ORIGIN <<<"$(make_repo pr-base-scope)"
FAKE_BIN="$PR_BASE_BIN"
(
  cd "$PR_BASE_REPO"
  git checkout -b mho/pr-base >/dev/null
  printf 'old pr\n' >pr-base.txt
  git add pr-base.txt
  git commit -m "old pr work" >/dev/null
  git push -u origin mho/pr-base >/dev/null

  git checkout main >/dev/null
  printf 'landed\n' >landed.txt
  git add landed.txt
  git commit -m "landed main work" >/dev/null
  git push origin main >/dev/null

  git checkout mho/pr-base >/dev/null
  git rebase origin/main >/dev/null
  printf 'new pr\n' >>pr-base.txt
  git add pr-base.txt
  git commit -m "new pr work" >/dev/null
)
export PG_TEST_PR_JSON='[{"number":181,"url":"https://example.test/pr/181","baseRefName":"main"}]'
pr_base_output=$(run_helper "$PR_BASE_REPO" draft-approve \
  --intent $'update pr #181\nsame branch\nno unrelated changes' \
  --assert-flow $'update pr #181\nbranch mho/pr-base\nno rewrite')
pr_base_draft=$(extract_path "$pr_base_output" "^JSON draft file:")
[[ "$(jq -r '.approved_scope.base_ref' "$pr_base_draft")" == "refs/remotes/origin/main" ]] \
  || fail "expected PR approval scope to use PR base origin/main, got $(jq -r '.approved_scope.base_ref' "$pr_base_draft")"
echo "ok 26 - existing PR approval scope uses GitHub PR base instead of tracking branch"

IFS='|' read -r FBA_BASE_REPO FBA_BASE_BIN FBA_BASE_ORIGIN <<<"$(make_repo fba-delivery-base fun-bash-automations)"
FAKE_BIN="$FBA_BASE_BIN"
(
  cd "$FBA_BASE_REPO"
  git checkout -b mh-netflix >/dev/null
  printf 'delivery\n' >delivery.txt
  git add delivery.txt
  git commit -m "delivery branch baseline" >/dev/null
  git push -u origin mh-netflix >/dev/null

  git checkout main >/dev/null
  printf 'main only\n' >main-only.txt
  git add main-only.txt
  git commit -m "main only work" >/dev/null
  git push origin main >/dev/null

  git checkout mh-netflix >/dev/null
  printf 'pending\n' >>delivery.txt
  git add delivery.txt
  git commit -m "pending delivery work" >/dev/null
)
export PG_TEST_PR_JSON='[{"number":3,"url":"https://example.test/pr/3","baseRefName":"main"}]'
fba_base_output=$(run_helper "$FBA_BASE_REPO" draft-approve \
  --intent $'update fun-bash-automations delivery branch\nsame branch\nno rewrite' \
  --assert-flow $'update fun-bash-automations delivery branch\nbranch mh-netflix\nno rewrite')
fba_base_draft=$(extract_path "$fba_base_output" "^JSON draft file:")
[[ "$(jq -r '.approved_scope.base_ref' "$fba_base_draft")" == "origin/mh-netflix" ]] \
  || fail "expected fun-bash-automations mh-netflix to use upstream base, got $(jq -r '.approved_scope.base_ref' "$fba_base_draft")"
echo "ok 27 - fun-bash-automations mh-netflix ignores stale PR base and uses tracking branch"

IFS='|' read -r TOPO_BIND_REPO TOPO_BIND_BIN TOPO_BIND_ORIGIN <<<"$(make_repo topology-bind)"
FAKE_BIN="$TOPO_BIND_BIN"
(
  cd "$TOPO_BIND_REPO"
  git checkout -b mho/topology-bind >/dev/null
  printf 'topology\n' >topology.txt
  git add topology.txt
  git commit -m "topology start" >/dev/null
  git remote add upstream git@example.test:Netflix-Skunkworks/topology-bind.git
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
export PG_TEST_REPO_VIEW_MAP='{"example.test/Netflix-Skunkworks/topology-bind":{"viewerPermission":"READ"}}'
topo_bind_output=$(run_helper "$TOPO_BIND_REPO" draft-approve \
  --intent $'allow topology bind\nsame branch' \
  --assert-flow $'new pr flow\nbranch mho/topology-bind\nno rewrite')
topo_bind_script=$(extract_path "$topo_bind_output" "^Approval script:")
topo_bind_draft=$(extract_path "$topo_bind_output" "^JSON draft file:")
topo_bind_common=$(current_common_dir "$TOPO_BIND_REPO")
topo_bind_lease="$topo_bind_common/push-gate/leases/refs/heads/mho/topology-bind.json"
topo_bind_block=$(printf 'y\n' | EDITOR=true bash "$topo_bind_script" 2>&1 || true)
expect_contains "$topo_bind_block" "Approval blocked"
mkdir -p "$(dirname "$topo_bind_lease")"
jq '.status = "active" | .updated_at = .created_at | .user_intent = ""' "$topo_bind_draft" >"$topo_bind_lease"
export PG_TEST_PR_LIST_MAP='{"example.test/Netflix-Skunkworks/topology-bind|mho/topology-bind":[{"number":77,"url":"https://example.test/pr/77"}]}'
run_helper "$TOPO_BIND_REPO" bind-pr --auto >/dev/null
[[ "$(jq -r '.pr_number' "$topo_bind_lease")" == "77" ]] || fail "expected bind-pr to use upstream pr_repo and bind PR #77"
[[ "$(jq -r '.pr_repo' "$topo_bind_lease")" == "example.test/Netflix-Skunkworks/topology-bind" ]] || fail "expected bound lease to retain upstream pr_repo"
echo "ok 28 - bind-pr uses topology-selected upstream PR repo"

IFS='|' read -r LOW_REPO LOW_BIN LOW_ORIGIN <<<"$(make_repo low-stakes)"
FAKE_BIN="$LOW_BIN"
(
  cd "$LOW_REPO"
  git checkout -b mho/low-stakes >/dev/null
  printf 'low stakes\n' >low-stakes.txt
  git add low-stakes.txt
  git commit -m "low stakes start" >/dev/null
)
low_prepare_output=$(run_helper "$LOW_REPO" prepare \
  --what "low stakes start" \
  --why "exercise reviewed low-stakes async defaults" \
  --approach "use shorthand profile without skipping approval" \
  --low-stakes)
low_prepare_path=$(extract_path "$low_prepare_output" "^Prepared brief written:")
[[ "$(jq -r '.async_iteration.enabled' "$low_prepare_path")" == "true" ]] \
  || fail "expected low-stakes prepare to enable async"
[[ "$(jq -r '.async_iteration.expires' "$low_prepare_path")" == "1h" ]] \
  || fail "expected low-stakes prepare to default expires to 1h"
[[ "$(jq -r '.async_iteration.max_pushes' "$low_prepare_path")" == "5" ]] \
  || fail "expected low-stakes prepare to default max_pushes to 5"
low_draft_output=$(run_helper "$LOW_REPO" draft-approve)
low_script=$(extract_path "$low_draft_output" "^Approval script:")
low_draft_file=$(extract_path "$low_draft_output" "^JSON draft file:")
[[ "$(jq -r '.async_iteration.enabled' "$low_draft_file")" == "true" ]] \
  || fail "expected low-stakes draft to carry async"
[[ "$(jq -r '.async_iteration.scope.branch_name' "$low_draft_file")" == "mho/low-stakes" ]] \
  || fail "expected low-stakes draft to scope branch"
expect_contains "$(cat "$low_script")" "review-diff --base"
expect_contains "$(cat "$low_script")" "-C \"\$REPO_ROOT\""
echo "ok 29 - low-stakes prepare creates reviewed short async lease draft with automatic diff review"

yes_draft_output=$(run_helper "$LOW_REPO" --yes)
yes_script=$(extract_path "$yes_draft_output" "^Approval script:")
yes_output=$(EDITOR=true bash "$yes_script" 2>&1 || true)
expect_contains "$yes_output" "Skipping Diffview review: non-interactive shell."
expect_contains "$yes_output" "Proceed: yes (--yes, after editor review)"
expect_contains "$yes_output" "pg approve requires an interactive terminal"
[[ "$yes_output" != *"Proceed? [Y/n]"* ]] || fail "expected --yes to skip final prompt"
echo "ok 30 - --yes skips final prompt but still requires editor and tty approval"

review_diff_json=$(run_helper "$LOW_REPO" review-diff --json --no-tmux)
[[ "$(jq -r '.diff.branch' <<<"$review_diff_json")" == "mho/low-stakes" ]] \
  || fail "expected review-diff branch metadata: $review_diff_json"
[[ "$(jq -r '.diff.label' <<<"$review_diff_json")" == "pending-push" ]] \
  || fail "expected review-diff to label pending-push diff: $review_diff_json"
[[ "$(jq -r '.diff.full_review.label' <<<"$review_diff_json")" == "full-review" ]] \
  || fail "expected review-diff to expose separate full-review diff: $review_diff_json"
[[ "$(jq -r '.reviewer.tool' <<<"$review_diff_json")" == "diffview.nvim" ]] \
  || fail "expected review-diff to target Diffview.nvim: $review_diff_json"
expect_contains "$(jq -r '.reviewer.command' <<<"$review_diff_json")" "DiffviewOpen"
expect_contains "$(jq -r '.reviewer.command' <<<"$review_diff_json")" "review-tools.vim"
expect_contains "$(jq -r '.reviewer.comments_command' <<<"$review_diff_json")" "Space g c"
expect_contains "$(jq -r '.reviewer.exit_command' <<<"$review_diff_json")" ":PgReviewDone"
expect_contains "$(jq -r '.reviewer.layout_command' <<<"$review_diff_json")" "Space r l"
expect_contains "$(jq -r '.reviewer.unified_diff_command' <<<"$review_diff_json")" "Space r u"
expect_contains "$(jq -r '.reviewer.ai_review_command' <<<"$review_diff_json")" "Space 9 s"
expect_contains "$(jq -r '.reviewer.suggested_edit_command' <<<"$review_diff_json")" "Space 9 v"
[[ "$(jq -r '.diff.review_unit.scope' <<<"$review_diff_json")" == "branch" ]] \
  || fail "expected review-diff to expose branch review unit: $review_diff_json"
review_script=$(jq -r '.reviewer.vimscript' <<<"$review_diff_json")
expect_contains "$(cat "$review_script")" "command! PgReviewDone"
expect_contains "$(cat "$review_script")" "function! PgReviewAddComment"
expect_contains "$(cat "$review_script")" "function! PgReviewClarifyComment"
expect_contains "$(cat "$review_script")" "function! PgReviewSubmitComment"
expect_contains "$(cat "$review_script")" "function! PgReviewThreadStart"
expect_contains "$(cat "$review_script")" "function! PgReviewThreadAskCodex"
expect_contains "$(cat "$review_script")" "function! PgReviewThreadReplyPrompt"
expect_contains "$(cat "$review_script")" "function! PgReviewThreadAccept"
expect_contains "$(cat "$review_script")" "function! PgReviewCodexLastMessage"
expect_contains "$(cat "$review_script")" "--output-last-message"
expect_contains "$(cat "$review_script")" "PgReviewCodexLastMessage(l:prompt, 'low')"
expect_contains "$(cat "$review_script")" "PgReviewCodexLastMessage(PgReviewThreadPrompt(), 'low')"
expect_contains "$(cat "$review_script")" "a accept/save  r reply/refine  e edit/save  q cancel"
expect_contains "$(cat "$review_script")" "strftime('%Y-%m-%dT%H:%M:%SZ', localtime())"
if grep -Fq "strftime('%Y-%m-%dT%H:%M:%SZ', localtime(), 1)" "$review_script"; then
  fail "expected PgReviewThreadNewMessage to avoid unsupported three-arg strftime"
fi
expect_contains "$(cat "$review_script")" "function! PgReviewCommentPrompt"
expect_contains "$(cat "$review_script")" "Window.capture_input(\"Review Comment\""
expect_contains "$(cat "$review_script")" "Window.capture_input(title"
expect_contains "$(cat "$review_script")" "model_reasoning_effort=\"' . a:effort . '\""
expect_contains "$(cat "$review_script")" "AI clarification (fast)"
expect_contains "$(cat "$review_script")" "Human ask:"
expect_contains "$(cat "$review_script")" "Requested change:"
expect_contains "$(cat "$review_script")" "Acceptance criteria:"
expect_contains "$(cat "$review_script")" "break down exactly what the reviewer is asking for"
expect_contains "$(cat "$review_script")" "function! PgReviewInstallMaps"
expect_contains "$(cat "$review_script")" "autocmd BufEnter,WinEnter * call PgReviewInstallMaps()"
expect_contains "$(cat "$review_script")" "nnoremap <buffer><nowait> q :PgReviewDone<CR>"
expect_contains "$(cat "$review_script")" "nnoremap <buffer><nowait> <Space>qr :PgReviewDone<CR>"
if grep -Fqx "nnoremap <buffer><nowait> <Space>q :PgReviewDone<CR>" "$review_script"; then
  fail "expected Space q to remain unmapped for review exit"
fi
expect_contains "$(cat "$review_script")" "nnoremap <buffer><nowait> <Space>gc :call PgReviewCommentPrompt()<CR>"
expect_contains "$(cat "$review_script")" "nnoremap <buffer><nowait> gc :call PgReviewCommentPrompt()<CR>"
expect_contains "$(cat "$review_script")" "xnoremap <buffer><nowait> gc :<C-U>call PgReviewCommentPrompt()<CR>"
expect_contains "$(cat "$review_script")" "nmap <buffer><nowait> <Space>rl g<C-x>"
expect_contains "$(cat "$review_script")" "function! PgReviewUnifiedDiff"
expect_contains "$(cat "$review_script")" "nnoremap <buffer><nowait> <Space>ru"
expect_contains "$(cat "$review_script")" "--review-unit-json"
expect_contains "$(cat "$review_script")" "function! PgReviewVisualRange"
expect_contains "$(cat "$review_script")" "command! -range -nargs=+ PgReviewSuggestedEdit"
expect_contains "$(cat "$review_script")" "xnoremap <buffer><nowait> <Space>gv"
expect_contains "$(cat "$review_script")" "function! PgReviewCodexSuggestedEditFromVisual"
expect_contains "$(cat "$review_script")" "xnoremap <buffer><nowait> <Space>9v"
expect_contains "$(cat "$review_script")" "--dangerously-bypass-approvals-and-sandbox"
thread_smoke_comments="$TEST_TMP/thread-smoke-comments.json"
PG_TEST_CODEX_RESPONSE='Human ask: transformed by fake Codex' PATH="$FAKE_BIN:$PATH" nvim --headless -u NONE -S "$review_script" \
  "+let g:pg_review_comments_file = '$thread_smoke_comments'" \
  '+call PgReviewThreadNewMessage("reviewer", "rough ask")' \
  '+call PgReviewThreadStart("low-stakes.txt", 1, "low stakes", "tighten this")' \
  '+if !exists("g:pg_review_thread") | cquit | endif' \
  '+call PgReviewThreadReply("make it concrete")' \
  '+call PgReviewThreadSaveEdited("Final request")' \
  '+qall'
thread_smoke_json=$(jq -s '.' "$thread_smoke_comments")
[[ "$(jq -r '.[0].thread | length' <<<"$thread_smoke_json")" == "5" ]] \
  || fail "expected headless review thread smoke to persist transcript: $thread_smoke_json"
[[ "$(jq -r '[.[0].thread[] | select(.role == "codex" and (.body | contains("transformed by fake Codex")))] | length' <<<"$thread_smoke_json")" == "2" ]] \
  || fail "expected headless review thread smoke to capture Codex last message: $thread_smoke_json"
[[ "$(jq -r '.[0].body' <<<"$thread_smoke_json")" == *"Final request"* ]] \
  || fail "expected headless review thread smoke to persist edited final request: $thread_smoke_json"
review_command=$(run_helper "$LOW_REPO" review-diff --print-command --no-tmux)
expect_contains "$review_command" "DiffviewOpen"
expect_contains "$review_command" "PG_REVIEW_COMMENTS_FILE="
echo "ok 31 - review-diff exposes exact Diffview command without launching UI"

comments_file=$(jq -r '.diff.comments_file' <<<"$review_diff_json")
add_comment_output=$(run_helper "$LOW_REPO" review-comments add \
  --comments-file "$comments_file" \
  --head "$(jq -r '.diff.head' <<<"$review_diff_json")" \
  --file "low-stakes.txt" \
  --line 1 \
  --thread-json '[{"role":"reviewer","body":"too vague"},{"role":"codex","body":"Human ask: tighten wording"}]' \
  --body "tighten wording")
expect_contains "$add_comment_output" "Recorded review comment: low-stakes.txt:1"
comments_json=$(run_helper "$LOW_REPO" review-comments --json)
[[ "$(jq -r '.supported' <<<"$comments_json")" == "true" ]] \
  || fail "expected review-comments to parse export: $comments_json"
[[ "$(jq -r '.counts.unresolved' <<<"$comments_json")" == "1" ]] \
  || fail "expected one unresolved review comment: $comments_json"
[[ "$(jq -r '.comments[0].file' <<<"$comments_json")" == "low-stakes.txt" ]] \
  || fail "expected normalized review comment file: $comments_json"
[[ "$(jq -r '.comments[0].type' <<<"$comments_json")" == "comment" ]] \
  || fail "expected typed review comment: $comments_json"
[[ "$(jq -r '.comments[0].review_unit.scope' <<<"$comments_json")" == "branch" ]] \
  || fail "expected branch-scoped review comment: $comments_json"
[[ "$(jq -r '.comments[0].thread | length' <<<"$comments_json")" == "2" ]] \
  || fail "expected review comment thread transcript: $comments_json"
[[ "$(jq -r '.comments[0].thread[1].body' <<<"$comments_json")" == "Human ask: tighten wording" ]] \
  || fail "expected review comment thread body: $comments_json"
status_json=$(run_helper "$LOW_REPO" review-comments status --json)
[[ "$(jq -r '.counts.unresolved' <<<"$status_json")" == "1" ]] \
  || fail "expected review-comments status to report unresolved comment: $status_json"
[[ "$(jq -r '.review_units[0].scope' <<<"$status_json")" == "branch" ]] \
  || fail "expected review-comments status to group by review unit: $status_json"
suggested_edit_output=$(run_helper "$LOW_REPO" review-comments add \
  --comments-file "$comments_file" \
  --head "$(jq -r '.diff.head' <<<"$review_diff_json")" \
  --file "low-stakes.txt" \
  --line 1 \
  --end-line 1 \
  --type suggested_edit \
  --selected-text "low stakes" \
  --suggestion "Use clearer wording")
expect_contains "$suggested_edit_output" "Recorded review comment: low-stakes.txt:1"
suggested_comments_json=$(run_helper "$LOW_REPO" review-comments --json)
[[ "$(jq -r '.comments | map(select(.type == "suggested_edit")) | length' <<<"$suggested_comments_json")" == "1" ]] \
  || fail "expected suggested_edit review comment: $suggested_comments_json"
[[ "$(jq -r '.comments[] | select(.type == "suggested_edit") | .selected_text' <<<"$suggested_comments_json")" == "low stakes" ]] \
  || fail "expected suggested_edit selected text: $suggested_comments_json"
[[ "$(jq -r '.comments[] | select(.type == "suggested_edit") | .suggestion' <<<"$suggested_comments_json")" == "Use clearer wording" ]] \
  || fail "expected suggested_edit suggestion: $suggested_comments_json"
low_common_dir=$(current_common_dir "$LOW_REPO")
low_lease_path="$low_common_dir/push-gate/leases/refs/heads/mho/low-stakes.json"
mkdir -p "$(dirname "$low_lease_path")"
jq '.status = "active" | .updated_at = .created_at' "$low_draft_file" >"$low_lease_path"
check_comments_json=$(run_helper "$LOW_REPO" check)
[[ "$(jq -r '.local_review.counts.unresolved' <<<"$check_comments_json")" == "2" ]] \
  || fail "expected pg check to surface unresolved local review comments: $check_comments_json"
(
  cd "$LOW_REPO"
  printf 'new head\n' >>low-stakes.txt
  git add low-stakes.txt
  git commit -m "low stakes followup" >/dev/null
)
stale_comments_json=$(run_helper "$LOW_REPO" review-comments --json)
[[ "$(jq -r '.stale' <<<"$stale_comments_json")" == "true" ]] \
  || fail "expected review comments to become stale after HEAD changes: $stale_comments_json"
[[ "$(jq -r '.counts.stale' <<<"$stale_comments_json")" == "2" ]] \
  || fail "expected stale comment count after HEAD changes: $stale_comments_json"
echo "ok 32 - review-comments records local comments and marks stale after HEAD changes"

IFS='|' read -r STALE_REPO STALE_BIN STALE_ORIGIN <<<"$(make_repo stale-review-base)"
FAKE_BIN="$STALE_BIN"
(
  cd "$STALE_REPO"
  git checkout -b mho/stale-review-base >/dev/null
  printf 'feature\n' >feature.txt
  git add feature.txt
  git commit -m "feature before upstream moves" >/dev/null
)
UPDATER="$TEST_TMP/stale-review-base-updater"
git clone "$STALE_ORIGIN" "$UPDATER" >/dev/null 2>&1
(
  cd "$UPDATER"
  git config user.name "Push Gate Test"
  git config user.email "push-gate@test"
  printf 'upstream\n' >>README.md
  git add README.md
  git commit -m "advance main" >/dev/null
  git push origin main >/dev/null
)
stale_base_output=$(run_helper "$STALE_REPO" review-diff --json --no-tmux 2>&1) && stale_base_rc=0 || stale_base_rc=$?
[[ "$stale_base_rc" != "0" ]] || fail "expected stale review base to block Diffview"
expect_contains "$stale_base_output" "Review pending-push base moved after fetch"
(
  cd "$STALE_REPO"
  git rebase refs/remotes/origin/main >/dev/null
)
fresh_base_json=$(run_helper "$STALE_REPO" review-diff --json --no-tmux)
[[ "$(jq -r '.diff.base_freshness.allowed' <<<"$fresh_base_json")" == "true" ]] \
  || fail "expected rebased branch to pass review base freshness: $fresh_base_json"
echo "ok 33 - review-diff blocks stale upstream base before Diffview"

IFS='|' read -r STACK_REPO STACK_BIN STACK_ORIGIN <<<"$(make_repo stacked-review-base)"
FAKE_BIN="$STACK_BIN"
(
  cd "$STACK_REPO"
  git checkout -b mho/parent >/dev/null
  printf 'parent\n' >parent.txt
  git add parent.txt
  git commit -m "parent change" >/dev/null
  git push -u origin mho/parent >/dev/null
  git checkout -b mho/child >/dev/null
  printf 'child\n' >child.txt
  git add child.txt
  git commit -m "child change" >/dev/null
)
PG_TEST_PR_LIST_MAP='{"|mho/parent":[{"number":7}]}'
stack_base_json=$(run_helper "$STACK_REPO" review-diff --json --no-tmux)
unset PG_TEST_PR_LIST_MAP
[[ "$(jq -r '.diff.base' <<<"$stack_base_json")" == "refs/remotes/origin/mho/parent" ]] \
  || fail "expected stacked branch review to use parent base, not origin/main: $stack_base_json"
stack_item_json=$(run_helper "$STACK_REPO" review-diff --json --no-tmux \
  --base "refs/remotes/origin/mho/parent" \
  --head HEAD \
  --scope stack_item \
  --stack demo-stack \
  --stack-item child-layer)
[[ "$(jq -r '.diff.review_unit.scope' <<<"$stack_item_json")" == "stack_item" ]] \
  || fail "expected stack-item review scope: $stack_item_json"
[[ "$(jq -r '.diff.review_unit.stack_item' <<<"$stack_item_json")" == "child-layer" ]] \
  || fail "expected stack item id in review metadata: $stack_item_json"
expect_contains "$(cat "$(jq -r '.reviewer.vimscript' <<<"$stack_item_json")")" "g:pg_review_unit_json"
echo "ok 34 - review-diff uses stacked parent base when present"

queue_json=$(run_helper "$LOW_REPO" queue --json)
[[ "$(jq -r '.prepared | length >= 1' <<<"$queue_json")" == "true" ]] \
  || fail "expected queue to include prepared briefs: $queue_json"
[[ "$(jq -r '.leases | type' <<<"$queue_json")" == "array" ]] \
  || fail "expected queue to include leases array: $queue_json"
echo "ok 35 - queue reports prepared briefs and active leases"

approve_all_output=$(run_helper "$LOW_REPO" approve-all -C "$LOW_REPO" 2>&1) && approve_all_rc=0 || approve_all_rc=$?
[[ "$approve_all_rc" != "0" ]] || fail "expected approve-all to require an interactive terminal"
expect_contains "$approve_all_output" "requires an interactive terminal"
echo "ok 36 - approve-all cannot be used as a noninteractive approval bypass"

IFS='|' read -r INFER_REPO INFER_BIN INFER_ORIGIN <<<"$(make_repo inference-disabled)"
FAKE_BIN="$INFER_BIN"
(
  cd "$INFER_REPO"
  git checkout -b mho/inference-disabled >/dev/null
  printf 'inference disabled\n' >inference-disabled.txt
  git add inference-disabled.txt
  git commit -m "inference disabled start" >/dev/null
)
set +e
inference_output=$(PG_ALLOW_INFERENCE=1 run_helper "$INFER_REPO" draft-approve 2>&1)
inference_rc=$?
set -e
[[ "$inference_rc" != "0" ]] || fail "expected PG_ALLOW_INFERENCE draft approval to be rejected"
expect_contains "$inference_output" "PG_ALLOW_INFERENCE is no longer accepted"
expect_contains "$inference_output" "pg prepare required"
echo "ok 37 - PG_ALLOW_INFERENCE is disabled as an agent-facing bypass"

IFS='|' read -r STACK_BASE_REPO STACK_BASE_BIN STACK_BASE_ORIGIN <<<"$(make_repo stacked-parent-base)"
FAKE_BIN="$STACK_BASE_BIN"
(
  cd "$STACK_BASE_REPO"
  git checkout -b mho/parent-feature >/dev/null
  printf 'parent\n' >parent.txt
  git add parent.txt
  git commit -m "parent feature work" >/dev/null
  git push -u origin mho/parent-feature >/dev/null

  git checkout -b mho/child-hook >/dev/null
  git branch --unset-upstream >/dev/null 2>&1 || true
  printf 'child\n' >child-hook.txt
  git add child-hook.txt
  git commit -m "child hook work" >/dev/null
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP='{"mho/parent-feature":[{"number":77,"url":"https://example.test/pr/77","baseRefName":"main"}],"mho/child-hook":[]}'
stack_base_output=$(run_helper "$STACK_BASE_REPO" draft-approve \
  --intent $'child hook work\nsame child branch\nexclude parent branch from scope' \
  --assert-flow $'new child pr flow\nbranch mho/child-hook\nbase parent feature')
stack_base_draft=$(extract_path "$stack_base_output" "^JSON draft file:")
[[ "$(jq -r '.approved_scope.base_ref' "$stack_base_draft")" == "refs/remotes/origin/mho/parent-feature" ]] \
  || fail "expected stacked child approval scope to use parent PR branch, got $(jq -r '.approved_scope.base_ref' "$stack_base_draft")"
echo "ok 38 - stacked child without upstream uses closest open parent PR branch as approval base"

IFS='|' read -r ASYNC_WORK_REPO ASYNC_WORK_BIN ASYNC_WORK_ORIGIN <<<"$(make_repo async-work-package)"
FAKE_BIN="$ASYNC_WORK_BIN"
(
  cd "$ASYNC_WORK_REPO"
  git checkout -b mho/async-work-package >/dev/null
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
run_helper "$ASYNC_WORK_REPO" prepare \
  --async \
  --expires 8h \
  --max-pushes 6 \
  --what "Build widget-review push-gate async feature" \
  --why "allow reviewed async feature building while human is unavailable" \
  --approach "add widget-review implementation files, regression tests, and docs under the reviewed package" >/dev/null
async_work_output=$(run_helper "$ASYNC_WORK_REPO" draft-approve)
async_work_draft=$(extract_path "$async_work_output" "^JSON draft file:")
[[ "$(jq -r '.approved_scope.work_package.enabled' "$async_work_draft")" == "true" ]] \
  || fail "expected async draft to include reviewed work package scope"
[[ "$(jq -r '.approved_scope.paths | length' "$async_work_draft")" == "0" ]] \
  || fail "expected async work package fixture to start with no changed paths"
async_work_common=$(current_common_dir "$ASYNC_WORK_REPO")
async_work_lease="$async_work_common/push-gate/leases/refs/heads/mho/async-work-package.json"
mkdir -p "$(dirname "$async_work_lease")"
jq --arg expires_at "$(future_utc)" \
  '.status = "active"
   | .updated_at = .created_at
   | .user_intent = ""
   | .async_iteration.expires_at = $expires_at' \
  "$async_work_draft" >"$async_work_lease"
(
  cd "$ASYNC_WORK_REPO"
  mkdir -p docs src/widget-review tests
  printf 'usage\n' >docs/setup.md
  printf 'widget review\n' >src/widget-review/flow.sh
  printf 'regression\n' >tests/review-flow.test
  git add docs/setup.md src/widget-review/flow.sh tests/review-flow.test
  git commit -m "widget review implementation" >/dev/null
)
async_work_allow=$(run_helper "$ASYNC_WORK_REPO" check)
[[ "$(jq -r '.allowed' <<<"$async_work_allow")" == "true" ]] \
  || fail "expected descendant widget-review file to remain inside async work package: $async_work_allow"
(
  cd "$ASYNC_WORK_REPO"
  printf 'unrelated\n' >src/unrelated.sh
  git add src/unrelated.sh
  git commit -m "widget review billing stray" >/dev/null
)
async_work_block=$(run_helper "$ASYNC_WORK_REPO" check)
[[ "$(jq -r '.allowed' <<<"$async_work_block")" == "false" ]] \
  || fail "expected unrelated async work-package path to be blocked: $async_work_block"
expect_contains "$(jq -r '.reason' <<<"$async_work_block")" "outside the reviewed async work package"
expect_contains "$(jq -r '.reason' <<<"$async_work_block")" "src/unrelated.sh"
echo "ok 39 - async work package can cover expected future files while blocking common-token path collisions"

IFS='|' read -r INTENT_REPO INTENT_BIN INTENT_ORIGIN <<<"$(make_repo semantic-check-alignment)"
FAKE_BIN="$INTENT_BIN"
(
  cd "$INTENT_REPO"
  git checkout -b mho/semantic-check-alignment >/dev/null
)
export PG_TEST_PR_JSON='[]'
export PG_TEST_PR_LIST_MAP=''
run_helper "$INTENT_REPO" prepare \
  --async \
  --expires 8h \
  --max-pushes 6 \
  --what "Write widget-review documentation" \
  --why "allow reviewed async feature building while human is unavailable" \
  --approach "add widget-review documentation under docs and verify semantic checks" >/dev/null
intent_output=$(run_helper "$INTENT_REPO" draft-approve)
intent_draft=$(extract_path "$intent_output" "^JSON draft file:")
intent_common=$(current_common_dir "$INTENT_REPO")
intent_lease="$intent_common/push-gate/leases/refs/heads/mho/semantic-check-alignment.json"
mkdir -p "$(dirname "$intent_lease")"
jq --arg expires_at "$(future_utc)" \
  '.status = "active"
   | .updated_at = .created_at
   | .async_iteration.expires_at = $expires_at' \
  "$intent_draft" >"$intent_lease"
(
  cd "$INTENT_REPO"
  mkdir -p docs
  printf 'review docs\n' >docs/widget-review.md
  git add docs/widget-review.md
  git commit -m "widget review documentation" >/dev/null
)
intent_check=$(PG_TEST_CODEX_RESPONSE='MISMATCH: widget review documentation is outside approved intent' \
  run_helper "$INTENT_REPO" check)
[[ "$(jq -r '.allowed' <<<"$intent_check")" == "false" ]] \
  || fail "expected pg check to surface semantic intent mismatch: $intent_check"
expect_contains "$(jq -r '.reason' <<<"$intent_check")" "branch diverges from approved intent"
set +e
intent_push=$(PG_TEST_CODEX_RESPONSE='MISMATCH: widget review documentation is outside approved intent' \
  run_helper "$INTENT_REPO" push --assert-flow $'update pr line\nbranch mho/semantic-check-alignment\nno rewrite' 2>&1)
intent_push_rc=$?
set -e
[[ "$intent_push_rc" != "0" ]] || fail "expected pg push to reject semantic mismatch"
expect_contains "$intent_push" "$(jq -r '.reason' <<<"$intent_check")"
echo "ok 40 - pg check and pg push both surface semantic intent mismatches"
