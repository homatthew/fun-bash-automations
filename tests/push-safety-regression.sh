#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-push-safety-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts"
  cp "$ROOT/scripts/check-push-safety.sh" "$repo/scripts/check-push-safety.sh"
  cp "$ROOT/scripts/check-push-safety.allow" "$repo/scripts/check-push-safety.allow"
  chmod +x "$repo/scripts/check-push-safety.sh"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name "Test User"
  printf 'clean\n' > "$repo/README.md"
  git -C "$repo" add README.md scripts/check-push-safety.sh scripts/check-push-safety.allow
  git -C "$repo" commit -q -m initial
}

repo="$TMP/repo"
make_repo "$repo"
base_oid="$(git -C "$repo" rev-parse HEAD)"

root_out="$("$ROOT/scripts/check-push-safety.sh")" || fail "real repository boundary scan failed"
[[ "$root_out" == *"push-safety scan clean (all)"* ]] || fail "real repository was not scanned"

private_policy="$TMP/private-policy.tsv"
cat > "$private_policy" <<'POLICY'
private-short-url	https?://shortcut\.example([^A-Za-z0-9.-]|$)
internal-domain	([A-Za-z0-9-]+\.)*corp\.example([^A-Za-z0-9.-]|$)
internal-tool	(^|[^A-Za-z0-9_-])private-tool([^A-Za-z0-9_-]|$)
internal-topology	(^|[^A-Za-z0-9_-])TEST_CLUSTER_[A-Z]+([^A-Za-z0-9_-]|$)
private-wrapper	(^|[^A-Za-z0-9_-])private-wrapper([^A-Za-z0-9_-]|$)
personal-state-path	(^|[^A-Za-z0-9_])(~|\$HOME)/private-state([^A-Za-z0-9_]|$)
private-workspace-marker	PRIVATE_WORKSPACE
private-path	restricted-zone
POLICY
if missing_policy_out="$(FBA_PUSH_SAFETY_POLICY_FILE="$TMP/missing-policy" "$repo/scripts/check-push-safety.sh" 2>&1)"; then
  fail "expected an explicitly selected missing policy to fail closed"
fi
[[ "$missing_policy_out" == *"policy file is not readable"* ]] || fail "missing policy failure was unclear: $missing_policy_out"
export FBA_PUSH_SAFETY_POLICY_FILE="$private_policy"

rm "$repo/README.md"
private_home='/Users/'
ln -s "${private_home}alice/private-target" "$repo/README.md"
if replaced_symlink_out="$("$repo/scripts/check-push-safety.sh" 2>&1)"; then
  fail "expected worktree scan to inspect an unstaged replacement symlink"
fi
[[ "$replaced_symlink_out" == *"README.md:1  [absolute-home-path]"* ]] ||
  fail "unstaged replacement symlink was missed: $replaced_symlink_out"
git -C "$repo" add README.md
if staged_type_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to inspect a regular-file-to-symlink type change"
fi
[[ "$staged_type_out" == *"README.md:1  [absolute-home-path]"* ]] ||
  fail "staged symlink type change was missed: $staged_type_out"
git -C "$repo" reset -q --hard HEAD

printf '# token=%s%s\n' 'sk-' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >> "$repo/scripts/check-push-safety.sh"
if scanner_self_out="$("$repo/scripts/check-push-safety.sh" 2>&1)"; then
  fail "expected the scanner to inspect its own published blob"
fi
[[ "$scanner_self_out" == *"scripts/check-push-safety.sh"*"[openai-secret]"* ]] ||
  fail "scanner implementation was excluded: $scanner_self_out"
git -C "$repo" reset -q --hard HEAD

printf '# token=%s%s\n' 'sk-' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >> "$repo/scripts/check-push-safety.allow"
if allow_self_out="$("$repo/scripts/check-push-safety.sh" 2>&1)"; then
  fail "expected the scanner to inspect its allow-list"
fi
[[ "$allow_self_out" == *"scripts/check-push-safety.allow"*"[openai-secret]"* ]] ||
  fail "allow-list was excluded: $allow_self_out"
git -C "$repo" reset -q --hard HEAD

