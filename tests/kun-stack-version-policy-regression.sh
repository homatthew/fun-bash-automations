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
mkdir -p "$fake_bin" "$TMP/user-home/.local/state/kun-stack"

cat > "$fake_bin/fake-tool" <<'SH'
#!/usr/bin/env bash
echo "runtime dependency v9.9.9"
echo "fake-tool version ${FAKE_TOOL_VERSION:-1.32.2}"
echo "A new version is available: ${FAKE_TOOL_UPDATE_VERSION:-9.9.9}"
exit "${FAKE_TOOL_RC:-0}"
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

git -C "$TMP" init -q -b main git-source
git -C "$TMP/git-source" config user.email test@example.com
git -C "$TMP/git-source" config user.name "Test User"
printf 'pinned\n' > "$TMP/git-source/value.txt"
git -C "$TMP/git-source" add value.txt
git -C "$TMP/git-source" commit -q -m pinned
pinned_ref="$(git -C "$TMP/git-source" rev-parse HEAD)"
printf 'later\n' > "$TMP/git-source/value.txt"
git -C "$TMP/git-source" commit -q -am later
git clone -q "$TMP/git-source" "$TMP/user-home/fake-git"

jq --arg repo "$TMP/git-source" --arg ref "$pinned_ref" \
  '.tools["fake-git"] = {
    kind: "git", repo: $repo, ref: $ref, dest: "~/fake-git", required: true
  }' "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"

if banner_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    FAKE_TOOL_VERSION=1.31.9 FAKE_TOOL_UPDATE_VERSION=1.32.2 \
    "$ROOT/bin/kun-stack-verify" 2>&1
)"; then
  fail "kun-stack-verify accepted an update banner as the installed version"
fi
[[ "$banner_out" == *"FAIL  fake-tool present but not v1.32.2"* ]] ||
  fail "kun-stack-verify did not reject the old actual version: $banner_out"

if failed_probe_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    FAKE_TOOL_VERSION=1.32.2 FAKE_TOOL_RC=7 \
    "$ROOT/bin/kun-stack-verify" 2>&1
)"; then
  fail "kun-stack-verify accepted version output from a failed probe"
fi
[[ "$failed_probe_out" == *"FAIL  fake-tool present but not v1.32.2"* ]] ||
  fail "kun-stack-verify did not report the failed version probe: $failed_probe_out"

touch "$TMP/user-home/.local/state/kun-stack/fake-tool"
if banner_install_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    FAKE_TOOL_VERSION=1.31.9 FAKE_TOOL_UPDATE_VERSION=1.32.2 \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)"; then
  fail "kun-stack-install skipped an old tool because its update banner matched"
fi
[[ "$banner_install_out" != *"already satisfies version policy"* ]] ||
  fail "kun-stack-install treated the update banner as the actual version: $banner_install_out"

if failed_install_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    FAKE_TOOL_VERSION=1.32.2 FAKE_TOOL_RC=7 \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)"; then
  fail "kun-stack-install accepted version output from a failed probe"
fi
[[ "$failed_install_out" != *"already satisfies version policy"* ]] ||
  fail "kun-stack-install ignored the failed probe exit status: $failed_install_out"

if wrong_ref_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-verify" 2>&1
)"; then
  fail "kun-stack-verify accepted a checkout at the wrong commit"
fi
[[ "$wrong_ref_out" == *"FAIL  fake-git (git)"* ]] ||
  fail "kun-stack-verify did not report the mismatched checkout: $wrong_ref_out"

git_install_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-install" fake-git 2>&1
)" || fail "kun-stack-install did not check out the pinned git ref: $git_install_out"
[[ "$(git -C "$TMP/user-home/fake-git" rev-parse HEAD)" == "$pinned_ref" ]] ||
  fail "kun-stack-install marked the wrong git commit as installed"

verify_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-verify" 2>&1
)" || fail "kun-stack-verify should accept pinned tools, got: $verify_out"
[[ "$verify_out" == *"PASS  fake-tool"* ]] ||
  fail "kun-stack-verify did not pass fake-tool: $verify_out"
[[ "$verify_out" == *"PASS  fake-git (git) at pinned ref"* ]] ||
  fail "kun-stack-verify did not pass the pinned git checkout: $verify_out"

touch "$TMP/user-home/.local/state/kun-stack/fake-tool"
install_out="$(
  HOME="$TMP/user-home" PATH="$fake_bin:$PATH" KUN_STACK_MANIFEST="$manifest" \
    "$ROOT/bin/kun-stack-install" fake-tool 2>&1
)" || fail "kun-stack-install should skip a marked tool whose noisy version output contains a matching semver, got: $install_out"
[[ "$install_out" == *"already satisfies version policy"* ]] ||
  fail "kun-stack-install did not skip fake-tool via relaxed version probe: $install_out"

managed_bin="$TMP/managed-bin"
mkdir -p "$managed_bin"
printf '#!/usr/bin/env bash\n' > "$managed_bin/fake-tool"
chmod +x "$managed_bin/fake-tool"
HOME="$TMP/user-home" PATH="$fake_bin:$PATH" GOBIN="$managed_bin" KUN_STACK_MANIFEST="$manifest" \
  "$ROOT/bin/kun-stack-uninstall" fake-tool >/dev/null 2>&1
[[ ! -e "$managed_bin/fake-tool" ]] || fail "kun-stack-uninstall left the managed GOBIN binary"
[[ -e "$fake_bin/fake-tool" ]] || fail "kun-stack-uninstall removed an unrelated PATH binary"

echo "kun stack version policy regression passed"
