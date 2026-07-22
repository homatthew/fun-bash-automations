#!/bin/bash
# bash-safety-guard.sh
# Claude-native implementation of the shared policy in:
#   ~/repos/fun-bash-automations/llm/command-guard-policy.md
# PreToolUse hook on Bash: blocks dangerous commands from autonomous agents.
# Each guard category is a function. To disable a category, comment out its call.
# Compatible with macOS BSD grep (no \b or \d).

INPUT=$(cat)
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Blocked: bash safety guard requires jq."}}'
  exit 0
fi

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
' >/dev/null 2>&1 || deny "Blocked: invalid Bash hook input."
command -v python3 >/dev/null 2>&1 ||
  deny "Blocked: bash safety guard requires Python 3."

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command')
if ! GIT_COMMAND=$(python3 - "$COMMAND" <<'PY'
import os
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    print("__GIT_NORMALIZATION_FAILED__")
    sys.exit(0)

segments = []
separators = []
current = []
for token in tokens:
    if token in {"&&", "||", ";", "|"}:
        segments.append(current)
        separators.append(token)
        current = []
    else:
        current.append(token)
segments.append(current)

assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
shells = {"bash", "dash", "ksh", "sh", "zsh"}
eval_short_options = {
    "lua": {"e"},
    "luajit": {"e"},
    "node": {"e", "p"},
    "nodejs": {"e", "p"},
    "osascript": {"e"},
    "perl": {"e", "E"},
    "php": {"r"},
    "R": {"e"},
    "Rscript": {"e"},
    "ruby": {"e"},
}
eval_long_options = {
    "node": {"--eval", "--print"},
    "nodejs": {"--eval", "--print"},
}

def has_shell_command_string(args):
    idx = 0
    value_options = {"-o", "-O", "--rcfile"}
    while idx < len(args):
        token = args[idx]
        if token == "--":
            return False
        if token in value_options:
            idx += 2
            continue
        if token.startswith("--rcfile="):
            idx += 1
            continue
        if token == "-c" or (token.startswith("-") and not token.startswith("--") and "c" in token[1:]):
            return True
        if not token.startswith("-"):
            return False
        idx += 1
    return False

def is_python(executable):
    return re.fullmatch(r"python(?:\d+(?:\.\d+)*)?", executable) is not None

def has_eval_string(executable, args):
    if executable in shells:
        return has_shell_command_string(args)
    if is_python(executable):
        return any(token == "-c" or token.startswith("-c") for token in args)
    short_options = eval_short_options.get(executable)
    long_options = eval_long_options.get(executable, set())
    if not short_options and not long_options:
        return False
    for token in args:
        if token.startswith("--"):
            if token in long_options or any(token.startswith(flag + "=") for flag in long_options):
                return True
            continue
        if token.startswith("-") and any(option in token[1:] for option in short_options):
            return True
    return False

def normalize(segment):
    original = list(segment)
    idx = 0
    while idx < len(segment) and assignment.match(segment[idx]):
        idx += 1
    prefix = segment[:idx]

    while idx < len(segment):
        executable = os.path.basename(segment[idx])
        if executable == "command":
            idx += 1
            while idx < len(segment) and segment[idx] in {"-p", "--"}:
                idx += 1
            if idx < len(segment) and segment[idx] in {"-v", "-V"}:
                return original
            continue
        if executable == "exec":
            idx += 1
            while idx < len(segment):
                token = segment[idx]
                if token == "--":
                    idx += 1
                    break
                if token == "-a":
                    if idx + 1 >= len(segment):
                        raise ValueError("missing exec argv name")
                    idx += 2
                    continue
                if token.startswith("-a") and len(token) > 2:
                    idx += 1
                    continue
                if re.fullmatch(r"-[cl]+", token):
                    idx += 1
                    continue
                break
            continue
        if executable == "env":
            idx += 1
            while idx < len(segment):
                token = segment[idx]
                if token in {"-S", "--split-string"}:
                    if idx + 1 >= len(segment):
                        raise ValueError("missing env split string")
                    split_args = shlex.split(segment[idx + 1], posix=True)
                    if not split_args:
                        raise ValueError("empty env split string")
                    segment = segment[:idx] + split_args + segment[idx + 2:]
                    continue
                if token.startswith("--split-string="):
                    split_args = shlex.split(token.split("=", 1)[1], posix=True)
                    if not split_args:
                        raise ValueError("empty env split string")
                    segment = segment[:idx] + split_args + segment[idx + 1:]
                    continue
                if token.startswith("-S") and len(token) > 2:
                    split_args = shlex.split(token[2:], posix=True)
                    if not split_args:
                        raise ValueError("empty env split string")
                    segment = segment[:idx] + split_args + segment[idx + 1:]
                    continue
                if assignment.match(token):
                    idx += 1
                    continue
                if token in {"-i", "--ignore-environment", "-0", "--null", "--"}:
                    idx += 1
                    continue
                if token in {"-u", "--unset", "-C", "--chdir"} and idx + 1 < len(segment):
                    idx += 2
                    continue
                if token.startswith(("--unset=", "--chdir=")):
                    idx += 1
                    continue
                break
            continue
        if executable in {"nice", "nohup", "time", "timeout"}:
            idx += 1
            while idx < len(segment):
                token = segment[idx]
                if token == "--":
                    idx += 1
                    break
                if executable == "nice" and (re.fullmatch(r"-\d+", token) or token.startswith("--adjustment=")):
                    idx += 1
                    continue
                if executable == "nice" and token in {"-n", "--adjustment"}:
                    if idx + 1 >= len(segment):
                        raise ValueError("missing nice adjustment")
                    idx += 2
                    continue
                if executable == "nohup" and not token.startswith("-"):
                    break
                if executable == "time" and token in {"-p", "-l", "--quiet", "--verbose"}:
                    idx += 1
                    continue
                if executable == "time" and token in {"-o", "--output", "-f", "--format"}:
                    if idx + 1 >= len(segment):
                        raise ValueError("missing time option value")
                    idx += 2
                    continue
                if executable == "time" and token.startswith(("--output=", "--format=")):
                    idx += 1
                    continue
                if executable == "timeout" and token in {"-k", "--kill-after", "-s", "--signal"}:
                    if idx + 1 >= len(segment):
                        raise ValueError("missing timeout option value")
                    idx += 2
                    continue
                if executable == "timeout" and token.startswith(("--kill-after=", "--signal=")):
                    idx += 1
                    continue
                if executable == "timeout" and token in {"--foreground", "--preserve-status", "--verbose"}:
                    idx += 1
                    continue
                if executable == "timeout" and not token.startswith("-"):
                    idx += 1
                    break
                if token.startswith("-"):
                    raise ValueError("unknown process wrapper option")
                break
            continue
        break

    for candidate in range(idx, len(segment)):
        executable = os.path.basename(segment[candidate])
        if has_eval_string(executable, segment[candidate + 1:]):
            raise RuntimeError("local interpreter command string")

    git_positions = [candidate for candidate in range(idx, len(segment)) if os.path.basename(segment[candidate]) == "git"]
    if git_positions:
        git_index = git_positions[0]
        return prefix + ["git"] + segment[git_index + 1:]
    return original

try:
    normalized = [normalize(segment) for segment in segments]
except RuntimeError:
    print("__LOCAL_INTERPRETER_WRAPPER__")
    sys.exit(0)
except ValueError:
    print("__GIT_NORMALIZATION_FAILED__")
    sys.exit(0)
parts = []
for index, segment in enumerate(normalized):
    if segment:
        parts.append(" ".join(shlex.quote(token) for token in segment))
    if index < len(separators):
        parts.append(separators[index])
print(" ".join(parts))
PY
); then
  deny "Blocked: unable to normalize command safely."
