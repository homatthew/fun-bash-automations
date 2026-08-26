#!/usr/bin/env bash

prepare_codex_no_mcp_args() {
  [ "$CODEX_NO_MCP_READY" -eq 0 ] || return 0
  local codex_bin raw effective id
  codex_bin="$(type -P codex 2>/dev/null || command -v codex 2>/dev/null || true)"
  [ -n "$codex_bin" ] || die "codex not found"
  raw="$("$codex_bin" mcp list --json 2>/dev/null)" \
    || die "could not enumerate Codex MCP servers for review isolation"
  printf '%s' "$raw" | jq -e \
    'type=="array" and all(.[]; (.name | type)=="string")' >/dev/null 2>&1 \
    || die "Codex MCP inventory had an unexpected schema"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9_-]*) die "cannot safely disable Codex MCP server id: $id" ;;
    esac
    CODEX_NO_MCP_ARGS+=( -c "mcp_servers.$id.enabled=false" )
  done < <(printf '%s' "$raw" | jq -r '.[]?.name // empty')
  CODEX_NO_MCP_ARGS+=( -c 'apps._default.enabled=false' )
  effective="$("$codex_bin" "${CODEX_NO_MCP_ARGS[@]}" mcp list --json 2>/dev/null)" \
    || die "could not verify Codex MCP isolation"
  printf '%s' "$effective" | jq -e \
    'type=="array" and all(.[]; .enabled==false)' >/dev/null 2>&1 \
    || die "Codex MCP isolation did not disable every effective server"
  CODEX_NO_MCP_READY=1
}

prepare_cursor_config() {
  local config_dir="$1" workspace="${2:-$PWD}" tmp cursor_bin listing line id after
  cursor_bin="$(type -P cursor-agent 2>/dev/null || command -v cursor-agent 2>/dev/null || true)"
  [ -n "$cursor_bin" ] || return 1
  secure_dir "$config_dir" 2>/dev/null || return 1
  tmp="$(mktemp "$config_dir/mcp.json.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '{"mcpServers":{}}\n' > "$tmp" || ! mv "$tmp" "$config_dir/mcp.json"; then
    rm -f "$tmp"
    return 1
  fi
  [ "$(cat "$config_dir/mcp.json" 2>/dev/null)" = '{"mcpServers":{}}' ] || return 1

  listing="$(cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" "$cursor_bin" mcp list 2>/dev/null)" \
    || return 1
  case "$listing" in
    "No MCP servers configured"*) return 0 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *": disabled") continue ;;
      *:*) id="${line%%:*}" ;;
      *) return 1 ;;
    esac
    [ -n "$id" ] || return 1
    (cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" \
      "$cursor_bin" mcp disable "$id" >/dev/null 2>&1) || return 1
  done <<< "$listing"
  after="$(cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" "$cursor_bin" mcp list 2>/dev/null)" \
    || return 1
  case "$after" in
    "No MCP servers configured"*) return 0 ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] || case "$line" in *": disabled") ;; *) return 1 ;; esac
  done <<< "$after"
}
