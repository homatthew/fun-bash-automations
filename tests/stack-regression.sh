#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/llm/hooks/stack.sh"

TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stack-test.XXXXXX")
export TMPDIR="$TEST_TMP"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected [$needle] in: $haystack"
}

expect_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "did NOT expect [$needle] in: $haystack"
}

# ------------------------------------------------------------------------
# Fakes
# ------------------------------------------------------------------------

make_fake_gh() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/gh" <<'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
  # Two query modes: --author @me (status) vs --head <branch> (sync's
  # adopt-merged-inner pass). Different schemas; route by flag presence.
  is_head=""
  head=""
  saved=("$@")
  for arg in "${saved[@]}"; do
    [[ "$arg" == "--head" ]] && is_head=1
  done
  if [[ -n "$is_head" ]]; then
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --head) head="$2"; shift 2;;
        *) shift;;
      esac
    done
    if [[ -n "${STACK_TEST_MERGED_HEAD:-}" && "$head" == "$STACK_TEST_MERGED_HEAD" ]]; then
      printf '%s\n' "${STACK_TEST_MERGED_PR_JSON:-[]}"
    else
      printf '%s\n' '[]'
    fi
    exit 0
  fi
  printf '%s\n' "${STACK_TEST_PR_JSON:-[]}"
  exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
  pr_number="${3:-}"
  var="STACK_TEST_PR_VIEW_${pr_number}"
  val="${!var:-}"
  if [[ -n "$val" ]]; then
    match_local="${STACK_TEST_PR_VIEW_MATCH_LOCAL:-}"
    if [[ "$match_local" != "1" && -n "${STACK_TEST_PUSHED_BRANCHES_FILE:-}" && -f "$STACK_TEST_PUSHED_BRANCHES_FILE" ]]; then
      head_branch=$(jq -r '.headRefName // ""' <<<"$val")
      if [[ -n "$head_branch" ]] && grep -Fx -- "$head_branch" "$STACK_TEST_PUSHED_BRANCHES_FILE" >/dev/null 2>&1; then
        match_local=1
      fi
    fi
    if [[ "$match_local" == "1" ]]; then
      head_branch=$(jq -r '.headRefName // ""' <<<"$val")
      if [[ -n "$head_branch" ]]; then
        head_oid=$(git rev-parse --verify "$head_branch" 2>/dev/null || jq -r '.headRefOid // ""' <<<"$val")
        val=$(jq --arg head_oid "$head_oid" '.headRefOid = $head_oid' <<<"$val")
      fi
    fi
    printf '%s\n' "$val"
    exit 0
  fi
  jq -n --argjson number "$pr_number" '{
    number: $number,
    headRefName: "",
    headRefOid: "",
    headRepositoryOwner: {login: ""},
    headRepository: {name: ""},
    baseRefName: ""
  }'
  exit 0
fi
echo "unexpected gh: $*" >&2
exit 1
EOF
  chmod +x "$bin_dir/gh"
}

make_fake_pg() {
  # stack.sh invokes push-gate.sh via stack_helper_dir/push-gate.sh.
  # The fake handles every subcommand stack.sh calls into:
  #   leases  - canned JSON (status, sync flag staleness, push lease check)
  #   check   - per-branch lease state via STACK_TEST_PG_CHECK_<branch>
  #   prepare - records args to STACK_TEST_PG_LOG (no-op success)
  #   push    - records args to STACK_TEST_PG_LOG (no-op success)
  local hook_dir="$1"
  cat >"$hook_dir/push-gate.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
log() {
  [[ -n "${STACK_TEST_PG_LOG:-}" ]] && echo "$@" >>"$STACK_TEST_PG_LOG"
}
if [[ "${STACK_TEST_PG_DOLT_MISSING:-}" == "1" && "${1:-}" == stack-store-* ]]; then
  echo "pg: dolt is required for stack-trunk workflows." >&2
  exit 1
fi
case "${1:-}" in
  stack-store-init)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    name=""; base=""; trunk=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        --trunk) trunk="$2"; shift 2 ;;
        *) echo "unexpected stack-store-init option: $1" >&2; exit 1 ;;
      esac
    done
    jq --arg name "$name" --arg base "$base" --arg trunk "$trunk" \
      '.[$name] = {version:1,name:$name,base:$base,trunk:$trunk,items:[]}' \
      "$store" >"$store.tmp"
    mv "$store.tmp" "$store"
    echo "Stack stored: $name"
    exit 0
    ;;
  stack-store-add)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    stack=""; id=""; branch=""; pr=""; after=""; base=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stack) stack="$2"; shift 2 ;;
        --id) id="$2"; shift 2 ;;
        --branch) branch="$2"; shift 2 ;;
        --pr) pr="$2"; shift 2 ;;
        --after) after="$2"; shift 2 ;;
        --base) base="$2"; shift 2 ;;
        *) echo "unexpected stack-store-add option: $1" >&2; exit 1 ;;
      esac
    done
    if [[ -n "$after" ]] && jq -e --arg stack "$stack" --arg id "$id" '.[$stack].items[]? | select(.id == $id)' "$store" >/dev/null; then
      echo "stack item already exists: $id; use stack trunk move --stack $stack --id $id --after $after" >&2
      exit 1
    fi
    jq --arg stack "$stack" --arg id "$id" --arg branch "$branch" --arg pr "$pr" --arg after "$after" --arg base "$base" '
      .[$stack] as $s
      | if $s == null then error("missing stack")
        else
          ({id:$id, branch:$branch}
            + (if $pr == "" then {} else {pr:($pr|tonumber)} end)
            + (if $base == "" then {} else {base:$base} end)) as $item
          | if $after == "" then
              .[$stack].items = ((.[$stack].items | map(select(.id != $id))) + [$item])
            else
              .[$stack].items = (reduce .[$stack].items[] as $old
                ([]; if $old.id == $id then .
                     elif $old.id == $after then . + [$old, $item]
                     else . + [$old] end))
            end
          | .[$stack].version = ((.[$stack].version // 1) + 1)
        end
    ' "$store" >"$store.tmp"
    mv "$store.tmp" "$store"
    echo "Stack item stored: $stack/$id"
    exit 0
    ;;
  stack-store-move)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    stack=""; id=""; after=""; before=""; first="false"; last="false"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stack|--name) stack="$2"; shift 2 ;;
        --id) id="$2"; shift 2 ;;
        --after) after="$2"; shift 2 ;;
        --before) before="$2"; shift 2 ;;
        --first) first="true"; shift ;;
        --last) last="true"; shift ;;
        *) echo "unexpected stack-store-move option: $1" >&2; exit 1 ;;
      esac
    done
    choices=0
    [[ -n "$after" ]] && choices=$((choices + 1))
    [[ -n "$before" ]] && choices=$((choices + 1))
    [[ "$first" == "true" ]] && choices=$((choices + 1))
    [[ "$last" == "true" ]] && choices=$((choices + 1))
    [[ "$choices" == "1" ]] || { echo "stack-store-move requires exactly one position" >&2; exit 1; }
    [[ "$after" != "$id" && "$before" != "$id" ]] || { echo "cannot move stack item relative to itself: $id" >&2; exit 1; }
    jq -e --arg stack "$stack" --arg id "$id" '.[$stack].items[]? | select(.id == $id)' "$store" >/dev/null \
      || { echo "stack item not found: $id" >&2; exit 1; }
    if [[ -n "$after" || -n "$before" ]]; then
      target="${after:-$before}"
      jq -e --arg stack "$stack" --arg target "$target" '.[$stack].items[]? | select(.id == $target)' "$store" >/dev/null \
        || { echo "stack item not found for move target: $target" >&2; exit 1; }
    fi
    jq --arg stack "$stack" --arg id "$id" --arg after "$after" --arg before "$before" --arg first "$first" --arg last "$last" '
      .[$stack].items as $items
      | ($items[] | select(.id == $id)) as $moving
      | ($items | map(select(.id != $id))) as $rest
      | .[$stack].items =
          (if $first == "true" then [$moving] + $rest
           elif $last == "true" then $rest + [$moving]
           elif $before != "" then
             reduce $rest[] as $item ([]; if $item.id == $before then . + [$moving, $item] else . + [$item] end)
           else
             reduce $rest[] as $item ([]; if $item.id == $after then . + [$item, $moving] else . + [$item] end)
           end)
      | .[$stack].version = ((.[$stack].version // 1) + 1)
    ' "$store" >"$store.tmp"
    mv "$store.tmp" "$store"
    echo "Stack item moved: $stack/$id"
    exit 0
    ;;
  stack-store-remove)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    stack=""; id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stack|--name) stack="$2"; shift 2 ;;
        --id) id="$2"; shift 2 ;;
        *) echo "unexpected stack-store-remove option: $1" >&2; exit 1 ;;
      esac
    done
    jq -e --arg stack "$stack" --arg id "$id" '.[$stack].items[]? | select(.id == $id)' "$store" >/dev/null \
      || { echo "stack item not found: $id" >&2; exit 1; }
    jq --arg stack "$stack" --arg id "$id" '
      .[$stack].items = (.[$stack].items | map(select(.id != $id)))
      | if (.[$stack].items | length) == 0 then
          del(.[$stack])
        else
          .[$stack].version = ((.[$stack].version // 1) + 1)
        end
    ' "$store" >"$store.tmp"
    mv "$store.tmp" "$store"
    if jq -e --arg stack "$stack" '.[$stack] == null' "$store" >/dev/null; then
      echo "Stack pruned: $stack (removed final item $id)"
    else
      echo "Stack item removed: $stack/$id"
    fi
    exit 0
    ;;
  stack-store-list)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    format="text"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) format="json"; shift ;;
        *) echo "unexpected stack-store-list option: $1" >&2; exit 1 ;;
      esac
    done
    if [[ "$format" == "json" ]]; then
      jq -c --arg repo "$PWD" '
        {
          repo:$repo,
          repo_key:$repo,
          stacks:(to_entries | map({
            manifest:{
              version:1,
              name:.value.name,
              base:.value.base,
              trunk:.value.trunk,
              store_version:(.value.version // 1),
              items:(.value.items // [])
            },
            materialization:null,
            approval:{allowed:false, reason:"No active trunk lease."}
          }))
        }
      ' "$store"
    else
      jq -r 'keys[]' "$store"
    fi
    exit 0
    ;;
  stack-store-manifest)
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    [[ -f "$store" ]] || printf '{}\n' >"$store"
    shift
    stack=""; format="text"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stack|--name) stack="$2"; shift 2 ;;
        --json) format="json"; shift ;;
        *) echo "unexpected stack-store-manifest option: $1" >&2; exit 1 ;;
      esac
    done
    jq -e --arg stack "$stack" '.[$stack] != null' "$store" >/dev/null \
      || { echo "stack not found in Dolt store: $stack" >&2; exit 1; }
    jq -c --arg stack "$stack" '.[$stack] | {version:1,name,base,trunk,store_version:(.version // 1),items}' "$store"
    exit 0
    ;;
  stack-store-record-materialization)
    log "record-materialization $*"
    if [[ -n "${STACK_TEST_STACK_MATERIALIZATIONS:-}" ]]; then
      shift
      stack=""
      json=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --stack) stack="$2"; shift 2 ;;
          --json) json="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      jq -c . <<<"$json" >>"$STACK_TEST_STACK_MATERIALIZATIONS"
    fi
    echo "Materialization stored"
    exit 0
    ;;
  stack-store-branch-materialization)
    if [[ -n "${STACK_TEST_BRANCH_MATERIALIZATION_SLEEP:-}" ]]; then
      sleep "$STACK_TEST_BRANCH_MATERIALIZATION_SLEEP"
    fi
    store="${STACK_TEST_STACK_STORE:?STACK_TEST_STACK_STORE required}"
    mat_file="${STACK_TEST_STACK_MATERIALIZATIONS:?STACK_TEST_STACK_MATERIALIZATIONS required}"
    shift
    branch=""
    format="text"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --branch) branch="$2"; shift 2 ;;
        --json) format="json"; shift ;;
        *) echo "unexpected stack-store-branch-materialization option: $1" >&2; exit 1 ;;
      esac
    done
    mat=$(jq -sc --arg branch "$branch" '[.[] | select(any(.items[]; .branch == $branch))] | last // empty' "$mat_file")
    [[ -n "$mat" ]] || exit 1
    stack=$(jq -r '.stack' <<<"$mat")
    trunk=$(jq -r --arg stack "$stack" '.[$stack].trunk // ""' "$store")
    if [[ "$format" == "json" ]]; then
      jq -c --arg branch "$branch" --arg trunk "$trunk" '
        . as $m
        | ($m.items[] | select(.branch == $branch)) as $item
        | {
            stack: $m.stack,
            trunk: $trunk,
            materialization_id: $m.materialization_id,
            manifest_hash: $m.manifest_hash,
            trunk_tip: $m.trunk_tip,
            item_id: $item.id,
            order_index: $item.order_index,
            branch: $item.branch,
            commit: $item.commit,
            pr: $item.pr
          }' <<<"$mat"
    else
      commit=$(jq -r --arg branch "$branch" '.items[] | select(.branch == $branch) | .commit' <<<"$mat")
      printf '%s\t%s\t%s\t%s\n' "$stack" "$trunk" "$branch" "$commit"
    fi
    exit 0
    ;;
  check-trunk)
    shift
    stack=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --stack|--name) stack="$2"; shift 2 ;;
        *) echo "unexpected check-trunk option: $1" >&2; exit 1 ;;
      esac
    done
    mat=$(jq -c --arg stack "$stack" 'select(.stack == $stack)' "${STACK_TEST_STACK_MATERIALIZATIONS:?}" | tail -1 || true)
    if [[ -z "$mat" ]]; then
      jq -n --arg stack "$stack" '{allowed:false, reason:("No active trunk lease for stack " + $stack)}'
    else
      jq -n --argjson mat "$mat" '{allowed:true, materialization:$mat, lease:{items:$mat.items}}'
    fi
    exit 0
    ;;
  leases)
    printf '%s\n' "${STACK_TEST_LEASES_JSON:-[]}"
    exit 0
    ;;
  check)
    branch="${2:-}"
    var="STACK_TEST_PG_CHECK_${branch//[^A-Za-z0-9]/_}"
    val="${!var:-}"
    if [[ -z "$val" ]]; then
      val="${STACK_TEST_PG_CHECK_DEFAULT:-}"
    fi
    if [[ -z "$val" ]]; then
      val='{"allowed":false}'
    fi
    printf '%s\n' "$val"
    exit 0
    ;;
  prepare)
    log "prepare $*"
    echo "Prepared brief written: /tmp/fake-prepare.json"
    exit 0
    ;;
  push)
    is_trunk=""
    source_ref=""
    saved=("$@")
    for ((i = 1; i <= $#; i++)); do
      arg="${saved[$((i - 1))]}"
      if [[ "$arg" == "--trunk-stack" ]]; then
        is_trunk=1
      elif [[ "$arg" == "--source-ref" && $i -lt $# ]]; then
        source_ref="${saved[$i]}"
      fi
    done
    if [[ -n "$is_trunk" && "$source_ref" =~ ^[0-9a-f]{40}$ ]]; then
      echo "raw commit source-ref is not a pushable branch ref: $source_ref" >&2
      exit 1
    fi
    log "push $*"
    if [[ -n "${STACK_TEST_PUSHED_BRANCHES_FILE:-}" && -n "$source_ref" ]]; then
      echo "$source_ref" >>"$STACK_TEST_PUSHED_BRANCHES_FILE"
    fi
    echo "(fake) git push ok"
    exit 0
    ;;
esac
echo "unexpected push-gate: $*" >&2
exit 1
EOF
  chmod +x "$hook_dir/push-gate.sh"
}

make_fake_branchless() {
  local bin_dir="$1" log_file="$2"
  cat >"$bin_dir/git-branchless" <<EOF
#!/bin/bash
set -euo pipefail
echo "git-branchless \$*" >>"$log_file"
case "\${STACK_TEST_BRANCHLESS_MODE:-ok}" in
  advance-base)
    git checkout mho/feature-base >/dev/null 2>&1
    printf 'scratch advance\n' >>scratch-sync.txt
    git add scratch-sync.txt
    git commit -m "scratch sync advance" >/dev/null
    ;;
  advance-all)
    for branch in mho/feature-base mho/feature-api mho/feature-ui; do
      git checkout "\$branch" >/dev/null 2>&1
      safe="\${branch//[^A-Za-z0-9]/_}"
      printf 'scratch advance %s\n' "\$branch" >>"scratch-\$safe.txt"
      git add "scratch-\$safe.txt"
      git commit -m "scratch sync \$branch" >/dev/null
    done
    ;;
  fail)
    echo "CONFLICT conflict.txt" >&2
    exit "\${STACK_TEST_BRANCHLESS_EXIT:-7}"
    ;;
esac
if [[ -n "\${STACK_TEST_STALE_REAL_REPO:-}" ]]; then
  git -C "\$STACK_TEST_STALE_REAL_REPO" update-ref refs/heads/mho/feature-base \
    "\$(git -C "\$STACK_TEST_STALE_REAL_REPO" rev-parse mho/feature-api)"
fi
exit 0
EOF
  chmod +x "$bin_dir/git-branchless"
}

