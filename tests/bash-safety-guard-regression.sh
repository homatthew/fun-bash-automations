#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/llm/hooks/bash-safety-guard.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bash-safety-guard-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
export SSH_LEASE_FILE="$TEST_TMP/ssh-leases"
export SSH_COMMAND_LEASE_FILE="$TEST_TMP/ssh-command-leases"
export BASH_SAFETY_GUARD_EXTENSION_DIRS="$TEST_TMP/bash-safety-guard.d"
export PG_AGENT_PUSH_POLICY_OVERLAY="$TEST_TMP/no-private-overlay.json"

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

run_guard_in() {
  local repo="$1"
  local command="$2"
  (
    cd "$repo"
    jq -n --arg command "$command" '{tool_input:{command:$command}}' | bash "$GUARD"
  )
}

run_guard_with_workdir() {
  local repo="$1"
  local command="$2"
  (
    cd "$TEST_TMP"
    jq -n --arg command "$command" --arg workdir "$repo" \
      '{tool_input:{command:$command, workdir:$workdir}}' | bash "$GUARD"
  )
}

run_guard_with_parameters_workdir() {
  local repo="$1"
  local command="$2"
  (
    cd "$TEST_TMP"
    jq -n --arg command "$command" --arg workdir "$repo" \
      '{tool_input:{command:$command}, parameters:{workdir:$workdir}}' | bash "$GUARD"
  )
}

write_payload() {
  local path="$1"
  local files_json="$2"
  jq -n --argjson files "$files_json" '{files:$files}' >"$path"
}

write_command_lease() {
  local host="$1"
  local expiry="$2"
  shift 2
  python3 - "$host" "$expiry" "$@" >>"$SSH_COMMAND_LEASE_FILE" <<'PY'
import hashlib
import shlex
import sys

host = sys.argv[1]
expiry = sys.argv[2]
joined = " ".join(sys.argv[3:])
tokens = shlex.split(joined, posix=True)
canonical = " ".join(shlex.quote(token) for token in tokens)
digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
print(f"{digest}\t{expiry}\t{host}\t{canonical}")
PY
}

echo "1..144"

read_allow=$(run_guard "gh api /gists/example-id")
[[ -z "$read_allow" ]] || fail "expected gist read to be allowed, got: $read_allow"
echo "ok 1 - gist reads stay allowed"

gist_cli_allow=$(run_guard "GH_HOST=example.test gh gist create 01_diagram.py 02_architecture.png 03_README.md --desc \"ordered files\"")
[[ -z "$gist_cli_allow" ]] || fail "expected explicitly hosted ordered gh gist create files to be allowed, got: $gist_cli_allow"
gist_cli_flag_allow=$(run_guard "gh --hostname example.test gist create 01_diagram.py 02_architecture.png 03_README.md --desc \"ordered files\"")
[[ -z "$gist_cli_flag_allow" ]] || fail "expected --hostname ordered gh gist create files to be allowed, got: $gist_cli_flag_allow"
echo "ok 2 - explicitly hosted ordered gh gist create files are allowed"

gist_cli_block=$(run_guard "GH_HOST=example.test gh gist create diagram.py 02_architecture.png README.md --desc \"unordered files\"")
expect_contains "$gist_cli_block" "gist uploads must use contiguous ordered filenames"
echo "ok 3 - unordered gh gist create files are blocked"

ordered_payload="$TEST_TMP/ordered-gist.json"
unordered_payload="$TEST_TMP/unordered-gist.json"
write_payload "$ordered_payload" '{"01_summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'
write_payload "$unordered_payload" '{"summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'

payload_allow=$(run_guard "GH_HOST=example.test gh api /gists --method POST --input $ordered_payload")
[[ -z "$payload_allow" ]] || fail "expected ordered gist payload keys to be allowed, got: $payload_allow"
echo "ok 4 - ordered gist payload keys are allowed"

payload_block=$(run_guard "GH_HOST=example.test gh api /gists --method POST --input $unordered_payload")
expect_contains "$payload_block" "gist uploads must use contiguous ordered filenames"
echo "ok 5 - unordered gist payload keys are blocked"

main_tracking_block=$(run_guard "git branch -u upstream/main feature/feature")
expect_contains "$main_tracking_block" "may only track a mirrored remote branch name"
echo "ok 15 - setting a feature branch upstream to upstream/main is blocked"

main_track_create_block=$(run_guard "git branch --track feature/service-dev upstream/main")
expect_contains "$main_track_create_block" "may only track a mirrored remote branch name"
echo "ok 16 - creating a branch that tracks upstream/main is blocked"

release_main_tracking_block=$(run_guard "git branch -u origin/release/main feature/feature")
expect_contains "$release_main_tracking_block" "may only track a mirrored remote branch name"
echo "ok 17 - setting a feature branch upstream to origin/release/main is blocked"

release_main_checkout_block=$(run_guard "git checkout -b feature/kv-cleanup origin/release/main")
expect_contains "$release_main_checkout_block" "may only track a mirrored remote branch name"
echo "ok 18 - creating a branch from release/main without --no-track is blocked"

worktree_main_block=$(run_guard "git worktree add -b feature/oodm-capacity-planner /tmp/oodm origin/main")
expect_contains "$worktree_main_block" "may only track a mirrored remote branch name"
echo "ok 19 - creating a worktree branch from origin/main without --no-track is blocked"

worktree_main_chained_block=$(run_guard "mkdir -p /tmp/oodm && git -C /tmp/repo worktree add -b feature/oodm-capacity-planner /tmp/oodm origin/main")
expect_contains "$worktree_main_chained_block" "may only track a mirrored remote branch name"
echo "ok 20 - chained git -C worktree branch creation is blocked"

worktree_no_track_allow=$(run_guard "git worktree add --no-track -b feature/oodm-capacity-planner /tmp/oodm origin/main")
[[ -z "$worktree_no_track_allow" ]] || fail "expected worktree add --no-track to be allowed, got: $worktree_no_track_allow"
echo "ok 21 - worktree branch creation with --no-track is allowed"

config_read_allow=$(run_guard "git config --get remote.origin.url")
[[ -z "$config_read_allow" ]] || fail "expected read-only git config to be allowed, got: $config_read_allow"
echo "ok 22 - read-only git config is allowed"

config_rerere_allow=$(run_guard "git config --local rerere.enabled true")
[[ -z "$config_rerere_allow" ]] || fail "expected local rerere.enabled=true to be allowed, got: $config_rerere_allow"
echo "ok 23 - local rerere.enabled=true is allowed"

config_rerere_c_allow=$(run_guard "git -C /tmp/repo config --local rerere.autoupdate true")
[[ -z "$config_rerere_c_allow" ]] || fail "expected git -C local rerere.autoupdate=true to be allowed, got: $config_rerere_c_allow"
echo "ok 24 - git -C local rerere.autoupdate=true is allowed"

config_global_block=$(run_guard "git config --global rerere.enabled true")
expect_contains "$config_global_block" "git config mutations are not allowed"
echo "ok 25 - global git config mutation is blocked"

config_system_block=$(run_guard "git config --system rerere.enabled true")
expect_contains "$config_system_block" "git config mutations are not allowed"
echo "ok 26 - system git config mutation is blocked"

config_rerere_false_block=$(run_guard "git config --local rerere.enabled false")
expect_contains "$config_rerere_false_block" "git config mutations are not allowed"
echo "ok 27 - disabling local rerere is blocked"

config_unset_block=$(run_guard "git config --unset rerere.enabled")
expect_contains "$config_unset_block" "git config mutations are not allowed"
echo "ok 28 - git config unset is blocked"

config_arbitrary_block=$(run_guard "git config --local core.hooksPath /tmp/hooks")
expect_contains "$config_arbitrary_block" "git config mutations are not allowed"
echo "ok 29 - arbitrary local git config mutation is blocked"

config_chained_block=$(run_guard "true; git config --global rerere.enabled true")
expect_contains "$config_chained_block" "git config mutations are not allowed"
echo "ok 30 - chained global git config mutation is blocked"

