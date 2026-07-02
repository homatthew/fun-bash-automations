#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUARD="$ROOT/llm/hooks/bash-safety-guard.sh"
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bash-safety-guard-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT
export SSH_LEASE_FILE="$TEST_TMP/ssh-leases"
export SSH_COMMAND_LEASE_FILE="$TEST_TMP/ssh-command-leases"
export BASH_SAFETY_GUARD_EXTENSION_DIRS="$TEST_TMP/bash-safety-guard.d"

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

echo "1..85"

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

wrong_hostname_flag=$(run_guard "gh auth status --hostname github.netflix.net")
expect_contains "$wrong_hostname_flag" "browser URL"
echo "ok 7 - wrong github.netflix.net --hostname is blocked"

wrong_repo_host=$(run_guard "gh pr view 123 --repo github.netflix.net/org/repo --json number")
expect_contains "$wrong_repo_host" "repos as owner/name"
echo "ok 8 - full github.netflix.net --repo is blocked"

wrong_repo_url=$(run_guard "GH_HOST=git.netflix.net gh pr view 123 --repo https://git.netflix.net/org/repo --json number")
expect_contains "$wrong_repo_url" "repos as owner/name"
echo "ok 9 - full git.netflix.net URL in --repo is blocked"

correct_netflix_pr_read=$(run_guard "GH_HOST=git.netflix.net gh pr view 123 --repo org/repo --json number")
[[ -z "$correct_netflix_pr_read" ]] || fail "expected correct Netflix PR read to be allowed, got: $correct_netflix_pr_read"
echo "ok 10 - correct Netflix PR read form is allowed"

gist_cli_allow=$(run_guard "GH_HOST=git.netflix.net gh gist create 01_diagram.py 02_architecture.png 03_README.md --desc \"ordered files\"")
[[ -z "$gist_cli_allow" ]] || fail "expected ordered gh gist create files to be allowed, got: $gist_cli_allow"
echo "ok 11 - ordered gh gist create files are allowed"

gist_cli_block=$(run_guard "GH_HOST=git.netflix.net gh gist create diagram.py 02_architecture.png README.md --desc \"unordered files\"")
expect_contains "$gist_cli_block" "gist uploads must use contiguous ordered filenames"
echo "ok 12 - unordered gh gist create files are blocked"

ordered_payload="$TEST_TMP/ordered-gist.json"
unordered_payload="$TEST_TMP/unordered-gist.json"
write_payload "$ordered_payload" '{"01_summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'
write_payload "$unordered_payload" '{"summary.md":{"content":"a"},"02_graph.png":{"content":"b"}}'

payload_allow=$(run_guard "GH_HOST=git.netflix.net gh api /gists --method POST --input $ordered_payload")
[[ -z "$payload_allow" ]] || fail "expected ordered gist payload keys to be allowed, got: $payload_allow"
echo "ok 13 - ordered gist payload keys are allowed"

payload_block=$(run_guard "GH_HOST=git.netflix.net gh api /gists --method POST --input $unordered_payload")
expect_contains "$payload_block" "gist uploads must use contiguous ordered filenames"
echo "ok 14 - unordered gist payload keys are blocked"

main_tracking_block=$(run_guard "git branch -u upstream/main")
expect_contains "$main_tracking_block" "may only track a mirrored remote branch name"
echo "ok 15 - setting a feature branch upstream to upstream/main is blocked"

main_track_create_block=$(run_guard "git branch --track mho/trunk/scm-cassandra-dev upstream/main")
expect_contains "$main_track_create_block" "may only track a mirrored remote branch name"
echo "ok 16 - creating a branch that tracks upstream/main is blocked"

release_main_tracking_block=$(run_guard "git branch -u origin/release/main")
expect_contains "$release_main_tracking_block" "may only track a mirrored remote branch name"
echo "ok 17 - setting a feature branch upstream to origin/release/main is blocked"

