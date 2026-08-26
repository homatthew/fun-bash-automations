#!/bin/bash
# public-repo-leak-guard.sh
# PreToolUse hook on Bash: blocks publishing private identifiers to public forges.
#
# Why: an agent working across a private fork and a public upstream can paste a
# private identifier into a public PR body. Redacting afterwards is not a fix:
# GitHub keeps
# comment edit history, so the original stays readable. The only reliable
# control is refusing the write before it happens.
#
# The environment-specific identifiers come from the same explicit policy file
# used by the push-safety scanner:
#   FBA_PUSH_SAFETY_POLICY_FILE=/path/outside/the/repository/policy.tsv
# Each non-comment line is label<TAB>extended-regular-expression, the same format
# accepted by scripts/check-push-safety.sh.
#
# Commands are tokenized rather than regex-matched, so a command that merely
# *mentions* `gh pr comment` inside a quoted string (a test fixture, a grep
# pattern, a heredoc) is not treated as a publish.
#
# Override, for a body that is genuinely fine:
#   PUBLIC_POST_REVIEWED=1 gh pr comment ...

INPUT=$(cat)
DEFAULT_POLICY_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/fba/push-safety-policy.tsv"
if [ "${FBA_PUSH_SAFETY_POLICY_FILE+x}" = x ]; then
  POLICY_FILE="$FBA_PUSH_SAFETY_POLICY_FILE"
  POLICY_REQUIRED=true
else
  POLICY_FILE="$DEFAULT_POLICY_FILE"
  POLICY_REQUIRED=false
fi
[ "${FBA_PUSH_SAFETY_POLICY_REQUIRED:-0}" = 1 ] && POLICY_REQUIRED=true

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: public-repo leak guard requires jq."}}'
  exit 0
fi

allow() { exit 0; }

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

printf '%s' "$INPUT" | jq -e '
  type == "object"
  and (.tool_input | type == "object")
  and (.tool_input.command | type == "string" and length > 0)
' >/dev/null 2>&1 || allow

command -v python3 >/dev/null 2>&1 || allow
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command')

# Emits a JSON object describing a public publish, or an empty payload when the
# command is not a public publish. Exits non-zero if it cannot parse.
PUBLISH=$(python3 - "$COMMAND" <<'PY'
import json
import shlex
import sys

PUBLISH_NOUNS = {"pr", "issue", "release", "gist"}
PUBLISH_VERBS = {"comment", "create", "edit", "review"}
SEPARATORS = {";", "&&", "||", "|", "&"}

command = sys.argv[1].replace("\n", " ; ")
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

# Split into command segments.
segments, current = [], []
for token in tokens:
    if token in SEPARATORS:
        if current:
            segments.append(current)
        current = []
    else:
        current.append(token)
if current:
    segments.append(current)

payloads = []
uninspectable_stdin = False
for segment in segments:
    env = {}
    while segment and "=" in segment[0] and not segment[0].startswith("-"):
        key, _, value = segment[0].partition("=")
        if not key.replace("_", "").isalnum():
            break
        env[key] = value
        segment = segment[1:]
    if not segment or segment[0] != "gh":
        continue
    if env.get("PUBLIC_POST_REVIEWED") == "1":
        continue

    args = segment[1:]
    words = [a for a in args if not a.startswith("-")]

    publishing = False
    for noun, verb in zip(words, words[1:]):
        if noun in PUBLISH_NOUNS and verb in PUBLISH_VERBS:
            publishing = True
    if "api" in words:
        if any(
            args[i] in ("-X", "--method") and i + 1 < len(args)
            and args[i + 1].upper() in ("POST", "PATCH", "PUT")
            for i in range(len(args))
        ):
            publishing = True
        if any(arg == "--input" or arg.startswith("--input=") for arg in args):
            publishing = True
    if not publishing:
        continue

    # An explicit non-GitHub target is private and outside this guard's scope.
    host = env.get("GH_HOST", "")
    for i, arg in enumerate(args):
        if arg in ("--hostname", "-H") and i + 1 < len(args):
            host = args[i + 1]
        elif arg.startswith("--hostname="):
            host = arg.split("=", 1)[1]
    if host and host != "github.com":
        continue

    joined = " ".join(segment)
    # Everything that would be transmitted: the segment itself plus any file
    # bodies it references.
    payloads.append(joined)
    for i, arg in enumerate(args):
        path = None
        if arg in ("--body-file", "-F", "-f") and i + 1 < len(args):
            nxt = args[i + 1]
            path = nxt.split("@", 1)[1] if "@" in nxt else nxt
        elif arg.startswith("--body-file="):
            path = arg.split("=", 1)[1]
        elif arg == "--input" and i + 1 < len(args):
            path = args[i + 1]
        elif arg.startswith("--input="):
            path = arg.split("=", 1)[1]
        if path == "-":
            uninspectable_stdin = True
            continue
        if not path or path.startswith("-"):
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as handle:
                payloads.append(handle.read())
        except OSError:
            pass

print(json.dumps({
    "payload": "\n".join(payloads),
    "uninspectable_stdin": uninspectable_stdin,
}))
PY
) || allow

PAYLOAD=$(printf '%s' "$PUBLISH" | jq -r '.payload // empty')
[ -n "$PAYLOAD" ] || allow

if [ "$(printf '%s' "$PUBLISH" | jq -r '.uninspectable_stdin // false')" = true ]; then
  deny "Blocked: gh api --input - reads a public request body from stdin, which cannot be inspected before execution. Re-run only after review with PUBLIC_POST_REVIEWED=1."
fi

if [ ! -n "$POLICY_FILE" ] || [ ! -r "$POLICY_FILE" ]; then
  [ "$POLICY_REQUIRED" = false ] && allow
  deny "Blocked: required public-repo leak policy is missing or unreadable: ${POLICY_FILE:-<empty>}."
fi

HITS=""
while IFS=$'\t' read -r label regex extra || [ -n "$label$regex$extra" ]; do
  [ -n "$label" ] && [ "${label#\#}" = "$label" ] || continue
  [ -n "$regex" ] && [ -z "$extra" ] || continue
  matches=$(printf '%s' "$PAYLOAD" | grep -nE "$regex" | head -6 || true)
  [ -n "$matches" ] || continue
  HITS="${HITS}${HITS:+
}${label}:
${matches}"
done < "$POLICY_FILE"
if [ -n "$HITS" ]; then
  deny "Blocked: this publishes to a public forge and contains private identifiers.

$HITS

GitHub keeps comment edit history, so redacting after posting does not remove it.
Sanitize the body first. If the content is genuinely fine, re-run with the
PUBLIC_POST_REVIEWED=1 prefix."
fi

allow