config_chained_after_allow_block=$(run_guard "git config --local rerere.enabled true; git config --global rerere.enabled true")
expect_contains "$config_chained_after_allow_block" "git config mutations are not allowed"
echo "ok 31 - chained git config mutation after allowed rerere is blocked"

ssh_option_block=$(run_guard "ssh -o LogLevel=ERROR db-node.example uptime")
expect_contains "$ssh_option_block" "ssh to 'db-node.example' requires a lease"
echo "ok 32 - ssh option parsing reports the target host"

ssh_strict_no_block=$(run_guard "ssh -o StrictHostKeyChecking=no db-node.example uptime")
expect_contains "$ssh_strict_no_block" "unsafe SSH host-key option"
echo "ok 33 - ssh StrictHostKeyChecking=no is blocked"

future_expiry=$(( $(date +%s) + 3600 ))
printf 'db-node.example %s\n' "$future_expiry" >"$SSH_LEASE_FILE"

ssh_option_allow=$(run_guard "ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR db-node.example uptime")
[[ -z "$ssh_option_allow" ]] || fail "expected ssh with safe options and leased host to be allowed, got: $ssh_option_allow"
echo "ok 34 - ssh lease matches host after safe options"

ssh_known_hosts_null_block=$(run_guard "ssh -o UserKnownHostsFile=/dev/null db-node.example uptime")
expect_contains "$ssh_known_hosts_null_block" "unsafe SSH host-key option"
echo "ok 35 - ssh UserKnownHostsFile=/dev/null is blocked"

ssh_user_host_allow=$(run_guard "ssh -p 22 operator@db-node.example 'ls /var/lib/cassandra/data'")
[[ -z "$ssh_user_host_allow" ]] || fail "expected ssh user@host to match host lease, got: $ssh_user_host_allow"
echo "ok 36 - ssh user@host normalizes to host lease"

ssh_interactive_block=$(run_guard "ssh db-node.example")
expect_contains "$ssh_interactive_block" "interactive ssh without an explicit remote command"
echo "ok 37 - interactive ssh is blocked"

ssh_remote_sudo_block=$(run_guard "ssh db-node.example 'sudo systemctl restart database'")
expect_contains "$ssh_remote_sudo_block" "dangerous remote ssh command: sudo"
echo "ok 38 - remote ssh sudo is blocked"

ssh_remote_wrapper_block=$(run_guard "ssh db-node.example 'bash -c uptime'")
expect_contains "$ssh_remote_wrapper_block" "remote ssh shell/code wrapper is not allowed"
echo "ok 39 - remote ssh shell wrapper is blocked"

ssh_remote_cqlsh_block=$(run_guard "ssh db-node.example 'cqlsh -e \"select now() from system.local\"'")
expect_contains "$ssh_remote_cqlsh_block" "dangerous remote ssh command: cqlsh"
echo "ok 40 - remote ssh cqlsh is blocked"

# Single-PID remote kill. The permitted host list comes from
# BASH_SAFETY_GUARD_PID_KILL_HOSTS, which is empty in this baseline, so the test
# supplies its own example hosts rather than encoding private hostnames.
printf 'dev1.example %s\n' "$future_expiry" >>"$SSH_LEASE_FILE"
printf 'dev9.example %s\n' "$future_expiry" >>"$SSH_LEASE_FILE"

ssh_pid_kill_unconfigured_block=$(run_guard "ssh dev1.example 'kill 1497'")
expect_contains "$ssh_pid_kill_unconfigured_block" "dangerous remote ssh command: kill"
echo "ok 40a - with no configured hosts, every remote PID kill stays blocked"

export BASH_SAFETY_GUARD_PID_KILL_HOSTS="dev1.example:dev2.example"

ssh_pid_kill_allow=$(run_guard "ssh dev1.example 'kill 1497'")
[[ -z "$ssh_pid_kill_allow" ]] || fail "expected one numeric PID kill on a configured host to be allowed, got: $ssh_pid_kill_allow"
echo "ok 40b - one numeric PID kill is allowed on a configured host"

ssh_unlisted_pid_kill_block=$(run_guard "ssh dev9.example 'kill 1497'")
expect_contains "$ssh_unlisted_pid_kill_block" "dangerous remote ssh command: kill"
ssh_multi_pid_kill_block=$(run_guard "ssh dev1.example 'kill 1497 1498'")
expect_contains "$ssh_multi_pid_kill_block" "dangerous remote ssh command: kill"
ssh_init_kill_block=$(run_guard "ssh dev1.example 'kill 1'")
expect_contains "$ssh_init_kill_block" "dangerous remote ssh command: kill"
ssh_signal_kill_block=$(run_guard "ssh dev1.example 'kill -9 1497'")
expect_contains "$ssh_signal_kill_block" "dangerous remote ssh command: kill"
ssh_compound_kill_block=$(run_guard "ssh dev1.example 'kill 1497 && echo done'")
expect_contains "$ssh_compound_kill_block" "dangerous remote ssh command: kill"
ssh_pkill_block=$(run_guard "ssh dev1.example 'pkill java'")
expect_contains "$ssh_pkill_block" "dangerous remote ssh command: pkill"
echo "ok 40c - remote PID kill exception stays host-, process-, and command-scoped"

# str.isdigit() accepts non-ASCII digits. '²' passed it and then made int()
# raise, crashing the scan; because the caller reads only stdout, the crash was
# indistinguishable from "no violation" and skipped every remaining segment.
ssh_superscript_pid_block=$(run_guard "ssh dev1.example 'kill ²'")
[[ -n "$ssh_superscript_pid_block" ]] || fail "a non-ASCII PID must not be allowed"
ssh_arabic_pid_block=$(run_guard "ssh dev1.example 'kill ٣'")
[[ -n "$ssh_arabic_pid_block" ]] || fail "an Arabic-Indic digit PID must not be allowed"
ssh_fullwidth_pid_block=$(run_guard "ssh dev1.example 'kill １２３'")
[[ -n "$ssh_fullwidth_pid_block" ]] || fail "a full-width digit PID must not be allowed"
echo "ok 40d - only ASCII digits count as a PID"

# The load-bearing one: a crash on an early segment must not allow a later one.
ssh_crash_then_sudo_block=$(run_guard "ssh dev1.example 'kill ²' && ssh dev9.example 'sudo id'")
[[ -n "$ssh_crash_then_sudo_block" ]] || fail "a failed scan must fail closed, not allow a later sudo segment"
echo "ok 40e - the ssh scan fails closed instead of skipping later segments"

# remote_target() reads the positional destination, so an -o HostName override
# would otherwise present an allowlisted host while connecting elsewhere.
ssh_hostname_override_block=$(run_guard "ssh -o HostName=evil.example dev1.example 'kill 1497'")
[[ -n "$ssh_hostname_override_block" ]] || fail "an -o HostName override must void the PID-kill exemption"
ssh_hostname_joined_block=$(run_guard "ssh -oHostName=evil.example dev1.example 'kill 1497'")
[[ -n "$ssh_hostname_joined_block" ]] || fail "a joined -oHostName override must void the PID-kill exemption"
ssh_hostname_case_block=$(run_guard "ssh -o hostname=evil.example dev1.example 'kill 1497'")
[[ -n "$ssh_hostname_case_block" ]] || fail "-o hostname is case-insensitive and must void the exemption"
echo "ok 40f - a HostName override voids the host-scoped exemption"

# The exemption must still work for the plain case after all of the above.
ssh_still_allowed=$(run_guard "ssh dev1.example 'kill 1497'")
[[ -z "$ssh_still_allowed" ]] || fail "the plain single-PID kill must still be allowed, got: $ssh_still_allowed"
echo "ok 40g - the intended single-PID kill is still allowed"

unset BASH_SAFETY_GUARD_PID_KILL_HOSTS

ssh_remote_nodetool_repair_block=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool repair example_keyspace'")
expect_contains "$ssh_remote_nodetool_repair_block" "dangerous remote nodetool command: nodetool repair"
echo "ok 41 - remote ssh nodetool repair is blocked"

