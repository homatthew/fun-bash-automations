#!/usr/bin/env bash

REVIEW_CORPUS_DIR="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:+$SECOND_BRAIN_DIR/review}}"
ADJ_FILE="${REVIEW_CORPUS_DIR:+$REVIEW_CORPUS_DIR/adjudications.jsonl}"

cmd_adjudicate() {
  local dir="${1:-}" commit=0
  shift || true
  [ "${1:-}" = "--commit" ] && commit=1
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $SELF --adjudicate <run-dir> [--commit]"
  local sheet="$dir/adjudication.tsv"

  if [ "$commit" -eq 0 ]; then
    if [ -s "$sheet" ]; then
      say "worksheet already exists: $sheet"
      say "fill the verdict column, then: $SELF --adjudicate $dir --commit"
      return 0
    fi
    local repo branch
    repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    {
      printf '# ctxreview adjudication worksheet — %s @ %s\n' "$repo" "$branch"
      printf '#\n# Set VERDICT to one of: accepted | refuted | deferred\n'
      printf '# Add REASON. A refutation with a domain fact is the most valuable\n'
      printf '# artefact here — it is what the bible rules are made of, and it is the\n'
      printf '# one thing no amount of re-reviewing can reconstruct later.\n'
      printf '# Leave VERDICT blank to skip a finding. Then:\n'
      printf '#   %s --adjudicate %s --commit\n#\n' "$SELF" "$dir"
      printf '# VERDICT\tLEG\tSEVERITY\tLOCATION\tFINDING\tREASON\n'
      cmd_consolidate "$dir" 2>/dev/null \
        | awk '/^- \*\*/ {
            line=$0
            sub(/^- \*\*/, "", line)
            marker=index(line, "** _(")
            if (marker == 0) next
            title = substr(line, 1, marker - 1)
            rest  = substr(line, marker)
            sev=""; legs=""; loc=""
            if (match(rest, /_\([^)]*\)_/)) { m=substr(rest,RSTART+2,RLENGTH-4); split(m,a,", "); sev=a[1]; legs=a[2] }
            if (match(rest, /`[^`]+`/)) loc=substr(rest,RSTART+1,RLENGTH-2)
            gsub(/[[:space:]]+$/,"",legs)
            gsub(/\t/," ",title)
            printf "\t%s\t%s\t%s\t%s\t\n", legs, sev, loc, title }'
    } > "$sheet"
    chmod 600 "$sheet"
    local n; n="$(grep -cv '^#' "$sheet" || true)"
    say "worksheet: $sheet ($n findings)"
    say "fill the VERDICT column, then: $SELF --adjudicate $dir --commit"
    return 0
  fi

  [ -n "$ADJ_FILE" ] \
    || die "--adjudicate --commit requires CTXPACK_BIBLE_DIR or SECOND_BRAIN_DIR"
  [ -s "$sheet" ] || die "no worksheet at $sheet — run $SELF --adjudicate $dir first"
  local repo branch who n=0
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  who="${CTXREVIEW_ADJUDICATOR:-$(git config user.name 2>/dev/null || true)}"
  who="${who:-${USER:-local-author}}"
  secure_dir "$(dirname "$ADJ_FILE")"
  while IFS=$'\t' read -r verdict legs sev loc finding reason; do
    case "$verdict" in ''|'#'*|VERDICT) continue ;; esac
    case "$verdict" in
      accepted|refuted|deferred) ;;
      *) say "skip: unknown verdict \"$verdict\" for: ${finding:0:50}"; continue ;;
    esac
    jq -nc --arg repo "local/$repo" --arg branch "$branch" --arg by "ctxreview-$legs" \
           --arg path "$loc" --arg finding "$finding" --arg sev "$sev" \
           --arg verdict "$verdict" --arg reason "$reason" --arg who "$who" \
      '{repo:$repo, pr:0, branch:$branch, path:$path, by:$by, severity:$sev,
        finding:$finding, replies:[{who:$who, body:$reason}],
        adjudication:"replied", verdict:$verdict, source:"ctxreview"}' \
      >> "$ADJ_FILE"
    n=$((n+1))
  done < "$sheet"
  sort -u "$ADJ_FILE" -o "$ADJ_FILE"
  secure_file "$ADJ_FILE"
  say "appended $n adjudications — corpus now $(wc -l < "$ADJ_FILE" | tr -d ' ') threads"
  [ "$n" -gt 0 ] && say "refutations with a domain fact are bible-rule material: see $ADJ_FILE"
}
