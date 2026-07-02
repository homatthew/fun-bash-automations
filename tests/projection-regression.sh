#!/usr/bin/env bash
# Verify bin/fba-deploy projects everything that claude/settings.json and
# codex/hooks.json reference, and that the Linux notify.sh short-circuit
# never invokes macOS binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d -t fba-projection-XXXXXX)"
TMP_HOME="$TMP_ROOT/home"
mkdir -p "$TMP_HOME"
TMP_LOG="$TMP_ROOT/deploy.log"

PASS=0
FAIL=0
FAILURES=()

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '  FAIL  %s\n' "$1"
}

assert_executable() {
  local path="$1" label="${2:-$1}"
  if [[ -x "$path" || -L "$path" ]]; then
    pass "$label"
  else
    fail "$label (missing: $path)"
  fi
}

assert_file() {
  local path="$1" label="${2:-$1}"
  if [[ -e "$path" ]]; then
    pass "$label"
  else
    fail "$label (missing: $path)"
  fi
}

assert_not_contains_file() {
  local path="$1" needle="$2" label="$3"
  if grep -Fq "$needle" "$path"; then
    fail "$label (found: $needle in $path)"
  else
    pass "$label"
  fi
}

run_deploy() {
  HOME="$TMP_HOME" \
    FBA_DEPLOY_LOG="$TMP_LOG" \
    FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
    USER_NETFLIX_EMAIL="ci-bot@netflix.com" \
    "$ROOT/bin/fba-deploy" "$@"
}

# --- Phase 1: full projection ---
echo "== Phase 1: fba-deploy (full) =="
mkdir -p "$TMP_HOME/.claude/skills/commit-push-pr" "$TMP_HOME/.claude/skills/worktree-dev" "$TMP_HOME/.codex/skills"
cat > "$TMP_HOME/.claude/skills/commit-push-pr/SKILL.md" <<'EOF'
---
name: commit-push-pr
description: Commit, push, and create a PR in one workflow
---
EOF
cat > "$TMP_HOME/.claude/skills/worktree-dev/SKILL.md" <<'EOF'
---
name: worktree-dev
description: Local custom replacement
---
EOF
ln -s "$ROOT/claude/skills/create-nflx-pr" "$TMP_HOME/.codex/skills/create-nflx-pr"
mkdir -p "$TMP_HOME/.codex"
cat > "$TMP_HOME/.codex/config.toml" <<'EOF'
[hooks.state]

[hooks.state."sentinel-hook"]
trusted_hash = "sha256:sentinel"

[tui.model_availability_nux]
"gpt-5.5" = 2

[mcp_servers.local-only]
command = "local-mcp"
args = ["--flag"]

[mcp_servers.local-only.env]
LOCAL_ONLY = "1"
EOF
run_deploy

# Hooks referenced by claude/settings.json must exist
echo "-- claude/settings.json hook coverage --"
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  resolved="${cmd/#~/$TMP_HOME}"
  assert_executable "$resolved" "claude hook: $cmd"
