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
# shellcheck source=/dev/null
. "$SCRIPT_DIR/push-gate.sh"

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
# plus a fresh pending self-assertion created by `pg push`.
check_push_guard() {
  local result allowed reason
  result=$(pg_validate_push_guard "$COMMAND")
  allowed=$(echo "$result" | jq -r '.allowed')
  if [ "$allowed" = "true" ]; then
    return
  fi
  reason=$(echo "$result" | jq -r '.reason')
  deny "$reason"
}

# --- 2b. Branch Creation Tracking Guard ---
# Prevent creating branches that auto-track origin/main or origin/master.
check_branch_tracking() {
  echo "$COMMAND" | grep -qE 'git\s+(checkout\s+-b|switch\s+-c)' || return
  echo "$COMMAND" | grep -qE -- '--no-track' && return
  echo "$COMMAND" | grep -qE '(origin|upstream)/(main|master)(\s|$)' &&
    deny "Blocked: branch would auto-track main. Add --no-track: git checkout -b <branch> origin/main --no-track"
}

# --- 3. Git Config & Hook Bypass ---
check_git_config() {
  echo "$COMMAND" | grep -qE 'git\s+config(\s|$)' &&
    deny "Blocked: git config changes are not allowed."
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
check_process_kill
check_docker_destructive

exit 0
