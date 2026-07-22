#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/llm/hooks/permission-allow.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_hook() {
  jq -n --arg command "$1" '{tool_name:"Bash",tool_input:{command:$command}}' | "$HOOK"
}

expect_allow() {
  local output
  output="$(run_hook "$1")"
  [[ "$output" == *'"behavior":"allow"'* ]] || fail "expected allow for [$1], got: $output"
}

expect_prompt() {
  local output
  output="$(run_hook "$1")"
  [[ "$output" == '{}' ]] || fail "expected normal prompt for [$1], got: $output"
}

expect_allow 'yq . config.yml'
expect_prompt 'yq -i . config.yml'
expect_prompt 'yq --in-place . config.yml'
expect_allow 'sed -E s/a/b/ file.txt'
expect_prompt 'sed -Ei.bak s/a/b/ file.txt'
expect_prompt 'sed --in-place=.bak s/a/b/ file.txt'
expect_allow 'git symbolic-ref --short HEAD'
expect_prompt 'git symbolic-ref HEAD refs/heads/main'
expect_prompt 'git symbolic-ref --delete HEAD'
expect_allow 'git reflog show HEAD'
expect_allow 'git reflog exists refs/heads/main'
expect_prompt 'git reflog expire --all'
expect_prompt 'git reflog delete HEAD@{0}'
expect_allow 'git branch --list feature/*'
expect_prompt 'git branch new-feature'
expect_prompt 'git branch --force new-feature HEAD'
expect_prompt 'rg --pre ./transform pattern .'
expect_prompt 'fd -x rm {}'
expect_prompt 'fd -xrm {}'
expect_prompt 'fd --exec=rm {}'
expect_prompt 'find . -fprintf output.txt %p'
expect_prompt 'find . -fls output.txt'
expect_prompt "sed 'w output.txt' file.txt"
expect_prompt "sed 's/a/b/e' file.txt"
expect_prompt "awk 'BEGIN { system (\"touch output\") }' file.txt"
expect_prompt "awk -f payload.awk input.txt"
expect_prompt 'awk '\''{ print $1 }'\'' input.txt'
expect_allow 'date +%s'
expect_prompt 'date --set 2026-01-01'
expect_allow 'hostname'
expect_prompt 'hostname replacement-name'
expect_allow 'git status --short --branch'
expect_prompt 'git log --oneline -5'
expect_prompt 'git diff --stat HEAD~1'
expect_prompt 'git diff --output=review.patch HEAD~1'
expect_prompt 'git diff --ext-diff HEAD~1'
expect_prompt 'git grep --open-files-in-pager=helper pattern'
expect_prompt 'git grep -Ohelper pattern'
expect_prompt 'git ls-remote -u helper origin'
expect_prompt 'git cat-file --filters HEAD:file.txt'
expect_prompt 'GIT_EXTERNAL_DIFF=helper git diff HEAD~1'
expect_prompt 'PATH=/tmp git status'
expect_prompt '/tmp/git status'

echo "permission allow regression passed"
