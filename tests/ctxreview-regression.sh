#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CTXREVIEW_IMPL="$ROOT/lib/ctxreview/main.sh"
CTXREVIEW_RUNTIME="$ROOT/lib/ctxreview/runtime-adapters.sh"
CURSOR_SPAWN_IMPL="$ROOT/lib/cursor-sub-review/spawn-cursor-pane.sh"
TMP="$(mktemp -d -t fba-ctxreview-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export CTXREVIEW_REAP_DIR="$TMP/reaped"
export CTXREVIEW_SESSION_STATE_DIR="$TMP/default-state"
export CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl"
export HERDR_SESSION_RUNNING_DIR="$TMP/herdr-running"
mkdir -p "$HERDR_SESSION_RUNNING_DIR"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

mkdir -p "$TMP/bin" "$TMP/repo" "$TMP/run" "$TMP/sol-run" "$TMP/link-run" \
  "$TMP/again-run" "$TMP/cursor-run" "$TMP/cursor-state/runs"
mkdir -p "$TMP/blocked-run"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" config user.email test@example.com
git -C "$TMP/repo" config user.name "Test User"
printf 'before\n' > "$TMP/repo/example.txt"
git -C "$TMP/repo" add example.txt
git -C "$TMP/repo" commit -qm initial
git -C "$TMP/repo" worktree add -q -b linked-fixture "$TMP/linked"
printf 'after\n' > "$TMP/repo/example.txt"
printf 'required = true\n' > "$TMP/repo/new_module.py"

cat > "$TMP/bin/ctxpack" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '# pack\n\nDiff base `HEAD`\n' > "$out"
EOF

cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TMP/bin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--list-models ") printf 'test-model\nkimi-k3-high\ncursor-grok-4.6-high\n' ;;
  "mcp list")
    if [ -e "${CURSOR_CONFIG_DIR:?}/ctxreview-fixture.disabled" ]; then
      printf 'ctxreview-fixture: disabled\n'
    else
      printf 'ctxreview-fixture: not loaded (needs approval)\n'
    fi
    ;;
  "mcp disable")
    [ "${3:-}" = ctxreview-fixture ] || exit 2
    : > "${CURSOR_CONFIG_DIR:?}/ctxreview-fixture.disabled"
    printf 'disable %s\n' "$3" >> "${CURSOR_MCP_CALLS:?}"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" mcp list --json "*)
    case " $* " in
      *mcp_servers.alpha.enabled=false*) enabled=false ;;
      *) enabled=true ;;
    esac
    printf '[{"name":"alpha","enabled":%s},{"name":"private-chat","enabled":%s}]\n' \
      "$enabled" "$enabled"
    ;;
esac
EOF

cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
session=""
if [ "${1:-}" = --session ]; then
  session="${2:-}"
  shift 2
  [ -z "${HERDR_SESSION_CALLS:-}" ] \
    || printf '%s\t%s\n' "$session" "$*" >> "$HERDR_SESSION_CALLS"