ssh_remote_nodetool_set_block=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool setstreamthroughput 1'")
expect_contains "$ssh_remote_nodetool_set_block" "dangerous remote nodetool command: nodetool setstreamthroughput"
echo "ok 42 - remote ssh nodetool set commands are blocked"

ssh_remote_toppartitions_block=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool toppartitions -a reads -k 100 -s 4096 example_keyspace example_table 60000'")
expect_contains "$ssh_remote_toppartitions_block" "requires an exact command lease"
echo "ok 43 - sensitive nodetool toppartitions requires exact command lease"

write_command_lease db-node.example "$future_expiry" "/opt/cassandra/bin/nodetool toppartitions -a reads -k 100 -s 4096 example_keyspace example_table 60000"
ssh_remote_toppartitions_allow=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool toppartitions -a reads -k 100 -s 4096 example_keyspace example_table 60000'")
[[ -z "$ssh_remote_toppartitions_allow" ]] || fail "expected leased nodetool toppartitions to be allowed, got: $ssh_remote_toppartitions_allow"
echo "ok 44 - exact command lease allows nodetool toppartitions"

ssh_remote_toppartitions_changed_block=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool toppartitions -a reads -k 200 -s 4096 example_keyspace example_table 60000'")
expect_contains "$ssh_remote_toppartitions_changed_block" "requires an exact command lease"
echo "ok 45 - changed sensitive command needs its own lease"

write_command_lease db-node.example "$future_expiry" "/opt/cassandra/bin/nodetool repair example_keyspace"
ssh_remote_repair_still_block=$(run_guard "ssh db-node.example '/opt/cassandra/bin/nodetool repair example_keyspace'")
expect_contains "$ssh_remote_repair_still_block" "dangerous remote nodetool command: nodetool repair"
echo "ok 46 - command lease cannot allow hard-blocked nodetool repair"

ssh_remote_jstack_block=$(run_guard "ssh db-node.example 'jstack 1234'")
expect_contains "$ssh_remote_jstack_block" "requires an exact command lease"
echo "ok 47 - remote jstack requires exact command lease"

write_command_lease db-node.example "$future_expiry" "jstack 1234"
ssh_remote_jstack_allow=$(run_guard "ssh db-node.example 'jstack 1234'")
[[ -z "$ssh_remote_jstack_allow" ]] || fail "expected leased jstack to be allowed, got: $ssh_remote_jstack_allow"
echo "ok 48 - exact command lease allows jstack"

scp_env_lease_allow=$(run_guard "scp operator@db-node.example:/tmp/schema.cql $TEST_TMP/schema.cql")
[[ -z "$scp_env_lease_allow" ]] || fail "expected scp to use configured lease file, got: $scp_env_lease_allow"
echo "ok 49 - scp uses shared ssh lease helper"

ssh_search_allow=$(run_guard "rg -n ssh llm/hooks/bash-safety-guard.sh")
[[ -z "$ssh_search_allow" ]] || fail "expected local rg search for ssh text to be allowed, got: $ssh_search_allow"
echo "ok 50 - local search containing ssh text is not treated as remote access"

ssh_config_dir="$TEST_TMP/ssh-config"
mkdir -p "$ssh_config_dir"
ssh_config="$ssh_config_dir/config"
cat >"$ssh_config" <<'EOF'
Host ignored
  Hostname resolved.example
  User operator
EOF
config_host_block=$(run_guard "ssh -F $ssh_config operator@ignored uptime")
expect_contains "$config_host_block" "ssh to 'resolved.example' requires a lease"
expect_contains "$config_host_block" "ssh-gate resolved.example"
if [[ "$config_host_block" == *"ssh-gate ignored"* ]]; then
  fail "expected placeholder host not to suggest ssh-gate ignored: $config_host_block"
fi
printf 'resolved.example %s\n' "$future_expiry" >"$SSH_LEASE_FILE"
config_host_allow=$(run_guard "ssh -F $ssh_config operator@ignored uptime")
[[ -z "$config_host_allow" ]] || fail "expected placeholder SSH to match resolved hostname lease, got: $config_host_allow"
echo "ok 51 - placeholder SSH config suggests and accepts resolved-host lease"

multi_ssh_unleased_block=$(run_guard "ssh resolved.example uptime; ssh unleased.example uptime")
expect_contains "$multi_ssh_unleased_block" "ssh to 'unleased.example' requires a lease"
echo "ok 51a - every SSH segment must have a host lease"

multi_ssh_sensitive_block=$(run_guard "ssh resolved.example uptime; ssh resolved.example 'jstack 1234'")
expect_contains "$multi_ssh_sensitive_block" "requires an exact command lease"
echo "ok 51b - later sensitive SSH segment needs its exact command lease"

fba_pr_create_block=$(run_guard "gh pr create --base main --head feature/nope --title nope")
expect_contains "$fba_pr_create_block" "fun-bash-automations uses main as its direct-push delivery branch"
echo "ok 52 - fun-bash-automations gh pr create is blocked"

fba_pr_ready_block=$(run_guard "gh -R example/fun-bash-automations pr ready 3")
expect_contains "$fba_pr_ready_block" "Do not create, reopen, or mark ready PRs"
echo "ok 53 - fun-bash-automations gh pr ready is blocked with explicit repo"

fba_pr_reopen_block=$(run_guard "gh pr reopen --repo=example/fun-bash-automations 3")
expect_contains "$fba_pr_reopen_block" "Do not create, reopen, or mark ready PRs"
echo "ok 54 - fun-bash-automations gh pr reopen is blocked with repo flag"

fba_pr_view_allow=$(run_guard "gh pr view 3 --json number")
[[ -z "$fba_pr_view_allow" ]] || fail "expected fun-bash-automations gh pr view to be allowed, got: $fba_pr_view_allow"
echo "ok 55 - fun-bash-automations gh pr view stays allowed"

other_pr_create_allow=$(run_guard "gh -R example/other-repo pr create --base main --head feature")
[[ -z "$other_pr_create_allow" ]] || fail "expected non-FBA gh pr create to be allowed by this guard, got: $other_pr_create_allow"
echo "ok 56 - non-FBA gh pr create is not blocked by FBA-specific rule"

gh_host_repo="$TEST_TMP/gh-host-repo"
git init -q "$gh_host_repo"
git -C "$gh_host_repo" remote add origin https://git.example.test/example/repo.git
wrong_gh_host_block=$(run_guard_in "$gh_host_repo" "GH_HOST=github.example.test gh pr create --base main --head feature")
expect_contains "$wrong_gh_host_block" "GH_HOST=github.example.test does not match this repository's origin host git.example.test"
expect_contains "$wrong_gh_host_block" "Omit GH_HOST and let gh derive the host from origin"
echo "ok 56a - mismatched GH_HOST is blocked with the repository-host hint"

plain_gh_host_allow=$(run_guard_in "$gh_host_repo" "gh pr create --base main --head feature")
[[ -z "$plain_gh_host_allow" ]] || fail "expected gh to derive the repository host, got: $plain_gh_host_allow"
echo "ok 56b - plain gh command relies on the repository remote"

matching_gh_host_allow=$(run_guard_in "$gh_host_repo" "GH_HOST=git.example.test gh pr create --base main --head feature")
[[ -z "$matching_gh_host_allow" ]] || fail "expected matching GH_HOST to be allowed, got: $matching_gh_host_allow"
echo "ok 56c - matching GH_HOST remains allowed"

cross_host_gist_allow=$(run_guard_in "$gh_host_repo" "GH_HOST=github.enterprise.test gh api /gists --method POST --input $ordered_payload")
[[ -z "$cross_host_gist_allow" ]] || fail "expected cross-host gist creation to be allowed, got: $cross_host_gist_allow"
echo "ok 56d - cross-host gh api gist creation remains allowed"

dotfiles_repo="$TEST_TMP/dotfiles"
git init -q "$dotfiles_repo"
git -C "$dotfiles_repo" remote add origin https://github.com/example/dotfiles.git
dotfiles_push_block=$(run_guard_with_workdir "$dotfiles_repo" "git push origin HEAD:main")
expect_contains "$dotfiles_push_block" "Deliver protected branches through no-mistakes"
echo "ok 57 - private repo delivery exceptions are not part of shared policy"