release_main_checkout_block=$(run_guard "git checkout -b mho/kv-cleanup origin/release/main")
expect_contains "$release_main_checkout_block" "may only track a mirrored remote branch name"
echo "ok 18 - creating a branch from release/main without --no-track is blocked"

worktree_main_block=$(run_guard "git worktree add -b mho/oodm-capacity-planner /tmp/oodm origin/main")
expect_contains "$worktree_main_block" "may only track a mirrored remote branch name"
echo "ok 19 - creating a worktree branch from origin/main without --no-track is blocked"

worktree_main_chained_block=$(run_guard "mkdir -p /tmp/oodm && git -C /tmp/repo worktree add -b mho/oodm-capacity-planner /tmp/oodm origin/main")
expect_contains "$worktree_main_chained_block" "may only track a mirrored remote branch name"
echo "ok 20 - chained git -C worktree branch creation is blocked"

worktree_no_track_allow=$(run_guard "git worktree add --no-track -b mho/oodm-capacity-planner /tmp/oodm origin/main")
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

ssh_option_block=$(run_guard "ssh -o LogLevel=ERROR nfcassandra-node.example uptime")
expect_contains "$ssh_option_block" "ssh to 'nfcassandra-node.example' requires a lease"
echo "ok 32 - ssh option parsing reports the target host"

ssh_strict_no_block=$(run_guard "ssh -o StrictHostKeyChecking=no nfcassandra-node.example uptime")
expect_contains "$ssh_strict_no_block" "unsafe SSH host-key option"
echo "ok 33 - ssh StrictHostKeyChecking=no is blocked"

future_expiry=$(( $(date +%s) + 3600 ))
printf 'nfcassandra-node.example %s\n' "$future_expiry" >"$SSH_LEASE_FILE"

ssh_option_allow=$(run_guard "ssh -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR nfcassandra-node.example uptime")
[[ -z "$ssh_option_allow" ]] || fail "expected ssh with safe options and leased host to be allowed, got: $ssh_option_allow"
echo "ok 34 - ssh lease matches host after safe options"

ssh_known_hosts_null_block=$(run_guard "ssh -o UserKnownHostsFile=/dev/null nfcassandra-node.example uptime")
expect_contains "$ssh_known_hosts_null_block" "unsafe SSH host-key option"
echo "ok 35 - ssh UserKnownHostsFile=/dev/null is blocked"

ssh_user_host_allow=$(run_guard "ssh -p 22 cassandra@nfcassandra-node.example 'ls /ebs/cassandra/data'")
[[ -z "$ssh_user_host_allow" ]] || fail "expected ssh user@host to match host lease, got: $ssh_user_host_allow"
echo "ok 36 - ssh user@host normalizes to host lease"

ssh_interactive_block=$(run_guard "ssh nfcassandra-node.example")
expect_contains "$ssh_interactive_block" "interactive ssh without an explicit remote command"
echo "ok 37 - interactive ssh is blocked"

ssh_remote_sudo_block=$(run_guard "ssh nfcassandra-node.example 'sudo systemctl restart cassandra'")
expect_contains "$ssh_remote_sudo_block" "dangerous remote ssh command: sudo"
echo "ok 38 - remote ssh sudo is blocked"

ssh_remote_wrapper_block=$(run_guard "ssh nfcassandra-node.example 'bash -c uptime'")
expect_contains "$ssh_remote_wrapper_block" "remote ssh shell/code wrapper is not allowed"
echo "ok 39 - remote ssh shell wrapper is blocked"

ssh_remote_cqlsh_block=$(run_guard "ssh nfcassandra-node.example 'cqlsh -e \"select now() from system.local\"'")
expect_contains "$ssh_remote_cqlsh_block" "dangerous remote ssh command: cqlsh"
echo "ok 40 - remote ssh cqlsh is blocked"

