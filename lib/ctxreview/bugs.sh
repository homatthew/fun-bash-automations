#!/usr/bin/env bash

BUGS_FILE="${CTXREVIEW_BUGS_FILE:-$HOME/.local/state/ctxreview/bugs.jsonl}"

cmd_bug() {
  local text="${1:-}" tool="${2:-ctxreview}"
  [ -n "$text" ] || die "usage: $SELF --bug \"<what broke>\" [tool]"
  [ -z "$bug_run" ] || valid_session_id "$bug_run" || die "invalid --run id"
  [ -z "$bug_leg" ] || valid_leg "$bug_leg" || die "invalid --leg name"
  [ -z "$owner_session" ] || valid_session_id "$owner_session" || die "invalid --session id"
  secure_dir "$(dirname "$BUGS_FILE")"
  local id repo line
  id="b$(date +%y%m%d%H%M%S)-$RANDOM"
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo '-')")"
  line="$(jq -nc --arg id "$id" --arg tool "$tool" --arg text "$text" \
         --arg repo "$repo" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg run "$bug_run" --arg leg "$bug_leg" --arg owner "$owner_session" \
    '{id:$id, tool:$tool, status:"open", filed:$when, repo:$repo, text:$text,
      run_id:$run,leg:$leg,owner_session:$owner} |
     with_entries(select(.value != ""))')" || die "could not encode bug"
  append_line_locked "$BUGS_FILE" "$line" || die "could not append $BUGS_FILE"
  chmod 600 "$BUGS_FILE" 2>/dev/null || true
  record_event tool_bug_filed "$bug_run" "$owner_session" filed "$id" "$bug_leg"
  printf 'bug:\n'
  printf '  id: %s\n  tool: %s\n  status: open\n' "$id" "$tool"
}

cmd_bugs() {
  local want="${1:-open}"
  [ -s "$BUGS_FILE" ] || { say "no bugs filed yet ($BUGS_FILE)"; return 0; }
  local cols="${COLUMNS:-100}"; [ "$cols" -ge 40 ] 2>/dev/null || cols=100
  jq -r --arg w "$want" 'select($w == "all" or .status == $w)
      | "\(.id)\t\(.status)\t\(.tool)\t\(.filed[0:10])\t\(.text)"' "$BUGS_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r id st tool filed text; do
        printf '\n%s  [%s] %s  %s\n' "$id" "$st" "$tool" "$filed"
        printf '%s\n' "$text" | fold -s -w $((cols - 4)) | sed 's/^/    /'
      done
  local o c
  o="$(jq -r 'select(.status=="open")|1' "$BUGS_FILE" 2>/dev/null | grep -c . || true)"
  c="$(jq -r 'select(.status=="fixed")|1' "$BUGS_FILE" 2>/dev/null | grep -c . || true)"
  printf '\n── %s open, %s fixed ──\n' "${o:-0}" "${c:-0}"
  printf '  %s --bugs all          include fixed\n' "$SELF"
  printf '  %s --bug-fixed <id>    close one\n' "$SELF"
  printf '  %s --bugs-to-beads     promote open ones into bd (needs .beads here)\n' "$SELF"
}

cmd_bugs_to_beads() {
  command -v bd >/dev/null || die "bd not installed"
  [ -s "$BUGS_FILE" ] || { say "no bugs filed"; return 0; }
  [ -d .beads ] || die "no .beads in $(pwd) — run \`bd init\` here first"
  local promoted=0 id text tool bead tmp="$WORK_C/promote.jsonl"
  : > "$tmp"
  while IFS=$'\t' read -r id tool text; do
    [ -n "$id" ] || continue
    bead="$(bd create --title "[$tool] ${text:0:70}" --type bug --priority 2 2>&1 \
            | grep -oE '[a-z-]+-[0-9]+' | head -1 || true)"
    if [ -n "$bead" ]; then
      say "promoted $id -> $bead"
      printf '%s\t%s\n' "$id" "$bead" >> "$tmp"
      promoted=$((promoted + 1))
    else
      say "could not promote $id"
    fi
  done < <(jq -r 'select(.status=="open" and (.bead // "") == "")
                 | "\(.id)\t\(.tool)\t\(.text)"' "$BUGS_FILE" 2>/dev/null)
  if [ "$promoted" -gt 0 ]; then
    local out="$WORK_C/bugs-with-beads.jsonl" bug_lock="${BUGS_FILE}.lock" rc=0
    acquire_file_lock "$bug_lock" || die "could not lock $BUGS_FILE"
    jq -c --slurpfile ignore /dev/null '.' "$BUGS_FILE" > "$out" || rc=1
    while IFS=$'\t' read -r id bead; do
      [ "$rc" -eq 0 ] || break
      jq -c --arg id "$id" --arg bead "$bead" \
        'if .id == $id then .bead = $bead else . end' "$out" > "$out.n" \
        && mv "$out.n" "$out" || rc=1
    done < "$tmp"
    [ "$rc" -ne 0 ] || mv "$out" "$BUGS_FILE" || rc=1
    release_file_lock "$bug_lock"
    [ "$rc" -eq 0 ] || die "could not update $BUGS_FILE"
  fi
  say "promoted $promoted; bd ready shows what to work next"
}

cmd_bug_fixed() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: $SELF --bug-fixed <id>"
  [ -s "$BUGS_FILE" ] || die "no bugs filed"
  local tmp="$WORK_C/bugs.jsonl" bug_lock="${BUGS_FILE}.lock"
  acquire_file_lock "$bug_lock" || die "could not lock $BUGS_FILE"
  if ! jq -c --arg id "$id" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'if .id == $id then .status = "fixed" | .fixed = $when else . end' \
      "$BUGS_FILE" > "$tmp" 2>/dev/null; then
    release_file_lock "$bug_lock"
    die "could not rewrite $BUGS_FILE"
  fi
  if ! diff -q "$BUGS_FILE" "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$BUGS_FILE" || { release_file_lock "$bug_lock"; die "could not replace $BUGS_FILE"; }
    release_file_lock "$bug_lock"
    say "closed $id"
  else
    release_file_lock "$bug_lock"
    die "no bug with id $id"
  fi
}
