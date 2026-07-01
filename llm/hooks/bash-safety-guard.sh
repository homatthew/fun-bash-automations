#!/bin/bash
# bash-safety-guard.sh
# Claude-native implementation of the shared policy in:
#   ~/repos/fun-bash-automations/llm/command-guard-policy.md
# PreToolUse hook on Bash: blocks dangerous commands from autonomous agents.
# Each guard category is a function. To disable a category, comment out its call.
# Compatible with macOS BSD grep (no \b or \d).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
INPUT_WORKDIR=$(echo "$INPUT" | jq -r '
  .tool_input.workdir
  // .tool_input.cwd
  // .tool_input.working_dir
  // .tool_input.arguments.workdir
  // .tool_input.args.workdir
  // .tool_input.parameters.workdir
  // .arguments.workdir
  // .args.workdir
  // .parameters.workdir
  // .workdir
  // .cwd
  // empty
')
GUARD_WORKDIR=$(python3 - "$COMMAND" "$INPUT_WORKDIR" <<'PY'
import os
import shlex
import sys

command = sys.argv[1]
input_workdir = "" if sys.argv[2] == "null" else sys.argv[2]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    print(input_workdir)
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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and "=" in segment[idx] and not segment[idx].startswith("-"):
        name = segment[idx].split("=", 1)[0]
        if not name.replace("_", "a").isalnum() or name[:1].isdigit():
            break
        idx += 1
    return segment[idx:]

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        continue
    idx = 1
    workdir = ""
    while idx < len(segment):
        token = segment[idx]
        if token == "-C" and idx + 1 < len(segment):
            workdir = segment[idx + 1]
            idx += 2
            continue
        if token == "push" or token == "commit":
            if workdir:
                if os.path.isabs(workdir):
                    print(workdir)
                elif input_workdir:
                    print(os.path.normpath(os.path.join(input_workdir, workdir)))
                else:
                    print(workdir)
            else:
                print(input_workdir)
            sys.exit(0)
        idx += 1
print(input_workdir)
PY
)
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

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

# --- Helpers ---
git_context() {
  if [[ -n "$GUARD_WORKDIR" && -d "$GUARD_WORKDIR" ]]; then
    git -C "$GUARD_WORKDIR" "$@"
  else
    git "$@"
  fi
}

has_wrong_netflix_gh_host() {
  echo "$COMMAND" | grep -qE "(^|[;&|[:space:]])(export[[:space:]]+)?GH_HOST=['\"]?github\\.netflix\\.net['\"]?([[:space:];&|]|$)"
}

has_wrong_netflix_gh_cli_target() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def bad_repo_value(value):
    return re.match(r"^(https?://)?(github|git)\.netflix\.net(/|:)", value) is not None

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "gh":
        continue
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        value = None
        if token in {"--hostname", "--repo", "-R"} and idx + 1 < len(segment):
            value = segment[idx + 1]
            idx += 2
        elif token.startswith("--hostname=") or token.startswith("--repo="):
            value = token.split("=", 1)[1]
            idx += 1
        else:
            idx += 1
            continue

        if token.startswith("--hostname") and value == "github.netflix.net":
            sys.exit(0)
        if (token == "--repo" or token == "-R" or token.startswith("--repo=")) and bad_repo_value(value):
            sys.exit(0)

sys.exit(1)
PY
}

is_fun_bash_automations_repo() {
  local root remote
  root=$(git_context rev-parse --show-toplevel 2>/dev/null || true)
  if [ "$(basename "$root")" = "fun-bash-automations" ]; then
    return 0
  fi
  remote=$(git_context config --get remote.origin.url 2>/dev/null || true)
  [[ "$remote" == *"fun-bash-automations"* ]]
}

is_dotfiles_repo() {
  local root remote
  root=$(git_context rev-parse --show-toplevel 2>/dev/null || true)
  if [ "$(basename "$root")" = "dotfiles" ]; then
    return 0
  fi
  remote=$(git_context config --get remote.origin.url 2>/dev/null || true)
  [[ "$remote" == *"dotfiles"* ]]
}

is_git_push_command() {
  echo "$COMMAND" | grep -qE '(^|[;&|][[:space:]]*)git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)'
}

agent_push_policy_path() {
  printf '%s\n' "${PG_AGENT_PUSH_POLICY:-$SCRIPT_DIR/../agent-push-policy.json}"
}

