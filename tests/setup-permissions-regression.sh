#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-setup-permissions-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'SH'
#!/usr/bin/env bash
echo Linux
SH
cat > "$TMP/bin/apt-get" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SETUP_SUDO_LOG"
SH
chmod +x "$TMP/bin/uname" "$TMP/bin/apt-get" "$TMP/bin/sudo"

out="$(
  SETUP_SUDO_LOG="$TMP/sudo.log" PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$ROOT/scripts/setup-desktop-notifications.sh"
)" || fail "Linux notification setup failed without Homebrew"
[[ "$out" == *"Installing libnotify-bin"* ]] ||
  fail "Linux notification setup did not select apt without Homebrew: $out"
[[ "$(cat "$TMP/sudo.log")" == "apt-get install -y libnotify-bin" ]] ||
  fail "Linux notification setup did not invoke the native package manager"

echo "setup permissions regression passed"