# ------------------------------------------------------------------------
# Repo + stack of three branches
# ------------------------------------------------------------------------

make_stacked_repo() {
  local repo_tmp
  repo_tmp=$(mktemp -d "$TEST_TMP/repo.XXXXXX")
  local base="$repo_tmp/work"
  local origin="$repo_tmp/origin.git"
  git -c init.defaultBranch=main init --bare "$origin" >/dev/null
  git -c init.defaultBranch=main init "$base" >/dev/null
  (
    cd "$base"
    git config user.name "Stack Test"
    git config user.email "stack@test"
    printf 'base\n' >README.md
    git add README.md
    git commit -m "base" >/dev/null
    git branch -M main
    git remote add origin "$origin"
    git push -u origin main >/dev/null

    git checkout -b mho/feature-base main >/dev/null
    printf 'a\n' >a.txt && git add a.txt && git commit -m "feature-base 1" >/dev/null
    printf 'aa\n' >>a.txt && git add a.txt && git commit -m "feature-base 2" >/dev/null

    git checkout -b mho/feature-api mho/feature-base >/dev/null
    printf 'b\n' >b.txt && git add b.txt && git commit -m "feature-api 1" >/dev/null

    git checkout -b mho/feature-ui mho/feature-api >/dev/null
    printf 'c\n' >c.txt && git add c.txt && git commit -m "feature-ui 1" >/dev/null

    # Set up a synthetic remote ref so the tool finds origin/main as base.
    git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  )
  echo "$base"
}

# ------------------------------------------------------------------------
# Test setup
# ------------------------------------------------------------------------

REPO=$(make_stacked_repo)
# Canonicalize REPO path — git rev-parse --show-toplevel resolves symlinks
# (e.g. macOS /var → /private/var), and stack.sh keys leases by that.
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
FAKE_BIN="$TEST_TMP/bin"
mkdir -p "$FAKE_BIN"
make_fake_gh "$FAKE_BIN"

# Sandbox stack.sh by copying it into a writable hook dir alongside fake push-gate.sh.
HOOK_DIR="$TEST_TMP/hooks"
mkdir -p "$HOOK_DIR"
cp "$HOOK" "$HOOK_DIR/stack.sh"
chmod +x "$HOOK_DIR/stack.sh"
make_fake_pg "$HOOK_DIR"
export STACK_TEST_STACK_STORE="$TEST_TMP/fake-stack-store.json"
export STACK_TEST_STACK_MATERIALIZATIONS="$TEST_TMP/fake-stack-materializations.jsonl"
: >"$STACK_TEST_STACK_STORE"
jq -n '{}' >"$STACK_TEST_STACK_STORE"
: >"$STACK_TEST_STACK_MATERIALIZATIONS"

BRANCHLESS_LOG="$TEST_TMP/branchless.log"
: >"$BRANCHLESS_LOG"
make_fake_branchless "$FAKE_BIN" "$BRANCHLESS_LOG"

run_stack() {
  (
    cd "$REPO"
    PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" "$@"
  )
}

UI_HEAD=$(git -C "$REPO" rev-parse mho/feature-ui)
API_HEAD=$(git -C "$REPO" rev-parse mho/feature-api)
BASE_HEAD=$(git -C "$REPO" rev-parse mho/feature-base)

export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":42,"headRefName":"mho/feature-base","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"url":"https://x/42","title":"base"},
  {"number":43,"headRefName":"mho/feature-api","baseRefName":"mho/feature-base","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"url":"https://x/43","title":"api"}
]')

export STACK_TEST_LEASES_JSON
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$BASE_HEAD" '[
  {"repo_root":$rr,"branch_name":"mho/feature-base","status":"active","approved_anchor":$anchor,"pr_number":42,"updated_at":"2026-04-24T00:00:00Z"},
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":"deadbeef","pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

echo "1..36"