fi
printf '%s\n' "$*" >> "$HERDR_CALLS"
case "$1 $2" in
  "--version ") printf 'herdr 0.8.0\n' ;;
  "server ") mkdir -p "$HERDR_SESSION_RUNNING_DIR"; : > "$HERDR_SESSION_RUNNING_DIR/$session" ;;
  "session list")
    printf '{"sessions":['
    sep=""
    for f in "$HERDR_SESSION_RUNNING_DIR"/*; do
      [ -e "$f" ] || continue
      name="${f##*/}"
      printf '%s{"name":"%s","running":true}' "$sep" "$name"
      sep=,
    done
    printf ']}\n'
    ;;
  "session stop") rm -f "$HERDR_SESSION_RUNNING_DIR/${3:-}"; printf '{"result":{}}\n' ;;
  "status server") printf 'status: running\n' ;;
  "workspace create")
    printf '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  "pane split")
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "workspace list")
    if [ "${HERDR_NO_REVIEW_WORKSPACES:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","label":"unrelated"}]}}'
    elif [ -e "${HERDR_WORKSPACE_CLOSED:-/nonexistent}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w9","label":"unrelated"}]}}'
    else
      jq -nc --arg label "${HERDR_REVIEW_LABEL:-review: test}" \
        '{result:{workspaces:[{workspace_id:"w1",label:$label},{workspace_id:"w9",label:"unrelated"}]}}'
    fi
    ;;
  "workspace close") : > "${HERDR_WORKSPACE_CLOSED:-/tmp/ctxreview-test-closed}"; printf '{"result":{}}\n' ;;
  "tab create") printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
  "agent list")
    [ "${HERDR_AGENT_LIST_FAIL:-0}" = 0 ] || exit 1
    if [ "${HERDR_NO_AGENTS:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"agents":[]}}'
    elif [ -e "${HERDR_WORKSPACE_CLOSED:-/nonexistent}" ] \
         && [ "${HERDR_FORCE_AGENT:-0}" != 1 ]; then
      printf '%s\n' '{"result":{"agents":[]}}'
    elif [ "${HERDR_AGENT_KIND:-claude}" = cursor ]; then
      jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
        '{result:{agents:[{name:"ctxreview-kimi-w1p1",workspace_id:"w1",pane_id:"w1:p1",agent:"cursor",agent_status:$status,agent_session:{agent:"cursor",source:"herdr:cursor",value:"test-cursor-session"}}]}}'
    elif [ "${HERDR_AGENT_KIND:-claude}" = codex ]; then
      if [ "${HERDR_AGENT_NO_SESSION:-0}" = 1 ]; then
        jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
          '{result:{agents:[{name:"ctxreview-sol-w1p1",workspace_id:"w1",pane_id:"w1:p1",agent_status:$status}]}}'
      else
        jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
          '{result:{agents:[{name:"ctxreview-sol-w1p1",workspace_id:"w1",pane_id:"w1:p1",agent_status:$status,agent_session:{agent:"codex",source:"herdr:codex",value:"test-sol-session"}}]}}'
      fi
    else
      if [ "${HERDR_EXTRA_AGENT:-0}" = 1 ]; then
        jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
          '{result:{agents:[{name:"ctxreview-opus-w1p1",workspace_id:"w1",pane_id:"w1:p1",agent:"claude",agent_status:$status,agent_session:{agent:"claude",source:"herdr:claude",value:"test-session"}},{name:"ctxreview-sol-extra",workspace_id:"w1",pane_id:"w1:p2",agent:"codex",agent_status:"done",agent_session:{agent:"codex",source:"herdr:codex",value:"extra-session"}}]}}'
      else
        jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
          --arg workspace "${HERDR_AGENT_WORKSPACE:-w1}" \
          --arg pane "${HERDR_AGENT_PANE:-w1:p1}" \
          '{result:{agents:[{name:"ctxreview-opus-w1p1",workspace_id:$workspace,pane_id:$pane,agent:"claude",agent_status:$status,agent_session:{agent:"claude",source:"herdr:claude",value:"test-session"}}]}}'
      fi
    fi
    ;;
  "pane list")
    if [ "${HERDR_PANE_LIST_FAIL:-0}" = 1 ]; then
      exit 1
    elif [ "${HERDR_FOCUS_FIXTURE:-0}" = 1 ]; then
      if [ -e "${HERDR_FOCUS_RESTORED:-/nonexistent}" ]; then
        focused=w9
      elif [ -e "${HERDR_WORKSPACE_CLOSED:-/nonexistent}" ]; then
        focused=w8
      else
        focused=w9
      fi
      jq -nc --arg focused "$focused" '{result:{panes:[
        {pane_id:"w1:p1",workspace_id:"w1",tab_id:"w1:t1",cwd:"/fixture",focused:false},
        {pane_id:"w8:p1",workspace_id:"w8",tab_id:"w8:t1",cwd:"/other",focused:($focused=="w8")},
        {pane_id:"w9:p1",workspace_id:"w9",tab_id:"w9:t1",cwd:"/user",focused:($focused=="w9")}]}}'
    elif [ -e "${HERDR_WORKSPACE_CLOSED:-/nonexistent}" ]; then
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"t9","cwd":"/unrelated"}]}}'
    else
      printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"t1","cwd":"/fixture"},{"pane_id":"w9:p1","workspace_id":"w9","tab_id":"t9","cwd":"/unrelated"}]}}'
    fi
    ;;
  "agent get")
    [ "${HERDR_AGENT_GET_FAIL:-0}" = 0 ] || exit 1
    jq -nc --arg status "${HERDR_AGENT_STATUS:-idle}" \
      --argjson ready "${HERDR_INTERACTIVE_READY:-true}" \
      '{result:{agent:{agent:"claude",interactive_ready:$ready,agent_status:$status}}}'
    ;;
  "agent start")
    if [ "${HERDR_FAIL_ALL_START:-0}" = 1 ] \
       || [ "${HERDR_FAIL_AGENT:-}" = "${3:-}" ]; then
      printf '{"error":{"code":"agent_start_failed"}}\n' >&2
      exit 1
    fi
    if [ ! -e "$HERDR_START_ATTEMPT" ]; then
      : > "$HERDR_START_ATTEMPT"
      printf '{"error":{"code":"agent_pane_busy"}}\n' >&2
      exit 1
    fi
    printf '{"result":{"agent":{"agent_status":"idle"},"type":"agent_started"}}\n'
    ;;
  "pane wait-output")
    if [ ! -e "$HERDR_BANNER_ATTEMPT" ]; then
      : > "$HERDR_BANNER_ATTEMPT"
      printf '{"error":{"code":"timeout"}}\n' >&2
      exit 1
    fi
    printf '{"result":{}}\n'
    ;;
  "pane read") printf 'Opus 5 1M\n' ;;
  "agent read")
    if [ "${HERDR_CURSOR_UNVERIFIED:-0}" = 1 ]; then
      printf 'Cursor idle without a completion footer\n'
    elif [ "${HERDR_CURSOR_COMPOSING:-0}" = 1 ]; then
      printf 'Add a follow-up   ctrl+c to stop\n'
    elif [ "${HERDR_AGENT_KIND:-}" = cursor ]; then
      printf 'Add a follow-up\n'
    else
      printf 'durable terminal tail\n'
    fi
    ;;
  "agent prompt")
    printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2
    exit 1
    ;;
  "agent focus") : > "${HERDR_FOCUS_RESTORED:-/tmp/ctxreview-test-focus-restored}"; printf '{"result":{}}\n' ;;
  "agent send-keys"|"agent wait"|"pane send-keys") printf '{"result":{}}\n' ;;
  "pane rename") printf '{"result":{}}\n' ;;
  *) printf '{"result":{}}\n' ;;
esac
EOF

chmod +x "$TMP/bin/ctxpack" "$TMP/bin/claude" "$TMP/bin/codex" \
  "$TMP/bin/cursor-agent" "$TMP/bin/herdr"
cat > "$TMP/bin/failing-cursor-spawn" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin/failing-cursor-spawn"

: > "$TMP/invalid-calls"
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/invalid-calls" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" --base HEAD --legs opus \
      --dir "$TMP/implicit-run" >/dev/null 2>&1
); then
  fail "legacy implicit review launch was accepted"
fi
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/invalid-calls" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD \
      --dir "$TMP/default-run" >/dev/null 2>&1
); then
  fail "review launch defaulted the requested legs"
fi
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/invalid-calls" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs bogus \
      --dir "$TMP/invalid-run" >/dev/null 2>&1
); then
  fail "invalid --legs value exited successfully"
fi
! grep -Fq 'workspace create' "$TMP/invalid-calls" \
  || fail "invalid --legs created a workspace before validation"
for invalid_legs in 'sol,' 'sol,,opus' 'sol,sol'; do
  if (
    cd "$TMP/repo"
    HERDR_CALLS="$TMP/invalid-calls" PATH="$TMP/bin:$PATH" \
      "$ROOT/bin/ctxreview" run --base HEAD --legs "$invalid_legs" \
        --dir "$TMP/invalid-run" >/dev/null 2>&1
  ); then
    fail "invalid --legs list was accepted: $invalid_legs"
  fi
