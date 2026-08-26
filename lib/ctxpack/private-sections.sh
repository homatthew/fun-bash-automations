#!/usr/bin/env bash

section_brain() {
  shift 0
  local files=("$@")
  printf '## Second-brain topics\n\n'
  if [ -z "$BRAIN_DIR" ]; then
    printf '(private topic corpus disabled; set `CTXPACK_BRAIN_DIR` to opt in)\n\n'
    return 0
  fi
  if [ ! -d "$BRAIN_DIR/topics" ]; then
    printf '(no second brain at `%s`)\n\n' "$BRAIN_DIR"; return 0
  fi
  # Match on path words rather than file contents: cheap, and precise enough
  # because topic folders are named after the subsystems they document.
  local words
  words=$(printf '%s\n' "${files[@]}" | tr '/._-' '\n' | tr 'A-Z' 'a-z' \
    | grep -E '^[a-z]{4,}$' | sort | uniq -c | sort -rn \
    | awk 'NR<=25 {print $2}' || true)
  [ -n "$words" ] || { printf '(no usable path words in this diff)\n\n'; return 0; }
  local hits=0 t
  while IFS= read -r t; do
    local name; name=$(basename "$t")
    local w
    while IFS= read -r w; do
      case "$name" in *"$w"*)
        printf -- '- [`%s`](%s/README.md)\n' "$name" "$t"; hits=$((hits+1)); break ;;
      esac
    done <<< "$words"
  done < <(find "$BRAIN_DIR/topics" -mindepth 1 -maxdepth 1 -type d | sort)
  [ "$hits" -gt 0 ] || printf '(no topic folder matched a path word from this diff)\n'
  printf '\n'
}

section_bible() {
  shift 0
  local files=("$@")
  printf '## Code bible — prior adjudications\n\n'
  if [ -z "$BIBLE_DIR" ]; then
    printf '(private review corpus disabled; set `CTXPACK_BIBLE_DIR` to opt in)\n\n'
    return 0
  fi
  local rules="$BIBLE_DIR/code-bible/rules"
  if [ ! -d "$rules" ]; then
    printf '(no code bible at `%s`)\n\n' "$rules"; return 0
  fi
  local shown=0 r
  for r in "$rules"/*.md; do
    [ -f "$r" ] || continue
    local applies title
    applies=$(awk -F': *' '/^applies:/ {print $2; exit}' "$r")
    title=$(awk '/^# / {sub(/^# /,""); print; exit}' "$r")
    local match=0
    if [ -z "$applies" ] || [ "$applies" = "*" ]; then
      match=1
    else
      local f
      for f in "${files[@]}"; do
        printf '%s\n' "$f" | grep -qE "$applies" && { match=1; break; }
      done
    fi
    if [ "$match" -eq 1 ]; then
      shown=$((shown+1))
      local verdict; verdict=$(awk -F': *' '/^verdict:/ {print $2; exit}' "$r")
      printf -- '- **%s** _(%s)_ — `%s`\n' "$title" "${verdict:-unclassified}" "$(basename "$r")"
    fi
  done
  [ "$shown" -gt 0 ] || printf '(no rule matched this diff)\n'
  printf '\n> `verdict: rejected` rules are findings that were raised and turned down\n'
  printf '> with a reason. Raising one again without addressing that reason is noise.\n'
  printf '> `verdict: upheld` rules are the checks worth spending review budget on.\n\n'
}

# Review lenses are what to look for; the bible is what has already been decided.
section_lens() {
  local files=("$@")
  printf '## Review lenses\n\n'
  if [ -z "$BIBLE_DIR" ]; then
    printf '(private review corpus disabled; set `CTXPACK_BIBLE_DIR` to opt in)\n\n'
    return 0
  fi
  local dir="$BIBLE_DIR/lenses"
  if [ ! -d "$dir" ]; then printf '(none at `%s`)\n\n' "$dir"; return 0; fi
  local shown=0 l
  for l in "$dir"/*.md; do
    [ -f "$l" ] || continue
    local applies title weight
    applies=$(awk -F': *' '/^applies:/ {print $2; exit}' "$l")
    title=$(awk '/^# / {sub(/^# /,""); print; exit}' "$l")
    weight=$(awk -F': *' '/^weight:/ {print $2; exit}' "$l")
    local match=0
    if [ -z "$applies" ] || [ "$applies" = ".*" ]; then
      match=1
    else
      local f
      for f in "${files[@]}"; do
        printf '%s\n' "$f" | grep -qE "$applies" && { match=1; break; }
      done
    fi
    if [ "$match" -eq 1 ]; then
      shown=$((shown+1))
      printf -- '- **%s** _(%s)_ — `%s`\n' "$title" "${weight:-?}" "$(basename "$l")"
    fi
  done
  [ "$shown" -gt 0 ] || printf '(no lens matched this diff)\n'
  printf '\n> Open the lens file before using it — the one-line title is a\n'
  printf '> reminder, the evidence and the "how to apply" are the content.\n\n'
}

section_persona() {
  printf '## Reviewer personas\n\n'
  if [ -z "$BIBLE_DIR" ]; then
    printf '(private review corpus disabled; set `CTXPACK_BIBLE_DIR` to opt in)\n\n'
    return 0
  fi
  local p="$BIBLE_DIR/personas"
  if [ ! -d "$p" ]; then printf '(none at `%s`)\n\n' "$p"; return 0; fi
  local f
  for f in "$p"/*.md; do
    [ -f "$f" ] || continue
    printf -- '- `%s` — %s\n' "$(basename "$f" .md)" \
      "$(awk -F': *' '/^summary:/ {print $2; exit}' "$f")"
  done
  printf '\n> These describe what the humans on this repo actually flag. Pre-empting\n'
  printf '> them is the cheapest review round you will ever run.\n\n'
}