# ------------------------------------------------------------------------
# 1. broad status rejects implicit inference; --implicit renders all branches
# ------------------------------------------------------------------------
default_status_rc=0
default_status=$(run_stack status 2>&1) || default_status_rc=$?
[[ "$default_status_rc" != "0" ]] || fail "broad stack status should require --implicit"
expect_contains "$default_status" "broad implicit stack inference is disabled by default"
expect_contains "$default_status" "stack trunk list"
expect_contains "$default_status" "stack status --pr <N> --children"

out=$(run_stack status --implicit 2>&1)
expect_contains "$out" "mho/feature-base"
expect_contains "$out" "mho/feature-api"
expect_contains "$out" "mho/feature-ui"
expect_contains "$out" "#42"
expect_contains "$out" "#43"
expect_contains "$out" "Next step:"
echo "ok 1 - broad status requires --implicit; implicit renders 3-branch stack with PR numbers"

# ------------------------------------------------------------------------
# 2. status surfaces lease state: allowed, stale-tip, missing
# ------------------------------------------------------------------------
expect_contains "$out" "allowed"
expect_contains "$out" "stale-tip"
# feature-ui has no lease → "—"
ui_line=$(echo "$out" | grep "mho/feature-ui" || true)
expect_contains "$ui_line" "—"
echo "ok 2 - lease states render allowed / stale-tip / —"

# ------------------------------------------------------------------------
# 3. status surfaces CI state: PASS for #42, PENDING for #43
# ------------------------------------------------------------------------
base_line=$(echo "$out" | grep "mho/feature-base" || true)
api_line=$(echo "$out" | grep "mho/feature-api" || true)
expect_contains "$base_line" "PASS"
expect_contains "$api_line" "PENDING"
echo "ok 3 - CI rollup summarized to PASS / PENDING"

# ------------------------------------------------------------------------
# 4. status --json is valid and has 3 branches in one stack
# ------------------------------------------------------------------------
json_out=$(run_stack status --implicit --json 2>&1)
expect_not_contains "$json_out" "Next step:"
n_stacks=$(echo "$json_out" | jq '.stacks | length')
[[ "$n_stacks" == "1" ]] || fail "expected 1 stack, got $n_stacks"
n_branches=$(echo "$json_out" | jq '.stacks[0].branches | length')
[[ "$n_branches" == "3" ]] || fail "expected 3 branches in stack, got $n_branches: $json_out"
root=$(echo "$json_out" | jq -r '.stacks[0].root')
[[ "$root" == "mho/feature-base" ]] || fail "expected root mho/feature-base, got $root"
echo "ok 4 - status --json shape is valid"

# ------------------------------------------------------------------------
# 5. status accepts explicit --base and --prefix
# ------------------------------------------------------------------------
explicit_out=$(run_stack status --implicit --base origin/main --prefix mho/feature- 2>&1)
expect_contains "$explicit_out" "Base: origin/main"
expect_contains "$explicit_out" "Prefix: mho/feature-"
expect_contains "$explicit_out" "mho/feature-base"
echo "ok 5 - status honors explicit --base and --prefix"

# ------------------------------------------------------------------------
# 6. sync --dry-run does NOT invoke git-branchless
# ------------------------------------------------------------------------
: >"$BRANCHLESS_LOG"
sync_dry_out=$(run_stack sync --dry-run 2>&1)
[[ ! -s "$BRANCHLESS_LOG" ]] || fail "dry-run should NOT call git-branchless, got: $(cat "$BRANCHLESS_LOG")"
expect_contains "$sync_dry_out" "Next step:"
expect_contains "$sync_dry_out" "Run the preflight and apply refs: stack sync"
echo "ok 6 - sync --dry-run skips git-branchless"

# ------------------------------------------------------------------------
# 7. sync invokes git-branchless sync --pull
# ------------------------------------------------------------------------
: >"$BRANCHLESS_LOG"
sync_normal_out=$(run_stack sync 2>&1)
grep -q "sync --pull" "$BRANCHLESS_LOG" || fail "expected git-branchless sync --pull, got: $(cat "$BRANCHLESS_LOG")"
expect_contains "$sync_normal_out" "Next step:"
echo "ok 7 - sync invokes git-branchless sync --pull"

# ------------------------------------------------------------------------
# 8. status handles missing PR / missing lease gracefully (no errors)
# ------------------------------------------------------------------------
# Run inside a subshell so the empty-PR/empty-lease overrides don't leak
# into later tests.
out=$(
  export STACK_TEST_PR_JSON='[]'
  export STACK_TEST_LEASES_JSON='[]'
  run_stack status --implicit 2>&1
)
expect_contains "$out" "mho/feature-base"
expect_not_contains "$out" "error"
expect_not_contains "$out" "null"
echo "ok 8 - missing PR/lease renders without errors"

# ------------------------------------------------------------------------
# 9: stack sync with multi-commit squash-merged parent restacks descendants
#    AND invokes branchless --pull exactly once.
# ------------------------------------------------------------------------

BASE_HEAD_BEFORE_ADOPT=$(git -C "$REPO" rev-parse mho/feature-base)

# Simulate squash-merge: collapse feature-base's 2 commits into one on main.
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git merge --squash mho/feature-base >/dev/null 2>&1
  git -c user.name=Test -c user.email=t@t commit -m "squash-merge feature-base" >/dev/null
  git update-ref refs/remotes/origin/main "$(git rev-parse main)"
  git checkout mho/feature-ui >/dev/null 2>&1
)

api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

: >"$BRANCHLESS_LOG"
sync_out=$(STACK_TEST_MERGED_HEAD=mho/feature-base \
  STACK_TEST_MERGED_PR_JSON="[{\"number\":100,\"state\":\"MERGED\",\"baseRefName\":\"main\",\"headRefOid\":\"$BASE_HEAD_BEFORE_ADOPT\"}]" \
  run_stack sync 2>&1)

expect_contains "$sync_out" "Adopting #100"
api_after=$(git -C "$REPO" rev-parse mho/feature-api)
ui_after=$(git -C "$REPO" rev-parse mho/feature-ui)
[[ "$api_after" != "$api_before" ]] || fail "feature-api tip didn't move"
[[ "$ui_after" != "$ui_before" ]] || fail "feature-ui tip didn't move"
api_ahead=$(git -C "$REPO" rev-list --count main..mho/feature-api)
[[ "$api_ahead" == "1" ]] || fail "expected feature-api 1 ahead of main, got $api_ahead"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not a descendant of new feature-api"
pull_calls=$(grep -c "sync --pull" "$BRANCHLESS_LOG" || true)
[[ "$pull_calls" == "1" ]] \
  || fail "expected git-branchless sync --pull invoked exactly once, got $pull_calls: $(cat "$BRANCHLESS_LOG")"
echo "ok 9 - sync cascades squash-merged parent then invokes branchless once"

# ------------------------------------------------------------------------
# 10: stack push requires PR scope; PR-scoped happy path updates PR branches.
# ------------------------------------------------------------------------

# After test 8's cascade, feature-base is a sibling of main. mho/feature-ui has
# no PR in STACK_TEST_PR_JSON, so PR-scoped push must not include it.
PG_LOG="$TEST_TMP/pg.log"
PUSHED_BRANCHES="$TEST_TMP/pushed-branches.log"
: >"$PG_LOG"
: >"$PUSHED_BRANCHES"

# Reset to a stable HEAD before stack push (which checks out branches).
git -C "$REPO" checkout main >/dev/null 2>&1
git -C "$REPO" remote add upstream git@github.com:example/stack-pr-head.git >/dev/null 2>&1 || true

broad_push_rc=0
broad_push_out=$(run_stack push 2>&1) || broad_push_rc=$?
[[ "$broad_push_rc" != "0" ]] || fail "plain stack push should require PR scope"
expect_contains "$broad_push_out" "broad implicit stack push is disabled by default"
expect_contains "$broad_push_out" "stack trunk push --stack <name>"
expect_contains "$broad_push_out" "stack push --pr <N> --children"

fresh_lease='{"allowed":true,"current":{"anchor_matches_head":true},"async_iteration":{"enabled":false}}'
fresh_async_lease='{"allowed":true,"current":{"anchor_matches_head":false},"async_iteration":{"enabled":true,"pushes":{"used":1,"max":5,"remaining":4}}}'
export STACK_TEST_PG_LOG="$PG_LOG"
export STACK_TEST_PUSHED_BRANCHES_FILE="$PUSHED_BRANCHES"
export STACK_TEST_PG_CHECK_mho_feature_base="$fresh_lease"
export STACK_TEST_PG_CHECK_mho_feature_api="$fresh_async_lease"
export STACK_TEST_PG_CHECK_mho_feature_ui="$fresh_lease"
export STACK_TEST_PR_VIEW_42='{"number":42,"headRefName":"mho/feature-base","headRefOid":"old-base","headRepositoryOwner":{"login":"example"},"headRepository":{"name":"stack-pr-head"},"baseRefName":"main"}'
export STACK_TEST_PR_VIEW_43='{"number":43,"headRefName":"mho/feature-api","headRefOid":"old-api","headRepositoryOwner":{"login":"example"},"headRepository":{"name":"stack-pr-head"},"baseRefName":"mho/feature-base"}'
push_out=$(run_stack push --pr 42 --children 2>&1)

expect_contains "$push_out" "Done."
expect_not_contains "$push_out" "mho/feature-ui"
expect_contains "$push_out" "Agent handoff:"
expect_contains "$push_out" "Next step:"
expect_contains "$push_out" "Phase: needs PR description update"
expect_contains "$push_out" "#42 mho/feature-base"
expect_contains "$push_out" "update description: /update-pr-description 42"
push_calls=$(grep -c "^push " "$PG_LOG" || true)
[[ "$push_calls" == "2" ]] \
  || fail "expected 2 pg push calls (base + api), got $push_calls: $(cat "$PG_LOG")"
force_push_calls=$(grep -c "^push push --force-with-lease" "$PG_LOG" || true)
[[ "$force_push_calls" == "2" ]] \
  || fail "expected pg push --force-with-lease for all pushes, got: $(cat "$PG_LOG")"
pr_remote_push_calls=$(grep -c -- "--remote upstream" "$PG_LOG" || true)
[[ "$pr_remote_push_calls" == "2" ]] \
  || fail "expected existing PR pushes to target PR head remote upstream, got: $(cat "$PG_LOG")"
set_upstream_calls=$(grep -c -- "--set-upstream" "$PG_LOG" || true)
[[ "$set_upstream_calls" == "0" ]] \
  || fail "did not expect --set-upstream in PR-scoped push, got: $(cat "$PG_LOG")"