done

: > "$HERDR_SESSION_RUNNING_DIR/ctxreview-existing"
: > "$TMP/collision-calls"
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/collision-calls" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs opus \
      --herdr-session ctxreview-existing --dir "$TMP/collision-run" >/dev/null 2>&1
); then
  fail "ctxreview reused an existing named Herdr session"
fi
! grep -Fq 'workspace create' "$TMP/collision-calls" \
  || fail "session collision was detected after mutating existing layout"
rm -f "$HERDR_SESSION_RUNNING_DIR/ctxreview-existing"

ln -s "$ROOT/bin/ctxreview" "$TMP/ctxreview-link"
if ! (
  cd "$TMP/repo"
  CURSOR_MCP_CALLS="$TMP/cursor-mcp-calls" \
    CTXREVIEW_SESSION_STATE_DIR="$TMP/link-state" PATH="$TMP/bin:$PATH" \
    "$TMP/ctxreview-link" run --base HEAD --legs kimi \
    --dry-run --dir "$TMP/link-run" >/dev/null 2>&1
); then
  fail "ctxreview could not resolve repo-owned helpers through an installed symlink"
fi

if ! output="$(
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_BANNER_ATTEMPT="$TMP/banner-attempt" \
    CTXREVIEW_SESSION_ID="test-parent" CTXREVIEW_SESSION_STATE_DIR="$TMP/state" \
    CTXREVIEW_PANE_READY_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs opus --dir "$TMP/run" 2>&1
)"; then
  printf '%s\n' "$output" >&2
  fail "ctxreview launch failed"
fi

grep -Fq \
  'agent start ctxreview-opus-w1p1 --kind claude --pane w1:p1 --timeout 90000 -- --strict-mcp-config --mcp-config {"mcpServers":{}} --permission-mode plan --dangerously-skip-permissions' \
  "$TMP/calls" || fail "Opus did not use the Herdr plan/unsafe launch contract"
grep -Eq '^workspace create .*--no-focus$' "$TMP/calls" \
  || fail "ctxreview did not explicitly preserve focus while creating its workspace"
! grep -Fq 'tab create' "$TMP/calls" \
  || fail "ctxreview created a redundant tab inside its dedicated workspace"
if grep -E 'herdr (workspace create|tab create|pane split)' "$CTXREVIEW_IMPL" \
     | grep -Ev '^[[:space:]]*#' \
     | grep -Fv -- '--no-focus' >/dev/null; then
  fail "a ctxreview background creation path can still steal focus"
fi
! grep -E 'herdr workspace focus' "$CTXREVIEW_IMPL" \
  | grep -Ev '^[[:space:]]*#' >/dev/null \
  || fail "ctxreview explicitly focuses a workspace"
[[ "$(grep -Fc 'agent start ctxreview-opus-w1p1' "$TMP/calls")" -eq 2 ]] \
  || fail "ctxreview did not retry a pane whose login shell was still starting"
grep -Fq 'agent send-keys ctxreview-opus-w1p1 enter' "$TMP/calls" \
  || fail "stalled prompt did not receive an explicit Enter"
grep -Fq 'agent wait ctxreview-opus-w1p1 --until working --timeout 10000' "$TMP/calls" \
  || fail "ctxreview did not verify lifecycle progress after Enter"
[[ "$output" == *"submitted with explicit Enter; conversible"* ]] \
  || fail "ctxreview did not report the recovered prompt"
grep -Fxq 'opus' "$TMP/run/.launched" \
  || fail "a submitted review leg was not recorded as launched"
[ -f "$TMP/run/.launch-complete" ] \
  || fail "ctxreview did not seal the final launched-leg count"
grep -Fq 'diff --git a/new_module.py b/new_module.py' "$TMP/run/diff.patch" \
  || fail "--base HEAD omitted an untracked file from the review patch"
grep -Fq '+required = true' "$TMP/run/diff.patch" \
  || fail "untracked file contents were absent from the review patch"
[[ "$(stat_mode "$TMP/run")" == 700 ]] \
  || fail "review artifact directory was not mode 700"
[[ "$(stat_mode "$TMP/run/session.json")" == 600 ]] \
  || fail "review session record was not mode 600"
[[ "$(stat_mode "$TMP/state")" == 700 ]] \
  || fail "review state directory was not mode 700"
[[ "$(stat_mode "$TMP/state/events.jsonl")" == 600 ]] \
  || fail "review events were not mode 600"

! grep -Fq -- "-c 'mcp_servers={}'" "$CTXREVIEW_RUNTIME" \
  || fail "Codex review legs still use the ineffective empty-table MCP override"
grep -Fq -- 'mcp_servers.$id.enabled=false' "$CTXREVIEW_RUNTIME" \
  || fail "Codex review legs do not disable each effective MCP server"
grep -Fq -- '--config-dir "$SESSION_STATE_DIR/cursor-config"' "$CTXREVIEW_IMPL" \
  || fail "Cursor review legs do not use an isolated config"
! grep -Fq -- '--approve-mcps' "$CURSOR_SPAWN_IMPL" \
  || fail "Cursor review legs still auto-approve every MCP server"
! grep -Fq -- '--approve-mcps' "$ROOT/llm/skills/cursor-sub-review/scripts/run-review.sh" \
  || fail "headless Cursor review legs still auto-approve every MCP server"

jq -e '
  .schema == 3 and
  .requested_legs == ["opus"] and
  .owner_session == "test-parent" and
  .workspace_ids == ["w1"] and
  .legs.opus.runtime_session_id == "test-session"
' "$TMP/run/session.json" >/dev/null \
  || fail "ctxreview did not persist parent/runtime session ownership"
run_id="$(jq -r '.run_id' "$TMP/run/session.json")"
[[ "$run_id" != run && "$run_id" == review-* ]] \
  || fail "explicit --dir basename was reused as a global ownership id"
