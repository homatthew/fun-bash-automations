#!/usr/bin/env bash
# ctxpack — assemble a local context pack for code review.
#
# A context pack is the evidence a reviewer (human or agent) needs *besides*
# the diff: the conventions the diff is being judged against, the sibling code
# that establishes them, the domain notes, and the record of which findings
# were upheld or rejected last time.
#
# No network, no index, no install. Everything is derived from the working
# tree, git history, and two plain-text corpora on disk.
#
# See: llm/context-packs/README.md
set -euo pipefail
umask 077

VERSION="0.1.0"
SELF="${CTXPACK_SELF:-${0##*/}}"

# ---------------------------------------------------------------- config ----

BRAIN_DIR="${CTXPACK_BRAIN_DIR:-${SECOND_BRAIN_DIR:-}}"
BIBLE_DIR="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:+$SECOND_BRAIN_DIR/review}}"
REPOS_DIR="${CTXPACK_REPOS_DIR:-$HOME/repos}"

# Tunables. Every cap is explicit so a truncated pack is never silent.
MAX_SIBLINGS="${CTXPACK_MAX_SIBLINGS:-40}"
MAX_FILES="${CTXPACK_MAX_FILES:-60}"
PRECEDENT_QUORUM="${CTXPACK_PRECEDENT_QUORUM:-60}"   # percent of siblings
PRECEDENT_MIN="${CTXPACK_PRECEDENT_MIN:-3}"          # absolute floor

# ----------------------------------------------------------------- utils ----

# One scratch dir for the whole run. A per-function `trap ... RETURN` looks
# tidier but bash installs it globally without `functrace`, so it fires on
# every other function's return and trips `set -u` on the stale variable.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ctxpack.XXXXXX")
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }
note() { [ -n "${CTXPACK_QUIET:-}" ] || printf '%s: %s\n' "$SELF" "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
$SELF $VERSION — assemble a local code-review context pack

USAGE
  $SELF build [--base REF] [--out FILE] [--sections LIST]
  $SELF precedent [--base REF]
  $SELF bible [--match] [--base REF]
  $SELF harvest REPO [--host HOST] [--prs N | --prs-list N,N,N]
  $SELF read [--min N] [--all]
  $SELF mine scope | sizes --authors a,b,c
  $SELF doctor

COMMANDS
  build       Assemble the full pack for the current diff (markdown on stdout).
  precedent   Only the sibling-precedent evidence table.
  bible       List code-bible rules; --match filters to rules touching this diff.
  harvest     Mine PR review threads from a GitHub host into the adjudication
              corpus, so the bible compounds from real verdicts.
  read        Order harvested findings for READING. Retrieval, not ranking —
              the corpus is small enough to read, and every score tried so far
              inverted what it was meant to measure.
  mine scope  List repos you have committed to — the corpus boundary.
  mine sizes  Commit-churn distribution per author. A diagnostic, not a target.
  mine outcomes  Post-merge repair rate. A diagnostic about *where* you work.
  doctor      Report which corpora and tools resolved.

OPTIONS
  --base REF     Diff base. Default: merge-base with the repo's default branch,
                 falling back to staged then unstaged changes.
  --out FILE     Write the pack to FILE instead of stdout.
  --sections L   Comma-separated subset of:
                 claim,scope,constitution,precedent,history,brain,bible,persona
  --prs N        How many recent PRs to harvest (default 60).
  --host HOST    GitHub host for harvest (default: the repo's origin host).

ENVIRONMENT
  SECOND_BRAIN_DIR      Explicitly opt into a private second brain and review corpus
  CTXPACK_BRAIN_DIR     Explicit private topic corpus (overrides SECOND_BRAIN_DIR)
  CTXPACK_BIBLE_DIR     Explicit private review corpus (overrides SECOND_BRAIN_DIR)
  CTXPACK_MAX_SIBLINGS  Sibling files scanned per directory (default 40)
  CTXPACK_PRECEDENT_QUORUM  Percent of siblings that makes a token a convention (60)

EXIT
  0 ok   1 nothing to review   2 usage/config error
EOF
}

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/core-input.sh"

# ------------------------------------------------------------- sections ----

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/public-sections.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/private-sections.sh"

# ------------------------------------------------------------- commands ----

cmd_build() {
  local base_arg="" out="" sections="claim,scope,constitution,precedent,history,brain,bible,lens,persona"
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) base_arg="${2:?--base needs a ref}"; shift 2 ;;
      --out) out="${2:?--out needs a path}"; shift 2 ;;
      --sections) sections="${2:?--sections needs a list}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"

  local base; base=$(resolve_base "$base_arg")
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(changed_files "$base" | sort -u | grep -v '^$' || true)
  [ "${#files[@]}" -gt 0 ] || { note "no changed files against $base"; return 1; }

  # A section that fails must say so in the pack. A pack that silently stops
  # half way is worse than no pack: the reviewer cannot tell "no precedent
  # found" from "the precedent miner crashed".
  run_section() {
    local name="$1"; shift
    case ",$sections," in *",$name,"*) ;; *) return 0 ;; esac
    if ! "$@"; then
      printf '\n> ⚠️ section `%s` failed — this pack is incomplete.\n\n' "$name"
    fi
  }

  render() {
    printf '# Review context pack — %s\n\n' "$(basename "$(git rev-parse --show-toplevel)")"
    printf '_Generated by %s %s. Diff base `%s`, %d changed files._\n\n' \
      "$SELF" "$VERSION" "$base" "${#files[@]}"
    printf -- '---\n\n'
    run_section claim        section_claim "$base"
    run_section scope        section_scope "$base" "${files[@]}"
    run_section constitution section_constitution
    run_section precedent    section_precedent "$base" "${files[@]}"
    run_section history      section_history "$base" "${files[@]}"
    run_section brain        section_brain "${files[@]}"
    run_section bible        section_bible "${files[@]}"
    run_section lens         section_lens "${files[@]}"
    run_section persona      section_persona
  }

  if [ -n "$out" ]; then
    local out_dir out_tmp
    out_dir="$(dirname "$out")"
    out_tmp="$(mktemp "$out_dir/.ctxpack.XXXXXX")"
    render > "$out_tmp"
    chmod 600 "$out_tmp"
    mv "$out_tmp" "$out"
    note "wrote $out ($(wc -l < "$out" | tr -d ' ') lines)"
  else render; fi
}