prep_calls=$(grep -c "^prepare " "$PG_LOG" || true)
[[ "$prep_calls" == "0" ]] \
  || fail "expected 0 pg prepare calls when leases fresh, got $prep_calls"
echo "ok 10 - stack push requires PR scope and reuses fresh PR leases"
unset STACK_TEST_PR_VIEW_42 STACK_TEST_PR_VIEW_43

# ------------------------------------------------------------------------
# 11: stack push stops at first branch with stale/missing lease, runs
#     pg prepare and prints resume instructions. No further pushes.
# ------------------------------------------------------------------------

: >"$PG_LOG"
git -C "$REPO" checkout main >/dev/null 2>&1

unset STACK_TEST_PG_CHECK_mho_feature_base STACK_TEST_PG_CHECK_mho_feature_api STACK_TEST_PG_CHECK_mho_feature_ui
export STACK_TEST_PG_CHECK_DEFAULT='{"allowed":false}'
stop_out=$(run_stack push --prefix mho/feature- --pr 42 --children --async --expires 8h --max-pushes 5 --allow-rewrite 2>&1)

expect_contains "$stop_out" "needs approval, preparing brief"
expect_contains "$stop_out" "Next step:"
expect_contains "$stop_out" "Human approval: pg -C"
expect_contains "$stop_out" "Agent re-run: stack push --prefix mho/feature- --pr 42 --children --async --expires 8h --max-pushes 5 --allow-rewrite"
expect_contains "$stop_out" "Agent handoff:"
expect_contains "$stop_out" "Phase: needs approval"
expect_contains "$stop_out" "Re-run this stack: stack push --prefix mho/feature- --pr 42 --children --async --expires 8h --max-pushes 5 --allow-rewrite"
prep_calls=$(grep -c "^prepare " "$PG_LOG" || true)
[[ "$prep_calls" == "1" ]] \
  || fail "expected exactly 1 pg prepare call (stop on first), got $prep_calls: $(cat "$PG_LOG")"
expect_contains "$(cat "$PG_LOG")" "prepare --async --expires 8h --max-pushes 5 --allow-rewrite"
push_calls=$(grep -c "^push " "$PG_LOG" || true)
[[ "$push_calls" == "0" ]] \
  || fail "expected 0 pg push calls when first lease stale, got $push_calls"
echo "ok 11 - stack push prepares async leases and stops with resume instructions"

# ------------------------------------------------------------------------
# 12: sync conflict preflight leaves real refs unchanged and auto-cleans
#     scratch on failure.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

set +e
conflict_out=$(STACK_TEST_BRANCHLESS_MODE=fail run_stack sync 2>&1)
conflict_rc=$?
set -e
[[ "$conflict_rc" != "0" ]] || fail "expected sync preflight failure"
expect_contains "$conflict_out" "scratch sync preflight failed"
expect_contains "$conflict_out" "CONFLICT conflict.txt"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$base_before" ]] || fail "feature-base moved after failed preflight"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "feature-api moved after failed preflight"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "feature-ui moved after failed preflight"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after failed sync: $scratch_left"
REPO="$OLD_REPO"
echo "ok 12 - sync preflight failure leaves refs unchanged and cleans scratch"

# ------------------------------------------------------------------------
# 13: successful sync imports scratch objects and applies all changed branch
#     refs, with scratch auto-cleanup on success.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

sync_apply_out=$(STACK_TEST_BRANCHLESS_MODE=advance-all run_stack sync 2>&1)
expect_contains "$sync_apply_out" "tip moved: mho/feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" != "$base_before" ]] || fail "feature-base did not move after successful sync"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api did not move after successful sync"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui did not move after successful sync"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after successful sync: $scratch_left"
REPO="$OLD_REPO"
echo "ok 13 - successful sync atomically applies branch updates and cleans scratch"

# ------------------------------------------------------------------------
# 14: stale real tips between preflight and apply abort the transaction
#     without applying other scratch updates.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

set +e
stale_out=$(STACK_TEST_BRANCHLESS_MODE=advance-all \
  STACK_TEST_STALE_REAL_REPO="$REPO" \
  run_stack sync 2>&1)
stale_rc=$?
set -e
[[ "$stale_rc" != "0" ]] || fail "expected stale-tip apply failure"
expect_contains "$stale_out" "aborted without partial updates"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$api_before" ]] || fail "test hook did not move feature-base to stale tip"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "feature-api should not receive scratch update after transaction abort"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "feature-ui should not receive scratch update after transaction abort"
[[ "$base_before" != "$api_before" ]] || fail "test setup invalid: base/api tips should differ"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-sync.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "scratch dirs should be removed after stale apply abort: $scratch_left"
REPO="$OLD_REPO"
echo "ok 14 - stale tips abort sync apply without partial updates"

# ------------------------------------------------------------------------
# 15: --keep-scratch preserves the scratch clone and prints a debug command.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)

set +e
keep_out=$(STACK_TEST_BRANCHLESS_MODE=fail run_stack sync --keep-scratch 2>&1)
keep_rc=$?
set -e
[[ "$keep_rc" != "0" ]] || fail "expected kept-scratch failure"
expect_contains "$keep_out" "Scratch kept:"
expect_contains "$keep_out" "Debug command:"
kept_repo=$(echo "$keep_out" | awk '/Scratch kept:/ {print $3; exit}')
[[ -d "$kept_repo/.git" ]] || fail "expected kept scratch repo at $kept_repo"
rm -rf "$(dirname "$kept_repo")"
REPO="$OLD_REPO"
echo "ok 15 - --keep-scratch preserves clone and prints debug command"

# ------------------------------------------------------------------------
# 16: squash collapses the current branch to one incremental commit and
#     restacks descendants.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')
git -C "$REPO" checkout mho/feature-base >/dev/null 2>&1

squash_out=$(run_stack squash -m "squashed base" 2>&1)
expect_contains "$squash_out" "Squashing 2 commits"
expect_contains "$squash_out" "Next step:"
expect_contains "$squash_out" "Stale push-gate leases: mho/feature-api"
expect_contains "$squash_out" "approve/push with: stack push"
base_count=$(git -C "$REPO" rev-list --count origin/main..mho/feature-base)
[[ "$base_count" == "1" ]] || fail "expected feature-base to have one incremental commit, got $base_count"
subject=$(git -C "$REPO" log -1 --format='%s' mho/feature-base)
[[ "$subject" == "squashed base" ]] || fail "unexpected squash subject: $subject"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api was not restacked"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui was not restacked"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/feature-api \
  || fail "feature-api is not descendant of squashed feature-base"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of restacked feature-api"
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
REPO="$OLD_REPO"
echo "ok 16 - squash creates one commit and restacks descendants"

# ------------------------------------------------------------------------
# 17: lease lookup works from linked worktrees that share git-common-dir.
# ------------------------------------------------------------------------

LINKED_WT="$TEST_TMP/linked-worktree"
git -C "$REPO" worktree add --detach "$LINKED_WT" mho/feature-ui >/dev/null 2>&1
LINKED_WT=$(cd "$LINKED_WT" && git rev-parse --show-toplevel)
linked_out=$(
  cd "$LINKED_WT"
  PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" status --implicit --prefix mho/feature- 2>&1
)
expect_contains "$linked_out" "mho/feature-base"
base_linked_line=$(echo "$linked_out" | grep "mho/feature-base" || true)
expect_contains "$base_linked_line" "allowed"
linked_debug_out=$(
  cd "$LINKED_WT"
  STACK_DEBUG=1 PATH="$FAKE_BIN:$PATH" bash "$HOOK_DIR/stack.sh" status --implicit --prefix mho/feature- 2>&1
)
expect_contains "$linked_debug_out" "stack: debug: status base="
expect_contains "$linked_debug_out" "stack: debug: lease lookup repo_root=$LINKED_WT"
expect_contains "$linked_debug_out" "main_repo_root=$REPO"
git -C "$REPO" worktree remove "$LINKED_WT" --force >/dev/null 2>&1
echo "ok 17 - leases render from linked worktrees"

# ------------------------------------------------------------------------
# 18: --pr --children scopes to the GitHub PR DAG and warns when local
#     ancestry disagrees.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/redundant-parent >/dev/null 2>&1
  printf 'redundant\n' >redundant.txt
  git add redundant.txt
  git commit -m "redundant parent" >/dev/null

  git checkout -b mho/pr266 >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/no-pr-child >/dev/null 2>&1
  printf 'no pr child\n' >no-pr-child.txt
  git add no-pr-child.txt
  git commit -m "no-pr child change" >/dev/null

  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr267 >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout main >/dev/null 2>&1
  git checkout -b mho/unrelated >/dev/null 2>&1
  printf 'unrelated\n' >unrelated.txt
  git add unrelated.txt
  git commit -m "unrelated change" >/dev/null
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"},
  {"number":271,"headRefName":"mho/unrelated","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/271","title":"unrelated"}
]')

scoped_status=$(run_stack status --pr 266 --children 2>&1)
expect_contains "$scoped_status" "Topology mismatch: PR #266 base is main, but local nearest parent is mho/redundant-parent"
expect_contains "$scoped_status" "GitHub PR base wins; local ancestry is stale/diagnostic"
expect_contains "$scoped_status" "Topology mismatch: PR #267 base is mho/pr266"
expect_contains "$scoped_status" "mho/pr266"
expect_contains "$scoped_status" "mho/pr267"
expect_contains "$scoped_status" "Next step:"
expect_contains "$scoped_status" "stack checkout --pr 266"
expect_contains "$scoped_status" "stack squash --pr 266 --onto-pr-base"
expect_contains "$scoped_status" "stack push --pr 266 --children"
expect_not_contains "$scoped_status" "stack push --dry-run"
expect_not_contains "$scoped_status" "mho/no-pr-child"
expect_not_contains "$scoped_status" "mho/unrelated"

scoped_push=$(run_stack push --dry-run --pr 266 --children 2>&1)
expect_contains "$scoped_push" "Push order:"
expect_contains "$scoped_push" "[1/2] mho/pr266"
expect_contains "$scoped_push" "[2/2] mho/pr267"
expect_contains "$scoped_push" "Next step:"
expect_contains "$scoped_push" "First live push action: stack push --pr 266 --children will prepare mho/pr266"
expect_contains "$scoped_push" "Downstream approvals wait: mho/pr267"
expect_contains "$scoped_push" "Re-run this stack: stack push --pr 266 --children"
expect_not_contains "$scoped_push" "mho/no-pr-child"
expect_not_contains "$scoped_push" "mho/unrelated"
echo "ok 18 - PR-scoped DAG filters unrelated branches and warns on local mismatches"

