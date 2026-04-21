#!/bin/bash
# Codex PermissionRequest hook: auto-allow obviously read-only Bash commands.
#
# PermissionRequest only fires when Codex was already going to prompt for
# approval (e.g. shell escalation, network). PreToolUse guards already ran.
# This hook adds a narrow safelist of unambiguously read-only, side-effect-
# free invocations so Julia doesn't have to approve `git status` for the
# hundredth time.
#
# Default is to decline (emit {}); Codex then falls through to the normal
# approval prompt. Allow only when the command matches a known-safe pattern.

set -euo pipefail

INPUT=$(cat)

emit_pass() {
  printf '{}\n'
  exit 0
}

emit_allow() {
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
  exit 0
}

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
[ "$TOOL_NAME" != "Bash" ] && emit_pass

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && emit_pass

# Reject compound/piped/redirected/substitution commands — easy to hide a
# side-effectful tail behind a safe-looking head.
case "$CMD" in
  *'&&'*|*'||'*|*';'*|*'|'*|*'>'*|*'<'*|*'`'*|*'$('*|*$'\n'*) emit_pass ;;
esac

# Strip leading env assignments (`FOO=bar cmd ...`) so we match the actual
# command keyword, not the assignment.
STRIPPED="$CMD"
while [[ "$STRIPPED" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+(.*)$ ]]; do
  STRIPPED="${BASH_REMATCH[1]}"
done

FIRST=$(printf '%s' "$STRIPPED" | awk '{print $1}')
SECOND=$(printf '%s' "$STRIPPED" | awk '{print $2}')

# --- Tier 1: pure read-only singletons (no mutating subcommand exists) ------
case "$FIRST" in
  ls|pwd|echo|printf|cat|head|tail|wc|tree|du|df\
  |which|type|file|stat|basename|dirname|realpath\
  |date|uname|hostname|whoami|id|sw_vers\
  |pgrep|ps|lsof)
    emit_allow
    ;;
esac

# --- Tier 2: search tools (read-only unless destructive flags are set) ------
case "$FIRST" in
  grep|rg|ag|ack)
    emit_allow
    ;;
  find|fd)
    case "$CMD" in
      *' -exec '*|*' -exec'|*' -execdir '*|*' -execdir'\
      |*' -delete '*|*' -delete'|*' -ok '*|*' -okdir '*)
        emit_pass
        ;;
    esac
    emit_allow
    ;;
esac

# --- Tier 3: text/data processors (allow when not modifying files) ----------
case "$FIRST" in
  jq|yq)
    emit_allow  # no in-place edit mode
    ;;
  sed)
    case "$CMD" in *' -i '*|*' -i'|*' -i'[!a-zA-Z0-9_-]*) emit_pass ;; esac
    emit_allow
    ;;
  awk)
    # awk `system(...)` or gsub-with-print to file; if a suspicious builtin
    # appears in source text, decline.
    case "$CMD" in *'system('*|*'print >'*|*'printf >'*) emit_pass ;; esac
    emit_allow
    ;;
esac

# --- Tier 4: tools with mixed read/write subcommands ------------------------
case "$FIRST" in
  defaults)
    # `defaults read|read-type|domains|find` are read-only. `write|delete`
    # mutate. Gate on subcommand.
    case "$SECOND" in
      read|read-type|domains|find) emit_allow ;;
    esac
    ;;
  git)
    case "$SECOND" in
      # Unambiguously read-only subcommands.
      status|diff|log|show|blame|rev-parse|ls-files|ls-tree|ls-remote\
      |describe|cat-file|merge-base|reflog|shortlog|for-each-ref\
      |symbolic-ref|show-ref|whatchanged|grep|name-rev|check-ref-format)
        emit_allow
        ;;
      # Mixed-mode subcommands: allow only known-read invocations.
      branch)
        case "$CMD" in
          'git branch'\
          |'git branch '*'--list'*\
          |'git branch '*'--show-current'*\
          |'git branch '*'-v'*\
          |'git branch '*'-a'*\
          |'git branch '*'--all'*\
          |'git branch '*'--contains'*\
          |'git branch '*'--merged'*\
          |'git branch '*'--no-merged'*\
          |'git branch '*'-r'*\
          |'git branch '*'--remotes'*)
            emit_allow ;;
        esac
        ;;
      tag)
        # `git tag` / `git tag -l [pattern]` list. Anything else creates/deletes.
        case "$CMD" in
          'git tag'|'git tag -l'*|'git tag --list'*|'git tag -n'*) emit_allow ;;
        esac
        ;;
      remote)
        case "$CMD" in
          'git remote'|'git remote -v'|'git remote show '*|'git remote get-url '*) emit_allow ;;
        esac
        ;;
      stash)
        case "$CMD" in
          'git stash list'*|'git stash show'*) emit_allow ;;
        esac
        ;;
      config)
        # Explicit read flags only; bare `git config KEY VALUE` writes.
        case "$CMD" in
          'git config --get '*|'git config --get-all '*|'git config --get-regexp '*\
          |'git config --get-urlmatch '*|'git config --list'*|'git config -l'*) emit_allow ;;
        esac
        ;;
    esac
    ;;
esac

emit_pass
