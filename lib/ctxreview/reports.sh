#!/usr/bin/env bash

cmd_list() {
  local agents any=0 record name run running sessions
  sessions="$(herdr_global session list --json 2>/dev/null || printf '{"sessions":[]}')"
  printf '%-28s %-12s %-42s %s\n' SESSION STATE LABEL LEGS
  for record in "$(session_runs_dir)"/*.json; do
    [ -s "$record" ] || continue
    name="$(jq -r '.herdr_session_name // empty' "$record")"
    [ -n "$name" ] || continue
    run="$(jq -r '.run_id // "?"' "$record")"
    running="$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '[.sessions[]? | select(.name==$name and .running==true)] | length')"
    if [ "$running" -eq 1 ]; then
      HERDR_SESSION_NAME="$name"
      agents="$(review_agents | awk -F'\t' '{printf "%s(%s) ", substr($1,11), $3}')"
      printf '%-28s %-12s %-42s %s\n' "$name" running \
        "$(jq -r '.label // "?"' "$record" | cut -c1-42)" "${agents:-(restoring)}"
    else
      printf '%-28s %-12s %-42s %s\n' "$name" stopped \
        "$(jq -r '.label // "?"' "$record" | cut -c1-42)" \
        "resume: $SELF --respawn $run"
    fi
    any=1
  done

  [ "$any" -eq 1 ] || printf '(no review sessions)\n'
}

cmd_consolidate() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $SELF --consolidate <run-dir>"

  local rows="$WORK_C/rows.tsv"; : > "$rows"
  local leg f src parsed total=0

  # Did the tree move under the legs? Findings cite file:line, so a changed tree
  # makes every line number a guess and means the legs did not all review the
  # same snapshot.
  if [ -s "$dir/.tree-fingerprint" ]; then
    local now_fp was_fp
    was_fp="$(cat "$dir/.tree-fingerprint")"
    now_fp="$({ git status --porcelain 2>/dev/null; git rev-parse HEAD 2>/dev/null; } \
              | shasum 2>/dev/null | awk '{print $1}')"
    if [ -n "$now_fp" ] && [ "$now_fp" != "$was_fp" ]; then
      printf '> ⚠️ **The working tree changed since this round started.**\n>\n'
      printf '> Every finding below cites a file:line from the original snapshot, so\n'
      printf '> line numbers may no longer match and the legs may not all have seen\n'
      printf '> the same code. Re-run with `--again` rather than trusting these.\n\n'
    fi
  fi

  printf '## Parse coverage\n\n'
  for leg in kimi grok sol opus; do
    f=""; src=""
    [ -s "$dir/$leg.md" ] && { f="$dir/$leg.md"; src="report"; }
    [ -z "$f" ] && [ -s "$dir/$leg.tail.md" ] && { f="$dir/$leg.tail.md"; src="terminal tail (leg wrote no report)"; }
    if [ -z "$f" ]; then
      printf -- '- %-5s **no output** — nothing to consolidate\n' "$leg"; continue
    fi
    # Strip ANSI and box-drawing so a terminal capture still yields findings.
    # Strip decoration as whole characters, and read as bytes.
    #
    # This used to `tr -d` the individual bytes of UTF-8 box-drawing glyphs, which
    # left invalid byte sequences mid-character; awk then died with "towc:
    # multibyte conversion failure" and the leg was reported as unparseable. It
    # also silently mangled every em dash and arrow in a legitimate report.
    #
    # LC_ALL=C makes awk byte-oriented, so no input can trip its decoder.
    parsed="$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$f" \
      | sed 's/▎//g; s/│//g; s/─//g; s/┌//g; s/└//g; s/├//g; s/✽//g; s/✶//g' \
      | LC_ALL=C awk -v leg="$leg" '
          # Block-based, not line-based. A finding title wraps across lines, so
          # reading one line at a time truncated them mid-sentence ("...on every
          # call, and"). And a leg often cites file:line in its Evidence line
          # rather than beside the title, so the location is searched across the
          # whole block -- without it, two legs describing one defect never
          # matched and agreement always read as zero.
          function flush() {
            if (buf == "") return
            title=""; loc=""
            if (match(buf, /\*\*[^*]+\*\*/)) {
              title = substr(buf, RSTART+2, RLENGTH-4)
            }
            # First backticked token that looks like a path, anywhere in the block.
            rest = buf
            while (match(rest, /`[^`]+`/)) {
              cand = substr(rest, RSTART+1, RLENGTH-2)
              # `\/` matters: awk ends a regex literal at a bare slash even
              # inside a character class, which made this a syntax error.
              if (cand ~ /[A-Za-z0-9_\/.-]+\.[A-Za-z]+(:[0-9]+)?$/) { loc = cand; break }
              rest = substr(rest, RSTART+RLENGTH)
            }
            gsub(/[[:space:]]+/, " ", title)
            gsub(/^ | $/, "", title)
            if (length(title) > 8)
              printf "%s\t%s\t%s\t%s\n", leg, (sev?sev:"Unclassified"), loc, title
            buf=""
          }
          /^#+[[:space:]]*(Critical|Important|Observation|Blocking|Nit)/ {
            flush(); sev=$0; gsub(/^#+[[:space:]]*/,"",sev); gsub(/[^A-Za-z].*$/,"",sev); next }
          /^#+[[:space:]]/ { flush(); next }
          {
            line=$0
            gsub(/^[[:space:]|+>-]*/,"",line)
            # Two shapes legs actually emit:
            #   1. **title** — `file:line`     (what the prompt asks for)
            #   **1. title** — `file:line`     (what opus wrote, 23 KB of it)
            #
            # Requiring the first scored a perfectly good report as 0 findings.
            # Ask for a format, accept what arrives.
            #
            # Deliberately NOT accepting "- **bold**": in that same report those
            # are sub-points *inside* a finding, so treating them as findings
            # inflated one defect into five.
            if (line ~ /^([0-9]+\.[[:space:]]*)?\*\*/) { flush(); buf=line }
            else if (buf != "") buf = buf " " line
          }
          END { flush() }' )"
    local n; n="$(printf '%s\n' "$parsed" | grep -c . || true)"
    total=$((total + n))
    printf '%s\n' "$parsed" | grep . >> "$rows" || true
    # Distinguish "the leg died" from "the leg said nothing useful".
    #
    # A Kimi K3 leg was killed mid-review by "Error: High Load" — provider
    # capacity, not a local defect and not a clean bill of health. Reported as
    # "0 findings parsed" it looked identical to a leg that ran fine and found
    # nothing, which is the same conflation L34 is about. A round that lost a leg
    # to capacity has three opinions, not four, and you should know which.
    local died=""
    case "$(tr -d '\0' < "$f" 2>/dev/null)" in
      *"High Load"*|*"high demand"*)        died="provider capacity (High Load)" ;;
      *"rate limit"*|*"Rate limit"*)        died="provider rate limit" ;;
      *"context length"*|*"too long"*)      died="context length exceeded" ;;
      *"Interrupted"*)                      died="interrupted mid-run" ;;
    esac

    if [ -n "$died" ] && [ "${n:-0}" -eq 0 ]; then
      printf -- '- %-5s %s — **leg did not finish: %s**\n' "$leg" "$src" "$died"
      printf -- '  This round has fewer opinions than legs. Not a clean result.\n'
    elif [ "${n:-0}" -eq 0 ]; then
      printf -- '- %-5s %s — **0 findings parsed** (format unrecognised; read it by hand)\n' "$leg" "$src"
    elif [ -n "$died" ]; then
      printf -- '- %-5s %s — %s findings, but %s: may be incomplete\n' "$leg" "$src" "$n" "$died"
    else
      printf -- '- %-5s %s — %s findings\n' "$leg" "$src" "$n"
    fi
  done

  [ "$total" -gt 0 ] || { printf '\nNo findings parsed from any leg. Read the reports directly.\n'; return 0; }

  # Group by location when present, else by the longest title words. Location is
  # the reliable key: two legs describing one defect agree on file:line far more
  # often than on wording.
  printf '\n## Findings, agreement first\n\n'
  awk -F'\t' '
    { key = $3
      if (key == "") { n=split(tolower($4),w," "); key=""
        for (i=1;i<=n && i<=4;i++) if (length(w[i])>5) key = key w[i] }
      # Key on file:LINE, never on file alone. Stripping the line merged
      # sol at fact_store.py:329 with opus at fact_store.py:330 -- two unrelated
      # findings -- into one entry tagged [2 legs]. Two findings in a busy file
      # are not a consensus, and false agreement is the worst defect a
      # consolidator can have, because agreement is the signal acted on without
      # re-deriving. Under-merge on purpose: a missed agreement costs a second
      # look, an invented one costs a wrong fix.
      # (No apostrophes in this awk block: it sits in a single-quoted shell
      # string and one would terminate the program.)
      legs[key] = legs[key] (index(legs[key],$1)?"":($1 " "))
      if (!(key in sev) || rank($2) > rank(sev[key])) sev[key]=$2
      if (!(key in title)) title[key]=$4
      cnt[key] = split(legs[key], tmp, " ") - 1
    }
    function rank(s) { return (s=="Critical"||s=="Blocking") ? 3 : (s=="Important" ? 2 : 1) }
    END {
      for (k in cnt) printf "%d\t%d\t%s\t%s\t%s\n", cnt[k], rank(sev[k]), sev[k], legs[k], title[k] }
  ' "$rows" | sort -rn -k1,1 -k2,2 | awk -F'\t' '
    $1 >= 2 { if (!m++) print "### Raised independently by more than one leg\n"
              printf "- **%s** _(%s)_ — [%d legs: %s]\n", $5, $3, $1, $4 }
    END { if (!m) print "### Raised independently by more than one leg\n\n(none — each finding came from a single leg)\n" }'
  printf '\n'
  awk -F'\t' '
    { key = $3
      if (key == "") { n=split(tolower($4),w," "); key=""
        for (i=1;i<=n && i<=4;i++) if (length(w[i])>5) key = key w[i] }
      # Full file:LINE, matching the agreement pass. Stripping the line here too
      # produced the same false merge in the leads list.
      legs[key] = legs[key] (index(legs[key],$1)?"":($1 " "))
      if (!(key in title)) { title[key]=$4; sv[key]=$2; loc[key]=$3 }
      cnt[key] = split(legs[key], tmp, " ") - 1 }
    END { print "### Single-leg leads — verify against the diff before acting\n"
          for (k in cnt) if (cnt[k] < 2)
            printf "- **%s** _(%s, %s)_%s\n", title[k], sv[k], legs[k], (loc[k]?" — `" loc[k] "`":"") }
  ' "$rows"

  printf '\n> Agreement raises confidence, it does not confer correctness: two legs\n'
  printf '> can share a wrong assumption. Verify before acting, and record what you\n'
  printf '> decided with `%s --adjudicate %s`.\n' "$SELF" "$dir"
}

. "$FBA/lib/ctxreview/adjudication.sh"

. "$FBA/lib/ctxreview/bugs.sh"