# ------------------------------------------------------------------------
# 19: squash can use an explicit PR base instead of the detected local parent.
# ------------------------------------------------------------------------

git -C "$REPO" checkout mho/pr266 >/dev/null 2>&1
scoped_squash=$(run_stack squash --dry-run --pr 266 --onto-pr-base -m "Fix Cassandra memory sizing and resource counts" 2>&1)
expect_contains "$scoped_squash" "Squashing 2 commits on mho/pr266 relative to origin/main"
expect_contains "$scoped_squash" "Next step:"
expect_not_contains "$scoped_squash" "relative to mho/redundant-parent"
REPO="$OLD_REPO"
echo "ok 19 - squash --pr --onto-pr-base ignores redundant local parent"

# ------------------------------------------------------------------------
# 20: checkout --pr resolves an open PR to its local branch and prints the
#     middle-stack edit workflow.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr266 >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/pr267 >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout main >/dev/null 2>&1
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"}
]')

checkout_out=$(run_stack checkout --pr 266 2>&1)
current_branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD)
[[ "$current_branch" == "mho/pr266" ]] || fail "expected checkout to move to mho/pr266, got $current_branch"
expect_contains "$checkout_out" "Checked out PR #266: mho/pr266"
expect_contains "$checkout_out" "=== Stack context ==="
expect_contains "$checkout_out" "mho/pr267"
expect_contains "$checkout_out" "Next step:"
expect_contains "$checkout_out" "Commit changes: git add <files> && git commit -m \"<subject>\""
expect_contains "$checkout_out" "stack squash --pr 266 --onto-pr-base"
expect_contains "$checkout_out" "stack push --dry-run --pr 266 --children"
expect_contains "$checkout_out" "stack push --pr 266 --children"
echo "ok 20 - checkout --pr switches to PR branch and prints edit workflow"

# ------------------------------------------------------------------------
# 21: checkout --pr refuses dirty worktrees.
# ------------------------------------------------------------------------

printf 'dirty\n' >"$REPO/dirty.tmp"
set +e
dirty_checkout_out=$(run_stack checkout --pr 266 2>&1)
dirty_checkout_rc=$?
set -e
[[ "$dirty_checkout_rc" != "0" ]] || fail "expected dirty checkout refusal"
expect_contains "$dirty_checkout_out" "working tree dirty"
rm -f "$REPO/dirty.tmp"
echo "ok 21 - checkout --pr refuses dirty worktrees"

# ------------------------------------------------------------------------
# 22: checkout --pr fails clearly when the PR is missing.
# ------------------------------------------------------------------------

set +e
missing_pr_out=$(run_stack checkout --pr 999 2>&1)
missing_pr_rc=$?
set -e
[[ "$missing_pr_rc" != "0" ]] || fail "expected missing PR failure"
expect_contains "$missing_pr_out" "open PR not found in stack data: #999"
echo "ok 22 - checkout --pr reports missing PRs"

# ------------------------------------------------------------------------
# 23: checkout --pr fails clearly when the PR branch is not local.
# ------------------------------------------------------------------------

STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":299,"headRefName":"mho/missing-local","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/299","title":"missing local"}
]')
set +e
missing_branch_out=$(run_stack checkout --pr 299 2>&1)
missing_branch_rc=$?
set -e
[[ "$missing_branch_rc" != "0" ]] || fail "expected missing local branch failure"
expect_contains "$missing_branch_out" "PR #299 branch not found locally: mho/missing-local"

STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"}
]')
LINKED_CHECKOUT_WT="$TEST_TMP/checkout-pr267-linked"
git -C "$REPO" worktree add "$LINKED_CHECKOUT_WT" mho/pr267 >/dev/null 2>&1
LINKED_CHECKOUT_WT=$(cd "$LINKED_CHECKOUT_WT" && pwd -P)
set +e
linked_checkout_out=$(run_stack checkout --pr 267 2>&1)
linked_checkout_rc=$?
set -e
[[ "$linked_checkout_rc" != "0" ]] || fail "expected linked worktree checkout failure"
expect_contains "$linked_checkout_out" "checkout failed: mho/pr267 is already checked out in another worktree: $LINKED_CHECKOUT_WT"
expect_contains "$linked_checkout_out" "cd $LINKED_CHECKOUT_WT"
REPO="$OLD_REPO"
echo "ok 23 - checkout --pr reports missing local branches"

# ------------------------------------------------------------------------
# 24: insert --dry-run prints the planned inserted-branch and descendant
#     rebases without moving refs.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout mho/feature-base >/dev/null 2>&1
  git checkout -b mho/inserted --no-track >/dev/null 2>&1
  printf 'inserted\n' >inserted.txt
  git add inserted.txt
  git commit -m "inserted change" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/inserted)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

insert_dry=$(run_stack insert --dry-run --branch mho/inserted --after mho/feature-base 2>&1)
expect_contains "$insert_dry" "Insert plan:"
expect_contains "$insert_dry" "Scope:         local descendants under mho/"
expect_contains "$insert_dry" "(dry-run) git rebase --onto mho/feature-base"
expect_contains "$insert_dry" "(dry-run) git rebase --onto mho/inserted"
expect_contains "$insert_dry" "Run the preflight and apply refs: stack insert --branch mho/inserted --after mho/feature-base"
[[ "$(git -C "$REPO" rev-parse mho/inserted)" == "$insert_before" ]] || fail "dry-run moved inserted branch"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "dry-run moved feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "dry-run moved feature-ui"
REPO="$OLD_REPO"
echo "ok 24 - insert --dry-run prints planned rebases without moving refs"

# ------------------------------------------------------------------------
# 25: insert applies a scratch-preflighted local restack atomically and
#     reports stale leases for moved branches.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/inserted --no-track >/dev/null 2>&1
  printf 'inserted\n' >inserted.txt
  git add inserted.txt
  git commit -m "inserted change" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/inserted)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

insert_live=$(run_stack insert --branch mho/inserted --after mho/feature-base 2>&1)
expect_contains "$insert_live" "Preflighting insert in scratch"
expect_contains "$insert_live" "Applying"
expect_contains "$insert_live" "Inserted mho/inserted after mho/feature-base"
expect_contains "$insert_live" "Stale push-gate leases: mho/feature-api"
[[ "$(git -C "$REPO" rev-parse mho/inserted)" != "$insert_before" ]] || fail "inserted branch did not move onto feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" != "$api_before" ]] || fail "feature-api did not move after insert"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" != "$ui_before" ]] || fail "feature-ui did not move after insert"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/inserted \
  || fail "inserted branch is not descendant of feature-base"
git -C "$REPO" merge-base --is-ancestor mho/inserted mho/feature-api \
  || fail "feature-api is not descendant of inserted branch"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of feature-api after insert"
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
REPO="$OLD_REPO"
echo "ok 25 - insert preflights and applies local restack with stale lease reporting"

# ------------------------------------------------------------------------
# 26: insert conflict preflight leaves real refs unchanged and auto-cleans
#     scratch on failure.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/conflict-after --no-track >/dev/null 2>&1
  printf 'after\n' >after.txt
  git add after.txt
  git commit -m "conflict after" >/dev/null

  git checkout -b mho/conflict-child --no-track >/dev/null 2>&1
  printf 'child\n' >conflict.txt
  git add conflict.txt
  git commit -m "conflict child" >/dev/null

  git checkout mho/conflict-after >/dev/null 2>&1
  git checkout -b mho/conflict-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >conflict.txt
  git add conflict.txt
  git commit -m "conflict insert" >/dev/null
)
insert_before=$(git -C "$REPO" rev-parse mho/conflict-insert)
child_before=$(git -C "$REPO" rev-parse mho/conflict-child)

set +e
conflict_insert=$(run_stack insert --prefix mho/conflict- --branch mho/conflict-insert --after mho/conflict-after 2>&1)
conflict_insert_rc=$?
set -e
[[ "$conflict_insert_rc" != "0" ]] || fail "expected insert preflight conflict"
expect_contains "$conflict_insert" "scratch insert preflight failed"
expect_contains "$conflict_insert" "Real branch refs were not changed"
[[ "$(git -C "$REPO" rev-parse mho/conflict-insert)" == "$insert_before" ]] || fail "conflict insert moved inserted branch"
[[ "$(git -C "$REPO" rev-parse mho/conflict-child)" == "$child_before" ]] || fail "conflict insert moved child branch"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-insert.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "insert scratch dirs should be removed after failed preflight: $scratch_left"
REPO="$OLD_REPO"
echo "ok 26 - insert preflight conflict leaves refs unchanged and cleans scratch"

# ------------------------------------------------------------------------
# 27: insert --after-pr scopes descendants through GitHub PR baseRefName,
#     excluding no-PR local children.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/pr266 --no-track >/dev/null 2>&1
  printf 'pr266\n' >pr266.txt
  git add pr266.txt
  git commit -m "pr 266 change" >/dev/null

  git checkout -b mho/pr267 --no-track >/dev/null 2>&1
  printf 'pr267\n' >pr267.txt
  git add pr267.txt
  git commit -m "pr 267 child change" >/dev/null

  git checkout mho/pr266 >/dev/null 2>&1
  git checkout -b mho/no-pr-child --no-track >/dev/null 2>&1
  printf 'no pr child\n' >no-pr-child.txt
  git add no-pr-child.txt
  git commit -m "no-pr child change" >/dev/null

  git checkout mho/pr266 >/dev/null 2>&1
  git checkout -b mho/pr-insert --no-track >/dev/null 2>&1
  printf 'pr insert\n' >pr-insert.txt
  git add pr-insert.txt
  git commit -m "pr insert change" >/dev/null
)
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":266,"headRefName":"mho/pr266","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/266","title":"pr 266"},
  {"number":267,"headRefName":"mho/pr267","baseRefName":"mho/pr266","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/267","title":"pr 267"}
]')
pr267_before=$(git -C "$REPO" rev-parse mho/pr267)
no_pr_before=$(git -C "$REPO" rev-parse mho/no-pr-child)

pr_insert=$(run_stack insert --branch mho/pr-insert --after-pr 266 2>&1)
expect_contains "$pr_insert" "Scope:         GitHub PR DAG rooted at #266"
expect_contains "$pr_insert" "PR bases:      not changed by this command"
expect_contains "$pr_insert" "Inserted mho/pr-insert after mho/pr266"
[[ "$(git -C "$REPO" rev-parse mho/pr267)" != "$pr267_before" ]] || fail "PR child did not move after PR-scoped insert"
[[ "$(git -C "$REPO" rev-parse mho/no-pr-child)" == "$no_pr_before" ]] || fail "no-PR child should not move in PR-scoped insert"
git -C "$REPO" merge-base --is-ancestor mho/pr-insert mho/pr267 \
  || fail "PR child is not descendant of inserted branch"