direct_push_delivery_branch_for_repo() {
  local repo="$1" policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 1
  jq -r --arg repo "$repo" '
    (.direct_push_exceptions // [])
    | map(select(.repo == $repo))
    | first
    | .delivery_branch // empty
  ' "$policy_path" 2>/dev/null
}

# --- yolo branch class helpers ---
# Read configured yolo branch prefixes, but only when the class is enabled.
# A disabled/missing/malformed yolo policy yields no prefixes, so nothing is
# ever exempted (fail-closed).
yolo_branch_prefixes() {
  local policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 0
  jq -r '
    (.yolo_branches // {})
    | select((.enabled // false) == true)
    | .prefixes // []
    | .[]
  ' "$policy_path" 2>/dev/null
}

# True when token starts with a configured (enabled) yolo prefix.
is_yolo_branch_token() {
  local token="$1" prefix
  [[ -n "$token" ]] || return 1
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    [[ "$token" == "$prefix"* ]] && return 0
  done < <(yolo_branch_prefixes)
  return 1
}

current_branch_is_yolo() {
  local branch
  branch=$(git_context symbolic-ref --quiet --short HEAD 2>/dev/null || git_context branch --show-current 2>/dev/null || true)
  is_yolo_branch_token "$branch"
}

current_branch_is_protected() {
  local branch
  branch=$(git_context symbolic-ref --quiet --short HEAD 2>/dev/null || git_context branch --show-current 2>/dev/null || true)
  [[ "$branch" == "main" || "$branch" == "master" ]]
}

has_git_commit_amend_command() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


global_value_options = {
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--exec-path",
    "--super-prefix",
}
global_no_value_options = {
    "--bare",
    "--no-replace-objects",
    "--no-optional-locks",
    "--no-pager",
    "-p",
    "--paginate",
    "-P",
}


def commit_args(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return None
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "commit":
            return segment[idx + 1 :]
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if any(token.startswith(prefix) for prefix in (
            "--git-dir=",
            "--work-tree=",
            "--namespace=",
            "--exec-path=",
            "--super-prefix=",
        )):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None


for segment in segments:
    args = commit_args(segment)
    if args is not None and "--amend" in args:
        sys.exit(0)

sys.exit(1)
PY
}

# Emit each branch name targeted by a force-delete (`git branch -D ...`, or a
# `-d`/`--delete` combined with `--force`/`-f`, or a bundled short flag like
# -Df) in COMMAND, one name per line. Empty output means no such delete.
# Used only to decide whether a `git branch -D` is a pure yolo cleanup.
git_branch_force_delete_targets() {
  python3 - "$COMMAND" <<'PY'
import re, shlex, sys

command = sys.argv[1]
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


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


def branch_args(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return None
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "-C":
            idx += 2
            continue
        if token in {"--git-dir", "--work-tree"}:
            idx += 2
            continue
        if token.startswith("--git-dir=") or token.startswith("--work-tree="):
            idx += 1
            continue
        if token == "branch":
            return segment[idx + 1:]
        return None
    return None


targets = []
for segment in segments:
    args = branch_args(segment)
    if args is None:
        continue
    force = False
    delete = False
    names = []
    for tok in args:
        if tok == "-D":
            force = True
            delete = True
            continue
        if tok in {"-d", "--delete"}:
            delete = True
            continue
        if tok in {"--force", "-f"}:
            force = True
            continue
        if tok.startswith("-") and not tok.startswith("--"):
            short = tok[1:]
            if "D" in short:
                force = True
                delete = True
            if "d" in short:
                delete = True
            if "f" in short:
                force = True
            continue
        if tok.startswith("-"):
            continue
        names.append(tok)
    if delete and force and names:
        targets.extend(names)

for name in targets:
    print(name)
PY
}

git_push_target_branch_from_command() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(0)

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def push_args_for_segment(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return None
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "push":
            return segment[idx + 1:]
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if token.startswith("--git-dir=") or token.startswith("--work-tree=") or token.startswith("--namespace=") or token.startswith("--exec-path=") or token.startswith("--super-prefix="):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None

push_args = [args for args in (push_args_for_segment(segment) for segment in segments) if args is not None]
if not push_args:
    sys.exit(0)
if len(push_args) > 1:
    print("__MULTI_PUSH__")
    sys.exit(0)

args = push_args[0]
remote = None
refspecs = []
skip_next = False
is_delete = False
for token in args:
    if skip_next:
        skip_next = False
        continue
    if token in {"--all", "--mirror", "--tags"}:
        print("__BROAD__")
        sys.exit(0)
    if token in {"--delete", "-d"}:
        is_delete = True
        continue
    if token == "--":
        continue
    if token.startswith("-"):
        if token in {"--repo"}:
            skip_next = True
        continue
    if remote is None:
        remote = token
    else:
        refspecs.append(token)

if len(refspecs) > 1:
    print("__MULTI__")
    sys.exit(0)
if is_delete:
    print("__DELETE__")
    sys.exit(0)
if not refspecs:
    sys.exit(0)

refspec = refspecs[0]
if refspec.startswith("+"):
    refspec = refspec[1:]
if ":" in refspec:
    source, target = refspec.split(":", 1)
    if source == "" and target:
        print("__DELETE__")
        sys.exit(0)
else:
    target = refspec
if target.startswith("refs/heads/"):
    target = target[len("refs/heads/"):]
if target and target != "HEAD":
    print(target)
PY
}

direct_push_exception_matches() {
  local repo="$1" delivery_branch target_branch
  delivery_branch=$(direct_push_delivery_branch_for_repo "$repo")
  [[ -n "$delivery_branch" ]] || return 1
  target_branch=$(git_push_target_branch_from_command)
  [[ "$target_branch" == "__MULTI__" || "$target_branch" == "__MULTI_PUSH__" || "$target_branch" == "__BROAD__" || "$target_branch" == "__DELETE__" ]] && return 1
  if [[ -n "$target_branch" ]]; then
    [[ "$target_branch" == "$delivery_branch" ]]
    return
  fi
  return 1
}

is_direct_delivery_push() {
  is_git_push_command || return 1
  if is_dotfiles_repo; then
    direct_push_exception_matches "dotfiles"
    return $?
  fi
  if is_fun_bash_automations_repo; then
    echo "$COMMAND" | grep -qE '(^|[[:space:]:/])(main|master)([[:space:]]|$)|HEAD:(main|master)|refs/heads/(main|master)' && return 1
    direct_push_exception_matches "fun-bash-automations"
    return $?
  fi
  return 1
}

ssh_lease_file() {
  printf '%s\n' "${SSH_LEASE_FILE:-/tmp/.claude-ssh-leases}"
}

ssh_command_lease_file() {
  printf '%s\n' "${SSH_COMMAND_LEASE_FILE:-/tmp/.claude-ssh-command-leases}"
}

extract_ssh_target() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

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

value_options = {
    "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
    "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
}
placeholder_hosts = {"ignored", "ignore", "placeholder", "dummy"}

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def normalize_host(token):
    if "@" in token:
        token = token.rsplit("@", 1)[1]
    if token.startswith("[") and "]" in token:
        token = token[1:token.index("]")]
    return token

def resolve_config_target(config_path, host):
    if not config_path or host not in placeholder_hosts:
        return host

    instance_match = re.search(r"i-[0-9a-fA-F]{8,}", config_path)
    if instance_match:
        return instance_match.group(0)

    hostname = None
    active = False
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = line.split()
                key = parts[0].lower()
                values = parts[1:]
                if key == "host":
                    active = host in values or "*" in values
                elif active and key == "hostname" and values:
                    hostname = values[0]
                    break
    except OSError:
        return host

    return hostname or host

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "ssh":
        continue
    idx = 1
    config_path = None
    while idx < len(segment):
        token = segment[idx]
        if token == "--":
            idx += 1
            if idx < len(segment):
                print(resolve_config_target(config_path, normalize_host(segment[idx])))
            sys.exit(0)
        if token == "-F" and idx + 1 < len(segment):
            config_path = segment[idx + 1]
            idx += 2
            continue
        if token.startswith("-F") and len(token) > 2:
            config_path = token[2:]
            idx += 1
            continue
        if token in value_options:
            idx += 2
            continue
        if token.startswith("-"):
            idx += 1
            continue
        print(resolve_config_target(config_path, normalize_host(token)))
        sys.exit(0)
sys.exit(0)
PY
}

has_ssh_invocation() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

for segment in segments:
    segment = strip_env_assignments(segment)
    if segment and segment[0] == "ssh":
        sys.exit(0)
sys.exit(1)
PY
}

ssh_remote_safety_violation() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

value_options = {
    "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
    "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
}

danger_commands = {
    "sudo", "su", "systemctl", "service", "kill", "pkill", "killall",
    "rm", "mv", "chmod", "chown", "cqlsh",
}
remote_wrappers = {
    ("bash", "-c"), ("sh", "-c"), ("zsh", "-c"),
    ("python", "-c"), ("python3", "-c"), ("perl", "-e"),
    ("ruby", "-e"), ("node", "-e"),
}
nodetool_deny = {
    "repair", "compact", "garbagecollect", "cleanup", "scrub",
    "upgradesstables", "refresh", "rebuild", "rebuild_index",
    "decommission", "removenode", "assassinate", "move", "bootstrap",
    "drain", "disablebinary", "disablegossip", "disablehandoff",
    "stopdaemon", "truncatehints",
}

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def remote_tokens(segment):
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "--":
            idx += 2
            return segment[idx:]
        if token in value_options:
            idx += 2
            continue
        if token.startswith("-o") and len(token) > 2:
            idx += 1
            continue
        if token.startswith("-F") and len(token) > 2:
            idx += 1
            continue
        if token.startswith("-"):
            idx += 1
            continue
        return segment[idx + 1 :]
    return []

def flatten_remote(remote):
    if not remote:
        return []
    joined = " ".join(remote)
    try:
        return shlex.split(joined, posix=True)
    except ValueError:
        return remote

def base(token):
    return token.rsplit("/", 1)[-1].lower()

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "ssh":
        continue

    remote = remote_tokens(segment)
    if not remote:
        print("interactive ssh without an explicit remote command")
        sys.exit(0)

    lowered = [base(token) for token in flatten_remote(remote)]
    for idx, token in enumerate(lowered):
        if token in danger_commands:
            print(f"dangerous remote ssh command: {token}")
            sys.exit(0)
        if idx + 1 < len(lowered) and (token, lowered[idx + 1]) in remote_wrappers:
            print(f"remote ssh shell/code wrapper is not allowed: {token} {lowered[idx + 1]}")
            sys.exit(0)
        if token == "nodetool" and idx + 1 < len(lowered):
            verb = lowered[idx + 1]
            if verb in nodetool_deny or verb.startswith(("disable", "set")):
                print(f"dangerous remote cassandra nodetool command: nodetool {verb}")
                sys.exit(0)

sys.exit(1)
PY
}

ssh_sensitive_remote_command() {
  python3 - "$COMMAND" <<'PY'
import hashlib
import re
import shlex
import sys

command = sys.argv[1]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

value_options = {
    "-B", "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
    "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
}

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def remote_tokens(segment):
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "--":
            idx += 2
            return segment[idx:]
        if token in value_options:
            idx += 2
            continue
        if token.startswith("-o") and len(token) > 2:
            idx += 1
            continue
        if token.startswith("-F") and len(token) > 2:
            idx += 1
            continue
        if token.startswith("-"):
            idx += 1
            continue
        return segment[idx + 1 :]
    return []

def flatten_remote(remote):
    if not remote:
        return []
    joined = " ".join(remote)
    try:
        return shlex.split(joined, posix=True)
    except ValueError:
        return remote

def base(token):
    return token.rsplit("/", 1)[-1].lower()

def canonical(tokens):
    return " ".join(shlex.quote(token) for token in tokens)

def sensitive_reason(tokens):
    lowered = [base(token) for token in tokens]
    for idx, token in enumerate(lowered):
        if token == "nodetool" and idx + 1 < len(lowered) and lowered[idx + 1] == "toppartitions":
            return "nodetool toppartitions"
        if token in {"jcmd", "jstack", "jmap"}:
            return token
        if token == "tar":
            return "remote tar"
        if token == "find" and any(part.startswith("/mnt/data/cassandra") for part in tokens[idx + 1 :]):
            return "find under /mnt/data/cassandra"
        if token == "tail":
            for part in tokens[idx + 1 :]:
                if part.isdigit() and int(part) > 5000:
                    return "large remote tail"
                if part.startswith("-") and part[1:].isdigit() and int(part[1:]) > 5000:
                    return "large remote tail"
        if token == "grep" and any(part.startswith("/mnt/data/cassandra/logs/") for part in tokens[idx + 1 :]):
            return "grep over cassandra logs"
    return ""

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "ssh":
        continue
    remote = flatten_remote(remote_tokens(segment))
    if not remote:
        continue
    reason = sensitive_reason(remote)
    if reason:
        remote_text = canonical(remote)
        digest = hashlib.sha256(remote_text.encode("utf-8")).hexdigest()
        print(f"{digest}\t{reason}\t{remote_text}")
        sys.exit(0)

sys.exit(1)
PY
}

ssh_uses_unsafe_host_key_options() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

unsafe = []

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def check_option(value):
    if "=" not in value:
        return
    key, raw = value.split("=", 1)
    key = key.strip().lower()
    val = raw.strip().lower()
    if key == "stricthostkeychecking" and val == "no":
        unsafe.append("StrictHostKeyChecking=no")
    elif key in {"userknownhostsfile", "globalknownhostsfile"} and val == "/dev/null":
        unsafe.append(f"{key}=/dev/null")

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] not in {"ssh", "scp", "rsync"}:
        continue
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "-o" and idx + 1 < len(segment):
            check_option(segment[idx + 1])
            idx += 2
            continue
        if token.startswith("-o") and len(token) > 2:
            check_option(token[2:])
        idx += 1

if unsafe:
    print(", ".join(dict.fromkeys(unsafe)))
    sys.exit(0)
sys.exit(1)
PY
}