printf 'token=%s%s\n' 'sk-' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$repo/secrets.txt"
git -C "$repo" add secrets.txt
printf 'token=redacted\n' > "$repo/secrets.txt"

if staged_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to catch the indexed secret"
fi
[[ "$staged_out" == *"LEAK  secrets.txt:1  [openai-secret]"* ]] ||
  fail "staged scan did not report the indexed secret with the expected path/line: $staged_out"

git -C "$repo" reset -q --hard HEAD
printf 'token=%s%s\n' 'sk-proj-' 'abcdefghijklmnopqrstuvwxyz_0123456789' > "$repo/modern-openai.txt"
git -C "$repo" add modern-openai.txt
if modern_openai_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to catch a modern OpenAI key"
fi
[[ "$modern_openai_out" == *"[openai-secret]"* ]] || fail "modern OpenAI key was missed: $modern_openai_out"
git -C "$repo" reset -q --hard HEAD

ln -s "${private_home}alice/private-target" "$repo/private-link"
git -C "$repo" add private-link
if symlink_out="$("$repo/scripts/check-push-safety.sh" 2>&1)"; then
  fail "expected worktree scan to inspect a tracked symlink target"
fi
[[ "$symlink_out" == *"private-link:1  [absolute-home-path]"* ]] || fail "symlink target was missed: $symlink_out"
git -C "$repo" commit -q -m "add private symlink"
symlink_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q private-link
git -C "$repo" commit -q -m "remove private symlink"

python3 - "$repo/utf16.txt" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(("token=" + "sk-" + "proj-" + "abcdefghijklmnopqrstuvwxyz_0123456789\n").encode("utf-16le"))
PY
git -C "$repo" add utf16.txt
if utf16_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to inspect UTF-16 content"
fi
[[ "$utf16_out" == *"[openai-secret]"* ]] || fail "UTF-16 secret was missed: $utf16_out"
git -C "$repo" commit -q -m "add UTF-16 secret"
utf16_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q utf16.txt
git -C "$repo" commit -q -m "remove UTF-16 secret"

mkdir -p "$repo/tests"
printf "token-service) printf '%s%s' ;;\n" 'xoxb-' 'fake-token' > "$repo/tests/notify-slack-regression.sh"
git -C "$repo" add tests/notify-slack-regression.sh
"$repo/scripts/check-push-safety.sh" --staged >/dev/null || fail "content-qualified Slack fixture was not allowed"
printf "real='%s%s'\n" 'xoxb-' 'abcdefghijklmnopqrstuvwxyz' >> "$repo/tests/notify-slack-regression.sh"
git -C "$repo" add tests/notify-slack-regression.sh
if slack_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected a real Slack token beside the fixture to be rejected"
fi
[[ "$slack_out" == *"[slack-bot-token]"* ]] || fail "Slack token was hidden by fixture allowance: $slack_out"
git -C "$repo" reset -q --hard HEAD

{
  printf 'url=%s%s\n' 'https://' 'shortcut.example/private-tool'
  printf 'domain=%s%s\n' 'git.' 'corp.example'
  printf 'tool=%s%s\n' 'private' '-tool'
  printf 'topology=%s%s\n' 'TEST_CLUSTER_' 'PROD'
  printf 'wrapper=%s%s\n' 'private-' 'wrapper'
  printf 'home=%s%s\n' '/Users/' 'alice/private.txt'
  printf 'state=%s%s\n' '~/' 'private-state/cache'
  printf 'workspace=%s%s\n' 'PRIVATE_' 'WORKSPACE'
} > "$repo/boundary.txt"
git -C "$repo" add boundary.txt
if boundary_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to catch private environment content"
fi
for label in private-short-url internal-domain internal-tool internal-topology private-wrapper absolute-home-path personal-state-path private-workspace-marker; do
  [[ "$boundary_out" == *"[$label]"* ]] || fail "missing $label finding: $boundary_out"
done

git -C "$repo" commit -q -m "add private content"
private_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q boundary.txt
git -C "$repo" commit -q -m "remove private content"