ssh_remote_nodetool_repair_block=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool repair greenseer'")
expect_contains "$ssh_remote_nodetool_repair_block" "dangerous remote cassandra nodetool command: nodetool repair"
echo "ok 41 - remote ssh nodetool repair is blocked"

ssh_remote_nodetool_set_block=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool setstreamthroughput 1'")
expect_contains "$ssh_remote_nodetool_set_block" "dangerous remote cassandra nodetool command: nodetool setstreamthroughput"
echo "ok 42 - remote ssh nodetool set commands are blocked"

ssh_remote_toppartitions_block=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool toppartitions -a reads -k 100 -s 4096 greenseer msghistory 60000'")
expect_contains "$ssh_remote_toppartitions_block" "requires an exact command lease"
echo "ok 43 - sensitive nodetool toppartitions requires exact command lease"

write_command_lease nfcassandra-node.example "$future_expiry" "/apps/nfcassandra_server/bin/nodetool toppartitions -a reads -k 100 -s 4096 greenseer msghistory 60000"
ssh_remote_toppartitions_allow=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool toppartitions -a reads -k 100 -s 4096 greenseer msghistory 60000'")
[[ -z "$ssh_remote_toppartitions_allow" ]] || fail "expected leased nodetool toppartitions to be allowed, got: $ssh_remote_toppartitions_allow"
echo "ok 44 - exact command lease allows nodetool toppartitions"

ssh_remote_toppartitions_changed_block=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool toppartitions -a reads -k 200 -s 4096 greenseer msghistory 60000'")
expect_contains "$ssh_remote_toppartitions_changed_block" "requires an exact command lease"
echo "ok 45 - changed sensitive command needs its own lease"

write_command_lease nfcassandra-node.example "$future_expiry" "/apps/nfcassandra_server/bin/nodetool repair greenseer"
ssh_remote_repair_still_block=$(run_guard "ssh nfcassandra-node.example '/apps/nfcassandra_server/bin/nodetool repair greenseer'")
expect_contains "$ssh_remote_repair_still_block" "dangerous remote cassandra nodetool command: nodetool repair"
echo "ok 46 - command lease cannot allow hard-blocked nodetool repair"

ssh_remote_jstack_block=$(run_guard "ssh nfcassandra-node.example 'jstack 1234'")
expect_contains "$ssh_remote_jstack_block" "requires an exact command lease"
echo "ok 47 - remote jstack requires exact command lease"

write_command_lease nfcassandra-node.example "$future_expiry" "jstack 1234"
ssh_remote_jstack_allow=$(run_guard "ssh nfcassandra-node.example 'jstack 1234'")
[[ -z "$ssh_remote_jstack_allow" ]] || fail "expected leased jstack to be allowed, got: $ssh_remote_jstack_allow"
echo "ok 48 - exact command lease allows jstack"

scp_env_lease_allow=$(run_guard "scp cassandra@nfcassandra-node.example:/tmp/schema.cql $TEST_TMP/schema.cql")
[[ -z "$scp_env_lease_allow" ]] || fail "expected scp to use configured lease file, got: $scp_env_lease_allow"
echo "ok 49 - scp uses shared ssh lease helper"

ssh_search_allow=$(run_guard "rg -n ssh llm/hooks/bash-safety-guard.sh")
[[ -z "$ssh_search_allow" ]] || fail "expected local rg search for ssh text to be allowed, got: $ssh_search_allow"
echo "ok 50 - local search containing ssh text is not treated as remote access"

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
echo "ok 51 - Pilgrim placeholder SSH config suggests and accepts instance-id lease"

fba_pr_create_block=$(run_guard "gh pr create --base main --head mh-netflix --title nope")
expect_contains "$fba_pr_create_block" "fun-bash-automations uses mh-netflix as the delivery branch"
echo "ok 52 - fun-bash-automations gh pr create is blocked"

