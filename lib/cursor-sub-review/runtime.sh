#!/usr/bin/env bash

prepare_zero_mcp() {
  local cfg="$1" workspace="$2" tmp listing line id after
  mkdir -p "$cfg" 2>/dev/null || return 1
  tmp="$(mktemp "$cfg/mcp.json.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '{"mcpServers":{}}\n' > "$tmp" || ! mv "$tmp" "$cfg/mcp.json"; then
    rm -f "$tmp"
    return 1
  fi
  [[ "$(cat "$cfg/mcp.json" 2>/dev/null)" == '{"mcpServers":{}}' ]] || return 1
  listing="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$listing" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      *": disabled") continue ;;
      *:*) id="${line%%:*}" ;;
      *) return 1 ;;
    esac
    [[ -n "$id" ]] || return 1
    (cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" \
      "$cursor_cmd" mcp disable "$id" >/dev/null 2>&1) || return 1
  done <<< "$listing"
  after="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$after" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -z "$line" ]] || case "$line" in *": disabled") ;; *) return 1 ;; esac
  done <<< "$after"
}

cursor_footer_settled() {
  local agent="$1" screen attempt
  for attempt in 1 2 3; do
    screen="$(herdr agent read "$agent" --source visible 2>/dev/null)" || return 1
    [[ -n "$screen" && "$screen" == *"Add a follow-up"* ]] || return 1
    [[ "$screen" != *"ctrl+c to stop"* ]] || return 1
    [[ "$attempt" -eq 3 ]] || sleep 1
  done
}

cmd_sweep() {
  [[ -n "$herdr_bin" ]] || die "herdr is not on PATH"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  local leaked agents_json panes_json status tab_id busy pane_id agent_info
  local agent_name agent_status agent_kind
  leaked="$(herdr tab list | jq -r --arg p "$EPHEMERAL_PREFIX" \
    '.result.tabs[] | select(.label | startswith($p)) | .tab_id')"
  if [[ -z "$leaked" ]]; then
    echo "no leaked ephemeral Cursor sessions"
    return 0
  fi
  agents_json="$(herdr agent list 2>/dev/null)" \
    && jq -e '.result.agents | type=="array"' >/dev/null 2>&1 <<<"$agents_json" \
    || die "could not verify Herdr agent inventory"
  panes_json="$(herdr pane list 2>/dev/null)" \
    && jq -e '.result.panes | type=="array"' >/dev/null 2>&1 <<<"$panes_json" \
    || die "could not verify Herdr pane inventory"
  status=0
  while IFS= read -r tab_id; do
    [[ -n "$tab_id" ]] || continue
    busy=0
    while IFS= read -r pane_id; do
      [[ -n "$pane_id" ]] || continue
      agent_info="$(jq -c --arg p "$pane_id" \
        '.result.agents[]? | select(.pane_id==$p)' <<<"$agents_json" | sed -n '1p')"
      [[ -n "$agent_info" ]] || continue
      agent_name="$(jq -r '.name // empty' <<<"$agent_info")"
      agent_status="$(jq -r '.agent_status // "unknown"' <<<"$agent_info")"
      agent_kind="$(jq -r '.agent // "unknown"' <<<"$agent_info")"
      case "$agent_status" in idle|done) ;; *) busy=1; continue ;; esac
      if [[ "$agent_kind" == cursor ]] && ! cursor_footer_settled "$agent_name"; then
        busy=1
      fi
    done < <(jq -r --arg t "$tab_id" '.result.panes[]? |
      select(.tab_id==$t) | .pane_id' <<<"$panes_json")
    if [[ "$busy" != "0" ]] && ! $force_sweep; then
      echo "still active or unverifiable, left alone: $tab_id (use --force-sweep to close anyway)"
      status=1
      continue
    fi
    while IFS= read -r pane_id; do
      [[ -n "$pane_id" ]] || continue
      herdr pane close "$pane_id" >/dev/null 2>&1 || true
    done < <(jq -r --arg t "$tab_id" '.result.panes[]? |
      select(.tab_id==$t) | .pane_id' <<<"$panes_json")
    echo "closed leaked ephemeral session: $tab_id"
  done <<<"$leaked"
  return "$status"
}
