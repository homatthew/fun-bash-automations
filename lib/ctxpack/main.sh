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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mining.sh"

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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/diagnostics.sh"

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
