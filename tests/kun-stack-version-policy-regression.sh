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
case "${FAKE_TOOL_SCENARIO:-valid}" in
  banner-old)
    echo "latest 1.32.2"
    echo "fake-tool version 1.31.9"
    ;;
  *)
    echo "runtime dependency v9.9.9"
    echo "fake-tool version 1.32.2"
    ;;
esac
SH
chmod +x "$fake_bin/fake-tool"

cat > "$fake_bin/go" <<'SH'
#!/usr/bin/env bash
if [ "${FAKE_TOOL_SCENARIO:-valid}" = "banner-old" ]; then
  echo "go install called for stale version" >&2
  exit 99
fi
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

set +e
verify_banner_out="$(
  HOME="$TMP/home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" FAKE_TOOL_SCENARIO=banner-old \
    "$ROOT/bin/kun-stack-verify" 2>&1
)"
verify_banner_rc=$?
set -e
[[ "$verify_banner_rc" -ne 0 ]] ||
  fail "kun-stack-verify accepted latest banner semver instead of installed version: $verify_banner_out"
[[ "$verify_banner_out" == *"FAIL  fake-tool present but not v1.32.2"* ]] ||
  fail "kun-stack-verify did not report stale installed version: $verify_banner_out"

touch "$TMP/home/.local/state/kun-stack/fake-tool"
install_out="$(
  HOME="$TMP/home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)" || fail "kun-stack-install should skip a marked tool whose noisy version output contains a matching semver, got: $install_out"
[[ "$install_out" == *"already satisfies version policy"* ]] ||
  fail "kun-stack-install did not skip fake-tool via relaxed version probe: $install_out"

set +e
install_banner_out="$(
  HOME="$TMP/home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" FAKE_TOOL_SCENARIO=banner-old \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)"
install_banner_rc=$?
set -e
[[ "$install_banner_rc" -ne 0 ]] ||
  fail "kun-stack-install skipped reinstall from latest banner semver: $install_banner_out"
[[ "$install_banner_out" != *"already satisfies version policy"* ]] ||
  fail "kun-stack-install treated latest banner as installed version: $install_banner_out"

echo "kun stack version policy regression passed"