printf 'home=%s%s\n' '/Users/' 'alice' > "$repo/terminal-home.txt"
git -C "$repo" add terminal-home.txt
if terminal_home_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected a terminal absolute home path to be rejected"
fi
[[ "$terminal_home_out" == *"[absolute-home-path]"* ]] || fail "terminal home path was missed: $terminal_home_out"
git -C "$repo" reset -q --hard HEAD

mkdir -p "$repo/docs"
printf 'clean content\n' > "$repo/docs/restricted-zone.txt"
git -C "$repo" add docs/restricted-zone.txt
if private_path_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected a forbidden pathname with clean content to be rejected"
fi
[[ "$private_path_out" == *"docs/restricted-zone.txt:path  [private-path]"* ]] ||
  fail "staged pathname was not scanned: $private_path_out"
git -C "$repo" commit -q -m "add restricted path"
private_path_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q docs/restricted-zone.txt
git -C "$repo" commit -q -m "remove restricted path"

printf 'identity test\n' > "$repo/identity.txt"
git -C "$repo" add identity.txt
GIT_AUTHOR_NAME='Private Author' GIT_AUTHOR_EMAIL='author@corp.example' \
  GIT_COMMITTER_NAME='Private Committer' GIT_COMMITTER_EMAIL='committer@corp.example' \
  git -C "$repo" commit -q -m "add identity fixture"
identity_oid="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -q identity.txt
git -C "$repo" commit -q -m "remove identity fixture"
tip_oid="$(git -C "$repo" rev-parse HEAD)"

mkdir -p "$repo/zsh"
portable_brew='/home/''linuxbrew/.linuxbrew/share'
printf 'paths=(%s %s)\n' "$portable_brew" "${private_home}alice/private" > "$repo/zsh/personal.zsh"
git -C "$repo" add zsh/personal.zsh
if mixed_home_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "content-qualified Linuxbrew allow rule hid another absolute home path"
fi
[[ "$mixed_home_out" == *"[absolute-home-path]"* ]] ||
  fail "mixed safe/private home line was not reported: $mixed_home_out"
git -C "$repo" reset -q --hard HEAD

all_out="$("$repo/scripts/check-push-safety.sh" 2>&1)" ||
  fail "expected full-tree scan of the safe worktree to pass, got: $all_out"
[[ "$all_out" == *"push-safety scan clean (all)"* ]] ||
  fail "full-tree scan did not report clean state: $all_out"

if unattested_out="$(printf 'refs/heads/main %s refs/heads/main %s\n' "$tip_oid" "$base_oid" |
  "$repo/scripts/check-push-safety.sh" --pre-push origin 2>&1)"; then
  fail "expected main pre-push scan to require no-mistakes attestation"
fi
[[ "$unattested_out" == *"main delivery requires the pinned no-mistakes binary"* ]] ||
  fail "main push was not rejected for missing gate attestation: $unattested_out"

if outgoing_out="$("$repo/scripts/check-push-safety.sh" --outgoing "$base_oid" 2>&1)"; then
  fail "expected explicit outgoing scan to catch content deleted at the tip"
fi
[[ "$outgoing_out" == *"boundary.txt@$private_oid"* ]] ||
  fail "explicit outgoing scan did not report historical content: $outgoing_out"
[[ "$outgoing_out" == *"private-link@$symlink_oid"* && "$outgoing_out" == *"utf16.txt@$utf16_oid"* ]] ||
  fail "explicit outgoing scan missed a symlink or binary-classified blob: $outgoing_out"
[[ "$outgoing_out" == *"docs/restricted-zone.txt@$private_path_oid:path  [private-path]"* ]] ||
  fail "explicit outgoing scan missed a historical pathname: $outgoing_out"
[[ "$outgoing_out" == *".git/commit/$identity_oid"*"[internal-domain]"* ]] ||
  fail "explicit outgoing scan missed commit identities: $outgoing_out"

missing_blob="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
missing_tree="$(printf '100644 blob %s\tmissing.txt\0' "$missing_blob" | git -C "$repo" mktree -z --missing)"
missing_commit="$(printf 'missing blob fixture\n' | git -C "$repo" commit-tree "$missing_tree" -p "$tip_oid")"
git -C "$repo" update-ref refs/heads/main "$missing_commit"
if missing_blob_out="$("$repo/scripts/check-push-safety.sh" --outgoing "$tip_oid" 2>&1)"; then
  fail "expected an unreadable outgoing blob to fail closed"