fba_pr_ready_block=$(run_guard "gh -R homatthew/fun-bash-automations pr ready 3")
expect_contains "$fba_pr_ready_block" "Do not create, reopen, or mark ready PRs"
echo "ok 53 - fun-bash-automations gh pr ready is blocked with explicit repo"

fba_pr_reopen_block=$(run_guard "gh pr reopen --repo=homatthew/fun-bash-automations 3")
expect_contains "$fba_pr_reopen_block" "Do not create, reopen, or mark ready PRs"
echo "ok 54 - fun-bash-automations gh pr reopen is blocked with repo flag"

fba_pr_view_allow=$(run_guard "gh pr view 3 --json number")
[[ -z "$fba_pr_view_allow" ]] || fail "expected fun-bash-automations gh pr view to be allowed, got: $fba_pr_view_allow"
echo "ok 55 - fun-bash-automations gh pr view stays allowed"

other_pr_create_allow=$(run_guard "gh -R homatthew/other-repo pr create --base main --head feature")
[[ -z "$other_pr_create_allow" ]] || fail "expected non-FBA gh pr create to be allowed by this guard, got: $other_pr_create_allow"
echo "ok 56 - non-FBA gh pr create is not blocked by FBA-specific rule"

dotfiles_repo="$TEST_TMP/dotfiles"
git init -q "$dotfiles_repo"
git -C "$dotfiles_repo" remote add origin https://git.netflix.net/matthewho/dotfiles.git
dotfiles_push_allow=$(run_guard_with_workdir "$dotfiles_repo" "git push origin HEAD:main")
[[ -z "$dotfiles_push_allow" ]] || fail "expected dotfiles direct push to be allowed, got: $dotfiles_push_allow"
echo "ok 57 - dotfiles direct delivery push bypasses feature-branch push guard"

dotfiles_push_c_allow=$(run_guard "git -C $dotfiles_repo push origin HEAD:main")
[[ -z "$dotfiles_push_c_allow" ]] || fail "expected dotfiles git -C direct push to be allowed, got: $dotfiles_push_c_allow"
echo "ok 58 - dotfiles git -C direct delivery push bypasses feature-branch push guard"

dotfiles_bare_push_block=$(run_guard_with_workdir "$dotfiles_repo" "git push")
expect_contains "$dotfiles_bare_push_block" "bare git push is not allowed"
echo "ok 58b - dotfiles bare git push is blocked despite direct-push exception"

fba_repo="$TEST_TMP/fun-bash-automations"
git init -q "$fba_repo"
git -C "$fba_repo" checkout -q -b mh-netflix
git -C "$fba_repo" remote add origin git@github.com:homatthew/fun-bash-automations.git
fba_push_allow=$(run_guard_with_workdir "$fba_repo" "git push origin mh-netflix")
[[ -z "$fba_push_allow" ]] || fail "expected FBA mh-netflix direct push to be allowed, got: $fba_push_allow"
echo "ok 59 - fun-bash-automations mh-netflix direct push bypasses feature-branch push guard"

fba_bare_push_block=$(run_guard_with_workdir "$fba_repo" "git push")
expect_contains "$fba_bare_push_block" "bare git push is not allowed"
echo "ok 59b - fun-bash-automations bare git push is blocked despite direct-push exception"

fba_main_push_block=$(run_guard_with_workdir "$fba_repo" "git push origin HEAD:main")
expect_contains "$fba_main_push_block" "pushing directly to origin/main is not allowed"
echo "ok 60 - fun-bash-automations main push remains blocked"

# Shell redirections must not confuse push-target parsing (regression: shlex
# split "2>&1" into extra tokens that were counted as refspecs -> false
# "bare push" block).
fba_push_redir_allow=$(run_guard_with_workdir "$fba_repo" "git push origin mho/x 2>&1")
[[ -z "$fba_push_redir_allow" ]] || fail "expected feature push with 2>&1 to be allowed, got: $fba_push_redir_allow"
echo "ok 60b - git push of a feature branch with 2>&1 redirect is allowed"

