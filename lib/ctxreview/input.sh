#!/usr/bin/env bash

need_herdr() { herdr_bin >/dev/null 2>&1 || die "herdr not on PATH"; }
if [ -z "$action" ]; then
  [ "$command_name" = run ] \
    || die "review launch requires: $SELF run --legs kimi,grok,sol,opus"
  [ "$legs_explicit" -eq 1 ] \
    || die "run requires --legs LIST (choose kimi,grok,sol,opus)"
elif [ -n "$command_name" ]; then
  die "run cannot be combined with inspection or lifecycle actions"
fi
case "$action" in
  "") validate_legs "$legs" ;;
esac
case "$action" in
  list)  need_herdr; cmd_list; exit 0 ;;
  close) need_herdr; cmd_close "$close_target"; exit 0 ;;
  consolidate) cmd_consolidate "$consolidate_dir"; exit 0 ;;
  bug) cmd_bug "$bug_text" "$bug_tool"; exit 0 ;;
  bugs) cmd_bugs "$bug_filter"; exit 0 ;;
  bugs2bd) cmd_bugs_to_beads; exit 0 ;;
  bugfixed) cmd_bug_fixed "$bug_id"; exit 0 ;;
  adjudicate) cmd_adjudicate "$adj_dir" $adj_commit; exit 0 ;;
  sessions) cmd_sessions "$session_filter"; exit 0 ;;
  stats) cmd_stats "$session_filter"; exit 0 ;;
  maintain) need_herdr; cmd_maintain "${maintain_args[@]+"${maintain_args[@]}"}"; exit $? ;;
  closesession) need_herdr; cmd_close_session "$session_filter"; exit 0 ;;
  sessionended) need_herdr; cmd_session_ended "$session_filter"; exit 0 ;;
  respawn) need_herdr; cmd_respawn "$respawn_run"; exit $? ;;
  attach) need_herdr; cmd_attach "$attach_run" "$attach_leg"; exit $? ;;
esac

# ------------------------------------------------------------- preflight ----

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
command -v ctxpack >/dev/null || die "ctxpack not on PATH"
# Gate on the SERVER being reachable, not on HERDR_ENV.
#
# HERDR_ENV=1 only means "this process is running inside a Herdr-managed pane".
# The CLI itself talks to a socket (~/.config/herdr/herdr.sock), so tab and pane
# operations work from anywhere the socket is reachable — a plain terminal, a
# Codex GUI session, a cron job. Gating on HERDR_ENV refused to run in exactly
# those cases for no reason, and the panes would have appeared in the user's
# session regardless.
if [ "$dry" -eq 0 ]; then
  need_herdr
  herdr_version="$(herdr_global --version 2>/dev/null | awk '{print $2}')"
  case "$herdr_version" in
    0.[89].*|0.[1-9][0-9].*|[1-9].*) ;;
    *) die "ctxreview requires Herdr 0.8+ (found ${herdr_version:-unknown})" ;;
  esac
fi

# A focused round: narrow the question, and carry the full checks for it.
#
# A normal pack lists lens *titles* — enough to remind a reviewer the lens
# exists. A focused round inlines the matching lens files in full, because when
# the whole round is about one thing the reviewer should be reading the actual
# evidence and "how to apply" bullets, not a one-line reminder.
#
# Refuses an unmatched topic rather than silently running an unfocused round.
# That matters here: the corpus has *zero* security/authz coverage, so
# `--focus security` finding nothing is a fact about the corpus, not a clean bill
# of health, and it must not be mistaken for one.
PRIVATE_REVIEW_DIR="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:+$SECOND_BRAIN_DIR/review}}"
LENS_DIR="${PRIVATE_REVIEW_DIR:+$PRIVATE_REVIEW_DIR/lenses}"

