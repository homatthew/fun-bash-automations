#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/llm/hooks/bash-safety-guard.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bash-safety-guard-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
export SSH_LEASE_FILE="$TEST_TMP/ssh-leases"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected output to contain [$needle], got: $haystack"
  fi
}

run_guard() {
  local command="$1"
  jq -n --arg command "$command" '{tool_input:{command:$command}}' | bash "$GUARD"
}

write_payload() {
  local path="$1"
  local files_json="$2"
  jq -n --argjson files "$files_json" '{files:$files}' >"$path"
}

echo "1..35"

blocked_output=$(run_guard "gh api /gists --method POST --input payload.json")
expect_contains "$blocked_output" "must target Netflix GHE explicitly"
echo "ok 1 - bare gh api gist creation is blocked"

env_allow=$(run_guard "GH_HOST=git.netflix.net gh api /gists --method POST --input payload.json")
[[ -z "$env_allow" ]] || fail "expected inline GH_HOST gist creation to be allowed, got: $env_allow"
echo "ok 2 - inline GH_HOST gist creation is allowed"

hostname_allow=$(run_guard "gh api --hostname git.netflix.net /gists --method POST --input payload.json")
[[ -z "$hostname_allow" ]] || fail "expected --hostname gist creation to be allowed, got: $hostname_allow"
echo "ok 3 - --hostname gist creation is allowed"

read_allow=$(run_guard "gh api /gists/example-id")
[[ -z "$read_allow" ]] || fail "expected gist read to be allowed, got: $read_allow"
echo "ok 4 - gist reads stay allowed"

wrong_host_inline=$(run_guard "GH_HOST=github.netflix.net gh pr list")
expect_contains "$wrong_host_inline" "Use GH_HOST=git.netflix.net"
echo "ok 5 - wrong github.netflix.net GH_HOST is blocked inline"

wrong_host_export=$(run_guard "export GH_HOST=github.netflix.net && gh api /user")
expect_contains "$wrong_host_export" "Use GH_HOST=git.netflix.net"
echo "ok 6 - wrong github.netflix.net GH_HOST is blocked after export"

gist_cli_allow=$(run_guard "GH_HOST=git.netflix.net gh gist create 01_diagram.py 02_architecture.png 03_README.md --desc \"ordered files\"")
[[ -z "$gist_cli_allow" ]] || fail "expected ordered gh gist create files to be allowed, got: $gist_cli_allow"
echo "ok 7 - ordered gh gist create files are allowed"

gist_cli_block=$(run_guard "GH_HOST=git.netflix.net gh gist create diagram.py 02_architecture.png README.md --desc \"unordered files\"")
expect_contains "$gist_cli_block" "gist uploads must use contiguous ordered filenames"
echo "ok 8 - unordered gh gist create files are blocked"

ordered_payload="$TEST_TMP/ordered-gist.json"
unordered_payload="$TEST_TMP/unordered-gist.json"
write_payload "$ordered_payload" '{"01_summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'
write_payload "$unordered_payload" '{"summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'

payload_allow=$(run_guard "GH_HOST=git.netflix.net gh api /gists --method POST --input $ordered_payload")
[[ -z "$payload_allow" ]] || fail "expected ordered gist payload keys to be allowed, got: $payload_allow"
echo "ok 9 - ordered gist payload keys are allowed"

payload_block=$(run_guard "GH_HOST=git.netflix.net gh api /gists --method POST --input $unordered_payload")
expect_contains "$payload_block" "gist uploads must use contiguous ordered filenames"
echo "ok 10 - unordered gist payload keys are blocked"

main_tracking_block=$(run_guard "git branch -u upstream/main")
expect_contains "$main_tracking_block" "must not track origin/main or upstream/main"
echo "ok 11 - setting a feature branch upstream to upstream/main is blocked"

main_track_create_block=$(run_guard "git branch --track mho/trunk/scm-cassandra-dev upstream/main")
expect_contains "$main_track_create_block" "would track origin/main or upstream/main"
echo "ok 12 - creating a branch that tracks upstream/main is blocked"

config_read_allow=$(run_guard "git config --get remote.origin.url")
[[ -z "$config_read_allow" ]] || fail "expected read-only git config to be allowed, got: $config_read_allow"
echo "ok 13 - read-only git config is allowed"

config_rerere_allow=$(run_guard "git config --local rerere.enabled true")
[[ -z "$config_rerere_allow" ]] || fail "expected local rerere.enabled=true to be allowed, got: $config_rerere_allow"
echo "ok 14 - local rerere.enabled=true is allowed"

config_rerere_c_allow=$(run_guard "git -C /tmp/repo config --local rerere.autoupdate true")
[[ -z "$config_rerere_c_allow" ]] || fail "expected git -C local rerere.autoupdate=true to be allowed, got: $config_rerere_c_allow"
echo "ok 15 - git -C local rerere.autoupdate=true is allowed"

config_global_block=$(run_guard "git config --global rerere.enabled true")
expect_contains "$config_global_block" "git config mutations are not allowed"
echo "ok 16 - global git config mutation is blocked"

config_system_block=$(run_guard "git config --system rerere.enabled true")
expect_contains "$config_system_block" "git config mutations are not allowed"
echo "ok 17 - system git config mutation is blocked"

config_rerere_false_block=$(run_guard "git config --local rerere.enabled false")
expect_contains "$config_rerere_false_block" "git config mutations are not allowed"
echo "ok 18 - disabling local rerere is blocked"

config_unset_block=$(run_guard "git config --unset rerere.enabled")
expect_contains "$config_unset_block" "git config mutations are not allowed"
echo "ok 19 - git config unset is blocked"

