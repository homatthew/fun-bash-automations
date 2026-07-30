#!/usr/bin/env bash
# Verify bin/fba-deploy projects everything that claude/settings.json and
# codex/hooks.json reference, and that the Linux notify.sh short-circuit
# never invokes macOS binaries.
set -euo pipefail

# This suite asserts what the *portable public baseline* projects, so it must not
# inherit the developer's private overlay. fba-deploy falls back to these when
# rendering codex/config.toml, and a workspace shell exports them (Netflix Model
# Gateway), which made "Codex defaults to the portable OpenAI provider" fail on
# exactly the machine it exists to protect.
unset CODEX_BASE_URL CODEX_PROVIDER_NAME

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
    FBA_DEPLOY_SKIP_GIT_HOOK=1 \
    "$ROOT/bin/fba-deploy" "$@"
}

# --- Phase 1: full projection ---
echo "== Phase 1: fba-deploy (full) =="
mkdir -p "$TMP_HOME/.claude/skills/commit-push-pr" "$TMP_HOME/.claude/skills/worktree-dev" "$TMP_HOME/.codex/skills"
mkdir -p "$TMP_HOME/repos/cursor-google-workspace-skills/skills/implicit-skill"
printf '%s\n' 'implicit' > "$TMP_HOME/repos/cursor-google-workspace-skills/skills/implicit-skill/SKILL.md"
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
    | (any(.repo == "fun-bash-automations" and .delivery_branch == "main"))
      and (all(.repo != "dotfiles"))
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy projects direct-push exceptions"
  else
    fail "$harness agent push policy projects direct-push exceptions"
  fi
  if jq -e '
    .yolo_branches.enabled == false
    and .yolo_branches.requires_user_opt_in == true
    and .yolo_branches.pr_eligible == false
    and .yolo_branches.allow_delete == false
    and (.yolo_branches.prefixes | index("yolo/") != null)
    and (.yolo_branches.protected_base_refs | index("main") != null)
    and (.yolo_branches.protected_base_refs | index("master") != null)
    and (.delivery_feature_branches.prefixes | index("feature/") != null)
    and (.delivery_feature_branches.prefixes | index("mho/") == null)
  ' "$policy" >/dev/null; then
    pass "$harness agent push policy disables the yolo branch class"
  else
    fail "$harness agent push policy disables the yolo branch class"
  fi
done

if [[ ! -e "$TMP_HOME/.claude/skills/implicit-skill" && ! -e "$TMP_HOME/.codex/skills/implicit-skill" ]]; then
  pass "machine-specific skill checkout is not discovered implicitly"
else
  fail "machine-specific skill checkout is not discovered implicitly"
fi

explicit_skills="$TMP_ROOT/explicit-skills"
mkdir -p "$explicit_skills/selected-skill"
printf '%s\n' 'selected' > "$explicit_skills/selected-skill/SKILL.md"
run_deploy --shared-only --external-skills-dir "$explicit_skills" >/dev/null
if [[ -L "$TMP_HOME/.claude/skills/selected-skill" && -L "$TMP_HOME/.codex/skills/selected-skill" ]]; then
  pass "explicit external skills directory is projected"
else
  fail "explicit external skills directory is projected"
fi

relative_skills="$TMP_ROOT/relative-skills"
mkdir -p "$relative_skills/relative-skill"
printf '%s\n' 'relative' > "$relative_skills/relative-skill/SKILL.md"
relative_canonical="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$relative_skills/relative-skill")"
(
  cd "$TMP_ROOT"
  HOME="$TMP_HOME" FBA_DEPLOY_LOG="$TMP_LOG" FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
    FBA_DEPLOY_SKIP_GIT_HOOK=1 "$ROOT/bin/fba-deploy" --shared-only \
    --external-skills-dir relative-skills >/dev/null
)
relative_target="$(readlink "$TMP_HOME/.claude/skills/relative-skill")"
if [[ "$relative_target" == "$relative_canonical" \
  && -e "$TMP_HOME/.claude/skills/relative-skill" \
  && -e "$TMP_HOME/.codex/skills/relative-skill" ]]; then
  pass "relative external skills resolve through canonical links"
