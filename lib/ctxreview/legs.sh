#!/usr/bin/env bash

valid_session_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9._:-]*) return 1 ;;
    *) [ "${#1}" -le 160 ] ;;
  esac
}

valid_leg() {
  case "${1:-}" in kimi|grok|sol|opus) return 0 ;; *) return 1 ;; esac
}

validate_legs() {
  local value="${1:-}" leg seen=","
  [ -n "$value" ] || die "--legs needs at least one of: kimi,grok,sol,opus"
  case "$value" in
    ,*|*,|*,,*) die "invalid --legs value: empty reviewer name" ;;
  esac
  IFS=',' read -r -a parsed_legs <<< "$value"
  [ "${#parsed_legs[@]}" -gt 0 ] || die "--legs needs at least one reviewer"
  for leg in "${parsed_legs[@]}"; do
    valid_leg "$leg" || die "invalid --legs value: ${leg:-<empty>} (choose kimi,grok,sol,opus)"
    case "$seen" in
      *",$leg,"*) die "duplicate --legs value: $leg" ;;
      *) seen="$seen$leg," ;;
    esac
  done
}