config_arbitrary_block=$(run_guard "git config --local core.hooksPath /tmp/hooks")
expect_contains "$config_arbitrary_block" "git config mutations are not allowed"
echo "ok 20 - arbitrary local git config mutation is blocked"

config_chained_block=$(run_guard "true; git config --global rerere.enabled true")
expect_contains "$config_chained_block" "git config mutations are not allowed"
echo "ok 21 - chained global git config mutation is blocked"

config_chained_after_allow_block=$(run_guard "git config --local rerere.enabled true; git config --global rerere.enabled true")
expect_contains "$config_chained_after_allow_block" "git config mutations are not allowed"
echo "ok 22 - chained git config mutation after allowed rerere is blocked"

ssh_option_block=$(run_guard "ssh -o LogLevel=ERROR nfcassandra-node.example uptime")
expect_contains "$ssh_option_block" "ssh to 'nfcassandra-node.example' requires a lease"
echo "ok 23 - ssh option parsing reports the target host"

ssh_strict_no_block=$(run_guard "ssh -o StrictHostKeyChecking=no nfcassandra-node.example uptime")
expect_contains "$ssh_strict_no_block" "unsafe SSH host-key option"
echo "ok 24 - ssh StrictHostKeyChecking=no is blocked"

future_expiry=$(( $(date +%s) + 3600 ))
printf 'nfcassandra-node.example %s\n' "$future_expiry" >"$SSH_LEASE_FILE"

ssh_option_allow=$(run_guard "ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR nfcassandra-node.example uptime")
[[ -z "$ssh_option_allow" ]] || fail "expected ssh with safe options and leased host to be allowed, got: $ssh_option_allow"
echo "ok 25 - ssh lease matches host after safe options"

ssh_known_hosts_null_block=$(run_guard "ssh -o UserKnownHostsFile=/dev/null nfcassandra-node.example uptime")
expect_contains "$ssh_known_hosts_null_block" "unsafe SSH host-key option"
echo "ok 26 - ssh UserKnownHostsFile=/dev/null is blocked"

ssh_user_host_allow=$(run_guard "ssh -p 22 cassandra@nfcassandra-node.example 'ls /ebs/cassandra/data'")
[[ -z "$ssh_user_host_allow" ]] || fail "expected ssh user@host to match host lease, got: $ssh_user_host_allow"
echo "ok 27 - ssh user@host normalizes to host lease"

scp_env_lease_allow=$(run_guard "scp cassandra@nfcassandra-node.example:/tmp/schema.cql $TEST_TMP/schema.cql")
[[ -z "$scp_env_lease_allow" ]] || fail "expected scp to use configured lease file, got: $scp_env_lease_allow"
echo "ok 28 - scp uses shared ssh lease helper"

ssh_search_allow=$(run_guard "rg -n ssh llm/hooks/bash-safety-guard.sh")
[[ -z "$ssh_search_allow" ]] || fail "expected local rg search for ssh text to be allowed, got: $ssh_search_allow"
echo "ok 29 - local search containing ssh text is not treated as remote access"

pilgrim_config_dir="$TEST_TMP/pilgrim/i-06d1de1f25c667a62"
mkdir -p "$pilgrim_config_dir"
pilgrim_config="$pilgrim_config_dir/config.nodelete"
cat >"$pilgrim_config" <<'EOF'
Host ignored
  Hostname 100.94.160.30
  User matthewho
EOF
pilgrim_block=$(run_guard "ssh -F $pilgrim_config matthewho@ignored uptime")
expect_contains "$pilgrim_block" "ssh to 'i-06d1de1f25c667a62' requires a lease"
expect_contains "$pilgrim_block" "ssh-gate i-06d1de1f25c667a62"
if [[ "$pilgrim_block" == *"ssh-gate ignored"* ]]; then
  fail "expected Pilgrim placeholder host not to suggest ssh-gate ignored: $pilgrim_block"
fi
printf 'i-06d1de1f25c667a62 %s\n' "$future_expiry" >"$SSH_LEASE_FILE"
pilgrim_allow=$(run_guard "ssh -F $pilgrim_config matthewho@ignored uptime")
[[ -z "$pilgrim_allow" ]] || fail "expected Pilgrim placeholder SSH to match instance-id lease, got: $pilgrim_allow"
echo "ok 30 - Pilgrim placeholder SSH config suggests and accepts instance-id lease"

fba_pr_create_block=$(run_guard "gh pr create --base main --head mh-netflix --title nope")
expect_contains "$fba_pr_create_block" "fun-bash-automations uses mh-netflix as the delivery branch"
echo "ok 31 - fun-bash-automations gh pr create is blocked"

fba_pr_ready_block=$(run_guard "gh -R homatthew/fun-bash-automations pr ready 3")
expect_contains "$fba_pr_ready_block" "Do not create, reopen, or mark ready PRs"
echo "ok 32 - fun-bash-automations gh pr ready is blocked with explicit repo"

fba_pr_reopen_block=$(run_guard "gh pr reopen --repo=homatthew/fun-bash-automations 3")
expect_contains "$fba_pr_reopen_block" "Do not create, reopen, or mark ready PRs"
echo "ok 33 - fun-bash-automations gh pr reopen is blocked with repo flag"

fba_pr_view_allow=$(run_guard "gh pr view 3 --json number")
[[ -z "$fba_pr_view_allow" ]] || fail "expected fun-bash-automations gh pr view to be allowed, got: $fba_pr_view_allow"
echo "ok 34 - fun-bash-automations gh pr view stays allowed"

other_pr_create_allow=$(run_guard "gh -R homatthew/other-repo pr create --base main --head feature")
[[ -z "$other_pr_create_allow" ]] || fail "expected non-FBA gh pr create to be allowed by this guard, got: $other_pr_create_allow"
echo "ok 35 - non-FBA gh pr create is not blocked by FBA-specific rule"