fi
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
GUARD_WORKDIR=$(python3 - "$GIT_COMMAND" "$INPUT_WORKDIR" <<'PY'
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

[[ "$GIT_COMMAND" == *"__GIT_NORMALIZATION_FAILED__"* ]] &&
  deny "Blocked: unable to safely parse wrapped git command."
[[ "$GIT_COMMAND" == *"__LOCAL_INTERPRETER_WRAPPER__"* ]] &&
  deny "Blocked: local code-interpreter command strings are not allowed."

# --- Helpers ---
git_context() {
  if [[ -n "$GUARD_WORKDIR" && -d "$GUARD_WORKDIR" ]]; then
    git -C "$GUARD_WORKDIR" "$@"
  else
    git "$@"
  fi
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

is_git_push_command() {
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}


def strip_env_assignments(segment):
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    return segment[idx:]


def is_push_segment(segment):
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "git":
        return False
    idx = 1
    while idx < len(segment):
        token = segment[idx]
        if token == "push":
            return True
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if any(token.startswith(prefix) for prefix in (
            "--git-dir=",
            "--work-tree=",
            "--namespace=",
            "--exec-path=",
            "--super-prefix=",
            "--config-env=",
        )):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return "push" in segment[idx + 1:]
    return False


sys.exit(0 if any(is_push_segment(segment) for segment in segments) else 1)
PY
}

git_push_has_plain_force_from_command() {
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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
        if any(token.startswith(prefix) for prefix in (
            "--git-dir=",
            "--work-tree=",
            "--namespace=",
            "--exec-path=",
            "--super-prefix=",
            "--config-env=",
        )):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None

def redir_start(args):
    for i, token in enumerate(args):
        if "<" in token or ">" in token or token == "&":
            if i > 0 and re.fullmatch(r"\d+", args[i - 1]):
                return i - 1
            return i
    return len(args)

def has_plain_force(args):
    args = args[:redir_start(args)]
    force_with_lease = False
    refspecs = []
    skip_next = False
    for token in args:
        if skip_next:
            skip_next = False
            continue
        if token == "--":
            continue
        if token == "--force-with-lease" or token.startswith("--force-with-lease="):
            force_with_lease = True
            continue
        if token == "--force" or token.startswith("--force="):
            return True
        if token in {"--repo"}:
            skip_next = True
            continue
        if token.startswith("--"):
            continue
        if token.startswith("-") and "f" in token[1:]:
            return True
        if token.startswith("-"):
            continue
        refspecs.append(token)
    # Leading-plus refspecs are force updates too. Permit them only when the
    # command also names the sanctioned lease flag explicitly.
    for refspec in refspecs[1:]:
        if refspec.startswith("+") and not force_with_lease:
            return True
    return False

for segment in segments:
    args = push_args_for_segment(segment)
    if args is not None and has_plain_force(args):
        sys.exit(0)

sys.exit(1)
PY
}

git_push_has_any_force_from_command() {
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None

def redir_start(args):
    for i, token in enumerate(args):
        if "<" in token or ">" in token or token == "&":
            if i > 0 and re.fullmatch(r"\d+", args[i - 1]):
                return i - 1
            return i
    return len(args)

def has_force(args):
    args = args[:redir_start(args)]
    refspecs = []
    skip_next = False
    for token in args:
        if skip_next:
            skip_next = False
            continue
        if token == "--":
            continue
        if token in {"--force", "--force-with-lease"}:
            return True
        if token.startswith("--force=") or token.startswith("--force-with-lease="):
            return True
        if token in {"--repo"}:
            skip_next = True
            continue
        if token.startswith("--"):
            continue
        if token.startswith("-") and "f" in token[1:]:
            return True
        if token.startswith("-"):
            continue
        refspecs.append(token)
    return any(refspec.startswith("+") for refspec in refspecs[1:])

for segment in segments:
    args = push_args_for_segment(segment)
    if args is not None and has_force(args):
        sys.exit(0)

sys.exit(1)
PY
}

agent_push_policy_path() {
  printf '%s\n' "${PG_AGENT_PUSH_POLICY:-$SCRIPT_DIR/../agent-push-policy.json}"
}

agent_push_policy_is_valid() {
  local policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 1
  jq -e '
    def valid_branch_class:
      type == "object"
      and (.enabled | type == "boolean")
      and (.prefixes | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
      and (.remotes | type == "array" and length > 0 and all(.[]; type == "string" and length > 0));
    type == "object"
    and (.version | type == "number")
    and (.scratch_branches | valid_branch_class)
    and (.scratch_branches.must_not_have_open_pr == true)
    and (.scratch_branches.must_not_be_pr_base == true)
    and (.yolo_branches | valid_branch_class)
  ' "$policy_path" >/dev/null 2>&1
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

yolo_branch_remotes() {
  local policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 0
  jq -r '
    (.yolo_branches // {})
    | select((.enabled // false) == true)
    | .remotes // []
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

is_yolo_remote_token() {
  local token="$1" remote
  [[ -n "$token" ]] || return 1
  while IFS= read -r remote; do
    [[ -z "$remote" ]] && continue
    [[ "$token" == "$remote" ]] && return 0
  done < <(yolo_branch_remotes)
  return 1
}

scratch_branch_prefixes() {
  local policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 0
  jq -r '
    (.scratch_branches // {})
    | select((.enabled // false) == true)
    | .prefixes // []
    | .[]
  ' "$policy_path" 2>/dev/null
}

scratch_branch_remotes() {
  local policy_path
  policy_path=$(agent_push_policy_path)
  [[ -f "$policy_path" ]] || return 0
  jq -r '
    (.scratch_branches // {})
    | select((.enabled // false) == true)
    | .remotes // []
    | .[]
  ' "$policy_path" 2>/dev/null
}

is_scratch_branch_token() {
  local token="$1" prefix
  [[ -n "$token" ]] || return 1
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    [[ "$token" == "$prefix"* ]] && return 0
  done < <(scratch_branch_prefixes)
  return 1
}

is_scratch_remote_token() {
  local token="$1" remote
  [[ -n "$token" ]] || return 1
  while IFS= read -r remote; do
    [[ -z "$remote" ]] && continue
    [[ "$token" == "$remote" ]] && return 0
  done < <(scratch_branch_remotes)
  return 1
}

scratch_branch_has_no_open_pr() {
  local branch="$1" root open_heads open_bases
  root=$(git_context rev-parse --show-toplevel 2>/dev/null) || return 1
  command -v gh >/dev/null 2>&1 || return 1
  open_heads=$(cd "$root" && gh pr list --state open --head "$branch" --limit 1 --json number 2>/dev/null) || return 1
  open_bases=$(cd "$root" && gh pr list --state open --base "$branch" --limit 1 --json number 2>/dev/null) || return 1
  jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<< "$open_heads" || return 1
  jq -e 'type == "array" and length == 0' >/dev/null 2>&1 <<< "$open_bases"
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
  python3 - "$GIT_COMMAND" <<'PY'
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
    "--config-env",
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
            "--config-env=",
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

has_git_reset_hard_command() {
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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
        if token == "reset":
            return token, segment[idx + 1:]
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return token, segment[idx + 1:]
    return None, []

for segment in segments:
    subcmd, args = git_subcommand(segment)
    if subcmd == "reset" and "--hard" in args:
        sys.exit(0)
sys.exit(1)
PY
}

has_git_clean_force_command() {
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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
        if token == "clean":
            return token, segment[idx + 1:]
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return token, segment[idx + 1:]
    return None, []

def clean_has_force(args):
    for token in args:
        if token == "--":
            break
        if token in {"--force", "-f"}:
            return True
        if token.startswith("--force="):
            return True
        if token.startswith("-") and not token.startswith("--") and "f" in token[1:]:
            return True
    return False

for segment in segments:
    subcmd, args = git_subcommand(segment)
    if subcmd == "clean" and clean_has_force(args):
        sys.exit(0)
sys.exit(1)
PY
}

# Emit each branch name targeted by a force-delete (`git branch -D ...`, or a
# `-d`/`--delete` combined with `--force`/`-f`, or a bundled short flag like
# -Df) in COMMAND, one name per line. Empty output means no such delete.
# Used only to decide whether a `git branch -D` is a pure yolo cleanup.
git_branch_force_delete_targets() {
  python3 - "$GIT_COMMAND" <<'PY'
import re, shlex, sys

command = sys.argv[1]
# Treat newlines as statement separators so a `git push` on its own line in a
# multi-line script is isolated. shlex(whitespace_split) otherwise consumes
# newlines as plain whitespace, merging statements into one segment and hiding
# the push (which then reads as a bare push). Newlines inside quotes stay part
# of their quoted token, so this only splits real statement boundaries.
command = command.replace("\n", " ; ")
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
  python3 - "$GIT_COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1]
# Treat newlines as statement separators so a `git push` on its own line in a
# multi-line script is isolated. shlex(whitespace_split) otherwise consumes
# newlines as plain whitespace, merging statements into one segment and hiding
# the push (which then reads as a bare push). Newlines inside quotes stay part
# of their quoted token, so this only splits real statement boundaries.
command = command.replace("\n", " ; ")
try:
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    sys.exit(0)

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
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
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
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

# Strip shell redirections (e.g. "2>&1", ">", "2>file", "<in", trailing "&")
# that shlex splits into tokens; they are not push refspecs. Truncate the args
# at the first redirection/background operator, dropping a leading file
# descriptor number (the "2" in "2 >& 1").
def _redir_start(toks):
    for i, t in enumerate(toks):
        if "<" in t or ">" in t or t == "&":
            if i > 0 and re.fullmatch(r"\d+", toks[i - 1]):
                return i - 1
            return i
    return len(toks)

args = args[:_redir_start(args)]
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
if any(char in refspec for char in "$`{}[]*?") or refspec.startswith("~"):
    print("__DYNAMIC__")
    sys.exit(0)
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

git_push_remote_from_command() {
  python3 - "$GIT_COMMAND" <<'PY'
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

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--bare", "--no-replace-objects", "--no-optional-locks", "--no-pager", "-p", "--paginate", "-P"}

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
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None

push_args = [args for args in (push_args_for_segment(segment) for segment in segments) if args is not None]
if len(push_args) != 1:
    sys.exit(0)

def redir_start(args):
    for i, token in enumerate(args):
        if "<" in token or ">" in token or token == "&":
            if i > 0 and re.fullmatch(r"\d+", args[i - 1]):
                return i - 1
            return i
    return len(args)

args = push_args[0][:redir_start(push_args[0])]
skip_next = False
for token in args:
    if skip_next:
        skip_next = False
        continue
    if token == "--":
        continue
    if token in {"--repo"}:
        skip_next = True
        continue
    if token.startswith("-"):
        continue
    print(token)
    sys.exit(0)
PY
}

git_push_delete_remote_and_target_from_command() {
  python3 - "$GIT_COMMAND" <<'PY'
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
    else:
        current.append(token)
if current:
    segments.append(current)

global_value_options = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"}
global_no_value_options = {"--literal-pathspecs", "--no-optional-locks", "--no-pager"}

def push_args_for_segment(segment):
    if not segment:
        return None
    idx = 0
    while idx < len(segment) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", segment[idx]):
        idx += 1
    if idx >= len(segment) or segment[idx] != "git":
        return None
    idx += 1
    while idx < len(segment):
        token = segment[idx]
        if token == "push":
            return segment[idx + 1:]
        if token in global_value_options and idx + 1 < len(segment):
            idx += 2
            continue
        if token.startswith(("--git-dir=", "--work-tree=", "--namespace=", "--exec-path=", "--super-prefix=", "--config-env=")):
            idx += 1
            continue
        if token in global_no_value_options:
            idx += 1
            continue
        return None
    return None

push_args = [args for args in (push_args_for_segment(segment) for segment in segments) if args is not None]
if len(push_args) != 1:
    sys.exit(0)

args = push_args[0]

def redir_start(toks):
    for i, t in enumerate(toks):
        if "<" in t or ">" in t or t == "&":
            if i > 0 and re.fullmatch(r"\d+", toks[i - 1]):
                return i - 1
            return i
    return len(toks)

args = args[:redir_start(args)]
remote = None
refspecs = []
skip_next = False
is_delete = False
for token in args:
    if skip_next:
        skip_next = False
        continue
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

target = ""
if is_delete:
    if len(refspecs) == 1:
        target = refspecs[0]
elif len(refspecs) == 1:
    refspec = refspecs[0]
    if refspec.startswith("+"):
        refspec = refspec[1:]
    if refspec.startswith(":"):
        target = refspec[1:]

if target.startswith("refs/heads/"):
    target = target[len("refs/heads/"):]
if target:
    print(f"{remote or ''}\t{target}")
PY
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

is_pure_ssh_command() {
  python3 - "$COMMAND" <<'PY'
import re
import shlex
import sys

command = sys.argv[1].replace("\n", " ; ")
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

if len(segments) != 1:
    sys.exit(1)

segment = strip_env_assignments(segments[0])
sys.exit(0 if segment and segment[0] == "ssh" else 1)
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
                print(f"dangerous remote nodetool command: nodetool {verb}")
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
        if token == "find" and any(part.startswith("/var/lib/cassandra") for part in tokens[idx + 1 :]):
            return "find under /var/lib/cassandra"
        if token == "tail":
            for part in tokens[idx + 1 :]:
                if part.isdigit() and int(part) > 5000:
                    return "large remote tail"
                if part.startswith("-") and part[1:].isdigit() and int(part[1:]) > 5000:
                    return "large remote tail"
        if token == "grep" and any(part.startswith("/var/log/cassandra/") for part in tokens[idx + 1 :]):
            return "grep over database logs"
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

ssh_lease_requirements() {
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

def split_ssh(segment):
    idx = 1
    config_path = None
    while idx < len(segment):
        token = segment[idx]
        if token == "--":
            idx += 1
            if idx < len(segment):
                target = resolve_config_target(config_path, normalize_host(segment[idx]))
                return target, segment[idx + 1:]
            return "", []
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
        target = resolve_config_target(config_path, normalize_host(token))
        return target, segment[idx + 1:]
    return "", []

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
        if token == "find" and any(part.startswith("/var/lib/cassandra") for part in tokens[idx + 1 :]):
            return "find under /var/lib/cassandra"
        if token == "tail":
            for part in tokens[idx + 1 :]:
                if part.isdigit() and int(part) > 5000:
                    return "large remote tail"
                if part.startswith("-") and part[1:].isdigit() and int(part[1:]) > 5000:
                    return "large remote tail"
        if token == "grep" and any(part.startswith("/var/log/cassandra/") for part in tokens[idx + 1 :]):
            return "grep over database logs"
    return ""

for segment in segments:
    segment = strip_env_assignments(segment)
    if not segment or segment[0] != "ssh":
        continue
    target, remote = split_ssh(segment)
    if not target:
        print("__NO_TARGET__\t\t\t")
        continue
    remote_tokens = flatten_remote(remote)
    reason = sensitive_reason(remote_tokens)
    if reason:
        remote_text = canonical(remote_tokens)
        digest = hashlib.sha256(remote_text.encode("utf-8")).hexdigest()
        print(f"{target}\t{digest}\t{reason}\t{remote_text}")
    else:
        print(f"{target}\t\t\t")
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
check_push_policy() {
  is_git_push_command || return
  agent_push_policy_is_valid ||
    deny "Blocked: git pushes require a valid agent push policy."
}

check_git_force() {
  git_push_has_plain_force_from_command &&
    deny "Blocked: git push force-updates remote history. Use --force-with-lease."
  if is_git_push_command && git_push_has_any_force_from_command && ! git_push_has_plain_force_from_command; then
    local _force_target _force_remote
    _force_target=$(git_push_target_branch_from_command)
    _force_remote=$(git_push_remote_from_command)
    if ! is_scratch_branch_token "$_force_target" &&
      { ! is_yolo_branch_token "$_force_target" || ! is_yolo_remote_token "$_force_remote"; }; then
      deny "Blocked: git push --force-with-lease requires an explicitly enabled private branch policy."
    fi
  fi
  has_git_reset_hard_command &&
    deny "Blocked: git reset --hard discards all uncommitted changes."
  echo "$GIT_COMMAND" | grep -qE -- 'git\s+checkout\s+--\s*\.' &&
    deny "Blocked: git checkout -- . discards unstaged changes."
  echo "$GIT_COMMAND" | grep -qE 'git\s+checkout\s+\.\s*$' &&
    deny "Blocked: git checkout . discards unstaged changes."
  echo "$GIT_COMMAND" | grep -qE 'git\s+restore\s+\.' &&
    deny "Blocked: git restore . discards changes broadly."
  has_git_clean_force_command &&
    deny "Blocked: git clean -f deletes untracked files."
  local _yolo_del_targets
  _yolo_del_targets=$(git_branch_force_delete_targets)
  if [[ -n "$_yolo_del_targets" ]]; then
    local _yolo_del_ok _yolo_del_t
    _yolo_del_ok=0
    _yolo_del_ok=1
    while IFS= read -r _yolo_del_t; do
      [[ -z "$_yolo_del_t" ]] && continue
      is_yolo_branch_token "$_yolo_del_t" || _yolo_del_ok=0
    done <<< "$_yolo_del_targets"
    [[ "$_yolo_del_ok" == "1" ]] ||
      deny "Blocked: git branch -D force-deletes a branch."
  fi
  echo "$GIT_COMMAND" | grep -qE 'git\s+stash\s+(drop|clear)(\s|$)' &&
    deny "Blocked: git stash drop/clear loses stashed work."
}

# --- 2. Push Guard ---
# Self-contained protected-branch guard for agent-initiated pushes. The
# authoritative main-branch protection is the git-level pre-push hook, which
# also catches external binaries (gnhf, no-mistakes); this agent-layer check is
# defense-in-depth.
#
# Allowed: configured no-mistakes delivery pushes and normal
# feature-branch / no-mistakes-remote / gnhf pushes that name a non-protected
# target. Scratch branch pushes require Remote Scratch Mode. Remote deletes are
# blocked unless a private policy explicitly enables an exception. Blocked:
# pushes (or deletes) to main/master/develop/trunk and bare or ambiguous pushes
# that do not name an explicit branch. Force-push protection lives separately in
# check_git_force.
check_push_guard() {
  is_git_push_command || return
  if printf '%s' "$GIT_COMMAND" | grep -Eiq 'core[.]hooksPath'; then
    deny "Blocked: git pushes must not override core.hooksPath."
  fi
  local target_branch
  target_branch=$(git_push_target_branch_from_command)
  case "$target_branch" in
    main|master|develop|trunk)
      deny "Blocked: pushing directly to ${target_branch} is not allowed. Deliver protected branches through no-mistakes."
      ;;
    ""|__MULTI__|__MULTI_PUSH__|__BROAD__)
      deny "Blocked: bare git push is not allowed. Name the target branch explicitly, e.g. git push origin <branch>."
      ;;
    __DYNAMIC__)
      deny "Blocked: git push refspecs must be literal and must not use shell expansion."
      ;;
    __DELETE__)
      local delete_info delete_remote delete_target
      delete_info=$(git_push_delete_remote_and_target_from_command)
      IFS=$'\t' read -r delete_remote delete_target <<< "$delete_info"
      if [[ "$delete_target" == "main" || "$delete_target" == "master" || "$delete_target" == "develop" || "$delete_target" == "trunk" ]]; then
        deny "Blocked: deleting a protected branch (main/master/develop/trunk) is not allowed."
      fi
      if ! is_yolo_remote_token "$delete_remote" || ! is_yolo_branch_token "$delete_target"; then
        deny "Blocked: deleting remote branches is only allowed for configured yolo branches on configured yolo remotes."
      fi
      ;;
  esac
  if is_scratch_branch_token "$target_branch"; then
    if [[ "${AGENT_WORK_MODE:-}" != "remote_scratch" && "${LLM_AGENT_WORK_MODE:-}" != "remote_scratch" ]]; then
      deny "Blocked: scratch branch pushes require Remote Scratch Mode (AGENT_WORK_MODE=remote_scratch or LLM_AGENT_WORK_MODE=remote_scratch)."
    fi
    local scratch_remote
    scratch_remote=$(git_push_remote_from_command)
    if ! is_scratch_remote_token "$scratch_remote"; then
      deny "Blocked: scratch branch pushes are only allowed to configured scratch remotes."
    fi
    if git_push_has_any_force_from_command; then
      deny "Blocked: scratch branch pushes must not force-update remote history."
    fi
    if ! scratch_branch_has_no_open_pr "$target_branch"; then
      deny "Blocked: could not confirm that the scratch branch is absent from open PR heads and bases."
    fi
  fi
}

# --- 2b. Branch Creation Tracking Guard ---
# Feature branches must not track integration branches or unrelated remote
# branches. The only allowed tracking relationship is a mirrored branch name:
# local feature/foo may track origin/feature/foo, but not origin/main or origin/bar.
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
  tracking_block=$(python3 - "$GIT_COMMAND" "$current_branch" <<'PY'
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
  git_config_block=$(python3 - "$GIT_COMMAND" <<'PY'
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
  echo "$GIT_COMMAND" | grep -qE -- '--no-verify' &&
    deny "Blocked: --no-verify bypasses safety hooks."
  if has_git_commit_amend_command && current_branch_is_protected; then
    deny "Blocked: git commit --amend is not allowed on protected branches."
  fi
  echo "$GIT_COMMAND" | grep -qE 'commit\.gpgsign=false' &&
    deny "Blocked: disabling GPG signing is not allowed."
  echo "$GIT_COMMAND" | grep -qE '(CHECKSTYLE_SKIP|VERIFY_SKIP|SPOTLESS_SKIP)=' &&
    deny "Blocked: skipping pre-commit checks is not allowed."
}

# --- 4. Broad Git Staging ---
check_broad_staging() {
  echo "$GIT_COMMAND" | grep -qE -- 'git\s+add\s+(-A|--all|\.)(\s|$)' &&
    deny "Blocked: git add -A / git add . is too broad. Name files explicitly."
  echo "$GIT_COMMAND" | grep -qE 'git\s+add\s+.*\.(env|pem|key)(\s|$)' &&
    deny "Blocked: staging secrets/keys is not allowed."
  echo "$GIT_COMMAND" | grep -qE 'git\s+add\s+.*(credential|secret)' &&
    deny "Blocked: staging credential/secret files is not allowed."
}

# --- 5. Git Rebase ---
check_git_rebase() {
  # Allow safe operations
  echo "$GIT_COMMAND" | grep -qE -- 'git\s+rebase\s+--(abort|continue|skip)' && return

  # Block interactive rebase
  echo "$GIT_COMMAND" | grep -qE -- 'git\s+rebase\s+.*(-i|--interactive)' &&
    deny "Blocked: git rebase -i (interactive) is not allowed."

  # Allow --onto (re-parenting for stacked PRs)
  echo "$GIT_COMMAND" | grep -qE -- 'git\s+rebase\s+--onto\s' && return

  # Allow rebase with explicit branch target
  echo "$GIT_COMMAND" | grep -qE 'git\s+rebase\s+[a-zA-Z0-9_./-]+\s*$' && return

  # Block bare rebase (no target)
  echo "$GIT_COMMAND" | grep -qE 'git\s+rebase\s*$' &&
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
  # Check SSH lease file for approved hosts (12-hour leases via ssh-gate).
  local ssh_requirements ssh_target hash reason remote_command
  ssh_requirements=$(ssh_lease_requirements 2>/dev/null || true)
  if [ -n "$ssh_requirements" ]; then
    while IFS=$'\t' read -r ssh_target hash reason remote_command; do
      [[ -n "$ssh_target" ]] || continue
      if [[ "$ssh_target" == "__NO_TARGET__" ]]; then
        deny "Blocked: ssh requires a lease. Ask the user to run: ssh-gate <host>"
      fi
      if ! has_valid_ssh_lease "$ssh_target"; then
        deny "Blocked: ssh to '$ssh_target' requires a lease. Ask the user to run: ssh-gate $ssh_target"
      fi
      if [ -n "$hash" ]; then
        if ! has_valid_ssh_command_lease "$ssh_target" "$hash"; then
          deny "Blocked: sensitive SSH remote command ($reason) requires an exact command lease for '$ssh_target'. Ask the user to run: ssh-command-gate $ssh_target -- $remote_command"
        fi
      fi
    done <<< "$ssh_requirements"
    return
  fi
  if has_ssh_invocation; then
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

# --- 10ba. fun-bash-automations PR Safety ---
check_fba_pr_safety() {
  has_fba_pr_open_command || return
  deny "Blocked: fun-bash-automations uses main as its direct-push delivery branch. Do not create, reopen, or mark ready PRs for this repository."
}

# --- 10bb. Scratch PR Safety ---
check_scratch_pr_safety() {
  has_scratch_pr_open_command || return
  deny "Blocked: scratch branches are not PR-eligible. Promote the commits to a delivery branch and use the no-mistakes gate."
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

ssh_local_execution_violation() {
  python3 - "$COMMAND" <<'PY'
import os
import re
import shlex
import sys

try:
    lexer = shlex.shlex(sys.argv[1].replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    tokens = list(lexer)
except ValueError:
    print("unable to parse ssh options")
    sys.exit(0)

segments = []
current = []
for token in tokens:
    if token in {"&&", "||", ";", "|"}:
        if current:
            segments.append(current)
            current = []
    else:
        current.append(token)
if current:
    segments.append(current)

assignment = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$")
value_options = {
    "-B", "-b", "-c", "-D", "-E", "-e", "-I", "-i", "-J", "-L",
    "-l", "-m", "-O", "-p", "-Q", "-R", "-S", "-W", "-w",
}

def option_pair(text):
    if "=" in text:
        return text.split("=", 1)
    parts = text.split(None, 1)
    return (parts[0], parts[1] if len(parts) == 2 else "")

def inspect_options(options, source):
    permit = False
    local_command = None
    for text in options:
        key, value = option_pair(text)
        key = key.lower()
        value = value.strip()
        if key == "proxycommand" and value.lower() != "none":
            return f"ProxyCommand in {source}"
        if key == "permitlocalcommand" and value.lower() in {"yes", "true"}:
            permit = True
        if key == "localcommand" and value.lower() != "none":
            local_command = value
        if key == "match" and value.lower().startswith("exec"):
            return f"Match exec in {source}"
        if key == "include":
            return f"Include in {source} cannot be validated safely"
    if permit and local_command:
        return f"PermitLocalCommand with LocalCommand in {source}"
    return None

for segment in segments:
    while segment and assignment.match(segment[0]):
        segment.pop(0)
    if not segment or os.path.basename(segment[0]) != "ssh":
        continue
    options = []
    config_paths = []
    index = 1
    while index < len(segment):
        token = segment[index]
        if token == "-o" and index + 1 < len(segment):
            options.append(segment[index + 1])
            index += 2
            continue
        if token.startswith("-o") and len(token) > 2:
            options.append(token[2:])
            index += 1
            continue
        if token == "-F" and index + 1 < len(segment):
            config_paths.append(segment[index + 1])
            index += 2
            continue
        if token.startswith("-F") and len(token) > 2:
            config_paths.append(token[2:])
            index += 1
            continue
        if token in value_options and index + 1 < len(segment):
            index += 2
            continue
        if token == "--":
            break
        if token.startswith("-"):
            index += 1
            continue
        break

    violation = inspect_options(options, "ssh command line")
    if violation:
        print(violation)
        sys.exit(0)
    for path in config_paths:
        config_options = []
        try:
            with open(os.path.expanduser(path), "r", encoding="utf-8") as config:
                for raw in config:
                    line = raw.split("#", 1)[0].strip()
                    if not line:
                        continue
                    parts = line.split(None, 1)
                    config_options.append(parts[0] + (" " + parts[1] if len(parts) == 2 else ""))
        except OSError:
            print(f"unable to inspect ssh config {path}")
            sys.exit(0)
        violation = inspect_options(config_options, path)
        if violation:
            print(violation)
            sys.exit(0)
sys.exit(1)
PY
}

is_trusted_ssh_target() {
  local target="$1" suffix
  [[ -n "$target" ]] || return 1
  while IFS= read -r suffix || [[ -n "$suffix" ]]; do
    [[ -n "$suffix" ]] || continue
    [[ "$target" == *"$suffix" ]] && return 0
  done < <(printf '%s' "${BASH_SAFETY_GUARD_TRUSTED_SSH_SUFFIXES:-}" | tr ':' '\n')
  return 1
}

_ssh_local_execution=$(ssh_local_execution_violation)
[[ -z "$_ssh_local_execution" ]] ||
  deny "Blocked: ssh configuration may execute a local command: $_ssh_local_execution"

_trusted_ssh_target=$(extract_ssh_target)
if is_pure_ssh_command && is_trusted_ssh_target "$_trusted_ssh_target"; then
  if ! has_valid_ssh_lease "$_trusted_ssh_target"; then
    deny "Blocked: ssh to '$_trusted_ssh_target' requires a lease. Ask the user to run: ssh-gate $_trusted_ssh_target"
  fi
  run_guard_extensions
  exit 0
fi

# --- Run all checks ---
check_push_policy
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
check_fba_pr_safety
check_scratch_pr_safety
check_gh_gist_filename_safety
check_docker_destructive
run_guard_extensions

exit 0