jq -s -e --arg run "$run_id" '
  any(.[]; .event=="round_created" and .run_id==$run) and
  any(.[]; .event=="leg_started" and .run_id==$run and .leg=="opus")
' "$TMP/state/events.jsonl" >/dev/null \
  || fail "review launch did not emit round/leg lifecycle telemetry"

if ! again_output="$(
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/again-calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_BANNER_ATTEMPT="$TMP/banner-attempt" HERDR_NO_REVIEW_WORKSPACES=1 \
    CTXREVIEW_SESSION_ID="again-parent" CTXREVIEW_SESSION_STATE_DIR="$TMP/again-state" \
    CTXREVIEW_PANE_READY_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --again --base HEAD --legs opus \
      --dir "$TMP/again-run" 2>&1
)"; then
  printf '%s\n' "$again_output" >&2
  fail "first-use --again crashed"
fi
[[ "$again_output" == *"no previous owned review workspace"* ]] \
  || fail "first-use --again did not take the no-prior-round path"

if ! (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/blocked-calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_BANNER_ATTEMPT="$TMP/banner-attempt" HERDR_AGENT_STATUS=blocked \
    CTXREVIEW_SESSION_ID="blocked-parent" CTXREVIEW_SESSION_STATE_DIR="$TMP/blocked-state" \
    CTXREVIEW_PANE_READY_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs opus \
      --dir "$TMP/blocked-run" >/dev/null 2>&1
); then
  fail "blocked-leg fixture did not launch"
fi
for _ in $(seq 1 20); do
  [ -s "$TMP/blocked-run/opus.reaper.log" ] && break
  sleep 0.05
done
for _ in $(seq 1 100); do
  jq -e '.legs.opus.outcome=="failure"' "$TMP/blocked-run/session.json" \
    >/dev/null 2>&1 && break
  sleep 0.05
done
jq -e '.outcome=="failure" and .legs.opus.outcome=="failure" and
       .legs.opus.reason=="blocked"' "$TMP/blocked-run/session.json" >/dev/null \
  || fail "a blocked reviewer did not become an explicit terminal failure"
blocked_run_id="$(jq -r '.run_id' "$TMP/blocked-run/session.json")"
for _ in $(seq 1 100); do
  [ "$(jq -r --arg run "$blocked_run_id" \
    'select(.event=="leg_terminal" and .run_id==$run and .leg=="opus")|1' \
    "$TMP/blocked-state/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ] && break
  sleep 0.05
done
[[ "$(jq -r --arg run "$blocked_run_id" \
  'select(.event=="leg_terminal" and .run_id==$run and .leg=="opus")|1' \
  "$TMP/blocked-state/events.jsonl" | wc -l | tr -d ' ')" -eq 1 ]] \
  || fail "blocked reviewer emitted zero or duplicate terminal events"

CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bug "flag-safe bug" --run review-attributed \
    --leg sol --session bug-parent >/dev/null
jq -e '.tool == "ctxreview" and .text == "flag-safe bug" and
       .run_id=="review-attributed" and .leg=="sol" and
       .owner_session=="bug-parent"' "$TMP/bugs.jsonl" >/dev/null \
  || fail "--bug consumed the following flag as its optional tool"
CTXREVIEW_RUN_ID=review-env CTXREVIEW_LEG=kimi CTXREVIEW_SESSION_ID=bug-env \
  CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bug "environment attribution" >/dev/null
jq -e 'select(.text=="environment attribution") |
       .run_id=="review-env" and .leg=="kimi" and .owner_session=="bug-env"' \
  "$TMP/bugs.jsonl" >/dev/null || fail "bug attribution environment defaults were lost"
if CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bug "bad leg" --leg unknown >/dev/null 2>&1; then
  fail "invalid bug leg was accepted"
fi
bugs_before="$(wc -l < "$TMP/bugs.jsonl" | tr -d ' ')"
bug_pids=()
for n in $(seq 1 12); do
  CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" --bug "concurrent bug $n" >/dev/null &
  bug_pids+=("$!")
done
for pid in "${bug_pids[@]}"; do wait "$pid"; done
bugs_after="$(wc -l < "$TMP/bugs.jsonl" | tr -d ' ')"
[[ "$bugs_after" -eq $((bugs_before + 12)) ]] \
  || fail "concurrent agent bug filings lost JSONL records"
first_bug_id="$(jq -r 'select(.text=="concurrent bug 1")|.id' "$TMP/bugs.jsonl")"
CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bug-fixed "$first_bug_id" >/dev/null & fixed_pid=$!
CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bug "filed during rewrite" >/dev/null & filing_pid=$!
wait "$fixed_pid"; wait "$filing_pid"
[[ "$(wc -l < "$TMP/bugs.jsonl" | tr -d ' ')" -eq $((bugs_after + 1)) ]] \
  || fail "bug status rewrite lost a concurrent agent filing"
jq -e --arg id "$first_bug_id" 'select(.id==$id and .status=="fixed")' \
  "$TMP/bugs.jsonl" >/dev/null || fail "bug status rewrite was not persisted"
mkdir -p "$TMP/workc"
TMPDIR="$TMP/workc" CTXREVIEW_BUGS_FILE="$TMP/bugs.jsonl" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --bugs open --session bug-parent >/dev/null
! find "$TMP/workc" -maxdepth 1 -type d -name 'ctxreview-c.*' | grep -q . \
  || fail "ctxreview leaked its scratch directory on an inspection action"

# Codex config overrides merge, so an empty mcp_servers table does not disable
# configured servers. The review leg must disable every effective id. Also prove
# that a late native session id does not make a successfully launched leg fail
# or disappear from ownership state; scoped cleanup refreshes it before close.
if ! sol_output="$(
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/sol-calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_BANNER_ATTEMPT="$TMP/banner-attempt" HERDR_AGENT_KIND=codex \
    HERDR_AGENT_NO_SESSION=1 CTXREVIEW_SESSION_ID="sol-parent" \
    CTXREVIEW_SESSION_STATE_DIR="$TMP/sol-state" \
    CTXREVIEW_PANE_READY_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs sol --dir "$TMP/sol-run" 2>&1
)"; then
  printf '%s\n' "$sol_output" >&2
  fail "Codex review launch failed when its native session id was late"
