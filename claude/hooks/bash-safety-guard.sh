#!/bin/bash
# bash-safety-guard.sh
# PreToolUse hook on Bash: blocks dangerous commands from autonomous agents.
# Each guard category is a function. To disable a category, comment out its call.
# Compatible with macOS BSD grep (no \b or \d).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

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
# Blocks ALL git push by default. Pushes require a one-time token
# created by the user running `push-gate` in their terminal.
# The token is tied to a specific commit hash — if the agent makes
# more commits after approval, the token becomes stale and push is blocked.
# Token is consumed (deleted) after one successful push.
check_push_guard() {
  echo "$COMMAND" | grep -qE 'git\s+push' || return

  # Absolute blocks — no bypass
  echo "$COMMAND" | grep -qE 'git\s+push\s+upstream(\s|$)' &&
    deny "Blocked: pushing to upstream is never allowed."
  echo "$COMMAND" | grep -qE 'git\s+push\s+.*\s(main|master)(\s|$)' &&
    deny "Blocked: pushing directly to main/master is not allowed."

  # Check for push token (created by user running push-gate or push-gate-batch).
  # Token file contains one commit hash per line. Matching line is consumed;
  # file is deleted when empty. Supports both single and batch approvals.
  local TOKEN_FILE="/tmp/.claude-push-token"
  if [ -f "$TOKEN_FILE" ]; then
    local CURRENT_HEAD
    CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null)
    if [ -n "$CURRENT_HEAD" ] && grep -qx "$CURRENT_HEAD" "$TOKEN_FILE" 2>/dev/null; then
      # Consume this entry (remove matching line)
      local REMAINING
      REMAINING=$(grep -vx "$CURRENT_HEAD" "$TOKEN_FILE")
      if [ -z "$REMAINING" ]; then
        rm -f "$TOKEN_FILE"  # last entry consumed
      else
        echo "$REMAINING" > "$TOKEN_FILE"
      fi
      return
    fi
    # Token exists but HEAD doesn't match any entry
    local FIRST_APPROVED
    FIRST_APPROVED=$(head -1 "$TOKEN_FILE")
    deny "Blocked: push token has no entry for HEAD ${CURRENT_HEAD:0:7} (first approved: ${FIRST_APPROVED:0:7}). Run push-gate again to approve current HEAD."
  fi

  deny "Blocked: git push requires approval. Ask the user to run push-gate in their terminal, then retry."
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
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)ssh\s' &&
    deny "Blocked: ssh is not allowed."
  echo "$COMMAND" | grep -qE '(^|[;&|]\s*)(scp|rsync)\s.*:' &&
    deny "Blocked: scp/rsync to remote hosts is not allowed."
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