else
  fail "relative external skills resolve through canonical links"
fi

failing_skills="$TMP_ROOT/failing-skills"
mkdir -p "$failing_skills/failing-skill" "$TMP_ROOT/fake-ln-bin"
printf '%s\n' 'failing' > "$failing_skills/failing-skill/SKILL.md"
real_ln="$(command -v ln)"
cat > "$TMP_ROOT/fake-ln-bin/ln" <<'STUB'
#!/usr/bin/env bash
if [[ "${3:-}" == *"failing-skill" ]]; then
  "$REAL_LN" -s "$2/missing" "$3"
  exit 0
fi
exec "$REAL_LN" "$@"
STUB
chmod +x "$TMP_ROOT/fake-ln-bin/ln"
if broken_link_out="$(
  export PATH="$TMP_ROOT/fake-ln-bin:$PATH"
  export REAL_LN="$real_ln"
  run_deploy --shared-only --external-skills-dir "$failing_skills" 2>&1
)"; then
  fail "projection verification rejects a misdirected created link"
elif [[ "$broken_link_out" == *"Projection target did not resolve to its source"* \
  && ! -e "$TMP_HOME/.claude/skills/failing-skill" \
  && ! -L "$TMP_HOME/.claude/skills/failing-skill" ]]; then
  pass "projection verification removes a misdirected created link"
else
  fail "misdirected projection cleanup failed: $broken_link_out"
fi

collision_home="$TMP_ROOT/collision-home"
mkdir -p "$collision_home/.claude/skills/architect"
printf '%s\n' 'unmanaged' > "$collision_home/.claude/skills/architect/SKILL.md"
if collision_out="$(HOME="$collision_home" FBA_DEPLOY_SKIP_GIT_HOOK=1 FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
  "$ROOT/bin/fba-deploy" --claude-only 2>&1)"; then
  fail "managed projection rejects an existing directory collision"
elif [[ "$collision_out" == *"Refusing to replace unmanaged projection"* ]]; then
  pass "managed projection rejects an existing directory collision"
else
  fail "managed projection collision failure was unclear: $collision_out"
fi

# A byte-identical regular file where a symlink belongs is re-adopted, not
# refused. Claude Code rewrites ~/.claude/CLAUDE.md as a regular file whenever
# user memory is edited, which used to break every later deploy even though the
# content was exactly the projection source.
adopt_home="$TMP_ROOT/adopt-home"
mkdir -p "$adopt_home/.claude"
cp "$ROOT/claude/CLAUDE.md" "$adopt_home/.claude/CLAUDE.md"
if adopt_out="$(HOME="$adopt_home" FBA_DEPLOY_SKIP_GIT_HOOK=1 FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
  "$ROOT/bin/fba-deploy" --claude-only 2>&1)"; then
  if [[ -L "$adopt_home/.claude/CLAUDE.md" ]] \
    && [[ "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$adopt_home/.claude/CLAUDE.md")" == "$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$ROOT/claude/CLAUDE.md")" ]]; then
    pass "identical regular file is re-adopted as a managed symlink"
  else
    fail "identical regular file was not relinked: $(ls -l "$adopt_home/.claude/CLAUDE.md")"
  fi
else
  fail "deploy failed against an identical regular file: $adopt_out"
fi

# ...but a file whose content differs is still refused, so real local edits are
# never silently discarded.
differ_home="$TMP_ROOT/differ-home"
mkdir -p "$differ_home/.claude"
printf '%s\n' 'locally modified, do not clobber' > "$differ_home/.claude/CLAUDE.md"
if differ_out="$(HOME="$differ_home" FBA_DEPLOY_SKIP_GIT_HOOK=1 FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
  "$ROOT/bin/fba-deploy" --claude-only 2>&1)"; then
  fail "deploy must refuse a differing regular file"