fba_push_redir_pipe_allow=$(run_guard_with_workdir "$fba_repo" "git push origin mho/x 2>&1 | tail -5")
[[ -z "$fba_push_redir_pipe_allow" ]] || fail "expected feature push with 2>&1 | tail to be allowed, got: $fba_push_redir_pipe_allow"
echo "ok 60c - git push of a feature branch with 2>&1 | tail is allowed"

fba_main_redir_block=$(run_guard_with_workdir "$fba_repo" "git push origin main 2>&1")
expect_contains "$fba_main_redir_block" "pushing directly to origin/main is not allowed"
echo "ok 60d - git push origin main 2>&1 stays blocked (redirect stripped, not a bypass)"

quoted_push_text_allow=$(run_guard_with_workdir "$fba_repo" 'rg -n "git push no-mistakes" README.md')
[[ -z "$quoted_push_text_allow" ]] || fail "expected quoted git-push search text to be allowed, got: $quoted_push_text_allow"
echo "ok 60d2 - quoted git push text in a search command is not treated as a push"

# Multi-line scripts: a git push on its own line must be isolated (regression:
# newline-separated statements merged into one segment -> false 'bare push').
fba_multiline_feature=$(run_guard_with_workdir "$fba_repo" $'echo prep\ngit push origin mho/x')
[[ -z "$fba_multiline_feature" ]] || fail "expected multi-line feature push to be allowed, got: $fba_multiline_feature"
echo "ok 60e - git push on its own line in a multi-line script is allowed"

fba_multiline_main=$(run_guard_with_workdir "$fba_repo" $'echo prep\ngit push origin main')
expect_contains "$fba_multiline_main" "pushing directly to origin/main is not allowed"
echo "ok 60f - git push origin main on its own line in a multi-line script stays blocked"

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

# --- yolo branch class (mho-yolo/) ---
# A yolo branch must be mechanically incapable of acquiring a base ref as
# upstream/tracking. check_branch_tracking is universal, so these must deny
# even though yolo pushes are otherwise allowed.
yolo_checkout_base_block=$(run_guard "git checkout -b mho-yolo/quick origin/main")
expect_contains "$yolo_checkout_base_block" "may only track a mirrored remote branch name"
echo "ok 65 - yolo checkout -b from origin/main without --no-track is blocked"

yolo_switch_base_block=$(run_guard "git switch -c mho-yolo/quick origin/main")
expect_contains "$yolo_switch_base_block" "may only track a mirrored remote branch name"
echo "ok 66 - yolo switch -c from origin/main without --no-track is blocked"

yolo_branch_u_block=$(run_guard "git branch -u origin/main")
expect_contains "$yolo_branch_u_block" "may only track a mirrored remote branch name"
echo "ok 67 - setting upstream to origin/main is blocked (yolo cannot acquire base upstream)"

yolo_set_upstream_block=$(run_guard "git branch --set-upstream-to=origin/main mho-yolo/quick")
expect_contains "$yolo_set_upstream_block" "may only track a mirrored remote branch name"
echo "ok 68 - --set-upstream-to=origin/main for a yolo branch is blocked"

yolo_track_block=$(run_guard "git branch --track mho-yolo/quick origin/main")
expect_contains "$yolo_track_block" "may only track a mirrored remote branch name"
echo "ok 69 - git branch --track mho-yolo/x origin/main is blocked"

yolo_worktree_base_block=$(run_guard "git worktree add -b mho-yolo/quick /tmp/yolo-x origin/main")
expect_contains "$yolo_worktree_base_block" "may only track a mirrored remote branch name"
echo "ok 70 - yolo worktree add -b from origin/main without --no-track is blocked"

yolo_switch_no_track_allow=$(run_guard "git switch --no-track -c mho-yolo/quick origin/main")
[[ -z "$yolo_switch_no_track_allow" ]] || fail "expected --no-track yolo switch to be allowed, got: $yolo_switch_no_track_allow"
echo "ok 71 - yolo switch --no-track -c from a base is allowed"

