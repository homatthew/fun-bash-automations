#!/usr/bin/env bash

# Quantitative diagnostics for corpus scope, change sizes, and repair outcomes.
cmd_mine() {
  local sub="${1:-}"; shift || true
  local me="${CTXPACK_ME:-$(git config user.email 2>/dev/null || echo unknown)}"
  local authors="${CTXPACK_AUTHORS:-}"
  local only_repos=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --me) me="${2:?}"; shift 2 ;;
      --authors) authors="${2:?}"; shift 2 ;;
      --repos) only_repos="${2:?}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done

  case "$sub" in
    scope)
      printf 'identity: %s   (override with --me a@x,b@y)\n\n' "$me"
      printf '%-34s %-8s %s\n' "repo" "mine" "total"
      local d n tot addr sum
      for d in "$REPOS_DIR"/*/; do
        d="${d%/}"; [ -d "$d/.git" ] || continue
        sum=0
        for addr in ${me//,/ }; do
          n=$( { git -C "$d" log --author="$addr" --oneline 2>/dev/null || true; } | wc -l | tr -d ' ')
          sum=$(( sum + ${n:-0} ))
        done
        [ "$sum" -gt 0 ] || continue
        tot=$( { git -C "$d" log --oneline 2>/dev/null || true; } | wc -l | tr -d ' ')
        printf '%-34s %-8s %s\n' "$(basename "$d")" "$sum" "$tot"
      done | sort -k2 -rn
      ;;
    sizes)
      [ -n "$authors" ] || die "mine sizes needs --authors a,b,c (or CTXPACK_AUTHORS)"
      local tsv="$WORK/commits.tsv"; : > "$tsv"
      local a d
      for a in ${authors//,/ }; do
        for d in "$REPOS_DIR"/*/; do
          d="${d%/}"; [ -d "$d/.git" ] || continue
          if [ -n "$only_repos" ]; then
            case ",$only_repos," in *",$(basename "$d"),"*) ;; *) continue ;; esac
          fi
          git -C "$d" log --no-merges --author="${a}" --format="__C__%h" --numstat 2>/dev/null \
          | awk -v OFS='\t' -v A="$a" '
              /^__C__/ { if (seen) print A, ch, nf; seen=1; ch=0; nf=0; next }
              NF==3 && $1 ~ /^[0-9]+$/ {
                if ($3 ~ /(lock|\.sum|generated|\.pb\.|_pb2)/) next
                ch += $1 + $2; nf++
              }
              END { if (seen) print A, ch, nf }' || true
        done
      done >> "$tsv"
      printf '%-14s %-7s %-8s %-8s %-11s %s\n' author n median p90 "<=50 lines" ">500 lines"
      for a in ${authors//,/ }; do
        awk -F'\t' -v a="$a" '$1==a {print $2}' "$tsv" | sort -n \
        | awk -v a="$a" '{v[NR]=$1} END {
            if (NR==0) next
            p=0; b=0
            for (i=1;i<=NR;i++) { if (v[i]<=50) p++; if (v[i]>500) b++ }
            printf "%-14s %-7d %-8d %-8d %-11s %s\n", a, NR, v[int(NR/2)+1],
                   v[int(NR*0.9)+1], sprintf("%.0f%%",100*p/NR), sprintf("%.0f%%",100*b/NR)
          }'
      done
      printf '\nChurn = added+deleted per non-merge commit, lock/generated excluded.\n'
      printf 'See the corpus weighting doc: large diffs are weak evidence.\n'
      ;;
    outcomes)
      local win="${CTXPACK_REPAIR_WINDOW_DAYS:-30}" ev="$WORK/events.tsv"
      : > "$ev"
      local d db
      for d in "$REPOS_DIR"/*/; do
        d="${d%/}"; [ -d "$d/.git" ] || continue
        if [ -n "$only_repos" ]; then
          case ",$only_repos," in *",$(basename "$d"),"*) ;; *) continue ;; esac
        fi
        db=$(git -C "$d" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
        if [ -z "$db" ]; then
          for c in origin/main origin/master main master; do
            git -C "$d" rev-parse -q --verify "$c" >/dev/null 2>&1 && { db="$c"; break; }
          done
        fi
        [ -n "$db" ] || continue
        { git -C "$d" log --first-parent -m --name-only \
            --format="__C__%H|%at|%ae|%s" "$db" 2>/dev/null || true; } \
        | awk -v OFS='\t' -v R="$(basename "$d")" '
            /^__C__/ {
              split(substr($0,6), p, "|"); h=p[1]; ep=p[2]; ae=p[3]
              s=""; for (i=4; i<=length(p); i++) s = s (i>4 ? "|" : "") p[i]
              skip = (ae ~ /(\[bot\]|noreply|^builds@|^msrc@)/) ? 1 : 0
              gsub(/@.*/, "", ae)
              isfix = (tolower(s) ~ /^(revert|fix|hotfix|bugfix)|\bfix(es|ed)?\b|\brevert|\bregression|\bbroke|follow.?up|\bmissed\b|\boops\b|\bcorrect/) ? 1 : 0
              next
            }
            NF>0 && h!="" && !skip {
              if ($0 ~ /(lock|\.sum|generated|\.pb\.|_pb2)/) next
              print $0, ep, ae, isfix, R":"h
            }' >> "$ev" || true
      done
      [ -s "$ev" ] || die "no history collected"
      sort -t"$(printf '\t')" -k1,1 -k2,2n "$ev" \
      | awk -F'\t' -v WIN="$win" '
          function flush() {
            L=0; R=0
            for (i=1; i<=n; i++) {
              if (fx[i]) continue
              split(hs[i], rp, ":")
              key = au[i] "\x1f" hs[i]; seen[key]=1; kr[key]=rp[1]
              L++
              hit = 0
              for (j=i+1; j<=n; j++) {
                if (ep[j]-ep[i] > WIN*86400) break
                if (fx[j] && hs[j] != hs[i]) { hit=1; break }
              }
              if (hit) { rep[key]=1; R++ }
              order[L] = key
            }
            if (L > 0) {
              rate = R / L
              if (rate > 0.999) rate = 0.999
              for (i=1; i<=L; i++) {
                k2 = order[i]
                if (!(k2 in prod)) prod[k2] = 1
                prod[k2] *= (1 - rate)
              }
            }
            n=0
          }
          { if ($1 != cur) { flush(); cur=$1 }
            n++; ep[n]=$2; au[n]=$3; fx[n]=$4; hs[n]=$5 }
          END {
            flush()
            for (k in seen) {
              split(k, a, "\x1f"); r=kr[k]
              tot[a[1] "\x1f" r]++; rtot[r]++
              if (k in rep) { bad[a[1] "\x1f" r]++; rbad[r]++ }
              fexp[a[1]] += (k in prod) ? (1 - prod[k]) : 0
              who[a[1]]=1
            }
            printf "%-14s %-9s %-9s %-9s %-10s %-8s %-10s %s\n",
                   "author","landings","repaired","raw-rate","repo-base","repo-r","file-base","file-r"
            for (a_ in who) {
              N=0; B=0; exp_=0
              for (k in tot) {
                split(k, p, "\x1f"); if (p[1] != a_) continue
                N += tot[k]; B += (bad[k]+0)
                exp_ += tot[k] * ((rbad[p[2]]+0) / rtot[p[2]])
              }
              if (N < 30) continue
              raw = 100*B/N; base = 100*exp_/N; fbase = 100*(fexp[a_]+0)/N
              printf "%-14s %-9d %-9d %-9s %-10s %-8s %-10s %s\n", a_, N, B,
                     sprintf("%.1f%%", raw), sprintf("%.1f%%", base),
                     sprintf("%.2f", (base>0 ? raw/base : 0)),
                     sprintf("%.1f%%", fbase),
                     sprintf("%.2f", (fbase>0 ? raw/fbase : 0))
            }
          }' | { IFS= read -r hdr; printf '%s\n' "$hdr"; sort -k8 -n; }
      printf '\nA "landing" is one first-parent commit on the default branch: a merged PR\n'
      printf 'or a direct push. Repaired = a LATER landing whose subject reads like a fix\n'
      printf 'touched one of the same files within %s days. Bots excluded.\n' "$win"
      printf 'ratio <1.0 = repaired less often than the average landing in the same repos.\n'
      printf 'Confounders: shared hot files inflate everyone (control is per-repo, not\n'
      printf 'per-file), and a conventional-commit `fix:` for an unrelated bug can\n'
      printf 'false-positive. Quote no figure without its n and baseline.\n'
      ;;
    *) die "usage: $SELF mine scope | sizes --authors a,b | outcomes [--repos x,y]" ;;
  esac
}
