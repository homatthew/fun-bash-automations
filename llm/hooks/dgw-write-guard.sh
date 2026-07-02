#!/bin/bash
# dgw-write-guard.sh
# Claude-native implementation of the shared policy in:
#   ~/repos/fun-bash-automations/llm/command-guard-policy.md
# PreToolUse hook: blocks dgw-cli kv put/delete against any environment
# unless the matching authorization flag is present:
#   DGW_TEST_WRITE_AUTHORIZED=1  for -e test
#   DGW_PROD_WRITE_AUTHORIZED=1  for -e prod

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

violation=$(python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(0)

segments = []
current = []
for token in tokens:
    if token in {"&&", "||", ";", "|"}:
        if current:
            segments.append(current)
            current = []
        continue
    current.append(token)
if current:
    segments.append(current)

def parse_env_assignments(segment):
    env = {}
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        name, value = segment[idx].split("=", 1)
        env[name] = value
        idx += 1
    return env, segment[idx:]

def dgw_write(segment):
    if not segment or segment[0] != "dgw-cli":
        return None
    if len(segment) < 2 or segment[1] != "kv":
        return None
    args = segment[2:]
    env = "unknown"
    idx = 0
    while idx < len(args):
        token = args[idx]
        if token in {"-e", "--env"} and idx + 1 < len(args):
            env = args[idx + 1]
            idx += 2
            continue
        if token.startswith("--env="):
            env = token.split("=", 1)[1]
            idx += 1
            continue
        if token in {"put", "delete"}:
            return env
        idx += 1
    return None

for raw_segment in segments:
    env_assignments, segment = parse_env_assignments(raw_segment)
    env = dgw_write(segment)
    if env is None:
        continue
    if env == "test":
        flag_name = "DGW_TEST_WRITE_AUTHORIZED"
        flag = "DGW_TEST_WRITE_AUTHORIZED=1"
    else:
        # Unknown environments fail closed with prod-level authorization.
        flag_name = "DGW_PROD_WRITE_AUTHORIZED"
        flag = "DGW_PROD_WRITE_AUTHORIZED=1"
        env = "prod" if env == "prod" else "unknown"
    if env_assignments.get(flag_name) == "1":
        continue
    print(f"{env}\t{flag}")
    sys.exit(0)
PY
)

if [[ -n "$violation" ]]; then
  IFS=$'\t' read -r ENV FLAG <<< "$violation"
  jq -n --arg env "$ENV" --arg flag "$FLAG" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("dgw-cli KV writes to " + $env + " are blocked. To authorize, the user must explicitly confirm intent in their message, then prefix the command with " + $flag + ".")
    }
  }'
  exit 0
fi

exit 0