yolo_worktree_no_track_allow=$(run_guard "git worktree add --no-track -b mho-yolo/quick /tmp/yolo-x origin/main")
[[ -z "$yolo_worktree_no_track_allow" ]] || fail "expected --no-track yolo worktree to be allowed, got: $yolo_worktree_no_track_allow"
echo "ok 72 - yolo worktree add --no-track -b from a base is allowed"

# Local force-delete (git branch -D) is exempt only for yolo-prefixed names.
yolo_branch_delete_allow=$(run_guard "git branch -D mho-yolo/quick")
[[ -z "$yolo_branch_delete_allow" ]] || fail "expected git branch -D of a yolo branch to be allowed, got: $yolo_branch_delete_allow"
echo "ok 73 - git branch -D of a yolo branch is allowed (local cleanup)"

yolo_amend_repo="$TEST_TMP/yolo-amend-repo"
git init -q "$yolo_amend_repo"
git -C "$yolo_amend_repo" checkout -q -b mho-yolo/amend
yolo_amend_allow=$(run_guard_with_parameters_workdir "$yolo_amend_repo" "git commit --amend --no-edit")
[[ -z "$yolo_amend_allow" ]] || fail "expected git commit --amend on a yolo branch to be allowed, got: $yolo_amend_allow"
echo "ok 74 - git commit --amend is allowed on a resolved yolo branch"

feature_amend_repo="$TEST_TMP/feature-amend-repo"
git init -q "$feature_amend_repo"
git -C "$feature_amend_repo" checkout -q -b mho/feature-amend
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

mixed_branch_delete_block=$(run_guard "git branch -D mho-yolo/quick main")
expect_contains "$mixed_branch_delete_block" "force-deletes a branch"
echo "ok 78 - mixed git branch -D (yolo + base) stays blocked"

feature_branch_delete_block=$(run_guard "git branch -D mho/feature")
expect_contains "$feature_branch_delete_block" "force-deletes a branch"
echo "ok 79 - git branch -D of an ordinary feature branch stays blocked"

# Plain (un-leased) force push stays blocked for yolo too; only
# --force-with-lease is sanctioned.
yolo_plain_force_block=$(run_guard "git push --force origin mho-yolo/quick")
expect_contains "$yolo_plain_force_block" "Use --force-with-lease"
echo "ok 80 - plain git push --force of a yolo branch stays blocked"

# Fail-closed: if the yolo class is disabled in policy, the branch -D exemption
# must not apply.
yolo_disabled_delete_block=$(
  export PG_AGENT_PUSH_POLICY="$TEST_TMP/yolo-disabled-policy.json"
  run_guard "git branch -D mho-yolo/quick"
)
expect_contains "$yolo_disabled_delete_block" "force-deletes a branch"
echo "ok 81 - yolo branch -D exemption fails closed when yolo_branches.enabled=false"

gist_cli_host_block=$(run_guard "gh gist create 01_report.md --desc \"secret\"")
expect_contains "$gist_cli_host_block" "gh gist creation must target Netflix GHE explicitly"
echo "ok 82 - bare gh gist create is blocked"

kill_pid_allow=$(run_guard "kill 12345")
[[ -z "$kill_pid_allow" ]] || fail "expected local kill PID to be allowed, got: $kill_pid_allow"
echo "ok 83 - local kill PID is allowed"

pkill_allow=$(run_guard "pkill -f t3-claude")
[[ -z "$pkill_allow" ]] || fail "expected local pkill to be allowed, got: $pkill_allow"
echo "ok 84 - local pkill is allowed"

killall_allow=$(run_guard "killall t3-claude")
[[ -z "$killall_allow" ]] || fail "expected local killall to be allowed, got: $killall_allow"
echo "ok 85 - local killall is allowed"
