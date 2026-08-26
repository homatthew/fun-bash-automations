#!/bin/bash
# Self-test for public-repo-leak-guard.sh.
#
#   llm/hooks/tests/run-tests.sh
#
# Each case is "want|command" where want is allow or deny. A guard that blocks
# legitimate work gets disabled wholesale, so the allow cases matter as much as
# the deny ones.
set -u

HOOK="$(cd "$(dirname "$0")/.." && pwd)/public-repo-leak-guard.sh"
CASES="$(dirname "$0")/public-repo-leak-guard-cases.txt"
TEST_TMP="$(mktemp -d)"
POLICY="$TEST_TMP/policy.tsv"
trap 'rm -rf "$TEST_TMP"' EXIT

printf '%s\t%s\n' \
  private-domain '([A-Za-z0-9-]+\.)*corp\.example([^A-Za-z0-9.-]|$)' \
  private-system '(^|[^A-Za-z0-9_-])private_service([^A-Za-z0-9_-]|$)' \
  > "$POLICY"

[ -f "$HOOK" ] || { echo "missing hook: $HOOK"; exit 1; }
[ -f "$CASES" ] || { echo "missing cases: $CASES"; exit 1; }

pass=0
fail=0
# Read the cases up front. The hook reads its JSON from stdin, so it must not
# share stdin with the loop -- and redirecting the hook's stdin to /dev/null to
# avoid that would starve it of the very input under test.
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  want=${line%%|*}
  cmd=${line#*|}
  out=$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' \
    | PUBLIC_REPO_LEAK_POLICY_FILE="$POLICY" bash "$HOOK" 2>/dev/null || true)
  if [ -z "$out" ]; then
    got=allow
  else
    got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')
  fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL want=%-5s got=%-5s %s\n' "$want" "$got" "$cmd"
  fi
done < <(cat "$CASES")

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