done < <(jq -r '
  [.hooks // {} | to_entries[]
    | .value[]?
    | .hooks[]?
    | .command // empty]
  | unique[]
' "$ROOT/claude/settings.json")

# Hooks referenced by codex/hooks.json must exist
echo "-- codex/hooks.json hook coverage --"
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  resolved="${cmd/#~/$TMP_HOME}"
  assert_executable "$resolved" "codex hook: $cmd"
done < <(jq -r '
  [.hooks // {} | to_entries[]
    | .value[]?
    | .hooks[]?
    | .command // empty]
  | map(select(. != "" and (test("^echo ") | not)))
  | unique[]
' "$ROOT/codex/hooks.json")
# Canary: the hooks the dotfiles installer used to miss
echo "-- hook drift canaries --"
assert_executable "$TMP_HOME/.claude/hooks/beads-prime.sh" "claude beads-prime.sh present"
assert_executable "$TMP_HOME/.claude/hooks/bash-safety-guard.sh" "claude bash-safety-guard.sh present"
assert_executable "$TMP_HOME/.codex/hooks/permission-allow.sh" "codex permission-allow.sh present"

if jq -e '
  [.hooks // {} | to_entries[]
    | .value[]?
    | .hooks[]?
    | .command // empty]
  | all(. != "~/.claude/hooks/notify.sh")
' "$ROOT/claude/settings.json" >/dev/null; then
  pass "claude custom notify hook disabled"
else
  fail "claude custom notify hook disabled"
fi

# AGENTS.md and skills projection
echo "-- AGENTS + skills projection --"
assert_file "$TMP_HOME/.claude/AGENTS.md" "~/.claude/AGENTS.md exists"
[[ -L "$TMP_HOME/.claude/AGENTS.md" ]] && pass "~/.claude/AGENTS.md is symlink" \
  || fail "~/.claude/AGENTS.md is symlink"
assert_file "$TMP_HOME/.codex/AGENTS.md" "~/.codex/AGENTS.md exists"
for harness in claude codex; do
  policy="$TMP_HOME/.$harness/agent-push-policy.json"
  schema="$TMP_HOME/.$harness/agent-push-policy.schema.json"
  assert_file "$policy" "~/.$harness/agent-push-policy.json exists"
  assert_file "$schema" "~/.$harness/agent-push-policy.schema.json exists"
  if jq . "$schema" >/dev/null; then
    pass "$harness agent push policy schema is valid JSON"
  else
    fail "$harness agent push policy schema is valid JSON"
  fi
  if jq -e '
    .scratch_branches.enabled == true
    and .scratch_branches.default_for_agents == false
    and .scratch_branches.requires_user_opt_in == true
    and (.scratch_branches.prefixes | index("wip/agent/") != null)
    and (.scratch_branches.prefixes | index("scratch/agent/") != null)
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy projects opt-in scratch branch defaults"
  else
    fail "$harness agent push policy projects opt-in scratch branch defaults"
  fi
  if jq -e '
    .scratch_branches.commit_push_cadence.mode == "regular_milestones"
    and (.scratch_branches.commit_push_cadence.events | index("after_coherent_checkpoint") != null)
    and (.scratch_branches.commit_push_cadence.events | index("after_verification_pass") != null)
    and (.scratch_branches.commit_push_cadence.events | index("before_long_running_or_interruptible_work") != null)
    and (.scratch_branches.commit_push_cadence.events | index("before_handoff_or_context_compaction") != null)
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy projects scratch cadence"
  else
    fail "$harness agent push policy projects scratch cadence"
  fi
  if jq -e '
    (.direct_push_exceptions // [])
    | (any(.repo == "fun-bash-automations" and .delivery_branch == "mh-netflix"))
      and (any(.repo == "dotfiles" and .delivery_branch == "main"))
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy projects direct-push exceptions"
  else
    fail "$harness agent push policy projects direct-push exceptions"
  fi
  if jq -e '
    .yolo_branches.enabled == true
    and .yolo_branches.requires_user_opt_in == false
    and .yolo_branches.pr_eligible == true
    and .yolo_branches.allow_delete == true
    and (.yolo_branches.prefixes | index("mho-yolo/") != null)
    and (.yolo_branches.protected_base_refs | index("main") != null)
    and (.yolo_branches.protected_base_refs | index("master") != null)
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy projects yolo branch class"
  else
    fail "$harness agent push policy projects yolo branch class"
  fi
done

missing_skills=()
for skill_dir in "$ROOT"/llm/skills/*/; do
  name="$(basename "$skill_dir")"
  [[ -e "$TMP_HOME/.claude/skills/$name" ]] || missing_skills+=("claude:$name")
  [[ -e "$TMP_HOME/.codex/skills/$name" ]] || missing_skills+=("codex:$name")
done
if [[ ${#missing_skills[@]} -eq 0 ]]; then
  pass "all llm/skills/* projected to both runtimes"
else
  fail "skills missing: ${missing_skills[*]}"
fi
if [[ ! -e "$TMP_HOME/.claude/skills/commit-push-pr" && ! -L "$TMP_HOME/.claude/skills/commit-push-pr" ]]; then
  pass "retired repo-managed skill directory pruned"
else
  fail "retired repo-managed skill directory pruned"
fi
if [[ ! -e "$TMP_HOME/.codex/skills/create-nflx-pr" && ! -L "$TMP_HOME/.codex/skills/create-nflx-pr" ]]; then
  pass "retired repo-managed skill symlink pruned"
else
  fail "retired repo-managed skill symlink pruned"
fi
if [[ -f "$TMP_HOME/.claude/skills/worktree-dev/SKILL.md" ]] \
  && grep -Fq "Local custom replacement" "$TMP_HOME/.claude/skills/worktree-dev/SKILL.md"; then
  pass "unmanaged local retired-name skill preserved"
else
  fail "unmanaged local retired-name skill preserved"
fi

echo "-- CLI wrappers --"
assert_executable "$ROOT/bin/slack-private-thread" "bin/slack-private-thread executable"

# Email substitution
echo "-- settings.json templating --"
assert_not_contains_file "$TMP_HOME/.claude/settings.json" "__USER_NETFLIX_EMAIL__" \
  "no __USER_NETFLIX_EMAIL__ placeholder left"
if grep -Fq "user.netflix_email=ci-bot@netflix.com" "$TMP_HOME/.claude/settings.json"; then
  pass "email substitution applied"
else
  fail "email substitution applied"
fi

echo "-- codex feature flags --"
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "codex_hooks" \
  "deprecated codex_hooks flag absent"
if grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP_HOME/.codex/config.toml"; then
  pass "codex hooks feature enabled"
else
  fail "codex hooks feature enabled"
fi
if grep -Fq 'notifications = []' "$TMP_HOME/.codex/config.toml"; then
  pass "codex TUI notifications disabled"
else
  fail "codex TUI notifications disabled"
fi
if jq -e '
  [.hooks // {} | to_entries[]
    | .value[]?
    | .hooks[]?
    | .command // empty]
  | all(. != "~/.codex/hooks/notify.sh")
' "$ROOT/codex/hooks.json" >/dev/null; then
  pass "codex custom notify hook disabled"
else
  fail "codex custom notify hook disabled"
fi
if grep -Fq '[hooks.state."sentinel-hook"]' "$TMP_HOME/.codex/config.toml" \
  && grep -Fq 'trusted_hash = "sha256:sentinel"' "$TMP_HOME/.codex/config.toml"; then
  pass "codex hook trust state preserved"
else
  fail "codex hook trust state preserved"
fi
if grep -Fq "[tui.model_availability_nux]" "$TMP_HOME/.codex/config.toml"; then
  pass "codex model availability state preserved"
else
  fail "codex model availability state preserved"
fi
if grep -Fq 'terminal_title = ["spinner", "project", "git-branch"]' "$TMP_HOME/.codex/config.toml" \
  && grep -Fq '"current-dir"' "$TMP_HOME/.codex/config.toml" \
  && ! grep -Fq '"project-root"' "$TMP_HOME/.codex/config.toml"; then
  pass "codex TUI config avoids deprecated title/status items"
else
  fail "codex TUI config avoids deprecated title/status items"
fi
if command -v python3 >/dev/null 2>&1 && python3 - "$TMP_HOME/.codex/config.toml" <<'PY'
import sys

try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)

with open(sys.argv[1], "rb") as f:
    tomllib.load(f)
PY
then
  pass "codex config TOML parses"
else
  fail "codex config TOML parses"
fi
echo "-- codex MCP allowlist --"
if grep -Fq "[mcp_servers.chrome-devtools]" "$TMP_HOME/.codex/config.toml" \
  && grep -Fq 'args = ["chrome-devtools-mcp@latest"]' "$TMP_HOME/.codex/config.toml"; then
  pass "codex Chrome DevTools MCP projected"
else
  fail "codex Chrome DevTools MCP projected"
fi
if grep -Fq "[mcp_servers.local-only]" "$TMP_HOME/.codex/config.toml" \
  && grep -Fq 'command = "local-mcp"' "$TMP_HOME/.codex/config.toml" \
  && grep -Fq "[mcp_servers.local-only.env]" "$TMP_HOME/.codex/config.toml"; then
  pass "unmanaged local Codex MCP preserved"
else
  fail "unmanaged local Codex MCP preserved"
fi
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "ngpmcpgateway.prod.local.dev.netflix.net" \
  "internal Codex MCP gateways stay out of FBA projection"
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "cde-ods-skills.git" \
  "internal Codex plugin marketplaces stay out of FBA projection"

# --- Phase 2: Linux notify.sh smoke ---
echo ""
echo "== Phase 2: Linux notify.sh short-circuit =="
LINUX_TMP="$TMP_ROOT/linux"
mkdir -p "$LINUX_TMP/bin" "$LINUX_TMP/.claude/hooks"
cp "$ROOT/llm/hooks/notify.sh" "$LINUX_TMP/.claude/hooks/notify.sh"
chmod +x "$LINUX_TMP/.claude/hooks/notify.sh"

# Stub notify-slack.sh — emits a sentinel so we can confirm it was exec'd
cat > "$LINUX_TMP/.claude/hooks/notify-slack.sh" <<'STUB'
#!/usr/bin/env bash
read -r _input || true
printf 'SLACK_FIRED runtime=%s\n' "${RUNTIME:-unset}"
exit 0
STUB
chmod +x "$LINUX_TMP/.claude/hooks/notify-slack.sh"

# Fake uname that returns Linux so the Darwin guard fails
cat > "$LINUX_TMP/bin/uname" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-s" ]]; then
  echo Linux
  exit 0
fi
exec /usr/bin/uname "$@"
STUB
chmod +x "$LINUX_TMP/bin/uname"

# Fail loudly if any macOS-only binary gets called
for bad in terminal-notifier alerter osascript open; do
  cat > "$LINUX_TMP/bin/$bad" <<STUB
#!/usr/bin/env bash
echo "FATAL: $bad invoked on Linux" >&2
exit 99
STUB
  chmod +x "$LINUX_TMP/bin/$bad"
done

linux_output=$(
  PATH="$LINUX_TMP/bin:/usr/bin:/bin" \
    TERM_PROGRAM=vscode \
    bash "$LINUX_TMP/.claude/hooks/notify.sh" \
    <<<'{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp","transcript_path":"/dev/null"}' \
    2>&1
) && rc=0 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "Linux notify.sh exits 0"
else
  fail "Linux notify.sh exits 0 (rc=$rc, output=$linux_output)"
fi

if [[ "$linux_output" == *"SLACK_FIRED"* ]]; then
  pass "Linux notify.sh execs notify-slack.sh"
else
  fail "Linux notify.sh execs notify-slack.sh (output: $linux_output)"
fi

if [[ "$linux_output" == *"FATAL:"* ]]; then
  fail "no macOS binaries invoked on Linux (got: $linux_output)"
else
  pass "no macOS binaries invoked on Linux"
fi

blocked_output=$(
  PATH="$LINUX_TMP/bin:/usr/bin:/bin" \
    TERM_PROGRAM=not-vscode \
    bash "$LINUX_TMP/.claude/hooks/notify.sh" \
    <<<'{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp","transcript_path":"/dev/null"}' \
    2>&1
) && rc=0 || rc=$?

if [[ "$rc" -eq 0 && "$blocked_output" != *"SLACK_FIRED"* && "$blocked_output" != *"FATAL:"* ]]; then
  pass "Linux notify.sh suppresses outside allowlisted terminals"
else
  fail "Linux notify.sh suppresses outside allowlisted terminals (rc=$rc, output=$blocked_output)"
fi

# Also: silent no-op when notify-slack.sh is missing
rm -f "$LINUX_TMP/.claude/hooks/notify-slack.sh"
silent_output=$(
  PATH="$LINUX_TMP/bin:/usr/bin:/bin" \
    TERM_PROGRAM=vscode \
    bash "$LINUX_TMP/.claude/hooks/notify.sh" \
    <<<'{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"/tmp","transcript_path":"/dev/null"}' \
    2>&1
) && rc=0 || rc=$?

if [[ "$rc" -eq 0 ]]; then
  pass "Linux notify.sh exits 0 without notify-slack.sh"
else
  fail "Linux notify.sh exits 0 without notify-slack.sh (rc=$rc, output=$silent_output)"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  printf '\nFailures:\n'
  for f in "${FAILURES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