fi
[[ "$missing_blob_out" == *"failed to read blob object $missing_blob"* ]] ||
  fail "missing blob failure was not reported: $missing_blob_out"
git -C "$repo" update-ref refs/heads/main "$tip_oid"

if deletion_out="$(printf 'refs/heads/main %040d refs/heads/main %s\n' 0 "$tip_oid" |
  "$repo/scripts/check-push-safety.sh" --pre-push origin "$repo" 2>&1)"; then
  fail "expected main deletion to be rejected"
fi
[[ "$deletion_out" == *"deleting main is not allowed"* ]] ||
  fail "main deletion bypassed the hook: $deletion_out"

advertised_remote="$TMP/advertised.git"
git init -q --bare "$advertised_remote"
git -C "$repo" push -q "$advertised_remote" "$base_oid:refs/heads/main"
git -C "$repo" update-ref refs/remotes/origin/forged "$tip_oid"
if advertised_out="$(printf 'refs/heads/feature/private %s refs/heads/feature/private %040d\n' "$tip_oid" 0 |
  "$repo/scripts/check-push-safety.sh" --pre-push origin "$advertised_remote" 2>&1)"; then
  fail "expected new-ref scan to ignore forged local tracking refs"
fi
[[ "$advertised_out" == *"boundary.txt@$private_oid"* ]] ||
  fail "new-ref scan trusted mutable tracking refs: $advertised_out"