dotfiles_push_c_block=$(run_guard "git -C $dotfiles_repo push origin HEAD:main")
expect_contains "$dotfiles_push_c_block" "Deliver protected branches through no-mistakes"
echo "ok 58 - git -C does not restore a private delivery exception"

private_repo="$TEST_TMP/private-direct-repo"
git init -q "$private_repo"
git -C "$private_repo" checkout -q -b main
git -C "$private_repo" remote add origin https://git.example.test/example/private-direct-repo.git
private_overlay="$TEST_TMP/private-agent-push-policy-overlay.json"
jq -n '{
  version: 1,
  direct_push_exceptions: [{
    repo: "private-direct-repo",
    delivery_branch: "main",
    delivery_remote: "origin",
    requires_explicit_user_ask: true
  }]
}' > "$private_overlay"
private_push_allow=$(
  export PG_AGENT_PUSH_POLICY_OVERLAY="$private_overlay"
  run_guard_with_workdir "$private_repo" "git push origin main"
)
[[ -z "$private_push_allow" ]] || fail "expected private direct-delivery overlay to allow the exact push, got: $private_push_allow"
echo "ok 58a - private policy overlay adds an exact direct-delivery repository"

custom_xdg="$TEST_TMP/custom-xdg"
mkdir -p "$custom_xdg/fba"
cp "$private_overlay" "$custom_xdg/fba/agent-push-policy-overlay.json"
xdg_private_push_allow=$(
  unset PG_AGENT_PUSH_POLICY_OVERLAY
  export XDG_CONFIG_HOME="$custom_xdg"
  run_guard_with_workdir "$private_repo" "git push origin main"
)
[[ -z "$xdg_private_push_allow" ]] \
  || fail "expected the XDG policy overlay to allow the exact push, got: $xdg_private_push_allow"
echo "ok 58a1 - private policy overlay loads from the XDG config root"

printf '%s\n' '{"version":1,"direct_push_exceptions":"invalid"}' > "$TEST_TMP/malformed-private-overlay.json"
malformed_private_push_block=$(
  export PG_AGENT_PUSH_POLICY_OVERLAY="$TEST_TMP/malformed-private-overlay.json"
  run_guard_with_workdir "$private_repo" "git push origin main"
)
expect_contains "$malformed_private_push_block" "Deliver protected branches through no-mistakes"
echo "ok 58a2 - malformed private policy overlay fails closed"

dotfiles_bare_push_block=$(run_guard_with_workdir "$dotfiles_repo" "git push")
expect_contains "$dotfiles_bare_push_block" "bare git push is not allowed"
echo "ok 58b - dotfiles bare git push is blocked despite direct-push exception"

fba_repo="$TEST_TMP/fun-bash-automations"
git init -q "$fba_repo"
git -C "$fba_repo" checkout -q -b main
git -C "$fba_repo" remote add origin git@github.com:example/fun-bash-automations.git
guard_bin="$TEST_TMP/guard-bin"
mkdir -p "$guard_bin"
cat > "$guard_bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "${GUARD_GH_FAIL:-0}" == "0" ]] || exit 1
printf '%s\n' "${GUARD_GH_PRS:-[]}"
SH
chmod +x "$guard_bin/gh"
export PATH="$guard_bin:$PATH"
# This repository is listed in direct_push_exceptions with delivery_branch main,
# so an exact push of main is its sanctioned delivery path, not a violation.
# These assertions previously required the opposite; the policy file described
# the exception all along but no guard read it, which forced every change onto a
# long-lived branch.
fba_push_allow=$(run_guard_with_workdir "$fba_repo" "git push origin main")
[[ -z "$fba_push_allow" ]] || fail "expected the configured direct-delivery main push to be allowed, got: $fba_push_allow"
echo "ok 59 - configured fun-bash-automations main push is allowed"

fba_dashc_push_allow=$(run_guard "git -C $fba_repo push origin main")
[[ -z "$fba_dashc_push_allow" ]] || fail "expected explicit-directory FBA delivery to be allowed, got: $fba_dashc_push_allow"
echo "ok 59a - explicit-directory FBA main push resolves the target repository"

# The exception is branch-exact: other protected refs stay blocked here.
fba_master_block=$(run_guard_with_workdir "$fba_repo" "git push origin master")
expect_contains "$fba_master_block" "pushing directly to master is not allowed"
fba_develop_block=$(run_guard_with_workdir "$fba_repo" "git push origin develop")
expect_contains "$fba_develop_block" "pushing directly to develop is not allowed"
echo "ok 59a2 - the exception covers only the configured delivery branch"

# ...and it never permits a destructive form of that push.
fba_force_main_block=$(run_guard_with_workdir "$fba_repo" "git push --force origin main")
[[ -n "$fba_force_main_block" ]] || fail "expected a force push to main to stay blocked"
fba_lease_main_block=$(run_guard_with_workdir "$fba_repo" "git push --force-with-lease origin main")
[[ -n "$fba_lease_main_block" ]] || fail "expected a force-with-lease push to main to stay blocked"
fba_plus_main_block=$(run_guard_with_workdir "$fba_repo" "git push origin +main:main")
[[ -n "$fba_plus_main_block" ]] || fail "expected a leading-plus refspec to main to stay blocked"
fba_delete_main_block=$(run_guard_with_workdir "$fba_repo" "git push origin --delete main")
[[ -n "$fba_delete_main_block" ]] || fail "expected deleting remote main to stay blocked"
echo "ok 59a3 - destructive pushes to the delivery branch stay blocked"

# An unlisted repository gets no exception, even with the same branch name.
other_repo="$TEST_TMP/some-service"
git init -q "$other_repo"
git -C "$other_repo" checkout -q -b main
other_main_block=$(run_guard_with_workdir "$other_repo" "git push origin main")
expect_contains "$other_main_block" "pushing directly to main is not allowed"
echo "ok 59a4 - unlisted repositories still cannot push to main"

# Repo identity is resolved from the working directory, so a push that redirects
# which repository it acts on must not borrow this repository's exception.
fba_dashc_other_block=$(run_guard_with_workdir "$fba_repo" "git -C $other_repo push origin main")
expect_contains "$fba_dashc_other_block" "pushing directly to main is not allowed"
fba_gitdir_block=$(run_guard_with_workdir "$fba_repo" "git --git-dir=$other_repo/.git push origin main")
expect_contains "$fba_gitdir_block" "pushing directly to main is not allowed"
fba_worktree_block=$(run_guard_with_workdir "$fba_repo" "git --work-tree=$other_repo push origin main")
expect_contains "$fba_worktree_block" "pushing directly to main is not allowed"
echo "ok 59a5 - a directory-redirecting push cannot borrow the delivery exception"

# ...but the redirect check is scoped to the push segment. An unrelated `git -C`
# elsewhere in a compound command must not void the exception, or ordinary
# main-forward work becomes unpushable.
fba_unrelated_dashc_allow=$(run_guard_with_workdir "$fba_repo" "git push origin main; git -C $other_repo status")
[[ -z "$fba_unrelated_dashc_allow" ]] || fail "an unrelated git -C must not void the delivery exception, got: $fba_unrelated_dashc_allow"
fba_chained_allow=$(run_guard_with_workdir "$fba_repo" "git status && git push origin main && echo done")
[[ -z "$fba_chained_allow" ]] || fail "a chained delivery push must be allowed, got: $fba_chained_allow"
echo "ok 59a5b - the redirect check is scoped to the push segment"

# The exception is remote-exact: the delivery branch may only go to its
# configured remote.
fba_upstream_main_block=$(run_guard_with_workdir "$fba_repo" "git push upstream main")
expect_contains "$fba_upstream_main_block" "pushing directly to main is not allowed"
echo "ok 59a6 - the delivery branch cannot be pushed to an unconfigured remote"