elif [[ "$differ_out" == *"Refusing to replace unmanaged projection"* ]] \
  && [[ "$(cat "$differ_home/.claude/CLAUDE.md")" == 'locally modified, do not clobber' ]]; then
  pass "differing regular file is refused and left untouched"
else
  fail "differing regular file was mishandled: $differ_out"
fi

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
if [[ -f "$TMP_HOME/.claude/skills/worktree-dev/SKILL.md" ]] \
  && grep -Fq "Local custom replacement" "$TMP_HOME/.claude/skills/worktree-dev/SKILL.md"; then
  pass "unmanaged local retired-name skill preserved"
else
  fail "unmanaged local retired-name skill preserved"
fi

echo "-- portable runtime settings --"
assert_not_contains_file "$TMP_HOME/.claude/settings.json" "private.internal.example.com" \
  "Claude base settings exclude internal endpoints"
assert_not_contains_file "$TMP_HOME/.claude/settings.json" "__USER_NETFLIX_EMAIL__" \
  "Claude base settings exclude private overlay placeholders"
if jq -e 'has("skipDangerousModePermissionPrompt") | not' "$TMP_HOME/.claude/settings.json" >/dev/null; then
  pass "Claude dangerous-mode prompt suppression is absent"
else
  fail "Claude dangerous-mode prompt suppression is absent"
fi
if grep -Fq 'name = "OpenAI"' "$TMP_HOME/.codex/config.toml" \
  && grep -Fq 'base_url = "https://api.openai.com/v1"' "$TMP_HOME/.codex/config.toml"; then
  pass "Codex defaults to the portable OpenAI provider"
else
  fail "Codex defaults to the portable OpenAI provider"
fi
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "__CODEX_PROVIDER_NAME__" \
  "Codex provider-name placeholder rendered"

echo "-- codex feature flags --"
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "codex_hooks" \
  "deprecated codex_hooks flag absent"
if grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$TMP_HOME/.codex/config.toml"; then
  pass "codex hooks feature enabled"
else
  fail "codex hooks feature enabled"
fi
if grep -Fq 'notifications = [ "agent-turn-complete", "approval-requested" ]' "$TMP_HOME/.codex/config.toml"; then
  pass "codex TUI notifications configured"
else
  fail "codex TUI notifications configured"
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
adversarial_provider='A&B | "quoted" \ provider'
adversarial_url='https://example.com/v1?x=a&y="quoted"\tail'
HOME="$TMP_HOME" FBA_DEPLOY_LOG="$TMP_LOG" FBA_DEPLOY_SKIP_MAC_EXTRAS=1 \
  FBA_DEPLOY_SKIP_GIT_HOOK=1 \
  CODEX_PROVIDER_NAME="$adversarial_provider" CODEX_BASE_URL="$adversarial_url" \
  "$ROOT/bin/fba-deploy" --codex-only >/dev/null
if python3 - "$TMP_HOME/.codex/config.toml" "$adversarial_provider" "$adversarial_url" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
provider = config["model_providers"]["openai-chat-completions"]
raise SystemExit(0 if provider["name"] == sys.argv[2] and provider["base_url"] == sys.argv[3] else 1)
PY
then
  pass "Codex TOML renderer escapes configured values"
else
  fail "Codex TOML renderer escapes configured values"
fi
echo "-- codex MCP allowlist --"
if grep -Fq "[mcp_servers.chrome-devtools]" "$TMP_HOME/.codex/config.toml" \
  && grep -Fq 'args = ["chrome-devtools-mcp@1.6.0"]' "$TMP_HOME/.codex/config.toml"; then
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
assert_not_contains_file "$TMP_HOME/.codex/config.toml" "private-mcp.internal.example.com" \
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