REPO="$OLD_REPO"
echo "ok 27 - insert --after-pr restacks PR children but excludes no-PR local children"

# ------------------------------------------------------------------------
# 28: trunk materialize --dry-run reads a private stack manifest and does
#     not create or move refs.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "demo",
    base: "origin/main",
    trunk: "mho/demo.trunk",
    items: [
      {id: "base", branch: "mho/feature-base"},
      {id: "api", branch: "mho/feature-api"},
      {id: "ui", branch: "mho/feature-ui"}
    ]
  }' >.stack/demo.json
  git add .stack/demo.json
  git commit -m "add stack manifest" >/dev/null
)
base_before=$(git -C "$REPO" rev-parse mho/feature-base)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
ui_before=$(git -C "$REPO" rev-parse mho/feature-ui)

trunk_dry=$(run_stack trunk materialize --dry-run --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_dry" "Stack trunk: demo"
expect_contains "$trunk_dry" "Trunk: mho/demo.trunk"
expect_contains "$trunk_dry" "Refs unchanged in dry-run"
git -C "$REPO" rev-parse --verify mho/demo.trunk >/dev/null 2>&1 \
  && fail "dry-run should not create private trunk"
[[ "$(git -C "$REPO" rev-parse mho/feature-base)" == "$base_before" ]] || fail "dry-run moved feature-base"
[[ "$(git -C "$REPO" rev-parse mho/feature-api)" == "$api_before" ]] || fail "dry-run moved feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$ui_before" ]] || fail "dry-run moved feature-ui"
REPO="$OLD_REPO"
echo "ok 28 - trunk materialize --dry-run leaves refs unchanged"

# ------------------------------------------------------------------------
# 29: trunk materialize constructs a private trunk and hard-points each stack
#     branch to its corresponding commit, including a manifest insertion.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
OLD_LEASES_JSON="$STACK_TEST_LEASES_JSON"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout mho/feature-base >/dev/null 2>&1
  git checkout -b mho/feature-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >insert.txt
  git add insert.txt
  git commit -m "insert middle feature" >/dev/null

  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "demo",
    base: "origin/main",
    trunk: "mho/demo.trunk",
    items: [
      {id: "base", branch: "mho/feature-base"},
      {id: "insert", branch: "mho/feature-insert"},
      {id: "api", branch: "mho/feature-api"},
      {id: "ui", branch: "mho/feature-ui"}
    ]
  }' >.stack/demo.json
  git add .stack/demo.json
  git commit -m "add stack manifest" >/dev/null
)
api_before=$(git -C "$REPO" rev-parse mho/feature-api)
STACK_TEST_LEASES_JSON=$(jq -c -n --arg rr "$REPO" --arg anchor "$api_before" '[
  {"repo_root":$rr,"branch_name":"mho/feature-api","status":"active","approved_anchor":$anchor,"pr_number":43,"updated_at":"2026-04-24T00:00:00Z"}
]')

trunk_live=$(run_stack trunk materialize --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_live" "Preflighting private trunk materialization in scratch"
expect_contains "$trunk_live" "Materialized private trunk: mho/demo.trunk"
expect_contains "$trunk_live" "Stale push-gate leases: mho/feature-api"
git -C "$REPO" merge-base --is-ancestor mho/feature-base mho/feature-insert \
  || fail "insert branch is not descendant of feature-base"
git -C "$REPO" merge-base --is-ancestor mho/feature-insert mho/feature-api \
  || fail "feature-api is not descendant of inserted branch"
git -C "$REPO" merge-base --is-ancestor mho/feature-api mho/feature-ui \
  || fail "feature-ui is not descendant of feature-api"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$(git -C "$REPO" rev-parse mho/demo.trunk)" ]] \
  || fail "private trunk should point to final stack commit"
trunk_status=$(run_stack trunk status --manifest .stack/demo.json 2>&1)
expect_contains "$trunk_status" "Pointer"
expect_contains "$trunk_status" "mho/demo.trunk"
STACK_TEST_LEASES_JSON="$OLD_LEASES_JSON"
REPO="$OLD_REPO"
echo "ok 29 - trunk materialize builds private trunk and pointer branches"

# ------------------------------------------------------------------------
# 30: trunk materialize conflict preflight leaves all real refs unchanged.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/trunk-after --no-track >/dev/null 2>&1
  printf 'after\n' >after.txt
  git add after.txt
  git commit -m "trunk after" >/dev/null

  git checkout -b mho/trunk-child --no-track >/dev/null 2>&1
  printf 'child\n' >conflict.txt
  git add conflict.txt
  git commit -m "trunk child" >/dev/null

  git checkout mho/trunk-after >/dev/null 2>&1
  git checkout -b mho/trunk-insert --no-track >/dev/null 2>&1
  printf 'insert\n' >conflict.txt
  git add conflict.txt
  git commit -m "trunk insert" >/dev/null

  git checkout main >/dev/null 2>&1
  mkdir -p .stack
  jq -n '{
    version: 1,
    name: "conflict",
    base: "origin/main",
    trunk: "mho/conflict.trunk",
    items: [
      {id: "after", branch: "mho/trunk-after"},
      {id: "insert", branch: "mho/trunk-insert"},
      {id: "child", branch: "mho/trunk-child"}
    ]
  }' >.stack/conflict.json
  git add .stack/conflict.json
  git commit -m "add conflict stack manifest" >/dev/null
)
after_before=$(git -C "$REPO" rev-parse mho/trunk-after)
insert_before=$(git -C "$REPO" rev-parse mho/trunk-insert)
child_before=$(git -C "$REPO" rev-parse mho/trunk-child)

set +e
trunk_conflict=$(run_stack trunk materialize --manifest .stack/conflict.json 2>&1)
trunk_conflict_rc=$?
set -e
[[ "$trunk_conflict_rc" != "0" ]] || fail "expected trunk materialize conflict"
expect_contains "$trunk_conflict" "stack trunk materialize preflight failed"
expect_contains "$trunk_conflict" "Real branch refs were not changed"
[[ "$(git -C "$REPO" rev-parse mho/trunk-after)" == "$after_before" ]] || fail "trunk conflict moved after branch"
[[ "$(git -C "$REPO" rev-parse mho/trunk-insert)" == "$insert_before" ]] || fail "trunk conflict moved insert branch"
[[ "$(git -C "$REPO" rev-parse mho/trunk-child)" == "$child_before" ]] || fail "trunk conflict moved child branch"
git -C "$REPO" rev-parse --verify mho/conflict.trunk >/dev/null 2>&1 \
  && fail "failed trunk materialize should not create private trunk"
scratch_left=$(find "$TEST_TMP" -maxdepth 1 -type d -name 'stack-trunk.*' | wc -l | tr -d ' ')
[[ "$scratch_left" == "0" ]] || fail "trunk scratch dirs should be removed after failed preflight: $scratch_left"
REPO="$OLD_REPO"
echo "ok 30 - trunk materialize conflict leaves refs unchanged and cleans scratch"

# ------------------------------------------------------------------------
# 31: trunk init/add/status/materialize can use push-gate's stack store as
#     the manifest source of truth instead of a repo .stack file.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
jq -n '{}' >"$STACK_TEST_STACK_STORE"
: >"$STACK_TEST_STACK_MATERIALIZATIONS"
(
  cd "$REPO"
  git checkout mho/feature-base >/dev/null 2>&1
  git checkout -b mho/dolt-insert --no-track >/dev/null 2>&1
  printf 'dolt insert\n' >dolt-insert.txt
  git add dolt-insert.txt
  git commit -m "dolt insert feature" >/dev/null

  git checkout mho/feature-ui >/dev/null 2>&1
  git checkout -b mho/remove-me --no-track >/dev/null 2>&1
  printf 'remove me\n' >remove-me.txt
  git add remove-me.txt
  git commit -m "temporary removable stack item" >/dev/null
)

store_init=$(run_stack trunk init --name dolt-demo --base origin/main --trunk mho/dolt-demo.trunk 2>&1)
expect_contains "$store_init" "Stack stored: dolt-demo"
expect_contains "$store_init" "stack trunk add --stack dolt-demo"

store_add_base=$(run_stack trunk add --stack dolt-demo --id base --branch mho/feature-base --base origin/main 2>&1)
expect_contains "$store_add_base" "Stack item stored: dolt-demo/base"
store_add_insert=$(run_stack trunk add --stack dolt-demo --id insert --branch mho/dolt-insert --after base 2>&1)
expect_contains "$store_add_insert" "Stack item stored: dolt-demo/insert"
store_add_api=$(run_stack trunk add --stack dolt-demo --id api --branch mho/feature-api --after insert --pr 43 2>&1)
expect_contains "$store_add_api" "Stack item stored: dolt-demo/api"
store_add_ui=$(run_stack trunk add --stack dolt-demo --id ui --branch mho/feature-ui --after api 2>&1)
expect_contains "$store_add_ui" "Stack item stored: dolt-demo/ui"
store_add_remove=$(run_stack trunk add --stack dolt-demo --id remove-me --branch mho/remove-me --after ui 2>&1)
expect_contains "$store_add_remove" "Stack item stored: dolt-demo/remove-me"
store_list_with_item_base=$(run_stack trunk list --json 2>&1)
[[ "$(jq -r '.stacks[] | select(.name == "dolt-demo") | .items[] | select(.id == "base") | .pr == null' <<<"$store_list_with_item_base")" == "true" ]] \
  || fail "expected trunk list to preserve item base without treating it as PR: $store_list_with_item_base"

set +e
store_add_existing_after=$(run_stack trunk add --stack dolt-demo --id insert --branch mho/dolt-insert --after ui 2>&1)
store_add_existing_after_rc=$?
set -e
[[ "$store_add_existing_after_rc" != "0" ]] || fail "expected add --after existing item to fail"
expect_contains "$store_add_existing_after" "use stack trunk move --stack dolt-demo --id insert --after ui"

store_move_dry=$(run_stack trunk move --stack dolt-demo --id ui --first --dry-run 2>&1)
expect_contains "$store_move_dry" "Current order:"
expect_contains "$store_move_dry" "Proposed order:"
expect_contains "$store_move_dry" "Apply order change: stack trunk move --stack dolt-demo --id ui --first"