fba_bare_push_block=$(run_guard_with_workdir "$fba_repo" "git push")
expect_contains "$fba_bare_push_block" "bare git push is not allowed"
echo "ok 59b - fun-bash-automations bare git push is blocked despite direct-push exception"

fba_main_refspec_block=$(run_guard_with_workdir "$fba_repo" "git push upstream HEAD:main")
expect_contains "$fba_main_refspec_block" "Deliver protected branches through no-mistakes"
fba_main_refspec_env_block=$(NO_MISTAKES_GATE=1 run_guard_with_workdir "$fba_repo" "git push upstream HEAD:main")
expect_contains "$fba_main_refspec_env_block" "Deliver protected branches through no-mistakes"
echo "ok 60 - FBA main delivery cannot be spoofed with a gate environment variable"

printf 'builder.work %s\n' "$future_expiry" >>"$SSH_LEASE_FILE"
dotwork_default_block=$(run_guard "ssh builder.work 'sudo systemctl restart test-service'")
expect_contains "$dotwork_default_block" "dangerous remote ssh command: sudo"
dotwork_pure_allow=$(
  export BASH_SAFETY_GUARD_TRUSTED_SSH_SUFFIXES=.work
  run_guard "ssh builder.work 'sudo systemctl restart test-service'"
)
[[ -z "$dotwork_pure_allow" ]] || fail "expected pure leased .work ssh to short-circuit, got: $dotwork_pure_allow"
echo "ok 60a - trusted SSH suffixes require explicit local configuration"

playground_hosts="$TEST_TMP/playground-ssh-hosts"
printf 'sandbox-a.example.test\nsandbox-b.example.test # comments are allowed\n' >"$playground_hosts"
playground_pkill_allow=$(
  export BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS_FILE="$playground_hosts"
  run_guard "ssh sandbox-a.example.test 'pkill -f worker-service'"
)
[[ -z "$playground_pkill_allow" ]] || fail "expected exact playground host to allow remote pkill without a lease, got: $playground_pkill_allow"
playground_killall_allow=$(
  export BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS="sandbox-a.example.test:sandbox-b.example.test"
  run_guard "ssh sandbox-b.example.test 'killall java'"
)
[[ -z "$playground_killall_allow" ]] || fail "expected environment-configured playground host to allow remote killall, got: $playground_killall_allow"
playground_lookalike_block=$(
  export BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS_FILE="$playground_hosts"
  run_guard "ssh not-sandbox-a.example.test 'pkill -f worker-service'"
)
expect_contains "$playground_lookalike_block" "dangerous remote ssh command: pkill"
playground_override_block=$(
  export BASH_SAFETY_GUARD_PLAYGROUND_SSH_HOSTS_FILE="$playground_hosts"
  run_guard "ssh -o HostName=prod.example sandbox-a.example.test 'pkill -f worker-service'"
)
expect_contains "$playground_override_block" "dangerous remote ssh command: pkill"
echo "ok 60a1 - exact playground SSH hosts bypass leases and remote command restrictions"

dotwork_compound_remote_block=$(run_guard "ssh builder.work 'sudo systemctl restart test-service'; printf done")
expect_contains "$dotwork_compound_remote_block" "dangerous remote ssh command: sudo"
echo "ok 60a2 - compound .work ssh does not bypass later guard checks"

dotwork_compound_push_block=$(run_guard_with_workdir "$fba_repo" "ssh builder.work uptime; git push origin master")
expect_contains "$dotwork_compound_push_block" "pushing directly to master is not allowed"
echo "ok 60a3 - compound .work ssh does not bypass push guard"

dotwork_multiline_push_block=$(run_guard_with_workdir "$fba_repo" $'ssh builder.work uptime\ngit push origin master')
expect_contains "$dotwork_multiline_push_block" "pushing directly to master is not allowed"
echo "ok 60a4 - newline-separated .work ssh does not bypass push guard"

# Shell redirections must not confuse push-target parsing (regression: shlex
# split "2>&1" into extra tokens that were counted as refspecs -> false
# "bare push" block).
fba_push_redir_allow=$(run_guard_with_workdir "$fba_repo" "git push origin feature/x 2>&1")
[[ -z "$fba_push_redir_allow" ]] || fail "expected feature push with 2>&1 to be allowed, got: $fba_push_redir_allow"
echo "ok 60b - git push of a feature branch with 2>&1 redirect is allowed"

fba_push_redir_pipe_allow=$(run_guard_with_workdir "$fba_repo" "git push origin feature/x 2>&1 | tail -5")
[[ -z "$fba_push_redir_pipe_allow" ]] || fail "expected feature push with 2>&1 | tail to be allowed, got: $fba_push_redir_pipe_allow"
echo "ok 60c - git push of a feature branch with 2>&1 | tail is allowed"

fba_main_redir_allow=$(NO_MISTAKES_GATE=1 run_guard_with_workdir "$fba_repo" "git push origin main 2>&1")
[[ -z "$fba_main_redir_allow" ]] || fail "expected a redirected direct-delivery main push to be allowed, got: $fba_main_redir_allow"
echo "ok 60d - redirected FBA main push is allowed as configured delivery"

quoted_push_text_allow=$(run_guard_with_workdir "$fba_repo" 'rg -n "git push no-mistakes" README.md')
[[ -z "$quoted_push_text_allow" ]] || fail "expected quoted git-push search text to be allowed, got: $quoted_push_text_allow"
echo "ok 60d2 - quoted git push text in a search command is not treated as a push"

# Multi-line scripts: a git push on its own line must be isolated (regression:
# newline-separated statements merged into one segment -> false 'bare push').
fba_multiline_feature=$(run_guard_with_workdir "$fba_repo" $'echo prep\ngit push origin feature/x')
[[ -z "$fba_multiline_feature" ]] || fail "expected multi-line feature push to be allowed, got: $fba_multiline_feature"
echo "ok 60e - git push on its own line in a multi-line script is allowed"

fba_multiline_main=$(NO_MISTAKES_GATE=1 run_guard_with_workdir "$fba_repo" $'echo prep\ngit push origin main')
[[ -z "$fba_multiline_main" ]] || fail "expected a multi-line direct-delivery main push to be allowed, got: $fba_multiline_main"
echo "ok 60f - multi-line FBA main push is allowed as configured delivery"

scratch_push_block=$(run_guard_with_workdir "$fba_repo" "git push origin wip/agent/checkpoint")
expect_contains "$scratch_push_block" "scratch branch pushes require Remote Scratch Mode"
echo "ok 60g - scratch branch push is blocked without Remote Scratch Mode"

scratch_push_agent_allow=$(
  export AGENT_WORK_MODE=remote_scratch
  run_guard_with_workdir "$fba_repo" "git push origin wip/agent/checkpoint"
)
[[ -z "$scratch_push_agent_allow" ]] || fail "expected AGENT_WORK_MODE remote_scratch scratch push to be allowed, got: $scratch_push_agent_allow"
echo "ok 60h - scratch branch push is allowed with AGENT_WORK_MODE=remote_scratch"

scratch_push_llm_allow=$(
  export LLM_AGENT_WORK_MODE=remote_scratch
  run_guard_with_workdir "$fba_repo" "git push origin scratch/agent/checkpoint"
)
[[ -z "$scratch_push_llm_allow" ]] || fail "expected LLM_AGENT_WORK_MODE remote_scratch scratch push to be allowed, got: $scratch_push_llm_allow"
echo "ok 60i - scratch branch push is allowed with LLM_AGENT_WORK_MODE=remote_scratch"

scratch_open_head_block=$(
  export AGENT_WORK_MODE=remote_scratch
  export GUARD_GH_PRS='[{"headRefName":"scratch/agent/checkpoint","baseRefName":"main"}]'
  run_guard_with_workdir "$fba_repo" "git push origin scratch/agent/checkpoint"
)
expect_contains "$scratch_open_head_block" "absent from open PR heads and bases"
echo "ok 60i2 - scratch branch push is blocked when it is an open PR head"