focus_lens_files() {  # focus_lens_files <topic> -> matching lens paths
  local topic="$1" hits=""
  [ -d "$LENS_DIR" ] || return 0

  # Tags first: they say what a lens is ABOUT, which is the thing being asked for.
  #
  # Body substring alone is a retrieval proxy and misfired exactly the way proxies
  # do -- `--focus tests` matched 11 of 31 lenses, because "test" appears in
  # almost every piece of evidence regardless of subject. Each lens now carries a
  # hand-assigned `tags:` line; matching a whole tag word is precise, and the
  # substring sweep stays as the fallback for topics nobody has tagged yet.
  hits="$(awk -v t="$topic" '
      FNR==1 { f=FILENAME }
      /^tags:/ { line=tolower($0)
                 n=split(line, w, /[[:space:]]+/)
                 for (i=2; i<=n; i++) if (w[i] == tolower(t)) { print f; break }
                 nextfile }
    ' "$LENS_DIR"/*.md 2>/dev/null | sort -u || true)"
  if [ -n "$hits" ]; then
    printf '%s' "$hits"; return 0
  fi

  # Match the lens id, the title, or the body — a topic is usually all over the
  # evidence even when it is in no filename.
  hits="$(grep -ril -- "$topic" "$LENS_DIR"/*.md 2>/dev/null | sort || true)"

  # Fall back to a stem. "concurrency" appears nowhere in the corpus while
  # "concurrent" and "concurrently" are everywhere, and refusing that is
  # pedantry, not precision. Nine characters of "concurrency" is "concurren",
  # which matches both without matching anything unrelated.
  # Require a long word and keep a long stem. Stripping 2 chars off a 7-letter
  # word turned "quantum" into "quant", which matched "quantitative" in the
  # metrics lenses and ran a bogus focused round instead of refusing. A stem is a
  # concession to morphology (concurrency/concurrent), not a fuzzy search.
  if [ -z "$hits" ] && [ "${#topic}" -ge 9 ]; then
    local stem="${topic:0:$(( ${#topic} - 2 ))}"
    hits="$(grep -ril -- "$stem" "$LENS_DIR"/*.md 2>/dev/null | sort || true)"
    [ -z "$hits" ] || say "focus \"$topic\" matched on stem \"$stem\""
  fi
  printf '%s' "$hits"
}

focus_topics() {  # what --focus can usefully match, for the error path
  [ -d "$LENS_DIR" ] || return 0
  # Tags, not lens ids. A lens id is one string you have to already know; tags are
  # the vocabulary the corpus actually indexes on, and listing them turns a
  # refusal into a menu.
  awk '/^tags:/ { sub(/^tags:[[:space:]]*/,""); n=split($0,w,/[[:space:]]+/)
                  for (i=1;i<=n;i++) if (w[i] != "") print w[i] }' \
    "$LENS_DIR"/*.md 2>/dev/null | sort | uniq -c | sort -rn \
    | awk '{printf "  %-26s (%d lens)\n", $2, $1}'
}