store_move_last=$(run_stack trunk move --stack dolt-demo --id insert --last 2>&1)
expect_contains "$store_move_last" "Stack item moved: dolt-demo/insert"
expect_contains "$store_move_last" "Materialize reordered trunk: stack trunk materialize --stack dolt-demo"
store_status_moved=$(run_stack trunk status --stack dolt-demo --json)
[[ "$(jq -r '.manifest.items[-1].id' <<<"$store_status_moved")" == "insert" ]] \
  || fail "expected insert to move last: $store_status_moved"

store_move_restore=$(run_stack trunk move --stack dolt-demo --id insert --after base 2>&1)
expect_contains "$store_move_restore" "Stack item moved: dolt-demo/insert"
store_status_restored=$(run_stack trunk status --stack dolt-demo --json)
[[ "$(jq -r '.manifest.items[1].id' <<<"$store_status_restored")" == "insert" ]] \
  || fail "expected insert restored after base: $store_status_restored"

store_remove_dry=$(run_stack trunk remove --stack dolt-demo --id remove-me --dry-run 2>&1)
expect_contains "$store_remove_dry" "Current order:"
expect_contains "$store_remove_dry" "Proposed order:"
expect_contains "$store_remove_dry" "Apply removal: stack trunk remove --stack dolt-demo --id remove-me"

store_remove_live=$(run_stack trunk remove --stack dolt-demo --id remove-me 2>&1)
expect_contains "$store_remove_live" "Stack item removed: dolt-demo/remove-me"
store_status_removed=$(run_stack trunk status --stack dolt-demo --json)
[[ "$(jq -r '[.manifest.items[].id] | index("remove-me") == null' <<<"$store_status_removed")" == "true" ]] \
  || fail "expected remove-me removed from manifest: $store_status_removed"

store_status=$(run_stack trunk status --stack dolt-demo 2>&1)
expect_contains "$store_status" "Stack trunk: dolt-demo"
expect_contains "$store_status" "Source: Dolt stack dolt-demo"
expect_contains "$store_status" "Materialize changes: stack trunk materialize --stack dolt-demo"

git -C "$REPO" checkout mho/feature-api >/dev/null 2>&1
store_live=$(run_stack trunk materialize --stack dolt-demo 2>&1)
expect_contains "$store_live" "Refreshed checked-out worktree for moved branch mho/feature-api"
expect_contains "$store_live" "Materialized private trunk: mho/dolt-demo.trunk"
expect_contains "$store_live" "Run affected tests, then inspect: stack trunk status --stack dolt-demo"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "materialize should refresh checked-out moved branch worktree"
git -C "$REPO" merge-base --is-ancestor mho/dolt-insert mho/feature-api \
  || fail "Dolt-store feature-api should be descendant of inserted branch"
[[ "$(git -C "$REPO" rev-parse mho/feature-ui)" == "$(git -C "$REPO" rev-parse mho/dolt-demo.trunk)" ]] \
  || fail "Dolt-store private trunk should point to final stack commit"
expect_contains "$(cat "$STACK_TEST_STACK_MATERIALIZATIONS")" '"stack":"dolt-demo"'
expect_contains "$(cat "$STACK_TEST_STACK_MATERIALIZATIONS")" '"trunk_tip":'

(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  printf 'base moved\n' >base-moved.txt
  git add base-moved.txt
  git commit -m "advance base after stack materialization" >/dev/null
  git update-ref refs/remotes/origin/main HEAD
)
store_stale_status=$(run_stack trunk status --stack dolt-demo 2>&1)
expect_contains "$store_stale_status" "Stack base moved since the private trunk was materialized."
expect_contains "$store_stale_status" "Materialize changes before review/approval: stack trunk materialize --stack dolt-demo"
store_stale_status_json=$(run_stack trunk status --stack dolt-demo --json)
[[ "$(jq -r '.alignment_state' <<<"$store_stale_status_json")" == "base_moved" ]] \
  || fail "expected stale base alignment state: $store_stale_status_json"
store_stale_review=$(run_stack trunk review --stack dolt-demo --json)
[[ "$(jq -r '.state' <<<"$store_stale_review")" == "needs_materialization" ]] \
  || fail "expected review to require materialization after base moves: $store_stale_review"
store_stale_push_plan=$(run_stack trunk push-plan --stack dolt-demo --json)
[[ "$(jq -r '.state' <<<"$store_stale_push_plan")" == "needs_materialization" ]] \
  || fail "expected push-plan to require materialization after base moves: $store_stale_push_plan"
[[ "$(jq -r '.checklist[] | select(.id == "materialized") | .ok' <<<"$store_stale_push_plan")" == "false" ]] \
  || fail "expected materialized checklist to fail after base moves: $store_stale_push_plan"
store_live_after_base_move=$(run_stack trunk materialize --stack dolt-demo 2>&1)
expect_contains "$store_live_after_base_move" "Materialized private trunk: mho/dolt-demo.trunk"
store_status_after_base_move=$(run_stack trunk status --stack dolt-demo --json)
[[ "$(jq -r '.alignment_state' <<<"$store_status_after_base_move")" == "up_to_date" ]] \
  || fail "expected rematerialize to clear stale base state: $store_status_after_base_move"

STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":43,"headRefName":"mho/feature-api","baseRefName":"mho/feature-base","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/43","title":"api"},
  {"number":44,"headRefName":"mho/feature-ui","baseRefName":"mho/feature-api","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/44","title":"ui"}
]')
materialized_status=$(run_stack status --pr 44 --children 2>&1)
expect_contains "$materialized_status" "Topology note: PR #44 base is mho/feature-api"
expect_contains "$materialized_status" "private trunk mho/dolt-demo.trunk from Dolt stack dolt-demo"
expect_contains "$materialized_status" "expected after stack trunk materialize"
expect_not_contains "$materialized_status" "local ancestry is stale/diagnostic"
store_push_dry=$(run_stack trunk push --stack dolt-demo --dry-run 2>&1)
expect_contains "$store_push_dry" "Trunk push order: dolt-demo"
expect_contains "$store_push_dry" "Push approved trunk items: stack trunk push --stack dolt-demo"

store_push_tip_dry=$(run_stack trunk push --stack dolt-demo --tip --dry-run 2>&1)
expect_contains "$store_push_tip_dry" "Trunk push mode: tip only"
expect_contains "$store_push_tip_dry" "Pushing validation ref:"
expect_contains "$store_push_tip_dry" "mho/dolt-demo.trunk"
expect_contains "$store_push_tip_dry" "Not pushing item branches:"
expect_contains "$store_push_tip_dry" "Push validation trunk tip: stack trunk push --stack dolt-demo --tip"

: >"$PG_LOG"
set +e
store_push_tip_live=$(run_stack trunk push --stack dolt-demo --tip --remote upstream 2>&1)
store_push_tip_live_rc=$?
set -e
[[ "$store_push_tip_live_rc" == "0" ]] \
  || fail "expected live trunk tip push to exit 0, got $store_push_tip_live_rc: $store_push_tip_live"
expect_contains "$store_push_tip_live" "Trunk push mode: tip only"
expect_contains "$store_push_tip_live" "Trunk tip push complete for dolt-demo."
expect_not_contains "$store_push_tip_live" "syntax error"
tip_push_calls=$(grep -c "^push push --trunk-stack dolt-demo" "$PG_LOG" || true)
[[ "$tip_push_calls" == "1" ]] \
  || fail "expected 1 trunk tip pg push call, got $tip_push_calls: $(cat "$PG_LOG")"
expect_contains "$(cat "$PG_LOG")" "--branch mho/dolt-demo.trunk"
expect_contains "$(cat "$PG_LOG")" "--source-ref mho/dolt-demo.trunk"
expect_contains "$(cat "$PG_LOG")" "--remote upstream"
expect_not_contains "$(cat "$PG_LOG")" "--branch mho/feature-ui"
expect_not_contains "$(cat "$PG_LOG")" "--source-ref $(git -C "$REPO" rev-parse mho/dolt-demo.trunk)"

git -C "$REPO" remote add upstream git@github.com:example/stack-pr-head.git >/dev/null 2>&1 || true
export STACK_TEST_PR_VIEW_43='{"number":43,"headRefName":"mho/feature-api","headRefOid":"old-api","headRepositoryOwner":{"login":"example"},"headRepository":{"name":"stack-pr-head"},"baseRefName":"mho/feature-base"}'
: >"$PG_LOG"
: >"$PUSHED_BRANCHES"
set +e
store_push_pr_remote=$(run_stack trunk push --stack dolt-demo 2>&1)
store_push_pr_remote_rc=$?
set -e
[[ "$store_push_pr_remote_rc" == "0" ]] \
  || fail "expected trunk push to infer PR head remote, got $store_push_pr_remote_rc: $store_push_pr_remote"
expect_contains "$store_push_pr_remote" "Trunk push complete for dolt-demo."
expect_contains "$store_push_pr_remote" "verified #43 head"
trunk_push_calls=$(grep -c "^push push --trunk-stack dolt-demo" "$PG_LOG" || true)
[[ "$trunk_push_calls" == "4" ]] \
  || fail "expected 4 trunk pg push calls with inferred remote, got $trunk_push_calls: $(cat "$PG_LOG")"
pr_remote_push_calls=$(grep -c -- "--remote upstream" "$PG_LOG" || true)
[[ "$pr_remote_push_calls" == "1" ]] \
  || fail "expected only PR item trunk push to infer upstream, got: $(cat "$PG_LOG")"
unset STACK_TEST_PR_VIEW_43

: >"$PG_LOG"
: >"$PUSHED_BRANCHES"
export STACK_TEST_PR_VIEW_43='{"number":43,"headRefName":"mho/feature-api","headRefOid":"old-api","headRepositoryOwner":{"login":"example"},"headRepository":{"name":"stack-pr-head"},"baseRefName":"mho/feature-base"}'
set +e
store_push_live=$(run_stack trunk push --stack dolt-demo --remote upstream 2>&1)
store_push_live_rc=$?
set -e
[[ "$store_push_live_rc" == "0" ]] \
  || fail "expected live trunk push to exit 0 after successful item pushes, got $store_push_live_rc: $store_push_live"
expect_contains "$store_push_live" "Trunk push order: dolt-demo"
expect_contains "$store_push_live" "Trunk push complete for dolt-demo."
expect_contains "$store_push_live" "Next step:"
expect_not_contains "$store_push_live" "syntax error"
trunk_push_calls=$(grep -c "^push push --trunk-stack dolt-demo" "$PG_LOG" || true)
[[ "$trunk_push_calls" == "4" ]] \
  || fail "expected 4 trunk pg push calls, got $trunk_push_calls: $(cat "$PG_LOG")"