scratch_open_base_block=$(
  export AGENT_WORK_MODE=remote_scratch
  export GUARD_GH_PRS='[{"headRefName":"feature/work","baseRefName":"scratch/agent/base"}]'
  run_guard_with_workdir "$fba_repo" "git push origin scratch/agent/base"
)
expect_contains "$scratch_open_base_block" "absent from open PR heads and bases"
echo "ok 60i3 - scratch branch push is blocked when it is an open PR base"

scratch_pr_query_block=$(
  export AGENT_WORK_MODE=remote_scratch
  export GUARD_GH_FAIL=1
  run_guard_with_workdir "$fba_repo" "git push origin scratch/agent/checkpoint"
)
expect_contains "$scratch_pr_query_block" "absent from open PR heads and bases"
echo "ok 60i4 - scratch branch push fails closed when PR state is unavailable"

feature_delete_block=$(run_guard_with_workdir "$fba_repo" "git push origin --delete feature/feature")
expect_contains "$feature_delete_block" "deleting remote branches is only allowed for configured yolo branches"
echo "ok 60j - ordinary remote branch delete is blocked"

yolo_delete_block=$(run_guard_with_workdir "$fba_repo" "git push origin --delete yolo/quick")
expect_contains "$yolo_delete_block" "configured yolo branches on configured yolo remotes"
echo "ok 60k - disabled yolo remote branch delete is blocked"

yolo_delete_wrong_remote_block=$(run_guard_with_workdir "$fba_repo" "git push upstream --delete yolo/quick")
expect_contains "$yolo_delete_wrong_remote_block" "configured yolo branches on configured yolo remotes"
echo "ok 60l - yolo remote branch delete on unconfigured remote is blocked"

protected_delete_block=$(run_guard_with_workdir "$fba_repo" "git push origin --delete main")
expect_contains "$protected_delete_block" "deleting a protected branch"
echo "ok 60m - protected remote branch delete is blocked"

colon_yolo_delete_block=$(run_guard_with_workdir "$fba_repo" "git push origin :yolo/quick")
expect_contains "$colon_yolo_delete_block" "configured yolo branches on configured yolo remotes"
echo "ok 60n - colon-form disabled yolo remote branch delete is blocked"

fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/date" <<'EOF'
#!/bin/bash
if [[ "$1" == "-r" ]]; then
  exit 1
fi
if [[ "$1" == "-d" && "$2" == @* ]]; then
  printf 'GNU-FALLBACK\n'
  exit 0
fi
exec /bin/date "$@"
EOF
chmod +x "$fake_bin/date"
zsh_smoke_out=$(
  SSH_LEASE_FILE="$TEST_TMP/zsh-ssh-leases" \
  SSH_COMMAND_LEASE_FILE="$TEST_TMP/zsh-ssh-command-leases" \
  FBA_ROOT="$ROOT" \
  PATH="$fake_bin:$PATH" \
  zsh -fc '
    source "$FBA_ROOT/zsh/personal.zsh" >/dev/null 2>&1
    ssh-gate --hours 1 host-a host-b host.a
    ssh-command-gate --hours 1 host-a -- nodetool toppartitions ks tbl 100
    ssh-gate-revoke host.a
    ssh-gate-list
    ssh-command-gate-list
  '
)
expect_contains "$zsh_smoke_out" "GNU-FALLBACK"
expect_contains "$zsh_smoke_out" "SSH lease granted for host-a"
expect_contains "$zsh_smoke_out" "SSH command lease granted for host-a"
expect_contains "$zsh_smoke_out" "nodetool toppartitions ks tbl 100"
if grep -Fq "host.a " "$TEST_TMP/zsh-ssh-leases"; then
  fail "expected ssh-gate-revoke to remove literal host.a without regex matching"
fi
grep -Fq "host-a " "$TEST_TMP/zsh-ssh-leases" \
  || fail "expected ssh-gate-revoke host.a not to remove host-a"
echo "ok 61 - zsh ssh lease helpers use configured files and GNU date fallback"

# --- private guard extension contract ---
mkdir -p "$BASH_SAFETY_GUARD_EXTENSION_DIRS"
extension_absent_allow=$(run_guard "printf ok")
[[ -z "$extension_absent_allow" ]] || fail "expected empty extension dir to allow, got: $extension_absent_allow"
echo "ok 62 - empty bash-safety-guard extension dir allows"

cat > "$BASH_SAFETY_GUARD_EXTENSION_DIRS/block-test.sh" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$input")
if [[ "$command" == *private-block* ]]; then
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Blocked: private extension test"}}'
fi
EOF
chmod +x "$BASH_SAFETY_GUARD_EXTENSION_DIRS/block-test.sh"
extension_deny=$(run_guard "private-block")
expect_contains "$extension_deny" "private extension test"
trusted_extension_deny=$(
  export BASH_SAFETY_GUARD_TRUSTED_SSH_SUFFIXES=.work
  run_guard "ssh builder.work private-block"
)
expect_contains "$trusted_extension_deny" "private extension test"
extension_allow=$(run_guard "printf ok")
[[ -z "$extension_allow" ]] || fail "expected nonmatching extension to allow, got: $extension_allow"
echo "ok 63 - private guard extension can deny or allow"

cat > "$BASH_SAFETY_GUARD_EXTENSION_DIRS/invalid-test.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'not json'
EOF
chmod +x "$BASH_SAFETY_GUARD_EXTENSION_DIRS/invalid-test.sh"
extension_invalid=$(run_guard "printf ok")
expect_contains "$extension_invalid" "returned invalid output"
rm -f "$BASH_SAFETY_GUARD_EXTENSION_DIRS/invalid-test.sh"
echo "ok 64 - invalid guard extension output fails closed"

# --- disabled yolo branch class (yolo/) ---
yolo_checkout_base_block=$(run_guard "git checkout -b yolo/quick origin/main")
expect_contains "$yolo_checkout_base_block" "may only track a mirrored remote branch name"
echo "ok 65 - yolo checkout -b from origin/main without --no-track is blocked"

yolo_switch_base_block=$(run_guard "git switch -c yolo/quick origin/main")
expect_contains "$yolo_switch_base_block" "may only track a mirrored remote branch name"
echo "ok 66 - yolo switch -c from origin/main without --no-track is blocked"

yolo_branch_u_block=$(run_guard "git branch -u origin/main yolo/quick")
expect_contains "$yolo_branch_u_block" "may only track a mirrored remote branch name"
echo "ok 67 - setting upstream to origin/main is blocked (yolo cannot acquire base upstream)"

yolo_set_upstream_block=$(run_guard "git branch --set-upstream-to=origin/main yolo/quick")
expect_contains "$yolo_set_upstream_block" "may only track a mirrored remote branch name"
echo "ok 68 - --set-upstream-to=origin/main for a yolo branch is blocked"

yolo_track_block=$(run_guard "git branch --track yolo/quick origin/main")
expect_contains "$yolo_track_block" "may only track a mirrored remote branch name"
echo "ok 69 - git branch --track yolo/x origin/main is blocked"

yolo_worktree_base_block=$(run_guard "git worktree add -b yolo/quick /tmp/yolo-x origin/main")
expect_contains "$yolo_worktree_base_block" "may only track a mirrored remote branch name"
echo "ok 70 - yolo worktree add -b from origin/main without --no-track is blocked"

yolo_switch_no_track_allow=$(run_guard "git switch --no-track -c yolo/quick origin/main")
[[ -z "$yolo_switch_no_track_allow" ]] || fail "expected --no-track yolo switch to be allowed, got: $yolo_switch_no_track_allow"
echo "ok 71 - yolo switch --no-track -c from a base is allowed"

yolo_worktree_no_track_allow=$(run_guard "git worktree add --no-track -b yolo/quick /tmp/yolo-x origin/main")
[[ -z "$yolo_worktree_no_track_allow" ]] || fail "expected --no-track yolo worktree to be allowed, got: $yolo_worktree_no_track_allow"
echo "ok 72 - yolo worktree add --no-track -b from a base is allowed"

# Local force-delete (git branch -D) is exempt only for yolo-prefixed names.
yolo_branch_delete_block=$(run_guard "git branch -D yolo/quick")
expect_contains "$yolo_branch_delete_block" "force-deletes a branch"
echo "ok 73 - git branch -D of a disabled yolo branch is blocked"