has_valid_ssh_lease() {
  local target="$1" lease_file now host expiry
  lease_file=$(ssh_lease_file)
  [ -f "$lease_file" ] && [ -n "$target" ] || return 1
  now=$(date +%s)
  while IFS=' ' read -r host expiry; do
    if [ "$host" = "$target" ] && [ "$expiry" -gt "$now" ] 2>/dev/null; then
      return 0
    fi
  done < "$lease_file"
  return 1
}

has_valid_ssh_command_lease() {
  local target="$1" command_hash="$2" lease_file now hash expiry host rest
  lease_file=$(ssh_command_lease_file)
  [ -f "$lease_file" ] && [ -n "$target" ] && [ -n "$command_hash" ] || return 1
  now=$(date +%s)
  while IFS=$'\t' read -r hash expiry host rest; do
    if [ "$hash" = "$command_hash" ] && [ "$host" = "$target" ] && [ "$expiry" -gt "$now" ] 2>/dev/null; then
      return 0
    fi
  done < "$lease_file"
  return 1
}

gist_upload_filenames() {
  python3 - "$COMMAND" <<'PY'
import json
import os
import re
import shlex
import sys

command = sys.argv[1]

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


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


def collect_gist_create_files(args):
    files = []
    idx = 0
    value_flags = {"-d", "--desc", "-f", "--filename"}
    while idx < len(args):
        token = args[idx]
        if token == "--":
            files.extend(args[idx + 1 :])
            break
        if token in value_flags:
            if token in {"-f", "--filename"} and idx + 1 < len(args):
                files.append(args[idx + 1])
            idx += 2
            continue
        if token.startswith("--desc="):
            idx += 1
            continue
        if token.startswith("--filename="):
            files.append(token.split("=", 1)[1])
            idx += 1
            continue
        if token.startswith("-"):
            idx += 1
            continue
        if token != "-":
            files.append(token)
        idx += 1
    return files


def collect_gist_api_files(args):
    endpoint = None
    input_path = None
    idx = 0
    while idx < len(args):
        token = args[idx]
        if endpoint is None and not token.startswith("-"):
            endpoint = token
            idx += 1
            continue
        if token == "--input" and idx + 1 < len(args):
            input_path = args[idx + 1]
            idx += 2
            continue
        if token.startswith("--input="):
            input_path = token.split("=", 1)[1]
            idx += 1
            continue
        idx += 1

    if not endpoint or not re.match(r"^/?gists(?:/[^\s]+)?$", endpoint):
        return []

    if not input_path:
        return []

    if input_path.startswith("@"):
        input_path = input_path[1:]

    try:
        with open(input_path, "r", encoding="utf-8") as fh:
            payload = json.load(fh)
    except Exception:
        return []

    files = payload.get("files")
    if not isinstance(files, dict):
        return []

    return list(files.keys())


filenames = []
for segment in segments:
    stripped = strip_env_assignments(segment)
    if len(stripped) >= 3 and stripped[0] == "gh" and stripped[1] == "gist" and stripped[2] == "create":
        filenames.extend(collect_gist_create_files(stripped[3:]))
        continue
    if len(stripped) >= 2 and stripped[0] == "gh" and stripped[1] == "api":
        filenames.extend(collect_gist_api_files(stripped[2:]))

for name in filenames:
    if name:
        print(os.path.basename(name))
PY
}

