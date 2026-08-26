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
  boundary-host '([A-Za-z0-9-]+\.)*restricted\.example\.invalid([^A-Za-z0-9.-]|$)' \
  boundary-marker '(^|[^A-Za-z0-9_-])EXTERNAL_POLICY_MARKER([^A-Za-z0-9_-]|$)' \
  > "$POLICY"

[ -f "$HOOK" ] || { echo "missing hook: $HOOK"; exit 1; }
[ -f "$CASES" ] || { echo "missing cases: $CASES"; exit 1; }

run_hook() {
  printf '%s' "$1" | jq -Rs '{tool_input:{command:.}}' | bash "$HOOK" 2>/dev/null || true
}

decision() {
  if [ -z "$1" ]; then
    printf 'allow\n'
  else
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision'
  fi
}

without_policy=$(printf '%s' \
  'gh pr comment 1 --repo Example-Org/repo --body EXTERNAL_POLICY_MARKER' \
  | jq -Rs '{tool_input:{command:.}}' \
  | HOME="$TEST_TMP/empty-home" bash "$HOOK" 2>/dev/null || true)
[ -z "$without_policy" ] || {
  echo "FAIL optional default policy blocked when absent"
  exit 1
}

default_dir="$TEST_TMP/config/fba"
mkdir -p "$default_dir"
cp "$POLICY" "$default_dir/push-safety-policy.tsv"
with_default=$(
  XDG_CONFIG_HOME="$TEST_TMP/config" run_hook \
    'gh pr comment 1 --repo Example-Org/repo --body EXTERNAL_POLICY_MARKER'
)
[ "$(decision "$with_default")" = deny ] || {
  echo "FAIL guard did not load the portable default policy"
  exit 1
}

explicit_missing=$(
  FBA_PUSH_SAFETY_POLICY_FILE="$TEST_TMP/missing.tsv" run_hook \
    'gh pr comment 1 --repo Example-Org/repo --body public'
)
[ "$(decision "$explicit_missing")" = deny ] || {
  echo "FAIL explicitly configured missing policy did not fail closed"
  exit 1
}

unreadable_policy="$TEST_TMP/unreadable.tsv"
cp "$POLICY" "$unreadable_policy"
chmod 000 "$unreadable_policy"
explicit_unreadable=$(
  FBA_PUSH_SAFETY_POLICY_FILE="$unreadable_policy" run_hook \
    'gh pr comment 1 --repo Example-Org/repo --body public'
)
chmod 600 "$unreadable_policy"
[ "$(decision "$explicit_unreadable")" = deny ] || {
  echo "FAIL explicitly configured unreadable policy did not fail closed"
  exit 1
}

required_missing=$(
  HOME="$TEST_TMP/required-home" FBA_PUSH_SAFETY_POLICY_REQUIRED=1 run_hook \
    'gh pr comment 1 --repo Example-Org/repo --body public'
)
[ "$(decision "$required_missing")" = deny ] || {
  echo "FAIL required default policy did not fail closed"
  exit 1
}

request_file="$TEST_TMP/request.json"
printf '{"body":"EXTERNAL_POLICY_MARKER"}\n' > "$request_file"
for input_arg in "--input $request_file" "--input=$request_file"; do
  out=$(
    FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" run_hook \
      "gh api /repos/Example-Org/repo/issues/1 $input_arg"
  )
  [ "$(decision "$out")" = deny ] || {
    echo "FAIL gh api $input_arg did not scan its request file"
    exit 1
  }
done

stdin_out=$(
  FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" run_hook \
    'gh api /repos/Example-Org/repo/issues/1 --input -'
)
[ "$(decision "$stdin_out")" = deny ] || {
  echo "FAIL gh api --input - did not fail closed"
  exit 1
}
reviewed_stdin=$(FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" run_hook \
  'PUBLIC_POST_REVIEWED=1 gh api /repos/Example-Org/repo/issues/1 --input -')
[ "$(decision "$reviewed_stdin")" = allow ] || {
  echo "FAIL reviewed gh api --input - was not allowed"
  exit 1
}
ambient_review=$(
  PUBLIC_POST_REVIEWED=1 FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" run_hook \
    'gh api /repos/Example-Org/repo/issues/1 --input -'
)
[ "$(decision "$ambient_review")" = deny ] || {
  echo "FAIL ambient PUBLIC_POST_REVIEWED disabled more than one command"
  exit 1
}
continued_command=$'gh api -X POST /repos/Example-Org/repo/issues \\\n  -f body=EXTERNAL_POLICY_MARKER'
continued_out=$(FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" run_hook "$continued_command")
[ "$(decision "$continued_out")" = deny ] || {
  echo "FAIL escaped-newline gh publish bypassed inspection"
  exit 1
}

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
    | FBA_PUSH_SAFETY_POLICY_FILE="$POLICY" bash "$HOOK" 2>/dev/null || true)
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