yolo_amend_repo="$TEST_TMP/yolo-amend-repo"
git init -q "$yolo_amend_repo"
git -C "$yolo_amend_repo" checkout -q -b yolo/amend
yolo_amend_allow=$(run_guard_with_parameters_workdir "$yolo_amend_repo" "git commit --amend --no-edit")
[[ -z "$yolo_amend_allow" ]] || fail "expected git commit --amend on a yolo branch to be allowed, got: $yolo_amend_allow"
echo "ok 74 - git commit --amend is allowed on a resolved yolo branch"

feature_amend_repo="$TEST_TMP/feature-amend-repo"
git init -q "$feature_amend_repo"
git -C "$feature_amend_repo" checkout -q -b feature/feature-amend
feature_amend_allow=$(run_guard_with_parameters_workdir "$feature_amend_repo" "git commit --amend --no-edit")
[[ -z "$feature_amend_allow" ]] || fail "expected git commit --amend on a feature branch to be allowed, got: $feature_amend_allow"
echo "ok 75 - git commit --amend is allowed on feature branches"

main_amend_repo="$TEST_TMP/main-amend-repo"
git init -q "$main_amend_repo"
git -C "$main_amend_repo" checkout -q -b main
main_amend_block=$(run_guard_with_parameters_workdir "$main_amend_repo" "git commit --amend --no-edit")
expect_contains "$main_amend_block" "git commit --amend is not allowed on protected branches"
echo "ok 76 - git commit --amend stays blocked on protected branches"

base_branch_delete_block=$(run_guard "git branch -D main")
expect_contains "$base_branch_delete_block" "force-deletes a branch"
echo "ok 77 - git branch -D main stays blocked"

mixed_branch_delete_block=$(run_guard "git branch -D yolo/quick main")
expect_contains "$mixed_branch_delete_block" "force-deletes a branch"
echo "ok 78 - mixed git branch -D (yolo + base) stays blocked"

feature_branch_delete_block=$(run_guard "git branch -D feature/feature")
expect_contains "$feature_branch_delete_block" "force-deletes a branch"
echo "ok 79 - git branch -D of an ordinary feature branch stays blocked"

# Plain and leased force pushes stay blocked without a private policy.
yolo_plain_force_block=$(run_guard "git push --force origin yolo/quick")
expect_contains "$yolo_plain_force_block" "Use --force-with-lease"
echo "ok 80 - plain git push --force of a yolo branch stays blocked"

force_with_lease_block=$(run_guard "git push --force-with-lease origin yolo/quick")
expect_contains "$force_with_lease_block" "requires an explicitly enabled private branch policy"
echo "ok 80a - git push --force-with-lease is blocked by the public policy"

git_c_plain_force_block=$(run_guard "git -C /tmp/repo push --force origin yolo/quick")
expect_contains "$git_c_plain_force_block" "Use --force-with-lease"
echo "ok 80b - git -C push --force is blocked"

mixed_plain_force_block=$(run_guard "git push --force-with-lease origin yolo/quick; git -C /tmp/repo push -f origin yolo/other")
expect_contains "$mixed_plain_force_block" "Use --force-with-lease"
echo "ok 80c - later plain force push is blocked even after force-with-lease"

plus_refspec_force_block=$(run_guard "git push origin +feature/feature:feature/feature")
expect_contains "$plus_refspec_force_block" "Use --force-with-lease"
echo "ok 80d - leading-plus push refspec is blocked without a lease flag"

plus_refspec_lease_block=$(run_guard "git push --force-with-lease origin +yolo/quick:yolo/quick")
expect_contains "$plus_refspec_lease_block" "requires an explicitly enabled private branch policy"
echo "ok 80e - leased leading-plus refspec is blocked by the public policy"

scratch_force_lease_remote_block=$(
  export AGENT_WORK_MODE=remote_scratch
  run_guard_with_workdir "$fba_repo" "git push --force-with-lease upstream scratch/agent/x"
)
expect_contains "$scratch_force_lease_remote_block" "configured scratch remotes"
echo "ok 80f - scratch branch push to an unconfigured remote is blocked"

scratch_force_lease_origin_block=$(
  export AGENT_WORK_MODE=remote_scratch
  run_guard_with_workdir "$fba_repo" "git push --force-with-lease origin scratch/agent/x"
)
expect_contains "$scratch_force_lease_origin_block" "must not force-update"
echo "ok 80g - scratch branch force-with-lease push is blocked"

git_c_reset_hard_block=$(run_guard "git -C /tmp/repo reset --hard")
expect_contains "$git_c_reset_hard_block" "git reset --hard"
echo "ok 80h - git -C reset --hard is blocked"

git_c_clean_force_block=$(run_guard "git -C /tmp/repo clean -fd")
expect_contains "$git_c_clean_force_block" "git clean -f"
echo "ok 80i - git -C clean -fd is blocked"

git_c_branch_delete_block=$(run_guard "git -C /tmp/repo branch -D main")
expect_contains "$git_c_branch_delete_block" "force-deletes a branch"
echo "ok 80j - git -C branch -D main is blocked"

# Fail-closed: if the yolo class is disabled in policy, the branch -D exemption
# must not apply.
yolo_disabled_delete_block=$(
  export PG_AGENT_PUSH_POLICY="$TEST_TMP/yolo-disabled-policy.json"
  run_guard "git branch -D yolo/quick"
)
expect_contains "$yolo_disabled_delete_block" "force-deletes a branch"
echo "ok 81 - yolo branch -D exemption fails closed when yolo_branches.enabled=false"

gist_cli_host_block=$(run_guard "gh gist create 01_report.md --desc \"portable report\"")
expect_contains "$gist_cli_host_block" "gist creation must target a host explicitly"
gist_cli_other_segment_host_block=$(run_guard "GH_HOST=example.test true && gh gist create 01_report.md --desc \"portable report\"")
expect_contains "$gist_cli_other_segment_host_block" "gist creation must target a host explicitly"
echo "ok 82 - implicit-host gist creation is blocked"

kill_pid_allow=$(run_guard "kill 12345")
[[ -z "$kill_pid_allow" ]] || fail "expected local kill PID to be allowed, got: $kill_pid_allow"
echo "ok 83 - local kill PID is allowed"

pkill_allow=$(run_guard "pkill -f local-agent")
[[ -z "$pkill_allow" ]] || fail "expected local pkill to be allowed, got: $pkill_allow"
echo "ok 84 - local pkill is allowed"

killall_allow=$(run_guard "killall local-agent")
[[ -z "$killall_allow" ]] || fail "expected local killall to be allowed, got: $killall_allow"
echo "ok 85 - local killall is allowed"

command_git_push_block=$(run_guard "command git push origin master")
expect_contains "$command_git_push_block" "pushing directly to master"
echo "ok 86 - command-wrapped git push is blocked"

nice_shell_wrapper_block=$(run_guard "nice bash -c 'git push origin HEAD:main'")
expect_contains "$nice_shell_wrapper_block" "local code-interpreter command strings are not allowed"
echo "ok 86a - process wrappers cannot hide local shell command strings"

unknown_git_wrapper_block=$(run_guard "opaque-wrapper git push origin master")
expect_contains "$unknown_git_wrapper_block" "pushing directly to master"
echo "ok 86b - unknown execution wrappers cannot hide git pushes"

echo_git_data_allow=$(run_guard "echo git push origin main")
[[ -z "$echo_git_data_allow" ]] || fail "expected data-only echo to stay allowed, got: $echo_git_data_allow"
echo "ok 86c - data-only command arguments are not promoted to executables"

watch_git_push_block=$(run_guard "watch 'git push origin HEAD:main'")
expect_contains "$watch_git_push_block" "local code-interpreter command strings are not allowed"
echo "ok 86d - watch command strings cannot hide git pushes"