has_netflix_gist_hostname() {
  echo "$COMMAND" | grep -qE "(^|[[:space:]])GH_HOST=['\"]?git\\.netflix\\.net['\"]?([[:space:]]|$)|--hostname(=|[[:space:]]+)['\"]?git\\.netflix\\.net['\"]?([[:space:]]|$)"
}

has_fba_pr_open_command() {
  python3 - "$COMMAND" "$(is_fun_bash_automations_repo && printf true || printf false)" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]
cwd_is_fba = sys.argv[2] == "true"

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def repo_is_fba(repo):
    if not repo:
        return False
    repo = repo.rstrip("/")
    return (
        repo == "homatthew/fun-bash-automations"
        or repo == "fun-bash-automations"
        or repo.endswith("/fun-bash-automations")
        or "fun-bash-automations.git" in repo
    )

def fba_target(args):
    repo = None
    idx = 0
    while idx < len(args):
        token = args[idx]
        if token in {"-R", "--repo"} and idx + 1 < len(args):
            repo = args[idx + 1]
            idx += 2
            continue
        if token.startswith("--repo="):
            repo = token.split("=", 1)[1]
        idx += 1
    return repo_is_fba(repo) or (repo is None and cwd_is_fba)

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "gh":
        continue
    args = segment[1:]
    while args and args[0] in {"-R", "--repo"}:
        args = args[2:] if len(args) > 1 else []
    while args and args[0].startswith("--repo="):
        args = args[1:]
    if len(args) >= 2 and args[0] == "pr" and args[1] in {"create", "ready", "reopen"}:
        if fba_target(segment[1:]):
            sys.exit(0)
sys.exit(1)
PY
}