want() { case ",$legs," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Presence check only. `herdr agent start --kind codex|claude` resolves and
# launches the binary itself, so the alias-ordering hazard that applies to
# hand-rolled `codex exec` invocations does not arise here.
want sol  && command -v codex  >/dev/null || ! want sol  || die "codex not found"
want opus && command -v claude >/dev/null || ! want opus || die "claude not found"
{ want kimi || want grok; } && [ -x "$SPAWN" ] || true
if { want kimi || want grok; } && [ ! -x "$SPAWN" ]; then
  die "missing $SPAWN"
fi
if want kimi || want grok; then
  prepare_cursor_config "$SESSION_STATE_DIR/cursor-config" "$PWD" \
    || die "could not create the isolated Cursor MCP config"
fi
want sol && prepare_codex_no_mcp_args

if [ -n "$focus" ]; then
  [ -n "$LENS_DIR" ] \
    || die "--focus requires explicit CTXPACK_BIBLE_DIR or SECOND_BRAIN_DIR"
  focus_files="$(focus_lens_files "$focus")"
  if [ -z "$focus_files" ]; then
    printf '%s: no lens matches focus "%s".\n\n' "$SELF" "$focus" >&2
    printf 'A focused round with no checks is an unfocused round wearing a label,\n' >&2
    printf 'and "found nothing" would then mean "the corpus has nothing", not "clean".\n' >&2
    printf 'Available tags (a whole tag matches exactly; substring is the fallback):\n' >&2
    focus_topics >&2
    exit 2
  fi
  n_focus="$(printf '%s\n' "$focus_files" | grep -c .)"
  say "focus \"$focus\" -> $n_focus lens file(s), inlined in full"
  # A topic that matches half the corpus is a theme, not a focus. Said plainly
  # rather than refused: the round still works, it just is not narrow, and the
  # prompt grows by every lens body it inlines.
  if [ "$n_focus" -gt 5 ]; then
    say "note: $n_focus lenses is broad for a focused round — a narrower topic"
    say "      gives the reviewer fewer, sharper checks. \`ctxreview run --focus\` with"
    say "      no match lists every available topic."
  fi
fi

# The run directory lives INSIDE the repo, because that is the only place a
# sandboxed leg can write.
#
# It used to be a mktemp under /var/folders. Every leg was then told to write its
# report to a path outside its own workspace: Codex `workspace-write` permits the
# workspace only, and a Claude leg in plan mode is read-only outright. One leg
# said so verbatim — "the plan file isn't writable in this context" — and simply
# printed its report instead, where only the ~4 KB terminal tail could recover it.
# That is the real reason reports went missing, not the models.
#
# `.ctxreview/` is excluded via `.git/info/exclude`, which is local and untracked,
# so this adds no churn to a tracked .gitignore. Overridable with --dir, and
# --dir outside the repo is exactly the failure above, so it warns.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$dir" ]; then
  if [ -n "$repo_root" ]; then
    dir="$repo_root/.ctxreview/$(date +%Y%m%d-%H%M%S)-$$"
    excl="$(git rev-parse --git-dir 2>/dev/null)/info/exclude"
    if [ -f "$excl" ] && ! grep -qx '/.ctxreview/' "$excl" 2>/dev/null; then
      printf '/.ctxreview/\n' >> "$excl"
      say "added /.ctxreview/ to .git/info/exclude (local, untracked)"
    fi
  else
    dir="$(mktemp -d "${TMPDIR:-/tmp}/ctxreview.XXXXXX")"
  fi
else
  case "$dir" in
    "$(git rev-parse --show-toplevel 2>/dev/null)"/*) ;;
    *) say "warning: --dir is outside the repo. A sandboxed leg (Codex"
       say "         workspace-write, Claude plan mode) cannot write there, so"
       say "         reports may be lost to the 4 KB terminal tail." ;;
  esac
fi
secure_dir "$dir"
dir="$(cd "$dir" && pwd -P)"
# A caller-selected --dir is a storage location, not a globally unique identity.
# Keep ownership records collision-resistant even when two repositories choose
# the same basename such as `review`.
current_run_id="review-$(date +%Y%m%d-%H%M%S)-$$-${RANDOM:-0}"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [ -z "$owner_session" ]; then
  owner_session="manual-$(date +%y%m%d%H%M%S)-$$"
  say "no parent harness session found; generated $owner_session"
fi
valid_session_id "$owner_session" || die "invalid --session id (letters, digits, . _ : -; max 160 chars)"

# Name the workspace after the CHANGE, not the branch.
#
# A branch name is what you typed when you started; a tab label is what you read
# three hours later, and by then `review: HEAD`, `review: main` and
# `review: ODS-4408-islands` all mean nothing. A ticket id is an index into
# something you have to go look up. The commit subject is the one string already
# written to explain the change to a human, so prefer it — falling back through
# progressively worse but still concrete options, never to the branch alone.