cmd_precedent() {
  local base_arg=""
  [ "${1:-}" = "--base" ] && { base_arg="${2:?}"; shift 2; }
  local base; base=$(resolve_base "$base_arg")
  local files=(); while IFS= read -r f; do files+=("$f"); done < <(changed_files "$base" | sort -u | grep -v '^$' || true)
  [ "${#files[@]}" -gt 0 ] || { note "no changed files"; return 1; }
  section_precedent "$base" "${files[@]}"
}

cmd_bible() {
  [ -n "$BIBLE_DIR" ] || die "private review corpus disabled; set CTXPACK_BIBLE_DIR"
  local match=0 base_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --match) match=1; shift ;;
      --base) base_arg="${2:?}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  if [ "$match" -eq 1 ]; then
    local base; base=$(resolve_base "$base_arg")
    local files=(); while IFS= read -r f; do files+=("$f"); done < <(changed_files "$base" | sort -u | grep -v '^$' || true)
    section_bible "${files[@]}"
  else
    local rules="$BIBLE_DIR/code-bible/rules"
    [ -d "$rules" ] || die "no code bible at $rules"
    local r
    for r in "$rules"/*.md; do
      printf '%-10s %-9s %s\n' \
        "$(basename "$r" .md)" \
        "$(awk -F': *' '/^verdict:/ {print $2; exit}' "$r")" \
        "$(awk '/^# / {sub(/^# /,""); print; exit}' "$r")"
    done
  fi
}

# Mine real PR review threads into the adjudication corpus. Every entry is a
# finding paired with what a human actually did about it — the only honest
# source for "which of these findings are worth making".
cmd_harvest() {
  [ -n "$BIBLE_DIR" ] || die "private review corpus disabled; set CTXPACK_BIBLE_DIR"
  local repo="${1:?usage: $SELF harvest REPO [--host HOST] [--prs N]}"; shift
  local host="" prs=60 prs_list=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) host="${2:?}"; shift 2 ;;
      --prs) prs="${2:?}"; shift 2 ;;
      --prs-list) prs_list="${2:?}"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  have gh || die "harvest needs the gh CLI"
  have jq || die "harvest needs jq"
  if [ -z "$host" ]; then
    host=$(git -C "$REPOS_DIR/$repo" remote get-url origin 2>/dev/null \
      | sed -E 's#^https?://([^/]+)/.*#\1#; s#^git@([^:]+):.*#\1#') || true
  fi
  [ -n "$host" ] || die "could not resolve a host; pass --host"
  # Accept an explicit owner/repo slug so a repo that is not cloned locally can
  # still be harvested -- the evidence that matters is not always in a repo you
  # have a checkout of.
  local owner_repo
  case "$repo" in
    */*) owner_repo="$repo" ;;
    *) owner_repo=$(git -C "$REPOS_DIR/$repo" remote get-url origin 2>/dev/null \
         | sed -E 's#^https?://[^/]+/##; s#^git@[^:]+:##; s#\.git$##') \
         || die "no origin for $repo (pass owner/repo explicitly if it is not cloned)" ;;
  esac
  [ -n "$owner_repo" ] || die "could not resolve a slug for $repo"

  local out="$BIBLE_DIR/adjudications.jsonl"
  mkdir -p "$(dirname "$out")"
  chmod 700 "$(dirname "$out")"
  touch "$out"
  chmod 600 "$out"
  note "harvesting $owner_repo from $host (last $prs PRs) -> $out"

  # The API caps per_page at 100 regardless of what you ask for, and
  # sort=updated is NOT monotonic in PR number -- so a single unpaginated page
  # silently omits PRs that are neither recent nor low-numbered. Four PRs the
  # corpus already cites were unreachable at every --prs value because of this.
  # --paginate walks the pages; --prs-list fetches exact PRs regardless of window.
  local nums
  if [ -n "$prs_list" ]; then
    nums=$(printf '%s\n' "${prs_list//,/ }" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
    note "explicit PR list: $(printf '%s' "$nums" | tr '\n' ' ')"
  else
    nums=$(gh api --hostname "$host" --paginate \
      "repos/${owner_repo}/pulls?state=all&per_page=100&sort=updated&direction=desc" \
      --jq '.[].number' 2>/dev/null | grep -E '^[0-9]+$' | awk -v n="$prs" 'NR<=n' || true)
  fi
  [ -n "$nums" ] || die "no PRs resolved for $owner_repo"

  local tmp="$WORK/harvest.jsonl" threads="$WORK/threads.jsonl"
  : > "$tmp"; : > "$threads"
  local n
  while IFS= read -r n; do
    gh api --hostname "$host" "repos/${owner_repo}/pulls/${n}/comments?per_page=100" \
      --jq ".[] | {repo: \"${owner_repo}\", pr: ${n}, id: .id, reply_to: .in_reply_to_id,
                   who: .user.login, path: .path, body: .body}" 2>/dev/null || true

    # Thread state, which is the adjudication signal that actually matters.
    # isOutdated means the code at that line changed after the comment -- a
    # silent fix, which is how most correct findings get accepted. isResolved
    # means somebody explicitly closed the thread. Neither leaves a reply.
    local owner="${owner_repo%%/*}" name="${owner_repo##*/}"
    gh api --hostname "$host" graphql -f query="
      { repository(owner:\"${owner}\", name:\"${name}\") {
          pullRequest(number:${n}) {
            reviewThreads(first:100) { nodes {
              isResolved isOutdated
              comments(first:1){ nodes { databaseId } } } } } } }" 2>/dev/null \
      | jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?
               | select(.comments.nodes[0].databaseId != null)
               | {root: .comments.nodes[0].databaseId, resolved: .isResolved, outdated: .isOutdated}' \
        2>/dev/null >> "$threads" || true
  done <<< "$nums" >> "$tmp"

  # Record EVERY root review comment, replied to or not.
  #
  # An earlier version kept only threads that had a reply, on the theory that a
  # thread with no reply carries no verdict. That was wrong twice over. Silence
  # is not refutation: the most clearly-correct findings are the ones least
  # likely to draw a reply, because the author just pushes a fix. Keeping only
  # argued threads therefore selects FOR contested and wrong findings and
  # against obvious ones. And it discarded the evidence outright rather than
  # down-weighting it, so the loss was unrecoverable without a re-harvest.
  #
  # `adjudication` now carries the real signal, in descending strength:
  #   replied      an author wrote a verdict
  #   code-changed the diff at that line moved afterwards (isOutdated) -- a silent fix
  #   resolved     thread explicitly closed with no reply
  #   pending      none of the above yet. On a day-old PR this means "too early",
  #                NOT "worthless". Weight it as unknown, never as refuted.
  jq -c -s --slurpfile th "$threads" '
    ($th | map({key: (.root|tostring), value: .}) | from_entries) as $state
    | (map(select(.reply_to != null)) | group_by(.reply_to)
       | map({key: (.[0].reply_to|tostring), value: map({who, body})}) | from_entries) as $replies
    | map(select(.reply_to == null))
    | map(. as $r
          | ($replies[($r.id|tostring)] // []) as $rep
          | ($state[($r.id|tostring)] // {}) as $st
          | {repo: $r.repo, pr: $r.pr, path: $r.path, by: $r.who, id: $r.id,
             finding: $r.body, replies: $rep,
             resolved: ($st.resolved // null), outdated: ($st.outdated // null),
             adjudication: (if ($rep|length) > 0 then "replied"
                            elif $st.outdated == true then "code-changed"
                            elif $st.resolved == true then "resolved"
                            else "pending" end)})
    | .[]
  ' "$tmp" >> "$out"

  # Harvest is append-only and re-runnable, so the same thread arrives again
  # every time its PR is still inside the window. jq emits keys in a fixed
  # order, which makes whole-line dedup exact.
  sort -u "$out" -o "$out"
  note "corpus now $(wc -l < "$out" | tr -d ' ') unique threads"
}

# Quantitative backbone for evidence weighting: which repos are in scope, and
# how big a "normal" change is for the people whose work is worth learning from.
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
      # In-scope == I have committed there. Patterns from code I do not touch
      # are not actionable.
      #
      # The identity is echoed because `git config user.email` is per-repo:
      # run from a repo with a personal identity, the default silently counts
      # the wrong author and reports a plausible, wrong scope. Pass a
      # comma-separated list to --me when you commit under more than one.
      printf 'identity: %s   (override with --me a@x,b@y)\n\n' "$me"
      printf '%-34s %-8s %s\n' "repo" "mine" "total"
      local d n tot addr sum
      for d in "$REPOS_DIR"/*/; do
        d="${d%/}"; [ -d "$d/.git" ] || continue
        # `|| true` on every count: ~/repos contains worktrees, gate clones and
        # a node_modules whose git calls exit non-zero. Under `set -e` +
        # pipefail an unguarded assignment aborts the whole sweep inside this
        # subshell, and the truncated list still looks like a complete answer.
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
          # Solo repos (dotfiles, personal tooling) are not comparable evidence:
          # nobody else commits there, so they only skew my own distribution.
          # --repos restricts the sweep to the shared repos that matter.
          if [ -n "$only_repos" ]; then
            case ",$only_repos," in *",$(basename "$d"),"*) ;; *) continue ;; esac
          fi
          # --format needs a '%' or git reads the string as a *named* pretty
          # format and dies with "invalid --pretty format".
          git -C "$d" log --no-merges --author="${a}" --format="__C__%h" --numstat 2>/dev/null \
          | awk -v OFS='\t' -v A="$a" '
              /^__C__/ { if (seen) print A, ch, nf; seen=1; ch=0; nf=0; next }
              NF==3 && $1 ~ /^[0-9]+$/ {
                if ($3 ~ /(lock|\.sum|generated|\.pb\.|_pb2)/) next
                ch += $1 + $2; nf++
              }
              END { if (seen) print A, ch, nf }' || true
          # `|| true`: ~/repos holds worktrees and gate clones whose git calls
          # exit 128; under pipefail that would abort the whole sweep.
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
      # Size is a gameable proxy: you can halve every diff without improving
      # anything. This measures what happened AFTER the merge instead.
      #
      # repair-rate = share of an author's non-fix commits that are followed,
      # on at least one of the same files, by a fix-language commit within N
      # days -- i.e. somebody had to come back and repair it.
      #
      # The raw rate is confounded by WHERE you work: per-repo fix-share ranges
      # roughly 1%-17%. So each author is also scored against the volume-
      # weighted baseline of the same repos. `ratio` is the number to read;
      # 1.0 means "as often as the average change to this same code".
      local win="${CTXPACK_REPAIR_WINDOW_DAYS:-30}" ev="$WORK/events.tsv"
      : > "$ev"
      local d db
      for d in "$REPOS_DIR"/*/; do
        d="${d%/}"; [ -d "$d/.git" ] || continue
        if [ -n "$only_repos" ]; then
          case ",$only_repos," in *",$(basename "$d"),"*) ;; *) continue ;; esac
        fi

        # Measure the DEFAULT BRANCH, not HEAD. A repo checked out on a feature
        # branch would otherwise count unmerged local commits as landed work --
        # which silently inflates whoever has branches checked out (me).
        db=$(git -C "$d" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
        if [ -z "$db" ]; then
          for c in origin/main origin/master main master; do
            git -C "$d" rev-parse -q --verify "$c" >/dev/null 2>&1 && { db="$c"; break; }
          done
        fi
        [ -n "$db" ] || continue

        # --first-parent restricts to the spine of landings. Every repo here uses
        # merge commits, so plain `log --no-merges` also returns PR-BRANCH
        # commits -- and a "fix review comments" commit pushed to a branch would
        # then score as a repair of the commit it was written alongside. Those
        # are pre-merge fixups, not repairs.
        #
        # `-m --first-parent` gives each merge's diff against the first parent,
        # i.e. exactly what main gained when that PR landed. On GHE the merge
        # commit's author is the PR author, so %ae attributes correctly.
        { git -C "$d" log --first-parent -m --name-only \
            --format="__C__%H|%at|%ae|%s" "$db" 2>/dev/null || true; } \
        | awk -v OFS='\t' -v R="$(basename "$d")" '
            /^__C__/ {
              split(substr($0,6), p, "|"); h=p[1]; ep=p[2]; ae=p[3]
              s=""; for (i=4; i<=length(p); i++) s = s (i>4 ? "|" : "") p[i]
              # Automation lands most dependency-lock traffic; counting it as an
              # engineer flooded the earlier table with a bot at rank 3.
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
          # Called once per file, with the landings for that file in time order.
          #
          # Two baselines come out of this. The repo baseline asks "how often does
          # a landing in this repo get repaired". The FILE baseline asks "how often
          # does a landing touching these particular files get repaired" -- which is
          # the control that actually matters, because a file a dozen people edit
          # generates repairs belonging to nobody, and the repo average cannot see
          # that.
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
            # Per-file repair rate, then fold it into each landing that touched
            # this file. Files are treated as independent, so the expected repair
            # probability for one landing is 1 - PROD(1 - rate_f) -- the same
            # "any file counts" semantics the observed number uses.
            # (No apostrophes in this awk block: it is inside a single-quoted
            # shell string and one would terminate the program.)
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
              # Expected repairs for this landing given only which files it touched.
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
    *)
      die "usage: $SELF mine scope | sizes --authors a,b | outcomes [--repos x,y]"
      ;;
  esac
}