has_scratch_pr_open_command() {
  local policy_path current_branch prefixes_json policy_valid
  policy_path=$(agent_push_policy_path)
  policy_valid=true
  if [[ -f "$policy_path" ]]; then
    prefixes_json=$(jq -c '
      if (.scratch_branches.enabled == true)
        and (.scratch_branches.prefixes | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
      then .scratch_branches.prefixes
      else error("invalid scratch branch policy")
      end
    ' "$policy_path" 2>/dev/null) || policy_valid=false
  else
    policy_valid=false
  fi
  [[ "$policy_valid" == "true" ]] || prefixes_json='[]'
  current_branch=$(git_context branch --show-current 2>/dev/null || true)
  python3 - "$COMMAND" "$current_branch" "$prefixes_json" "$policy_valid" <<'PY'
import json
import re
import shlex
import sys

command = sys.argv[1]
current_branch = sys.argv[2]
prefixes = json.loads(sys.argv[3])
policy_valid = sys.argv[4] == "true"

try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(1)

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

def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]

def strip_gh_global_args(args):
    out = []
    idx = 0
    value_opts = {"-R", "--repo", "--hostname"}
    while idx < len(args):
        token = args[idx]
        if token in value_opts and idx + 1 < len(args):
            idx += 2
            continue
        if token.startswith("--repo=") or token.startswith("--hostname="):
            idx += 1
            continue
        out.append(token)
        idx += 1
    return out

def option_value(args, names):
    idx = 0
    while idx < len(args):
        token = args[idx]
        if token in names and idx + 1 < len(args):
            return args[idx + 1]
        for name in names:
            if token.startswith(name + "="):
                return token.split("=", 1)[1]
        idx += 1
    return None

def positional_args(args):
    out = []
    idx = 0
    value_opts = {"--head", "-H", "--base", "-B", "--title", "-t", "--body", "-b", "--body-file", "-F", "--assignee", "-a", "--reviewer", "-r", "--label", "-l", "--milestone", "-m", "--project", "-p", "--template", "-T"}
    flag_opts = {"--draft", "--fill", "--fill-first", "--fill-verbose", "--web", "--recover", "--no-maintainer-edit", "--remove-source-branch"}
    while idx < len(args):
        token = args[idx]
        if token == "--":
            out.extend(args[idx + 1:])
            break
        if token in value_opts and idx + 1 < len(args):
            idx += 2
            continue
        if any(token.startswith(name + "=") for name in value_opts if name.startswith("--")):
            idx += 1
            continue
        if token in flag_opts or token.startswith("-"):
            idx += 1
            continue
        out.append(token)
        idx += 1
    return out

def is_scratch_ref(ref):
    if not ref:
        return False
    candidates = [ref]
    if ":" in ref:
        candidates.append(ref.rsplit(":", 1)[1])
    return any(candidate.startswith(prefix) for candidate in candidates for prefix in prefixes)

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "gh":
        continue
    args = strip_gh_global_args(segment[1:])
    if len(args) < 2 or args[0] != "pr" or args[1] not in {"create", "ready", "reopen"}:
        continue
    if not policy_valid:
        sys.exit(0)
    pr_args = args[2:]
    head = option_value(pr_args, {"--head", "-H"})
    base = option_value(pr_args, {"--base", "-B"})
    if is_scratch_ref(head) or is_scratch_ref(base):
        sys.exit(0)
    if args[1] in {"ready", "reopen"}:
        for arg in positional_args(pr_args):
            if is_scratch_ref(arg):
                sys.exit(0)
    if head is None and is_scratch_ref(current_branch):
        sys.exit(0)

sys.exit(1)
PY
}

is_gh_api_gist_create() {
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh\s+api([[:space:]]|$)' || return 1
  echo "$COMMAND" | grep -qE "(^|[[:space:]\"'])/?gists([[:space:]\"']|$)" || return 1

  echo "$COMMAND" | grep -qE -- '--method[[:space:]]+POST|--method=POST|-X[[:space:]]+POST|-XPOST' && return 0
  echo "$COMMAND" | grep -qE -- '--input([=[:space:]]|$)' && return 0

  return 1
}

is_gh_gist_create() {
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh\s+gist\s+create([[:space:]]|$)'
}

check_gist_filename_sequence() {
  local filenames sorted_filenames line expected_index expected_prefix
  filenames=$(gist_upload_filenames)
  [ -n "$filenames" ] || return

  sorted_filenames=$(printf '%s\n' "$filenames" | LC_ALL=C sort)
  expected_index=1

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    expected_prefix=$(printf '%02d_' "$expected_index")
    case "$line" in
      "$expected_prefix"*)
        expected_index=$((expected_index + 1))
        ;;
      *)
        deny "Blocked: gist uploads must use contiguous ordered filenames like 01_..., 02_..., 03_.... Rename uploaded files or gist payload keys. First offending file: $line"
        ;;
    esac
  done <<EOF
$sorted_filenames
EOF
}

# --- 1. Git Force/Destructive ---
check_git_force() {
  # Allow --force-with-lease (safe for stacked PRs — fails if remote diverged)
  echo "$COMMAND" | grep -qE -- 'git\s+push\s+.*--force-with-lease' && return
  echo "$COMMAND" | grep -qE -- 'git\s+push\s+.*(-f |--force)' &&
    deny "Blocked: git push --force rewrites remote history. Use --force-with-lease."
  echo "$COMMAND" | grep -qE -- 'git\s+reset\s+--hard' &&
    deny "Blocked: git reset --hard discards all uncommitted changes."
  echo "$COMMAND" | grep -qE -- 'git\s+checkout\s+--\s*\.' &&
    deny "Blocked: git checkout -- . discards unstaged changes."
  echo "$COMMAND" | grep -qE 'git\s+checkout\s+\.\s*$' &&
    deny "Blocked: git checkout . discards unstaged changes."
  echo "$COMMAND" | grep -qE 'git\s+restore\s+\.' &&
    deny "Blocked: git restore . discards changes broadly."
  echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-f' &&
    deny "Blocked: git clean -f deletes untracked files."
  if echo "$COMMAND" | grep -qE 'git\s+branch\s+-D\s'; then
    # yolo branches may be force-deleted locally for cleanup of unmerged work.
    # Exempt only when EVERY deleted branch name is yolo-prefixed; a mixed or
    # non-yolo delete still blocks. Remote deletes are gated in push-gate, not
    # here.
    local _yolo_del_targets _yolo_del_ok _yolo_del_t
    _yolo_del_targets=$(git_branch_force_delete_targets)
    _yolo_del_ok=0
    if [[ -n "$_yolo_del_targets" ]]; then
      _yolo_del_ok=1
      while IFS= read -r _yolo_del_t; do
        [[ -z "$_yolo_del_t" ]] && continue
        is_yolo_branch_token "$_yolo_del_t" || _yolo_del_ok=0
      done <<< "$_yolo_del_targets"
    fi
    [[ "$_yolo_del_ok" == "1" ]] ||
      deny "Blocked: git branch -D force-deletes a branch."
  fi
  echo "$COMMAND" | grep -qE 'git\s+stash\s+(drop|clear)(\s|$)' &&
    deny "Blocked: git stash drop/clear loses stashed work."
}

