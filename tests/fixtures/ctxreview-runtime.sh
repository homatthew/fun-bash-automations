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
