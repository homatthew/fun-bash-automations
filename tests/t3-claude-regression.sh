#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t t3-claude-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

T3_CLAUDE="$ROOT/bin/t3-claude"
FAKE_HOME="$TMP/home"
STABLE_NODE_BIN="$FAKE_HOME/.local/share/fnm/aliases/default/bin"
LOGIN_BIN="$TMP/login/bin"
mkdir -p "$STABLE_NODE_BIN" "$LOGIN_BIN" "$TMP/empty"

printf '%s\n' '#!/usr/bin/env bash' 'echo stable-node' >"$STABLE_NODE_BIN/node"
printf '%s\n' '#!/usr/bin/env bash' 'printf "claude:%s\n" "$*"' >"$LOGIN_BIN/claude"
printf '%s\n' '#!/usr/bin/env bash' 'echo override' >"$TMP/override-claude"
chmod +x "$STABLE_NODE_BIN/node" "$LOGIN_BIN/claude" "$TMP/override-claude"

# The app hands over a PATH snapshot that can carry directories which no longer
# exist; the stable node bin has to win and the dead entry has to go.
env_output="$(env -i HOME="$FAKE_HOME" PATH="$TMP/gone:$LOGIN_BIN:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="/usr/bin:/bin" "$T3_CLAUDE" --t3-env)" ||
  fail "t3-claude --t3-env failed"
[[ "$env_output" == *"claude: $LOGIN_BIN/claude"* ]] ||
  fail "--t3-env did not resolve claude from PATH: $env_output"
[[ "$env_output" == *"node:   $STABLE_NODE_BIN/node"* ]] ||
  fail "--t3-env did not resolve node from the stable fnm alias: $env_output"
path_line="$(printf '%s\n' "$env_output" | sed -n 's/^PATH:[[:space:]]*//p')"
[[ "$path_line" == "$STABLE_NODE_BIN:"* ]] || fail "stable node bin not first: $path_line"
[[ "$path_line" != *"$TMP/gone"* ]] || fail "nonexistent PATH entry survived: $path_line"

# Provider args belong to the app, including its permission flag: pass them
# through untouched and add nothing.
run_output="$(env -i HOME="$FAKE_HOME" PATH="$LOGIN_BIN:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="/usr/bin:/bin" "$T3_CLAUDE" \
  --output-format stream-json --verbose)" || fail "t3-claude exec failed"
[[ "$run_output" == "claude:--output-format stream-json --verbose" ]] ||
  fail "arguments were rewritten: $run_output"

# The app health-checks with a bare `--version` on a 4s budget, so that call has
# to come from the installed CLI, not from a launcher that talks to the network.
INSTALLED_CLI_BIN="$FAKE_HOME/.local/share/claude/bin"
mkdir -p "$INSTALLED_CLI_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'echo "9.9.9 (Claude Code)"' >"$INSTALLED_CLI_BIN/claude"
chmod +x "$INSTALLED_CLI_BIN/claude"

version_output="$(env -i HOME="$FAKE_HOME" PATH="$LOGIN_BIN:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="/usr/bin:/bin" "$T3_CLAUDE" --version)" ||
  fail "t3-claude --version failed"
[[ "$version_output" == "9.9.9 (Claude Code)" ]] ||
  fail "--version did not come from the installed CLI: $version_output"

# Anything beyond a bare --version is a real invocation and belongs to the launcher.
passthrough_output="$(env -i HOME="$FAKE_HOME" PATH="$LOGIN_BIN:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="/usr/bin:/bin" "$T3_CLAUDE" --version --verbose)" ||
  fail "t3-claude --version --verbose failed"
[[ "$passthrough_output" == "claude:--version --verbose" ]] ||
  fail "--version fast path swallowed a real invocation: $passthrough_output"

override_output="$(env -i HOME="$FAKE_HOME" PATH="$LOGIN_BIN:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="/usr/bin:/bin" T3_CLAUDE_BIN="$TMP/override-claude" \
  "$T3_CLAUDE")" || fail "T3_CLAUDE_BIN override failed"
[[ "$override_output" == "override" ]] || fail "T3_CLAUDE_BIN ignored: $override_output"

# A missing launcher must fail loudly; a silent success would leave the app
# reporting a healthy provider that cannot run a thread.
set +e
missing_output="$(env -i HOME="$FAKE_HOME" PATH="$TMP/empty:/usr/bin:/bin" \
  T3_CLAUDE_FALLBACK_DIRS="$TMP/empty" "$T3_CLAUDE" 2>&1)"
missing_status=$?
set -e
[[ "$missing_status" -eq 127 ]] || fail "missing claude exited $missing_status, expected 127"
[[ "$missing_output" == *"no 'claude' found on PATH"* ]] ||
  fail "missing claude message unclear: $missing_output"

echo "t3-claude regression passed"