# --- 2. Push Guard ---
# Self-contained protected-branch guard for agent-initiated pushes. The
# authoritative main-branch protection is the git-level pre-push hook, which
# also catches external binaries (gnhf, no-mistakes); this agent-layer check is
# defense-in-depth. The push-gate lease / Remote Scratch Mode / Dolt-stack
# auditing was retired with the rest of that stack, so this guard has no
# external dependency.
#
# Allowed: configured delivery pushes (FBA mh-netflix, dotfiles main) and normal
# feature-branch / no-mistakes-remote / gnhf pushes that name a non-protected
# target. Blocked: pushes (or deletes) to main/master/develop/trunk and bare or
# ambiguous pushes that do not name an explicit branch. Force-push protection
# lives separately in check_git_force.
check_push_guard() {
  is_git_push_command || return
  if is_direct_delivery_push; then
    return
  fi
  local target_branch
  target_branch=$(git_push_target_branch_from_command)
  case "$target_branch" in
    main|master|develop|trunk)
      deny "Blocked: pushing directly to origin/${target_branch} is not allowed. Push a feature branch and open a PR (e.g. via the no-mistakes remote)."
      ;;
    ""|__MULTI__|__MULTI_PUSH__|__BROAD__)
      deny "Blocked: bare git push is not allowed. Name the target branch explicitly, e.g. git push origin <branch>."
      ;;
    __DELETE__)
      # Protected-branch deletes are caught authoritatively by the git-level
      # pre-push hook; mirror that here as defense-in-depth.
      if echo "$COMMAND" | grep -qE '(^|[[:space:]:/+])(main|master|develop|trunk)([[:space:]]|$)|refs/heads/(main|master|develop|trunk)'; then
        deny "Blocked: deleting a protected branch (main/master/develop/trunk) is not allowed."
      fi
      ;;
  esac
}

# --- 2b. Branch Creation Tracking Guard ---
# Feature branches must not track integration branches or unrelated remote
# branches. The only allowed tracking relationship is a mirrored branch name:
# local mho/foo may track origin/mho/foo, but not origin/main or origin/bar.
remote_tracking_ref_from_token() {
  local token="$1"
  case "$token" in
    refs/remotes/*/*)
      echo "${token#refs/remotes/}"
      ;;
    origin/*|upstream/*)
      echo "$token"
      ;;
    *)
      return 1
      ;;
  esac
}

remote_tracking_branch_from_token() {
  local ref
  ref=$(remote_tracking_ref_from_token "$1") || return 1
  echo "${ref#*/}"
}

check_branch_tracking() {
  local current_branch tracking_block
  current_branch=$(git_context branch --show-current 2>/dev/null || true)
  tracking_block=$(python3 - "$COMMAND" "$current_branch" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]
current_branch = sys.argv[2]

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


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


def git_subcommand(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return None, []
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "-C":
            idx += 2
            continue
        if token in {"--git-dir", "--work-tree"}:
            idx += 2
            continue
        if token.startswith("--git-dir=") or token.startswith("--work-tree="):
            idx += 1
            continue
        return token, segment[idx + 1 :]
    return None, []


def remote_tracking_branch(token):
    if token.startswith("refs/remotes/"):
        pieces = token.split("/", 3)
        if len(pieces) == 4 and pieces[2] in {"origin", "upstream"}:
            return pieces[3]
    if token.startswith(("origin/", "upstream/")):
        return token.split("/", 1)[1]
    return None


def block_message(new_branch, remote_token, setting=False):
    if setting:
        return (
            f"Blocked: branch '{new_branch}' must not track '{remote_token}'. "
            "Feature branches may only track a mirrored remote branch name."
        )
    return (
        f"Blocked: branch '{new_branch}' would track '{remote_token}'. "
        "Feature branches may only track a mirrored remote branch name; use --no-track when branching from a base."
    )


def check_new_branch_from_tokens(args, branch_flags):
    if "--no-track" in args:
        return None
    create_idx = -1
    for idx, token in enumerate(args):
        if token in branch_flags:
            create_idx = idx
    if create_idx < 0 or create_idx + 1 >= len(args):
        return None
    new_branch = args[create_idx + 1]
    for token in args[create_idx + 2 :]:
        remote_branch = remote_tracking_branch(token)
        if remote_branch and new_branch != remote_branch:
            return block_message(new_branch, token)
    return None


for segment in segments:
    subcmd, args = git_subcommand(segment)
    if subcmd in {"checkout", "switch"}:
        message = check_new_branch_from_tokens(args, {"-b", "-c"})
        if message:
            print(message)
            sys.exit(0)
    elif subcmd == "worktree" and args and args[0] == "add":
        message = check_new_branch_from_tokens(args[1:], {"-b", "-B"})
        if message:
            print(message)
            sys.exit(0)
    elif subcmd == "branch":
        for idx, token in enumerate(args):
            if token == "--track" and idx + 2 < len(args):
                new_branch = args[idx + 1]
                remote_token = args[idx + 2]
                remote_branch = remote_tracking_branch(remote_token)
                if remote_branch and new_branch != remote_branch:
                    print(block_message(new_branch, remote_token))
                    sys.exit(0)
            elif token in {"-u", "--set-upstream-to"} and idx + 1 < len(args):
                remote_token = args[idx + 1]
                target_branch = args[idx + 2] if idx + 2 < len(args) else current_branch
                remote_branch = remote_tracking_branch(remote_token)
                if remote_branch and target_branch != remote_branch:
                    print(block_message(target_branch, remote_token, setting=True))
                    sys.exit(0)
            elif token.startswith("--set-upstream-to="):
                remote_token = token.split("=", 1)[1]
                target_branch = args[idx + 1] if idx + 1 < len(args) else current_branch
                remote_branch = remote_tracking_branch(remote_token)
                if remote_branch and target_branch != remote_branch:
                    print(block_message(target_branch, remote_token, setting=True))
                    sys.exit(0)
PY
)
  [[ -z "$tracking_block" ]] || deny "$tracking_block"
}

