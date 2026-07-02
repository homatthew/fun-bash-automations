#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-kun-version-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fake_bin="$TMP/bin"
mkdir -p "$fake_bin" "$TMP/home/.local/state/kun-stack"

cat > "$fake_bin/fake-tool" <<'SH'
#!/usr/bin/env bash
echo "runtime dependency v9.9.9"
echo "fake-tool version 1.32.2"
SH
chmod +x "$fake_bin/fake-tool"

cat > "$fake_bin/go" <<'SH'
#!/usr/bin/env bash
echo "go install should not be called when the marker and relaxed version probe match" >&2
exit 99
SH
chmod +x "$fake_bin/go"

manifest="$TMP/manifest.json"
cat > "$manifest" <<'JSON'
{
  "version": 1,
  "marker_dir": "~/.local/state/kun-stack",
  "tools": {
    "fake-tool": {
      "kind": "go",
      "module": "example.com/fake-tool",
      "version": "v1.32.2",
      "bin": "fake-tool",
      "version_args": ["--version"],
      "version_match": "1.32.0",
      "version_policy": "same_minor_or_newer_patch",
      "required": true
    }
  }
}
JSON

verify_out="$(
  HOME="$TMP/home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-verify" 2>&1
)" || fail "kun-stack-verify should accept a matching later semver in noisy output, got: $verify_out"
[[ "$verify_out" == *"PASS  fake-tool"* ]] ||
  fail "kun-stack-verify did not pass fake-tool: $verify_out"

touch "$TMP/home/.local/state/kun-stack/fake-tool"
install_out="$(
  HOME="$TMP/home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)" || fail "kun-stack-install should skip a marked tool whose noisy version output contains a matching semver, got: $install_out"
[[ "$install_out" == *"already satisfies version policy"* ]] ||
  fail "kun-stack-install did not skip fake-tool via relaxed version probe: $install_out"

echo "kun stack version policy regression passed"