hook_log="$TMP/existing-hook.log"
hook="$(git -C "$repo" rev-parse --git-path hooks/pre-push)"
case "$hook" in
  /*) ;;
  *) hook="$repo/$hook" ;;
esac
hook_dir="$(dirname "$hook")"
mkdir -p "$hook_dir"
cat > "$hook_dir/existing-helper" <<HOOK
printf 'existing\n' >> '$hook_log'
HOOK
cat > "$hook_dir/existing-hook-target" <<'HOOK'
#!/usr/bin/env bash
. "$(dirname "$0")/existing-helper"
cat >/dev/null
HOOK
chmod +x "$hook_dir/existing-hook-target"
ln -s existing-hook-target "$hook"

"$repo/scripts/check-push-safety.sh" --install-hook >/dev/null
(
  unset FBA_PUSH_SAFETY_POLICY_FILE
  "$repo/scripts/check-push-safety.sh" --install-hook >/dev/null
)
policy_pointer="$hook_dir/pre-push.d/45-push-safety-policy"
[[ "$(cat "$policy_pointer")" == "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$private_policy")" ]] ||
  fail "routine hook reinstall did not preserve the explicit private policy path"
printf 'refs/heads/feature/test %s refs/heads/feature/test %s\n' "$base_oid" "$base_oid" | "$hook" origin "$repo" >/dev/null
[[ "$(wc -l < "$hook_log" | tr -d ' ')" == "1" ]] ||
  fail "composed pre-push dispatcher did not preserve exactly one existing-hook invocation"
[[ -x "$(dirname "$hook")/pre-push.d/50-push-safety" ]] ||
  fail "push-safety hook component was not installed"
trusted_scanner="$hook_dir/pre-push.d/.push-safety/check-push-safety.sh"
trusted_allow="$hook_dir/pre-push.d/.push-safety/check-push-safety.allow"
[[ -x "$trusted_scanner" && -f "$trusted_allow" && ! -L "$trusted_scanner" && ! -L "$trusted_allow" ]] ||
  fail "trusted push-safety assets were not installed as regular files"
[[ -L "$hook_dir/pre-push.fba-existing" ]] ||
  fail "existing relative hook was not preserved beside its original path"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/scripts/check-push-safety.sh"
printf '%s\t%s\n' 'attack[.]txt:openai-secret' '.*' >> "$repo/scripts/check-push-safety.allow"
printf 'token=%s%s\n' 'sk-' 'cccccccccccccccccccccccccccccccc' > "$repo/attack.txt"
git -C "$repo" add scripts/check-push-safety.sh scripts/check-push-safety.allow attack.txt
git -C "$repo" commit -q -m "attempt scanner bypass"
attack_oid="$(git -C "$repo" rev-parse HEAD)"
if mutable_scanner_out="$(printf 'refs/heads/feature/test %s refs/heads/feature/test %s\n' "$attack_oid" "$tip_oid" |
  (cd "$repo" && "$hook" origin "$repo") 2>&1)"; then
  fail "outgoing scanner and allow-list changes bypassed the installed enforcement copy"
fi
[[ "$mutable_scanner_out" == *"attack.txt@$attack_oid"*"[openai-secret]"* ]] ||
  fail "trusted enforcement copy did not scan the malicious outgoing snapshot: $mutable_scanner_out"
git -C "$repo" reset -q --hard "$tip_oid"

capture_fail_bin="$TMP/capture-fail-bin"
mkdir -p "$capture_fail_bin"
cat > "$capture_fail_bin/cat" <<'STUB'
#!/usr/bin/env bash
exit 9
STUB
chmod +x "$capture_fail_bin/cat"
if capture_fail_out="$(printf 'refs/heads/feature/test %s refs/heads/feature/test %s\n' "$base_oid" "$base_oid" |
  PATH="$capture_fail_bin:$PATH" "$hook" origin "$repo" 2>&1)"; then
  fail "expected dispatcher input capture failure to block the push"
fi
[[ "$capture_fail_out" == *"failed to capture pre-push input"* ]] ||
  fail "dispatcher input capture failure was unclear: $capture_fail_out"

chmod -x "$hook_dir/pre-push.d/50-push-safety"
if missing_enforcement_out="$(printf 'refs/heads/feature/test %s refs/heads/feature/test %s\n' "$base_oid" "$base_oid" |
  "$hook" origin "$repo" 2>&1)"; then
  fail "expected a missing enforcement component to block the push"
fi
[[ "$missing_enforcement_out" == *"required enforcement hook is missing or not executable"* ]] ||
  fail "missing enforcement failure was unclear: $missing_enforcement_out"
chmod +x "$hook_dir/pre-push.d/50-push-safety"

rm "$hook_dir/pre-push.d/50-push-safety"
ln -s "$TMP/missing-enforcement" "$hook_dir/pre-push.d/50-push-safety"
if symlinked_component_out="$("$repo/scripts/check-push-safety.sh" --install-hook 2>&1)"; then
  fail "expected a dangling managed hook symlink to be rejected"
fi
[[ "$symlinked_component_out" == *"refusing symlinked managed hook component"* ]] ||
  fail "managed hook symlink failure was unclear: $symlinked_component_out"
rm "$hook_dir/pre-push.d/50-push-safety"
"$repo/scripts/check-push-safety.sh" --install-hook >/dev/null

mv "$private_policy" "$private_policy.saved"
if stale_policy_out="$(
  unset FBA_PUSH_SAFETY_POLICY_FILE
  "$repo/scripts/check-push-safety.sh" --install-hook 2>&1
)"; then
  fail "expected routine reinstall to reject an unreadable persisted policy"
fi
[[ "$stale_policy_out" == *"policy file is not readable"* ]] ||
  fail "persisted policy validation failure was unclear: $stale_policy_out"
mv "$private_policy.saved" "$private_policy"
(
  unset FBA_PUSH_SAFETY_POLICY_FILE
  FBA_PUSH_SAFETY_CLEAR_POLICY=1 "$repo/scripts/check-push-safety.sh" --install-hook >/dev/null
)
[[ ! -e "$policy_pointer" ]] || fail "explicit policy clear did not remove the persisted pointer"
"$repo/scripts/check-push-safety.sh" --install-hook >/dev/null

gate_repo="$TMP/gate-repo"
make_repo "$gate_repo"
gate_remote="$TMP/gate-remote.git"
git init -q --bare "$gate_remote"
git -C "$gate_repo" remote add origin "$gate_remote"
mkdir -p "$TMP/genuine" "$TMP/spoof"
ln -s /bin/bash "$TMP/genuine/no-mistakes"
ln -s /bin/sh "$TMP/spoof/no-mistakes"
PATH="$TMP/genuine:$PATH" "$gate_repo/scripts/check-push-safety.sh" --install-hook >/dev/null
gate_attestation="$(git -C "$gate_repo" rev-parse --git-path hooks/pre-push.d/40-no-mistakes.attestation)"
case "$gate_attestation" in
  /*) ;;
  *) gate_attestation="$gate_repo/$gate_attestation" ;;
esac
[[ ! -e "$gate_attestation" ]] || fail "PATH-first no-mistakes was enrolled without independent trust"
trusted_no_mistakes="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMP/genuine/no-mistakes")"
trusted_hash="$(sha256_file "$trusted_no_mistakes")"
if mismatched_trust_out="$(FBA_NO_MISTAKES_TRUSTED_PATH="$TMP/genuine/no-mistakes" \
  FBA_NO_MISTAKES_TRUSTED_SHA256="$(printf '0%.0s' {1..64})" \
  "$gate_repo/scripts/check-push-safety.sh" --install-hook 2>&1)"; then
  fail "expected a mismatched independent digest to be rejected"
fi
[[ "$mismatched_trust_out" == *"trusted no-mistakes digest does not match"* ]] ||
  fail "mismatched trust failure was unclear: $mismatched_trust_out"
FBA_NO_MISTAKES_TRUSTED_PATH="$TMP/genuine/no-mistakes" \
  FBA_NO_MISTAKES_TRUSTED_SHA256="$trusted_hash" \
  "$gate_repo/scripts/check-push-safety.sh" --install-hook >/dev/null
attestation_before="$(cat "$gate_attestation")"
"$gate_repo/scripts/check-push-safety.sh" --install-hook >/dev/null
[[ "$(cat "$gate_attestation")" == "$attestation_before" ]] ||
  fail "routine hook reinstall did not preserve no-mistakes trust"
printf '%s\t%s\n' "$trusted_no_mistakes" "$(printf '0%.0s' {1..64})" > "$gate_attestation"
if stale_trust_out="$("$gate_repo/scripts/check-push-safety.sh" --install-hook 2>&1)"; then
  fail "expected routine reinstall to reject stale persisted trust"
fi
[[ "$stale_trust_out" == *"trusted no-mistakes digest does not match"* ]] ||
  fail "persisted trust validation failure was unclear: $stale_trust_out"
printf '%s\n' "$attestation_before" > "$gate_attestation"
FBA_NO_MISTAKES_CLEAR_TRUST=1 "$gate_repo/scripts/check-push-safety.sh" --install-hook >/dev/null
[[ ! -e "$gate_attestation" ]] || fail "explicit trust clear did not remove the attestation"
FBA_NO_MISTAKES_TRUSTED_PATH="$TMP/genuine/no-mistakes" \
  FBA_NO_MISTAKES_TRUSTED_SHA256="$trusted_hash" \
  "$gate_repo/scripts/check-push-safety.sh" --install-hook >/dev/null
NO_MISTAKES_GATE=1 "$TMP/genuine/no-mistakes" -c \
  'git -C "$1" push -q origin HEAD:main; rc=$?; sleep 0.1; exit "$rc"' sh "$gate_repo" ||
  fail "pinned no-mistakes binary could not deliver main"

printf 'next\n' >> "$gate_repo/README.md"
git -C "$gate_repo" commit -qam next
if spoof_out="$(NO_MISTAKES_GATE=1 "$TMP/spoof/no-mistakes" -c \
  'git -C "$1" push origin HEAD:main; rc=$?; sleep 0.1; exit "$rc"' sh "$gate_repo" 2>&1)"; then
  fail "a different executable named no-mistakes spoofed gate provenance"
fi
[[ "$spoof_out" == *"main delivery requires the pinned no-mistakes binary"* ]] ||
  fail "spoofed gate failure was not attributed to provenance: $spoof_out"
NO_MISTAKES_GATE=1 "$TMP/genuine/no-mistakes" -c \
  'git -C "$1" push -q origin HEAD:main; rc=$?; sleep 0.1; exit "$rc"' sh "$gate_repo" ||
  fail "pinned no-mistakes binary could not deliver the updated main"

echo "push safety regression passed"