# --- 3. Git Config & Hook Bypass ---
check_git_config() {
  local git_config_block
  git_config_block=$(python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]

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


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


read_flags = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}
rerere_keys = {"rerere.enabled", "rerere.autoupdate"}


def git_config_args(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return None
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "-C":
            idx += 2
            continue
        if token.startswith("--git-dir=") or token.startswith("--work-tree="):
            idx += 1
            continue
        if token in {"--git-dir", "--work-tree"}:
            idx += 2
            continue
        if token == "config":
            return segment[idx + 1 :]
        return None
    return None


def allowed_git_config(args):
    if not args:
        return False
    if args[0] in read_flags:
        return True
    return (
        len(args) == 3
        and args[0] == "--local"
        and args[1] in rerere_keys
        and args[2] == "true"
    )


for segment in segments:
    args = git_config_args(segment)
    if args is not None and not allowed_git_config(args):
        print("Blocked: git config mutations are not allowed except read-only queries and local rerere enablement.")
        break
PY
  )
  [[ -n "$git_config_block" ]] && deny "$git_config_block"
  echo "$COMMAND" | grep -qE -- '--no-verify' &&
    deny "Blocked: --no-verify bypasses safety hooks."
  if has_git_commit_amend_command && current_branch_is_protected; then
    deny "Blocked: git commit --amend is not allowed on protected branches."
  fi
  echo "$COMMAND" | grep -qE 'commit\.gpgsign=false' &&
    deny "Blocked: disabling GPG signing is not allowed."
  echo "$COMMAND" | grep -qE '(CHECKSTYLE_SKIP|VERIFY_SKIP|SPOTLESS_SKIP)=' &&
    deny "Blocked: skipping pre-commit checks is not allowed."
}

# --- 4. Broad Git Staging ---
check_broad_staging() {
  echo "$COMMAND" | grep -qE -- 'git\s+add\s+(-A|--all|\.)(\s|$)' &&
    deny "Blocked: git add -A / git add . is too broad. Name files explicitly."
  echo "$COMMAND" | grep -qE 'git\s+add\s+.*\.(env|pem|key)(\s|$)' &&
    deny "Blocked: staging secrets/keys is not allowed."
  echo "$COMMAND" | grep -qE 'git\s+add\s+.*(credential|secret)' &&
    deny "Blocked: staging credential/secret files is not allowed."
}

# --- 5. Git Rebase ---
check_git_rebase() {
  # Allow safe operations
  echo "$COMMAND" | grep -qE -- 'git\s+rebase\s+--(abort|continue|skip)' && return

  # Block interactive rebase
  echo "$COMMAND" | grep -qE -- 'git\s+rebase\s+.*(-i|--interactive)' &&
    deny "Blocked: git rebase -i (interactive) is not allowed."

  # Allow --onto (re-parenting for stacked PRs)
  echo "$COMMAND" | grep -qE -- 'git\s+rebase\s+--onto\s' && return

  # Allow rebase with explicit branch target
  echo "$COMMAND" | grep -qE 'git\s+rebase\s+[a-zA-Z0-9_./-]+\s*$' && return

  # Block bare rebase (no target)
  echo "$COMMAND" | grep -qE 'git\s+rebase\s*$' &&
    deny "Blocked: bare git rebase with no target. Specify a branch."
}

# --- 6. File System Destruction ---
check_fs_destruction() {
  echo "$COMMAND" | grep -qE 'rm\s+.*-(r|rf|fr)(\s|$)' &&
    deny "Blocked: rm -rf / rm -r is not allowed. Remove files individually."
  echo "$COMMAND" | grep -qE 'rm\s+.*(/\s|~/|~/repos/|\.git/)' &&
    deny "Blocked: rm targeting critical paths is not allowed."
}

# --- 7. Elevated Privileges ---
check_elevated_privileges() {
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)sudo\s' &&
    deny "Blocked: sudo is not allowed."
  echo "$COMMAND" | grep -qE 'chmod\s+(-R\s+)?777' &&
    deny "Blocked: chmod 777 sets insecure permissions."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)chown\s' &&
    deny "Blocked: chown is not allowed."
}

# --- 8. Remote Code Execution ---
check_remote_exec() {
  echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|\s*(bash|sh|zsh)' &&
    deny "Blocked: pipe-to-shell (curl|sh) is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)eval\s' &&
    deny "Blocked: eval is not allowed."
  local ssh_remote_violation
  ssh_remote_violation=$(ssh_remote_safety_violation 2>/dev/null || true)
  if [ -n "$ssh_remote_violation" ]; then
    deny "Blocked: unsafe SSH remote command ($ssh_remote_violation). Use a bounded read-only command or an authorized probe script."
  fi
  local unsafe_ssh_options
  unsafe_ssh_options=$(ssh_uses_unsafe_host_key_options 2>/dev/null || true)
  if [ -n "$unsafe_ssh_options" ]; then
    deny "Blocked: unsafe SSH host-key option ($unsafe_ssh_options). Use StrictHostKeyChecking=accept-new instead."
  fi
  # Check SSH lease file for approved hosts (12-hour leases via ssh-gate)
  local SSH_TARGET sensitive_ssh hash reason remote_command
  SSH_TARGET=$(extract_ssh_target)
  if [ -n "$SSH_TARGET" ] || has_ssh_invocation; then
    if [ -n "$SSH_TARGET" ]; then
      if ! has_valid_ssh_lease "$SSH_TARGET"; then
        deny "Blocked: ssh to '$SSH_TARGET' requires a lease. Ask the user to run: ssh-gate $SSH_TARGET"
      fi
      sensitive_ssh=$(ssh_sensitive_remote_command 2>/dev/null || true)
      if [ -n "$sensitive_ssh" ]; then
        IFS=$'\t' read -r hash reason remote_command <<< "$sensitive_ssh"
        if ! has_valid_ssh_command_lease "$SSH_TARGET" "$hash"; then
          deny "Blocked: sensitive SSH remote command ($reason) requires an exact command lease for '$SSH_TARGET'. Ask the user to run: ssh-command-gate $SSH_TARGET -- $remote_command"
        fi
      fi
      return
    fi
    deny "Blocked: ssh requires a lease. Ask the user to run: ssh-gate <host>"
  fi
  # scp/rsync: allow local-only, check SSH lease for remote hosts
  if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)(scp|rsync)\s'; then
    # No [user@]host: pattern means local-only — allow
    echo "$COMMAND" | grep -qE '([a-zA-Z0-9._-]+@)?[a-zA-Z0-9._-]+:' || return
    # Remote host detected — extract and check lease
    local REMOTE_HOST
    REMOTE_HOST=$(echo "$COMMAND" | grep -oE '([a-zA-Z0-9._-]+@)?[a-zA-Z0-9._-]+:' | head -1 | sed 's/.*@//' | sed 's/://')
    if has_valid_ssh_lease "$REMOTE_HOST"; then
      return
    fi
    deny "Blocked: scp/rsync to remote host '$REMOTE_HOST' requires an SSH lease. Ask the user to run: ssh-gate $REMOTE_HOST"
  fi
}

