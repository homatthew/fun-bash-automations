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

for target in '.vimrc' '.zshrc' 'zsh/personal.zsh' 'ghostty/config'; do
  grep -Fq "\$ROOT_DIR/$target" "$ROOT/setupPermissions.sh" ||
    fail "setupPermissions does not link $target from ROOT_DIR"
done
if rg -n '~/repos/fun-bash-automations' "$ROOT/setupPermissions.sh" >/dev/null; then
  fail "setupPermissions retains fixed-checkout symlink targets"
fi
for path in 'rebase-all-branches/rebaseAllBranches.sh' 'rp/rp-completion.sh' 'rp/rp.sh'; do
  grep -Fq 'chmod +x "$ROOT_DIR/$path"' "$ROOT/setupPermissions.sh" ||
    fail "setupPermissions still chmods relative paths"
done

echo "setup permissions regression passed"
