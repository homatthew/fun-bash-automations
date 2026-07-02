#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-push-safety-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

printf 'token=%s%s\n' 'sk-' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$repo/secrets.txt"
git -C "$repo" add secrets.txt
printf 'token=redacted\n' > "$repo/secrets.txt"

if staged_out="$("$repo/scripts/check-push-safety.sh" --staged 2>&1)"; then
  fail "expected staged scan to catch the indexed secret"
fi
[[ "$staged_out" == *"LEAK  secrets.txt:1  [openai-secret]"* ]] ||
  fail "staged scan did not report the indexed secret with the expected path/line: $staged_out"

all_out="$("$repo/scripts/check-push-safety.sh" 2>&1)" ||
  fail "expected full-tree scan of the safe worktree to pass, got: $all_out"
[[ "$all_out" == *"push-safety scan clean (all)"* ]] ||
  fail "full-tree scan did not report clean state: $all_out"

git -C "$repo" reset -q --hard HEAD
linked="$TMP/linked"
git -C "$repo" worktree add -q "$linked" -b linked-test
"$linked/scripts/check-push-safety.sh" --install-hook >/tmp/fba-push-safety-hook.out
hook="$(git -C "$linked" rev-parse --git-path hooks/pre-push)"
[[ -x "$hook" ]] || fail "expected executable linked-worktree pre-push hook at $hook"

echo "push safety regression passed"