# Reading order over the harvested findings. RETRIEVAL, NOT RANKING.
#
# Every quantitative layer in this corpus turned out to be a proxy that inverted
# what it was supposed to measure, so evidence is now selected by reading it. The
# corpus is small enough for that: a few hundred human findings, median ~120
# characters. This just puts the ones most likely to carry a transferable insight
# first.
#
# Deliberately NOT used for ordering: adjudication outcome (a rejected finding
# produced one of the strongest rules in the bible) and length (the best comments
# here are one-liners).
cmd_read() {
  [ -n "$BIBLE_DIR" ] || die "private review corpus disabled; set CTXPACK_BIBLE_DIR"
  local min=2 who="human"
  while [ $# -gt 0 ]; do
    case "$1" in
      --min) min="${2:?}"; shift 2 ;;
      --all) who="all"; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  local adj="$BIBLE_DIR/adjudications.jsonl"
  [ -f "$adj" ] || die "no corpus at $adj"

  jq -r --arg who "$who" --argjson min "$min" '
    select(.by != null)
    | select(if $who == "human" then (.by | test("\\[bot\\]") | not) else true end)
    | (.finding // "" | gsub("\\s+"; " ")) as $b
    | select(($b | length) > 25 and ($b | length) < 4000)
    | [ ($b | test("[0-9]+ *(k|ms|MB|GB|KiB|%|x|rps|qps|days?|hours?|min)\\b|[0-9]{3,}")),
        ($b | test("[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*|[A-Z][A-Z0-9]*_[A-Z0-9_]+")),
        ($b | test("(?i)\\b(because|since|so that|which means|otherwise|leads to|causes|results in|the reason|that way)\\b")),
        ($b | test("(?i)\\b(race|deadlock|corrupt|data loss|silent|silently|overflow|leak|stale|drift|split.?brain|unbounded|throttl|timeout|regress|starv|amplif|hot ?key|blast radius|mixed.?mode|rollback|idempot|fail open|retry)\\b")),
        ($b | test("(?m)[1-9][.)] .*[1-9][.)] |\\b[0-9]+ of [0-9]+\\b|\\bevery other\\b|\\ball other\\b")),
        ($b | test("(?i)\\b(instead|prefer|rather than|we could|we should|what about|why not)\\b")),
        ($b | test("(?i)\\b(operator|on.?call|production|prod\\b|upgrade|fleet|customer)\\b"))
      ] as $m
    | ($m | map(select(.)) | length) as $ord
    | select($ord >= $min)
    | "\($ord)\t\(.by)\t\(.adjudication)\t\(.repo|split("/")|last)#\(.pr)\t\(.path // "-" | split("/") | last)\t\($b | .[0:520])"
  ' "$adj" | sort -rn -k1,1 \
  | awk -F'\t' '{printf "\n── [%s] %-14s %-14s %-28s %s\n%s\n", $1, $2, $3, $4, $5, $6}'
  printf '\nOrder is a reading aid, not a quality rank. Adjudication is shown, never\n'
  printf 'ranked on: a refuted finding can be the most valuable thing in the corpus.\n'
}

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
  local t
  for t in git jq gh; do
    printf '%-22s %s\n' "$t" "$(have "$t" && command -v "$t" || echo 'MISSING')"
  done
}

# ----------------------------------------------------------------- main ----

case "${1:-}" in
  build)     shift; cmd_build "$@" ;;
  mine)      shift; cmd_mine "$@" ;;
  read)      shift; cmd_read "$@" ;;
  precedent) shift; cmd_precedent "$@" ;;
  bible)     shift; cmd_bible "$@" ;;
  harvest)   shift; cmd_harvest "$@" ;;
  doctor)    shift; cmd_doctor "$@" ;;
  -h|--help|help|"") usage ;;
  --version) printf '%s\n' "$VERSION" ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