fi
grep -Fq -- '-c mcp_servers.alpha.enabled=false' "$TMP/sol-calls" \
  || fail "Codex review did not disable the first effective MCP server"
grep -Fq -- '-c mcp_servers.private-chat.enabled=false' "$TMP/sol-calls" \
  || fail "Codex review did not disable a hyphenated MCP server id"
grep -Fq -- '-c apps._default.enabled=false' "$TMP/sol-calls" \
  || fail "Codex review did not disable app/connector tools"
grep -Fq -- '100000 characters' "$TMP/sol-run/sol.prompt.md" \
  || fail "review pointers do not tell capped file readers to continue in chunks"
grep -Fq -- 'Never run `find`, `grep`' "$TMP/sol-run/prompt.md" \
  || fail "review prompt does not keep recursive searches inside the repository"
sol_pointer_run="$(jq -r '.run_id' "$TMP/sol-run/session.json")"
grep -Fq -- "ctxreview --bug \"<what broke, concretely>\" ctxreview --run $sol_pointer_run --leg sol --session sol-parent" \
  "$TMP/sol-run/sol.prompt.md" \
  || fail "review pointer omitted the exact attributed bug filing command"
jq -e '
  .owner_session == "sol-parent" and
  .legs.sol.agent_name == "ctxreview-sol-w1p1" and
  .legs.sol.runtime_session_id == ""
' "$TMP/sol-run/session.json" >/dev/null \
  || fail "a late native id caused Codex ownership metadata to be dropped"

# Requested legs exist before launch. A partial failure must retain both legs,
# classify the usable terminal tail as degraded, and fail the round.
mkdir -p "$TMP/partial-run"
if partial_output="$(
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/partial-calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_BANNER_ATTEMPT="$TMP/banner-attempt" HERDR_AGENT_KIND=codex \
    HERDR_FAIL_AGENT=ctxreview-opus-w1p1 \
    CTXREVIEW_SESSION_ID=partial-parent CTXREVIEW_SESSION_STATE_DIR="$TMP/partial-state" \
    CTXREVIEW_PANE_READY_DELAY_SECONDS=0 PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs sol,opus \
      --dir "$TMP/partial-run" 2>&1
)"; then
  printf '%s\n' "$partial_output" >&2
  fail "partial launch failure exited successfully"
fi
for _ in $(seq 1 100); do
  jq -e '.legs.sol.outcome=="degraded" and .legs.opus.outcome=="failure"' \
    "$TMP/partial-run/session.json" >/dev/null 2>&1 && break
  sleep 0.05
done
jq -e '.schema==3 and .requested_legs==["sol","opus"] and
       .legs.sol.outcome=="degraded" and .legs.sol.reason=="tail_only" and
       .legs.opus.outcome=="failure" and .legs.opus.reason=="start_failed" and
       .outcome=="failure"' "$TMP/partial-run/session.json" >/dev/null \
  || fail "partial launch outcomes were dropped or rewritten"

mkdir -p "$TMP/all-failed-run"
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/all-failed-calls" HERDR_FAIL_ALL_START=1 \
    CTXREVIEW_SESSION_ID=all-failed-parent \
    CTXREVIEW_SESSION_STATE_DIR="$TMP/all-failed-state" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs sol,opus \
      --dir "$TMP/all-failed-run" \
      >/dev/null 2>&1
); then
  fail "all-failed launch exited successfully"
fi
jq -e '.requested_legs==["sol","opus"] and .outcome=="failure" and
       ([.legs.sol.outcome,.legs.opus.outcome] | all(.=="failure"))' \
  "$TMP/all-failed-run/session.json" >/dev/null \
  || fail "all-failed launch did not persist every requested outcome"

mkdir -p "$TMP/cursor-failed-run"
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/cursor-failed-calls" HERDR_AGENT_GET_FAIL=1 \
    CURSOR_MCP_CALLS="$TMP/cursor-failed-mcp" \
    CTXREVIEW_CURSOR_SPAWN="$TMP/bin/failing-cursor-spawn" \
    CTXREVIEW_SESSION_ID=cursor-failed-parent \
    CTXREVIEW_SESSION_STATE_DIR="$TMP/cursor-failed-state" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs kimi \
      --dir "$TMP/cursor-failed-run" >/dev/null 2>&1
); then
  fail "failed Cursor spawn exited successfully"
fi
jq -e '.workspace_ids==["w1"] and (.herdr_session_name | startswith("ctxreview-")) and
       .outcome=="failure" and
       .legs.kimi.outcome=="failure" and .legs.kimi.reason=="spawn_failed" and
       .legs.kimi.agent_name=="ctxreview-kimi-w1p1" and
       .legs.kimi.pane_id=="w1:p1" and .legs.kimi.kind=="cursor"' \
  "$TMP/cursor-failed-run/session.json" >/dev/null \
  || fail "failed Cursor spawn lost named-session cleanup ownership"

mkdir -p "$TMP/not-ready-run"
if (
  cd "$TMP/repo"
  HERDR_CALLS="$TMP/not-ready-calls" HERDR_START_ATTEMPT="$TMP/start-attempt" \
    HERDR_INTERACTIVE_READY=false CTXREVIEW_INTERACTIVE_READY_ATTEMPTS=1 \
    CTXREVIEW_INTERACTIVE_READY_DELAY_SECONDS=0 \
    CTXREVIEW_SESSION_ID=not-ready-parent \
    CTXREVIEW_SESSION_STATE_DIR="$TMP/not-ready-state" PATH="$TMP/bin:$PATH" \
    "$ROOT/bin/ctxreview" run --base HEAD --legs opus --dir "$TMP/not-ready-run" \
      >/dev/null 2>&1
); then
  fail "non-ready agent launch exited successfully"
