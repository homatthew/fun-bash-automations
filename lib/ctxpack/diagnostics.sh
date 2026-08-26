#!/usr/bin/env bash

cmd_doctor() {
  printf '%-22s %s\n' "ctxpack" "$VERSION"
  if [ -z "$BRAIN_DIR" ]; then
    printf '%-22s %s\n' "second brain" "(disabled; set CTXPACK_BRAIN_DIR)"
  else
    printf '%-22s %s %s\n' "second brain" "$BRAIN_DIR" \
      "$([ -d "$BRAIN_DIR/topics" ] && echo "(ok, $(find "$BRAIN_DIR/topics" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') topics)" || echo '(MISSING)')"
  fi
  if [ -z "$BIBLE_DIR" ]; then
    printf '%-22s %s\n' "review corpus" "(disabled; set CTXPACK_BIBLE_DIR)"
  else
    printf '%-22s %s %s\n' "code bible" "$BIBLE_DIR/code-bible/rules" \
      "$([ -d "$BIBLE_DIR/code-bible/rules" ] && echo "(ok, $(ls -1 "$BIBLE_DIR/code-bible/rules"/*.md 2>/dev/null | wc -l | tr -d ' ') rules)" || echo '(MISSING)')"
    printf '%-22s %s %s\n' "adjudications" "$BIBLE_DIR/adjudications.jsonl" \
      "$([ -f "$BIBLE_DIR/adjudications.jsonl" ] && echo "(ok, $(wc -l < "$BIBLE_DIR/adjudications.jsonl" | tr -d ' ') threads)" || echo '(empty)')"
    printf '%-22s %s %s\n' "lenses" "$BIBLE_DIR/lenses" \
      "$([ -d "$BIBLE_DIR/lenses" ] && echo "(ok, $(ls -1 "$BIBLE_DIR/lenses"/*.md 2>/dev/null | wc -l | tr -d ' ') lenses)" || echo '(MISSING)')"
    printf '%-22s %s\n' "personas" \
      "$([ -d "$BIBLE_DIR/personas" ] && ls -1 "$BIBLE_DIR/personas"/*.md 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  fi
  local tool
  for tool in git jq gh; do
    printf '%-22s %s\n' "$tool" "$(have "$tool" && command -v "$tool" || echo 'MISSING')"
  done
}