# --- 9. Package Publishing ---
check_package_publish() {
  echo "$COMMAND" | grep -qE 'npm\s+publish' &&
    deny "Blocked: npm publish is not allowed."
  echo "$COMMAND" | grep -qE '(twine|pip)\s+upload' &&
    deny "Blocked: PyPI publishing is not allowed."
  echo "$COMMAND" | grep -qE 'cargo\s+publish' &&
    deny "Blocked: cargo publish is not allowed."
  echo "$COMMAND" | grep -qE 'gem\s+push' &&
    deny "Blocked: gem push is not allowed."
}

# --- 10. GitHub Destructive ---
check_gh_destructive() {
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)gh\s+(pr\s+)?merge' &&
    deny "Blocked: gh merge is not allowed. Merging PRs requires human action."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)gh\s+repo\s+delete' &&
    deny "Blocked: gh repo delete is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)gh\s+pr\s+close' &&
    deny "Blocked: gh pr close requires human judgment."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)gh\s+issue\s+close' &&
    deny "Blocked: gh issue close requires human judgment."
}

# --- 10b. GitHub Host Safety ---
check_gh_host_safety() {
  if has_wrong_netflix_gh_host || has_wrong_netflix_gh_cli_target; then
    deny "Blocked: github.netflix.net is the browser URL, not the gh CLI host. Use GH_HOST=git.netflix.net and pass repos as owner/name, e.g. GH_HOST=git.netflix.net gh pr view 123 --repo org/repo."
  fi
}

# --- 10ba. fun-bash-automations PR Safety ---
check_fba_pr_safety() {
  has_fba_pr_open_command || return
  deny "Blocked: fun-bash-automations uses mh-netflix as the delivery branch. Do not create, reopen, or mark ready PRs from mh-netflix to main."
}

# --- 10bb. Scratch PR Safety ---
check_scratch_pr_safety() {
  has_scratch_pr_open_command || return
  deny "Blocked: scratch branches are not PR-eligible. Promote the commits to a delivery branch and use push-gate."
}

# --- 10c. GitHub Gist Host Safety ---
check_gh_gist_host_safety() {
  is_gh_api_gist_create || is_gh_gist_create || return
  has_netflix_gist_hostname && return

  deny "Blocked: gh gist creation must target Netflix GHE explicitly. Use GH_HOST=git.netflix.net or --hostname git.netflix.net."
}

# --- 10d. GitHub Gist Filename Safety ---
check_gh_gist_filename_safety() {
  check_gist_filename_sequence
}

# --- 11. Docker Destructive ---
check_docker_destructive() {
  echo "$COMMAND" | grep -qE 'docker\s+push' &&
    deny "Blocked: docker push is not allowed."
  echo "$COMMAND" | grep -qE 'docker\s+system\s+prune' &&
    deny "Blocked: docker system prune is not allowed."
  echo "$COMMAND" | grep -qE 'docker\s+rm\s+.*-f' &&
    deny "Blocked: docker rm -f is not allowed."
}

# --- 13. Private guard extensions ---
guard_extension_dirs() {
  local configured="${BASH_SAFETY_GUARD_EXTENSION_DIRS:-}"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured" | tr ':' '\n'
  else
    printf '%s\n' "$SCRIPT_DIR/bash-safety-guard.d"
  fi
}

run_guard_extensions() {
  local dir ext out rc
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    for ext in "$dir"/*.sh; do
      [[ -f "$ext" ]] || continue
      out=$(printf '%s\n' "$INPUT" | "$ext" 2>&1)
      rc=$?
      if [[ "$rc" -ne 0 ]]; then
        deny "Blocked: safety guard extension $(basename "$ext") failed (rc=$rc): $out"
      fi
      [[ -z "$out" ]] && continue
      if printf '%s\n' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
        printf '%s\n' "$out"
        exit 0
      fi
      deny "Blocked: safety guard extension $(basename "$ext") returned invalid output: $out"
    done
  done < <(guard_extension_dirs)
}

# --- Trusted dev-workspace bypass (scoped to *.work ssh) ---
# An ssh invocation whose target host ends in ".work" runs its command on a
# sandboxed Netflix dev workspace, not on this machine, so the content guards
# below (rm/kill/eval/wrappers/sensitive-command lease/etc.) do not apply. The
# host lease (ssh-gate) is still required. Intentionally loosened for hands-on
# dev-workspace bring-up; delete this block to restore full guarding.
_dotwork_target=$(extract_ssh_target)
case "$_dotwork_target" in
  *.work)
    if has_valid_ssh_lease "$_dotwork_target"; then
      exit 0
    fi
    deny "Blocked: ssh to '$_dotwork_target' requires a lease. Ask the user to run: ssh-gate $_dotwork_target"
    ;;
esac

# --- Run all checks ---
check_git_force
check_push_guard
check_branch_tracking
check_git_config
check_broad_staging
check_git_rebase
check_fs_destruction
check_elevated_privileges
check_remote_exec
check_package_publish
check_gh_destructive
check_gh_host_safety
check_fba_pr_safety
check_scratch_pr_safety
check_gh_gist_host_safety
check_gh_gist_filename_safety
check_docker_destructive
run_guard_extensions

exit 0