remote_push_calls=$(grep -c -- "--remote upstream" "$PG_LOG" || true)
[[ "$remote_push_calls" == "4" ]] \
  || fail "expected each trunk push to preserve --remote upstream, got: $(cat "$PG_LOG")"
expect_contains "$(cat "$PG_LOG")" "--source-ref mho/feature-base"
expect_contains "$(cat "$PG_LOG")" "--source-ref mho/dolt-insert"
expect_contains "$(cat "$PG_LOG")" "--source-ref mho/feature-api"
expect_contains "$(cat "$PG_LOG")" "--source-ref mho/feature-ui"
unset STACK_TEST_PR_VIEW_43
REPO="$OLD_REPO"
echo "ok 31 - trunk commands use push-gate stack store as source of truth"

# ------------------------------------------------------------------------
# 32: stack trunk names must be private branches, not protected main refs.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
jq -n '{}' >"$STACK_TEST_STACK_STORE"

safe_trunk_init=$(run_stack trunk init --name scm-cassandra --base origin/main --trunk mho/trunk/scm-cassandra-dev 2>&1)
expect_contains "$safe_trunk_init" "Stack stored: scm-cassandra"

set +e
bad_trunk_init=$(run_stack trunk init --name bad-main --base origin/main --trunk upstream/main 2>&1)
bad_trunk_rc=$?
set -e
[[ "$bad_trunk_rc" != "0" ]] || fail "expected protected upstream/main trunk init to fail"
expect_contains "$bad_trunk_init" "not protected main ref: upstream/main"
REPO="$OLD_REPO"
echo "ok 32 - trunk init accepts private trunk branches and rejects upstream main"

# ------------------------------------------------------------------------
# 33: stack trunk commands print actionable Dolt prerequisite guidance.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
set +e
export STACK_TEST_PG_DOLT_MISSING=1
missing_dolt=$(run_stack trunk status --stack missing-dolt 2>&1)
missing_dolt_rc=$?
unset STACK_TEST_PG_DOLT_MISSING
set -e
[[ "$missing_dolt_rc" != "0" ]] || fail "expected missing Dolt stack status to fail"
expect_contains "$missing_dolt" "Dolt is required for stack trunk store commands."
expect_contains "$missing_dolt" "Install: brew install dolt"
expect_contains "$missing_dolt" "Verify: dolt version"
expect_contains "$missing_dolt" "PG_STORE_DIR"
REPO="$OLD_REPO"
echo "ok 33 - stack trunk commands explain missing Dolt setup"

# Restore default fake PR data for the final help/doc test.
export STACK_TEST_PR_JSON
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":42,"headRefName":"mho/feature-base","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"url":"https://x/42","title":"base"},
  {"number":43,"headRefName":"mho/feature-api","baseRefName":"mho/feature-base","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[{"conclusion":null,"status":"IN_PROGRESS"}],"url":"https://x/43","title":"api"}
]')

# ------------------------------------------------------------------------
# 34: help and skill docs match the supported command surface.
# ------------------------------------------------------------------------

help_out=$(run_stack --help 2>&1)
expect_contains "$help_out" "status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]"
expect_contains "$help_out" "checkout --pr N [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "insert --branch BRANCH (--after BRANCH|--after-pr N)"
expect_contains "$help_out" "trunk init --name NAME --base REF --trunk BRANCH"
expect_contains "$help_out" "trunk add --stack NAME --id ID --branch BRANCH"
expect_contains "$help_out" "trunk move --stack NAME --id ID"
expect_contains "$help_out" "trunk remove --stack NAME --id ID"
expect_contains "$help_out" "trunk materialize --stack NAME"
expect_contains "$help_out" "trunk materialize --manifest PATH"
expect_contains "$help_out" "Compatibility/import path"
expect_contains "$help_out" "trunk review --stack NAME [--json]"
expect_contains "$help_out" "trunk push-plan --stack NAME [--json]"
expect_contains "$help_out" "trunk push --stack NAME [--tip]"
expect_contains "$help_out" "squash [--dry-run] [-m SUBJECT] [--branch BRANCH] [--onto REF|--onto-pr-base]"
expect_contains "$help_out" "push [--dry-run] --pr N [--children] [--base REF] [--prefix PREFIX]"
expect_contains "$help_out" "STACK_DEBUG=1"
expect_contains "$help_out" "Every human-readable command prints Next step:"
expect_contains "$help_out" "Dolt is required for --stack"
expect_not_contains "$help_out" "prune"
skill_doc=$(cat "$ROOT/llm/skills/stack/SKILL.md")
expect_contains "$skill_doc" "agent-stack-refresh"
expect_contains "$skill_doc" "Dolt install/verification guidance"
expect_contains "$skill_doc" "stack squash [--dry-run]"
expect_contains "$skill_doc" "--onto-pr-base"
expect_contains "$skill_doc" "--keep-scratch"
expect_contains "$skill_doc" "stack insert --branch"
expect_contains "$skill_doc" "stack trunk move --stack"
expect_contains "$skill_doc" "Do not"
expect_contains "$skill_doc" "stack trunk materialize"
expect_contains "$skill_doc" "STACK_DEBUG=1"
expect_contains "$skill_doc" "Next step:"
expect_contains "$skill_doc" "stack checkout --pr <N>"
expect_contains "$skill_doc" 'Plain `stack push` no longer acts on broad local ancestry'
stack_doc=$(cat "$ROOT/llm/stack/README.md")
expect_contains "$stack_doc" "GitHub PR base wins"
expect_contains "$stack_doc" "stack insert --branch"
expect_contains "$stack_doc" "stack trunk move"
expect_contains "$stack_doc" "private trunk"
expect_contains "$stack_doc" "expected topology"
expect_contains "$stack_doc" "brew install dolt"
expect_contains "$stack_doc" "Next step:"
expect_contains "$stack_doc" "stack checkout --pr <N>"
expect_contains "$stack_doc" 'Plain `stack push` no longer acts on broad local ancestry'
expect_not_contains "$skill_doc" "## Deferred"
echo "ok 34 - help and stack skill docs match supported commands"

# ------------------------------------------------------------------------
# 35: status degrades when branch materialization lookup is slow.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
(
  cd "$REPO"
  git checkout main >/dev/null 2>&1
  git checkout -b mho/slow-redundant --no-track >/dev/null 2>&1
  printf 'slow redundant\n' >slow-redundant.txt
  git add slow-redundant.txt
  git commit -m "slow redundant parent" >/dev/null

  git checkout -b mho/slow-root --no-track >/dev/null 2>&1
  printf 'slow root\n' >slow-root.txt
  git add slow-root.txt
  git commit -m "slow root" >/dev/null

  git checkout -b mho/slow-child --no-track >/dev/null 2>&1
  printf 'slow child\n' >slow-child.txt
  git add slow-child.txt
  git commit -m "slow child" >/dev/null
)
STACK_TEST_PR_JSON=$(jq -c -n '[
  {"number":501,"headRefName":"mho/slow-root","baseRefName":"main","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/501","title":"slow root"},
  {"number":502,"headRefName":"mho/slow-child","baseRefName":"mho/slow-root","mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":[],"url":"https://x/502","title":"slow child"}
]')
export STACK_TEST_BRANCH_MATERIALIZATION_SLEEP=5
SECONDS=0
slow_status=$(STACK_BRANCH_MATERIALIZATION_TIMEOUT_SECONDS=1 run_stack status --pr 501 --children 2>&1)
elapsed=$SECONDS
unset STACK_TEST_BRANCH_MATERIALIZATION_SLEEP
expect_contains "$slow_status" "Topology mismatch: PR #501 base is main"
expect_contains "$slow_status" "mho/slow-root"
expect_contains "$slow_status" "mho/slow-child"
expect_contains "$slow_status" "Next step:"
(( elapsed < 4 )) || fail "status waited too long for branch materialization lookup: ${elapsed}s"
REPO="$OLD_REPO"
echo "ok 35 - status falls back when branch materialization lookup is slow"

# ------------------------------------------------------------------------
# 36: removing the final Dolt-backed stack item prunes empty stack metadata.
# ------------------------------------------------------------------------

OLD_REPO="$REPO"
REPO=$(make_stacked_repo)
REPO=$(cd "$REPO" && git rev-parse --show-toplevel)
jq -n '{}' >"$STACK_TEST_STACK_STORE"
: >"$STACK_TEST_STACK_MATERIALIZATIONS"

prune_init=$(run_stack trunk init --name prune-demo --base origin/main --trunk mho/prune-demo.trunk 2>&1)
expect_contains "$prune_init" "Stack stored: prune-demo"
prune_add=$(run_stack trunk add --stack prune-demo --id only --branch mho/feature-base 2>&1)
expect_contains "$prune_add" "Stack item stored: prune-demo/only"

prune_dry=$(run_stack trunk remove --stack prune-demo --id only --dry-run 2>&1)
expect_contains "$prune_dry" "Proposed order:"
expect_contains "$prune_dry" "  (empty)"
expect_contains "$prune_dry" "This will prune empty stack metadata; no materialize step remains."

prune_live=$(run_stack trunk remove --stack prune-demo --id only 2>&1)
expect_contains "$prune_live" "Stack pruned: prune-demo (removed final item only)"
expect_contains "$prune_live" "Empty stack metadata pruned: prune-demo"
expect_contains "$prune_live" "Confirm it is gone: stack trunk list"
expect_not_contains "$prune_live" "unbound variable"
expect_not_contains "$prune_live" "invalid stack trunk manifest"

prune_list=$(run_stack trunk list --json)
[[ "$(jq -r '[.stacks[].name] | index("prune-demo") == null' <<<"$prune_list")" == "true" ]] \
  || fail "expected prune-demo omitted from trunk list after final removal: $prune_list"

set +e
prune_status=$(run_stack trunk status --stack prune-demo 2>&1)
prune_status_rc=$?
prune_materialize=$(run_stack trunk materialize --stack prune-demo 2>&1)
prune_materialize_rc=$?
set -e
[[ "$prune_status_rc" != "0" ]] || fail "expected pruned stack status to fail"
[[ "$prune_materialize_rc" != "0" ]] || fail "expected pruned stack materialize to fail"
expect_contains "$prune_status" "stack not found in Dolt store: prune-demo"
expect_contains "$prune_materialize" "stack not found in Dolt store: prune-demo"
expect_not_contains "$prune_status" "invalid stack trunk manifest"
expect_not_contains "$prune_materialize" "invalid stack trunk manifest"

REPO="$OLD_REPO"
echo "ok 36 - final stack item removal prunes empty Dolt stack metadata"
