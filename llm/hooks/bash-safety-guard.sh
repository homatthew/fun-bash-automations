#!/bin/bash
# bash-safety-guard.sh
# Claude-native implementation of the shared policy in:
#   ~/repos/fun-bash-automations/llm/command-guard-policy.md
# PreToolUse hook on Bash: blocks dangerous commands from autonomous agents.
# Each guard category is a function. To disable a category, comment out its call.
# Compatible with macOS BSD grep (no \b or \d).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Do NOT source push-gate.sh here — a syntax error in that file would take
# down the Bash tool entirely. Call it as a subprocess below (guard-check)
# so its failures are isolated and reported through deny() cleanly.

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
has_wrong_netflix_gh_host() {
  echo "$COMMAND" | grep -qE "(^|[;&|[:space:]])(export[[:space:]]+)?GH_HOST=['\"]?github\\.netflix\\.net['\"]?([[:space:];&|]|$)"
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

is_gh_api_gist_create() {
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*gh\s+api([[:space:]]|$)' || return 1
  echo "$COMMAND" | grep -qE "(^|[[:space:]\"'])/?gists([[:space:]\"']|$)" || return 1

  echo "$COMMAND" | grep -qE -- '--method[[:space:]]+POST|--method=POST|-X[[:space:]]+POST|-XPOST' && return 0
  echo "$COMMAND" | grep -qE -- '--input([=[:space:]]|$)' && return 0

  return 1
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
  echo "$COMMAND" | grep -qE 'git\s+branch\s+-D\s' &&
    deny "Blocked: git branch -D force-deletes a branch."
  echo "$COMMAND" | grep -qE 'git\s+stash\s+(drop|clear)(\s|$)' &&
    deny "Blocked: git stash drop/clear loses stashed work."
}

# --- 2. Push Guard ---
# Blocks ALL git push by default. Pushes require a durable branch lease
# plus a fresh pending self-assertion created by `pg push`. Invokes
# push-gate.sh as a subprocess so a bug there can't take down this hook.
check_push_guard() {
  local result allowed reason rc
  result=$(bash "$SCRIPT_DIR/push-gate.sh" guard-check --command "$COMMAND" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$result" ]; then
    # push-gate itself failed — allow the command through (fail-open) so
    # a broken push-gate doesn't block all shell usage. The user still
    # gets a warning on stderr for visibility.
    echo "bash-safety-guard: push-gate subprocess failed (rc=$rc); allowing command through" >&2
    return
  fi
  allowed=$(echo "$result" | jq -r '.allowed' 2>/dev/null)
  if [ "$allowed" = "true" ]; then
    return
  fi
  reason=$(echo "$result" | jq -r '.reason' 2>/dev/null)
  deny "${reason:-push blocked by push-gate}"
}

# --- 2b. Branch Creation Tracking Guard ---
# Prevent creating branches that auto-track origin/main or origin/master.
check_branch_tracking() {
  if echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)'; then
    echo "$COMMAND" | grep -qE -- '--no-track' && return
    echo "$COMMAND" | grep -qE '(origin|upstream)/(main|master)(\s|$)' &&
      deny "Blocked: branch would auto-track main. Add --no-track: git checkout -b <branch> origin/main --no-track"
  fi

  echo "$COMMAND" | grep -qE 'git\s+branch\s+.*(--set-upstream-to(=|[[:space:]]+)|-u[[:space:]]+)(origin|upstream)/(main|master)([[:space:]]|$)' &&
    deny "Blocked: feature branches must not track origin/main or upstream/main. Use --set-upstream-to=origin/<branch> instead."

  echo "$COMMAND" | grep -qE 'git\s+branch\s+.*--track[[:space:]]+[^[:space:]]+[[:space:]]+(origin|upstream)/(main|master)([[:space:]]|$)' &&
    deny "Blocked: branch would track origin/main or upstream/main. Add --no-track and push only through pg/stack."
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
  echo "$COMMAND" | grep -qE -- 'git\s+commit\s+.*--amend' &&
    deny "Blocked: git commit --amend modifies previous commit."
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
  # Check SSH lease file for approved hosts (12-hour leases via ssh-gate)
  if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)ssh\s'; then
    local SSH_TARGET
    SSH_TARGET=$(echo "$COMMAND" | grep -oE 'ssh[[:space:]]+("[^"]*"|[^[:space:];&|]+)' | head -1 | sed 's/^ssh[[:space:]]*//' | tr -d '"')
    local LEASE_FILE="/tmp/.claude-ssh-leases"
    if [ -f "$LEASE_FILE" ] && [ -n "$SSH_TARGET" ]; then
      local NOW
      NOW=$(date +%s)
      while IFS=' ' read -r host expiry; do
        if [ "$host" = "$SSH_TARGET" ] && [ "$expiry" -gt "$NOW" ] 2>/dev/null; then
          return  # Valid lease found
        fi
      done < "$LEASE_FILE"
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
    local LEASE_FILE="/tmp/.claude-ssh-leases"
    if [ -f "$LEASE_FILE" ] && [ -n "$REMOTE_HOST" ]; then
      local NOW
      NOW=$(date +%s)
      while IFS=' ' read -r host expiry; do
        if [ "$host" = "$REMOTE_HOST" ] && [ "$expiry" -gt "$NOW" ] 2>/dev/null; then
          return  # Valid lease found
        fi
      done < "$LEASE_FILE"
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
  has_wrong_netflix_gh_host || return
  deny "Blocked: GH_HOST=github.netflix.net is wrong for Netflix GHE. Use GH_HOST=git.netflix.net."
}

# --- 10c. GitHub Gist Host Safety ---
check_gh_gist_host_safety() {
  is_gh_api_gist_create || return
  has_netflix_gist_hostname && return

  deny "Blocked: gh api gist creation must target Netflix GHE explicitly. Use GH_HOST=git.netflix.net or --hostname git.netflix.net."
}

# --- 10d. GitHub Gist Filename Safety ---
check_gh_gist_filename_safety() {
  check_gist_filename_sequence
}

# --- 11. Process Killing ---
check_process_kill() {
  # Allow port-targeted kills: lsof -ti :PORT | xargs kill or kill $(lsof -ti :PORT)
  echo "$COMMAND" | grep -qE 'lsof\s.*-ti\s*:[0-9]+.*\|\s*(xargs\s+)?kill' && return
  echo "$COMMAND" | grep -qE 'kill\s+\$\(lsof\s.*-ti\s*:' && return

  echo "$COMMAND" | grep -qE 'kill\s+-9' &&
    deny "Blocked: kill -9 is not allowed."
  echo "$COMMAND" | grep -qE -- 'kill\s+-(KILL|SIGKILL)' &&
    deny "Blocked: kill -KILL is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)killall\s' &&
    deny "Blocked: killall is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)pkill\s' &&
    deny "Blocked: pkill is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)kill\s+[0-9]' &&
    deny "Blocked: kill PID is not allowed. Use lsof -ti :PORT | xargs kill for port-targeted kills."
}

# --- 12. Docker Destructive ---
check_docker_destructive() {
  echo "$COMMAND" | grep -qE 'docker\s+push' &&
    deny "Blocked: docker push is not allowed."
  echo "$COMMAND" | grep -qE 'docker\s+system\s+prune' &&
    deny "Blocked: docker system prune is not allowed."
  echo "$COMMAND" | grep -qE 'docker\s+rm\s+.*-f' &&
    deny "Blocked: docker rm -f is not allowed."
}

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
check_gh_gist_host_safety
check_gh_gist_filename_safety
check_process_kill
check_docker_destructive

exit 0