fi
jq -e '.outcome=="failure" and .legs.opus.outcome=="failure" and
       .legs.opus.reason=="interactive_not_ready" and
       .legs.opus.agent_name=="ctxreview-opus-w1p1" and
       .legs.opus.pane_id=="w1:p1"' "$TMP/not-ready-run/session.json" >/dev/null \
  || fail "post-start readiness failure left its live agent unowned"

sol_review_label="$(jq -r '.label' "$TMP/sol-run/session.json")"
: > "$TMP/sol-calls"
HERDR_CALLS="$TMP/sol-calls" HERDR_REVIEW_LABEL="$sol_review_label" \
  HERDR_WORKSPACE_CLOSED="$TMP/sol-workspace-closed" HERDR_AGENT_KIND=codex \
  HERDR_AGENT_NO_SESSION=1 \
  HERDR_AGENT_LIST_FAIL=1 CTXREVIEW_SESSION_STATE_DIR="$TMP/sol-state" \
  PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --close-session sol-parent >/dev/null
! grep -Fq 'session stop' "$TMP/sol-calls" \
  || fail "session cleanup stopped a named session without an agent inventory"
jq -e '.status == "waiting"' "$TMP/sol-run/session.json" >/dev/null \
  || fail "failed inventory was not persisted as waiting"

sol_run_id="$(jq -r '.run_id' "$TMP/sol-run/session.json")"
for record in "$TMP/sol-run/session.json" "$TMP/sol-state/runs/$sol_run_id.json"; do
  jq '.legs.sol.runtime_session_id="preserved-sol-session" |
      .legs.sol.runtime_session_source="herdr:codex"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
done

HERDR_CALLS="$TMP/sol-calls" HERDR_REVIEW_LABEL="$sol_review_label" \
  HERDR_WORKSPACE_CLOSED="$TMP/sol-workspace-closed" HERDR_AGENT_KIND=codex \
  HERDR_AGENT_NO_SESSION=1 \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/sol-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --close-session sol-parent >/dev/null
jq -e '.status == "closed" and .legs.sol.status == "closed" and
       .legs.sol.runtime_session_id == "preserved-sol-session"' \
  "$TMP/sol-run/session.json" >/dev/null || {
    jq '.' "$TMP/sol-run/session.json" >&2
    fail "scoped cleanup did not preserve the Codex session id before close"
  }

sol_herdr_session="$(jq -r '.herdr_session_name' "$TMP/sol-run/session.json")"
grep -Fq "session stop $sol_herdr_session --json" "$TMP/sol-calls" \
  || fail "settled cleanup did not stop the exact named Herdr session"
! grep -Eq 'workspace close|pane close|agent focus' "$TMP/sol-calls" \
  || fail "named-session cleanup mutated the shared default-session layout"

: > "$TMP/sol-respawn-calls"
: > "$TMP/sol-session-calls"
HERDR_CALLS="$TMP/sol-respawn-calls" HERDR_SESSION_CALLS="$TMP/sol-session-calls" \
  HERDR_AGENT_KIND=codex CTXREVIEW_SESSION_STATE_DIR="$TMP/sol-state" \
  PATH="$TMP/bin:$PATH" "$ROOT/bin/ctxreview" --respawn "$sol_run_id" >/dev/null
! grep -Fq 'agent start' "$TMP/sol-respawn-calls" \
  || fail "named restore manually relaunched an agent"
grep -Fq "$sol_herdr_session"$'\t''agent list' "$TMP/sol-session-calls" \
  || fail "named restore did not inspect the isolated session"
jq -e '.status=="open" and .herdr_session_state=="running" and .last_resumed_at' \
  "$TMP/sol-run/session.json" >/dev/null \
  || fail "named restore state was not persisted"

: > "$TMP/sol-attach-calls"
HERDR_CALLS="$TMP/sol-respawn-calls" HERDR_SESSION_CALLS="$TMP/sol-attach-calls" \
  HERDR_AGENT_KIND=codex CTXREVIEW_SESSION_STATE_DIR="$TMP/sol-state" \
  PATH="$TMP/bin:$PATH" "$ROOT/bin/ctxreview" --attach "$sol_run_id" sol >/dev/null
grep -Fq "$sol_herdr_session"$'\t''agent attach ctxreview-sol-w1p1' "$TMP/sol-attach-calls" \
  || fail "direct attach did not target the persisted agent in its named session"

mkdir -p "$TMP/working-state/runs" "$TMP/working-run"
jq -n --arg repo "$TMP/repo" --arg rundir "$TMP/working-run" \
  '{schema:3,run_id:"working-run",owner_session:"working-parent",repo_root:$repo,
    run_dir:$rundir,label:"review: working fixture",created_at:"2000-01-01T00:00:00Z",
    owner_ended_at:"2000-01-01T00:00:00Z",
    herdr_session_name:"ctxreview-working",herdr_session_state:"running",
    workspace_ids:["w1"],requested_legs:["opus"],status:"open",
    legs:{opus:{agent_name:"ctxreview-opus-w1p1",kind:"claude",model:"test-model",
      pane_id:"w1:p1",runtime_session_id:"working-session",status:"open",outcome:"pending"}}}' \
  > "$TMP/working-state/runs/working-run.json"
cp "$TMP/working-state/runs/working-run.json" "$TMP/working-run/session.json"
: > "$HERDR_SESSION_RUNNING_DIR/ctxreview-working"
: > "$TMP/working-calls"
HERDR_CALLS="$TMP/working-calls" HERDR_AGENT_STATUS=working \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/working-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --close-session working-parent >/dev/null
! grep -Fq 'session stop ctxreview-working' "$TMP/working-calls" \
  || fail "cleanup stopped a working named session"
jq -e '.status=="waiting" and .last_cleanup_outcome=="deferred"' \
  "$TMP/working-run/session.json" >/dev/null \
  || fail "working named session was not preserved"

HERDR_CALLS="$TMP/working-calls" HERDR_AGENT_STATUS=working \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/working-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --maintain --all --owner-ended-idle 0 >/dev/null
! grep -Fq 'session stop ctxreview-working' "$TMP/working-calls" \
  || fail "aged-idle policy stopped a working named session"