awk_git_push_block=$(run_guard "awk 'BEGIN { system(\"git push origin HEAD:main\") }'")
expect_contains "$awk_git_push_block" "local code-interpreter command strings are not allowed"
echo "ok 86e - AWK system calls cannot hide git pushes"

env_git_config_block=$(run_guard "env SESSION=test git config --global core.hooksPath /tmp/hooks")
expect_contains "$env_git_config_block" "git config mutations are not allowed"
echo "ok 87 - env-wrapped git config mutation is blocked"

config_env_push_block=$(run_guard "HOOKS=/tmp/empty git --config-env=core.hooksPath=HOOKS push origin HEAD:main")
expect_contains "$config_env_push_block" "must not override core.hooksPath"
echo "ok 87a - git config-env cannot disable hooks for a push"

config_push_block=$(run_guard "git -c core.hooksPath=/tmp/empty push origin feature/x")
expect_contains "$config_push_block" "must not override core.hooksPath"
echo "ok 87b - git inline config cannot disable hooks for a push"

include_config_push_block=$(run_guard "git -c include.path=/tmp/disable-hooks push origin feature/x")
expect_contains "$include_config_push_block" "inject Git configuration"
echo "ok 87c - indirect inline Git configuration cannot disable hooks"

global_config_push_block=$(run_guard "GIT_CONFIG_GLOBAL=/tmp/disable-hooks git push origin feature/x")
expect_contains "$global_config_push_block" "inject Git configuration"
echo "ok 87d - Git config-source environment overrides cannot disable hooks"

env_global_config_push_block=$(run_guard "env GIT_CONFIG_GLOBAL=/tmp/disable-hooks git push origin feature/x")
expect_contains "$env_global_config_push_block" "inject Git configuration"
echo "ok 87e - env-wrapped Git config-source overrides cannot disable hooks"

absolute_git_reset_block=$(run_guard "/usr/bin/git reset --hard")
expect_contains "$absolute_git_reset_block" "git reset --hard"
echo "ok 88 - absolute-path git reset is blocked"

stacked_wrapper_tracking_block=$(run_guard "command env git branch -u upstream/main feature/feature")
expect_contains "$stacked_wrapper_tracking_block" "may only track a mirrored remote branch name"
echo "ok 89 - stacked command and env wrappers cannot bypass branch tracking"

env_split_reset_block=$(run_guard "env -S 'git reset --hard'")
expect_contains "$env_split_reset_block" "git reset --hard"
echo "ok 90 - env split-string cannot bypass destructive git checks"

env_long_split_config_block=$(run_guard "env --split-string='git config --global core.hooksPath /tmp/hooks'")
expect_contains "$env_long_split_config_block" "git config mutations are not allowed"
echo "ok 91 - long env split-string cannot bypass git config checks"

env_attached_split_branch_block=$(run_guard "env -Sgit branch -D main")
expect_contains "$env_attached_split_branch_block" "git branch -D force-deletes a branch"
echo "ok 92 - attached env split-string cannot bypass branch checks"

env_missing_split_value_block=$(run_guard "env -S")
expect_contains "$env_missing_split_value_block" "unable to safely parse wrapped git command"
echo "ok 93 - malformed env split-string fails closed"

shell_wrapper_block=$(run_guard "bash -c 'git -c core.hooksPath=/dev/null push origin HEAD:main'")
expect_contains "$shell_wrapper_block" "local code-interpreter command strings are not allowed"
echo "ok 93a - local shell wrappers cannot bypass git checks"

dynamic_refspec_block=$(run_guard "git push origin HEAD:ma{in,ster}")
expect_contains "$dynamic_refspec_block" "refspecs must be literal"
echo "ok 93a2 - dynamic push refspecs are blocked"

stacked_shell_wrapper_block=$(run_guard "command env zsh -lc 'git config --global core.hooksPath /dev/null'")
expect_contains "$stacked_shell_wrapper_block" "local code-interpreter command strings are not allowed"
echo "ok 93b - stacked local shell wrappers fail closed"

exec_shell_wrapper_block=$(run_guard "exec bash -c 'git -c core.hooksPath=/dev/null push origin HEAD:main'")
expect_contains "$exec_shell_wrapper_block" "local code-interpreter command strings are not allowed"
echo "ok 93b2 - exec shell wrappers fail closed"

python_wrapper_block=$(run_guard "command env SESSION=x exec -a worker python3 -c 'import os; os.system(\"git push origin HEAD:main\")'")
expect_contains "$python_wrapper_block" "local code-interpreter command strings are not allowed"
echo "ok 93b3 - stacked Python command strings fail closed"

malformed_hook_input_block=$(printf '{not-json' | bash "$GUARD")
expect_contains "$malformed_hook_input_block" "invalid Bash hook input"
echo "ok 93c - malformed hook input fails closed"

mkdir -p "$TEST_TMP/no-jq-bin"
ln -s /bin/cat "$TEST_TMP/no-jq-bin/cat"
missing_jq_block=$(printf '%s\n' '{"tool_input":{"command":"git push origin feature/x"}}' | PATH="$TEST_TMP/no-jq-bin" /bin/bash "$GUARD")
expect_contains "$missing_jq_block" "requires jq"
echo "ok 93d - missing jq fails closed"

mkdir -p "$TEST_TMP/no-python-bin"
ln -s /bin/cat "$TEST_TMP/no-python-bin/cat"
ln -s /usr/bin/jq "$TEST_TMP/no-python-bin/jq"
missing_python_block=$(printf '%s\n' '{"tool_input":{"command":"git push origin feature/x"}}' | PATH="$TEST_TMP/no-python-bin" /bin/bash "$GUARD")
expect_contains "$missing_python_block" "requires Python 3"
echo "ok 93d2 - missing Python fails closed"

mkdir -p "$TEST_TMP/failing-python-bin"
ln -s /bin/cat "$TEST_TMP/failing-python-bin/cat"
ln -s /usr/bin/jq "$TEST_TMP/failing-python-bin/jq"
printf '%s\n' '#!/bin/bash' 'exit 9' >"$TEST_TMP/failing-python-bin/python3"
chmod +x "$TEST_TMP/failing-python-bin/python3"
failing_python_block=$(printf '%s\n' '{"tool_input":{"command":"git push origin feature/x"}}' | PATH="$TEST_TMP/failing-python-bin" /bin/bash "$GUARD")
expect_contains "$failing_python_block" "unable to normalize command safely"
echo "ok 93d3 - Python normalization failure fails closed"

missing_policy_block=$(
  export PG_AGENT_PUSH_POLICY="$TEST_TMP/missing-policy.json"
  run_guard "git push origin feature/x"
)
expect_contains "$missing_policy_block" "require a valid agent push policy"
echo "ok 93e - missing push policy fails closed"

printf '%s\n' '{"scratch_branches":' >"$TEST_TMP/malformed-policy.json"
malformed_policy_block=$(
  export PG_AGENT_PUSH_POLICY="$TEST_TMP/malformed-policy.json"
  run_guard "git push origin feature/x"
)
expect_contains "$malformed_policy_block" "require a valid agent push policy"
echo "ok 93f - malformed push policy fails closed"

proxy_command_block=$(run_guard "ssh -o ProxyCommand='touch /tmp/proxy-ran' builder.work uptime")
expect_contains "$proxy_command_block" "ssh configuration may execute a local command"
echo "ok 94 - leased workspace SSH rejects ProxyCommand"

local_command_block=$(run_guard "ssh -o PermitLocalCommand=yes -o LocalCommand='touch /tmp/local-ran' builder.work uptime")
expect_contains "$local_command_block" "ssh configuration may execute a local command"
echo "ok 95 - leased workspace SSH rejects enabled LocalCommand"

unsafe_ssh_config="$TEST_TMP/unsafe-ssh-config"
cat > "$unsafe_ssh_config" <<'EOF'
Host builder.work
  ProxyCommand touch /tmp/config-proxy-ran
EOF
proxy_config_block=$(run_guard "ssh -F $unsafe_ssh_config builder.work uptime")
expect_contains "$proxy_config_block" "ssh configuration may execute a local command"
echo "ok 96 - leased workspace SSH inspects explicit config files"