# An owner-ended session with only idle agents eventually hibernates even when
# Cursor's footer cannot prove completion. The first pass proves the TTL still
# defers it; the second expires it. Keep run_dir relative to cover maintenance
# launched from a different repository than the review itself.
mkdir -p "$TMP/aged-state/runs" "$TMP/aged-repo/.ctxreview/run"
jq -n --arg repo "$TMP/aged-repo" \
  '{schema:3,run_id:"aged-idle-run",owner_session:"aged-parent",repo_root:$repo,
    run_dir:".ctxreview/run",label:"review: aged idle fixture",
    created_at:"2000-01-01T00:00:00Z",owner_ended_at:"2000-01-01T00:00:00Z",
    herdr_session_name:"ctxreview-aged-idle",herdr_session_state:"running",
    workspace_ids:["w1"],requested_legs:["kimi"],status:"waiting",
    legs:{kimi:{agent_name:"ctxreview-kimi-w1p1",kind:"cursor",model:"test-model",
      pane_id:"w1:p1",runtime_session_id:"aged-session",status:"open",outcome:"pending"}}}' \
  > "$TMP/aged-state/runs/aged-idle-run.json"
: > "$HERDR_SESSION_RUNNING_DIR/ctxreview-aged-idle"
: > "$TMP/aged-calls"
HERDR_CALLS="$TMP/aged-calls" HERDR_AGENT_KIND=cursor HERDR_CURSOR_UNVERIFIED=1 \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/aged-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --maintain --all --owner-ended-idle 99999999 >/dev/null
! grep -Fq 'session stop ctxreview-aged-idle' "$TMP/aged-calls" \
  || fail "owner-ended idle session ignored its abandonment TTL"

aged_output="$(HERDR_CALLS="$TMP/aged-calls" HERDR_AGENT_KIND=cursor \
  HERDR_CURSOR_UNVERIFIED=1 CTXREVIEW_SESSION_STATE_DIR="$TMP/aged-state" \
  PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --maintain --all --owner-ended-idle 0)"
[[ "$aged_output" == *"owner_ended_idle_expired"* ]] \
  || fail "aged-idle maintenance did not report its explicit close reason"
grep -Fq 'session stop ctxreview-aged-idle --json' "$TMP/aged-calls" \
  || fail "aged owner-ended idle session was not hibernated"
jq -e --arg artifact "$TMP/aged-repo/.ctxreview/run/kimi.tail.md" '
  .status=="closed" and .closed_reason=="owner_ended_idle_expired" and
  .herdr_session_state=="stopped" and .resumable==true and
  .legs.kimi.outcome=="degraded" and .legs.kimi.reason=="tail_only" and
  .legs.kimi.artifact==$artifact' "$TMP/aged-state/runs/aged-idle-run.json" >/dev/null \
  || fail "aged idle cleanup did not persist its tail and terminal outcome"
[ -s "$TMP/aged-repo/.ctxreview/run/kimi.tail.md" ] \
  || fail "relative run_dir was not resolved against the review repository"
! grep -Fq 'agent focus' "$TMP/aged-calls" \
  || fail "aged idle cleanup changed focus"

mkdir -p "$TMP/untracked-state/runs" "$TMP/untracked-run"
printf 'report\n' > "$TMP/untracked-run/opus.md"
jq -n --arg repo "$TMP/repo" --arg rundir "$TMP/untracked-run" \
  '{schema:3,run_id:"untracked-run",owner_session:"untracked-parent",repo_root:$repo,
    run_dir:$rundir,label:"review: untracked fixture",created_at:"2000-01-01T00:00:00Z",
    herdr_session_name:"ctxreview-untracked",herdr_session_state:"running",
    workspace_ids:["w1"],requested_legs:["opus"],status:"settled",
    legs:{opus:{agent_name:"ctxreview-opus-w1p1",kind:"claude",model:"test-model",
      pane_id:"w1:p1",runtime_session_id:"tracked-session",status:"settled",outcome:"success"}}}' \
  > "$TMP/untracked-state/runs/untracked-run.json"
cp "$TMP/untracked-state/runs/untracked-run.json" "$TMP/untracked-run/session.json"
: > "$HERDR_SESSION_RUNNING_DIR/ctxreview-untracked"
: > "$TMP/untracked-calls"
HERDR_CALLS="$TMP/untracked-calls" HERDR_EXTRA_AGENT=1 \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/untracked-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --close-session untracked-parent >/dev/null
! grep -Fq 'session stop ctxreview-untracked' "$TMP/untracked-calls" \
  || fail "cleanup stopped a named session containing an untracked agent"
jq -e '.status=="waiting" and
       .last_cleanup_detail=="untracked_agent_in_named_session"' \
  "$TMP/untracked-run/session.json" >/dev/null \
  || fail "untracked named-session agent was not surfaced"

mkdir -p "$TMP/stopped-state/runs" "$TMP/stopped-run"
jq -n --arg repo "$TMP/repo" --arg rundir "$TMP/stopped-run" \
  '{schema:3,run_id:"stopped-run",owner_session:"stopped-parent",repo_root:$repo,
    run_dir:$rundir,label:"review: stopped fixture",created_at:"2000-01-01T00:00:00Z",
    herdr_session_name:"ctxreview-stopped",herdr_session_state:"running",
    workspace_ids:["w1"],requested_legs:["opus"],status:"open",
    legs:{opus:{agent_name:"ctxreview-opus-w1p1",kind:"claude",model:"test-model",
      pane_id:"w1:p1",status:"open",outcome:"pending"}}}' \
  > "$TMP/stopped-state/runs/stopped-run.json"
cp "$TMP/stopped-state/runs/stopped-run.json" "$TMP/stopped-run/session.json"
stopped_output="$(HERDR_CALLS="$TMP/stopped-calls" \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/stopped-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --maintain --all)"
[[ "$stopped_output" == *"reconciled: 1"* ]] \
  || fail "maintenance did not reconcile a stopped named session"
jq -e '.status=="closed" and .herdr_session_state=="stopped" and .resumable==true' \
  "$TMP/stopped-run/session.json" >/dev/null \
  || fail "stopped named session was not persisted as resumable"

named_stats="$(HERDR_CALLS="$TMP/stopped-calls" \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/stopped-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --stats)"
[[ "$named_stats" == *$'  focus_isolation:\n    strategy: named_herdr_session_socket'* &&
   "$named_stats" == *$'    default_session_mutations: 0'* ]] \
  || fail "telemetry omitted the named-session focus-isolation contract"

# The OKR denominator is terminal schema-3 leg outcomes only. Degraded is
# visible but is not silently folded into either success or failure; historical
# schema-2 rounds remain explicitly unclassified.
mkdir -p "$TMP/stats-state/runs"
jq -n '{schema:3,run_id:"okr-four",owner_session:"okr-parent",
  requested_legs:["kimi","grok","sol","opus"],status:"open",legs:{
    kimi:{outcome:"success"},grok:{outcome:"degraded"},
    sol:{outcome:"failure"},opus:{outcome:"pending"}}}' \
  > "$TMP/stats-state/runs/okr-four.json"
jq -n '{schema:3,run_id:"okr-subset",owner_session:"okr-parent",
  requested_legs:["sol"],status:"settled",legs:{sol:{outcome:"success"}}}' \
  > "$TMP/stats-state/runs/okr-subset.json"
jq -n '{schema:2,run_id:"okr-pre-named",owner_session:"okr-parent",
  status:"settled",legs:{opus:{status:"settled"}}}' \
  > "$TMP/stats-state/runs/okr-pre-named.json"
jq -n '{schema:3,run_id:"okr-boundary",owner_session:"boundary-parent",
  requested_legs:["kimi","sol","opus"],status:"settled",legs:{
    kimi:{outcome:"success"},sol:{outcome:"success"},opus:{outcome:"failure"}}}' \
  > "$TMP/stats-state/runs/okr-boundary.json"
okr_stats="$(HERDR_CALLS="$TMP/stats-calls" HERDR_NO_REVIEW_WORKSPACES=1 \
  HERDR_NO_AGENTS=1 CTXREVIEW_SESSION_STATE_DIR="$TMP/stats-state" \
  CTXREVIEW_FAILURE_RATE_TARGET_PERCENT=20 PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --stats okr-parent)"
for expected in \
  '    status: missed' \
  '    sample_size: 4' \
  '    numerator_failures: 1' \
  '    denominator_terminal: 4' \
  '    failure_rate_percent: 25' \
  '    successful: 2' \
  '    degraded: 1' \
  '    pending: 1' \
  '    requested: 5' \
  '    classification_coverage_percent: 80' \
  '    eligible_rounds: 2' \
  '    default_four_leg_rounds: 1' \
  '    subset_rounds: 1' \
  '    pre_named_unclassified_rounds: 1'; do
  [[ "$okr_stats" == *"$expected"* ]] || fail "OKR stats omitted: $expected"
done
boundary_stats="$(HERDR_CALLS="$TMP/stats-calls" HERDR_NO_REVIEW_WORKSPACES=1 \
  HERDR_NO_AGENTS=1 CTXREVIEW_SESSION_STATE_DIR="$TMP/stats-state" \
  CTXREVIEW_FAILURE_RATE_TARGET_PERCENT=33.33 PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --stats boundary-parent)"
[[ "$boundary_stats" == *$'    failure_rate_percent: 33.33'* &&
   "$boundary_stats" == *$'    target_failure_rate_percent: 33.33'* &&
   "$boundary_stats" == *$'    status: met'* ]] \
  || fail "OKR status disagreed with its displayed threshold boundary"

mkdir -p "$TMP/unmatched-state/runs"
: > "$TMP/unmatched-calls"
HERDR_CALLS="$TMP/unmatched-calls" HERDR_NO_REVIEW_WORKSPACES=1 HERDR_NO_AGENTS=1 \
  CTXREVIEW_SESSION_STATE_DIR="$TMP/unmatched-state" PATH="$TMP/bin:$PATH" \
  "$ROOT/bin/ctxreview" --session-ended unmatched-parent >/dev/null
jq -e 'select(.event=="session_end" and .owner_session=="unmatched-parent" and
              .outcome=="unmatched")' "$TMP/unmatched-state/events.jsonl" >/dev/null \
  || fail "unmatched SessionEnd hook delivery was not measurable"

cat > "$TMP/bin/ctxreview" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HOOK_CALL"
EOF
chmod +x "$TMP/bin/ctxreview"
printf '%s\n' '{"session_id":"hook-parent","hook_event_name":"SessionEnd"}' \
  | HOME="$TMP/home" HOOK_CALL="$TMP/hook-call" PATH="$TMP/bin:$PATH" \
      CTXREVIEW_SESSION_STATE_DIR="$TMP/hook-state" \
      "$ROOT/llm/hooks/ctxreview-session-end.sh"
for _ in $(seq 1 20); do [ -s "$TMP/hook-call" ] && break; sleep 0.05; done
[[ "$(cat "$TMP/hook-call")" == '--session-ended hook-parent' ]] \
  || fail "SessionEnd hook did not pass the parent session id"

printf '%s\n' '{"session_id":"start-parent","hook_event_name":"SessionStart"}' \
  | HOME="$TMP/home" HOOK_CALL="$TMP/start-hook-call" PATH="$TMP/bin:$PATH" \
      CTXREVIEW_SESSION_STATE_DIR="$TMP/hook-state" \
      "$ROOT/llm/hooks/ctxreview-session-start.sh"
for _ in $(seq 1 20); do [ -s "$TMP/start-hook-call" ] && break; sleep 0.05; done
[[ "$(cat "$TMP/start-hook-call")" == '--maintain --all' ]] \
  || fail "SessionStart hook did not launch the global safe maintenance heartbeat"

printf 'ctxreview regression passed\n'
