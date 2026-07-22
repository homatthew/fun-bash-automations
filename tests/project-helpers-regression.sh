#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d -t fba-project-helpers-XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

export HOME="$TMP_HOME"
export PROJECTS_DIR="$TMP_HOME/projects"
export REPOS_DIR="$TMP_HOME/repos"
export REPOS_ARCHIVE_DIR="$TMP_HOME/repos-archive"
export FBA_ROOT="$ROOT"

mkdir -p "$PROJECTS_DIR/alpha/service-a" "$PROJECTS_DIR/beta" "$REPOS_DIR" "$REPOS_ARCHIVE_DIR"

source_personal='autoload -Uz compinit; compinit -C; source "$FBA_ROOT/zsh/personal.zsh"'

safe_aliases="$(zsh -fc "$source_personal; alias cld; alias cldr; alias claude 2>/dev/null || true; alias codex 2>/dev/null || true")"
[[ "$safe_aliases" == *"cld=claude"* ]]
[[ "$safe_aliases" != *"dangerously"* ]]

list_output="$(zsh -fc "$source_personal; projl")"
[[ "$list_output" == *"alpha"* ]]
[[ "$list_output" == *"beta"* ]]

pwd_output="$(zsh -fc "$source_personal; proj alpha >/dev/null; pwd")"
[[ "$pwd_output" == "$PROJECTS_DIR/alpha" ]]

missing_output=""
if missing_output="$(zsh -fc "$source_personal; proj missing" 2>&1)"; then
    echo "expected proj missing to fail" >&2
    exit 1
fi
[[ "$missing_output" == *"proj: no project at $PROJECTS_DIR/missing"* ]]

completion_output="$(zsh -fc 'autoload -Uz compinit; compinit -C; source "$FBA_ROOT/zsh/personal.zsh"; print -- "${_comps[proj]} ${_comps[rp]}"')"
[[ "$completion_output" == "_proj_completion _rp_completion" ]]

deferred_completion_output="$(zsh -fc 'source "$FBA_ROOT/zsh/personal.zsh"; autoload -Uz compinit; compinit -C; _fba_register_pending_compdefs; print -- "${_comps[proj]} ${_comps[rp]}"')"
[[ "$deferred_completion_output" == "_proj_completion _rp_completion" ]]

mkdir -p "$TMP_HOME/.treehouse/worktrees/demo" "$TMP_HOME/outside-repo"
git -C "$TMP_HOME/.treehouse/worktrees/demo" init -q
git -C "$TMP_HOME/outside-repo" init -q

nm_home_one="$("$ROOT/bin/nm-home" --for "$TMP_HOME/.treehouse/worktrees/demo")"
nm_home_two="$("$ROOT/bin/nm-home" --for "$TMP_HOME/.treehouse/worktrees/demo")"
[[ "$nm_home_one" == "$nm_home_two" ]]
[[ "$nm_home_one" == "$TMP_HOME/.no-mistakes-homes/demo-"* ]]
[[ ! -e "$nm_home_one/config.yaml" ]]

nm_home_created="$("$ROOT/bin/nm-home" --for "$TMP_HOME/.treehouse/worktrees/demo" --mkdir)"
[[ "$nm_home_created" == "$nm_home_one" ]]
grep -qx 'agent: codex' "$nm_home_created/config.yaml"

nm_home_activated="$("$ROOT/bin/nm-home" --for "$TMP_HOME/.treehouse/worktrees/demo" --activate)"
[[ "$nm_home_activated" == "$nm_home_one" ]]
[[ "$(git -C "$TMP_HOME/.treehouse/worktrees/demo" config --get extensions.worktreeConfig)" == "true" ]]
nm_remote="$(git -C "$TMP_HOME/.treehouse/worktrees/demo" config --worktree --get remote.no-mistakes.url)"
[[ "$nm_remote" == "$nm_home_created/repos/"*".git" ]]
[[ "$(git -C "$TMP_HOME/.treehouse/worktrees/demo" config --worktree --get remote.no-mistakes.fetch)" == "+refs/heads/*:refs/remotes/no-mistakes/*" ]]

treehouse_nm_output="$(zsh -fc "$source_personal; cd '$TMP_HOME/.treehouse/worktrees/demo'; print -- \${NM_HOME:t}; print -- \${NM_HOME_AUTO:-}")"
[[ "$treehouse_nm_output" == *$'\n'"1" ]]
[[ "$treehouse_nm_output" == *"demo-"* ]]
grep -qx 'agent: codex' "$nm_home_created/config.yaml"
treehouse_nm_remote="$(git -C "$TMP_HOME/.treehouse/worktrees/demo" config --worktree --get remote.no-mistakes.url)"
[[ "$treehouse_nm_remote" == "$nm_home_created/repos/"*".git" ]]

outside_nm_output="$(zsh -fc "$source_personal; cd '$TMP_HOME/outside-repo'; print -- \${NM_HOME:-unset}; print -- \${NM_HOME_AUTO:-unset}")"
[[ "$outside_nm_output" == *$'\n'"unset"$'\n'"unset" ]]

mkdir -p "$TMP_HOME/source" "$TMP_HOME/remotes"
git -C "$TMP_HOME/source" init -b main service-b >/dev/null
git -C "$TMP_HOME/source/service-b" config user.email "test@example.com"
git -C "$TMP_HOME/source/service-b" config user.name "Test User"
printf "hello\n" > "$TMP_HOME/source/service-b/README.md"
git -C "$TMP_HOME/source/service-b" add README.md
git -C "$TMP_HOME/source/service-b" commit -m "Initial commit" >/dev/null
git init --bare -b main "$TMP_HOME/remotes/service-b.git" >/dev/null
git -C "$TMP_HOME/source/service-b" remote add origin "$TMP_HOME/remotes/service-b.git"
git -C "$TMP_HOME/source/service-b" push -u origin main >/dev/null 2>&1
git clone "$TMP_HOME/remotes/service-b.git" "$REPOS_DIR/service-b" >/dev/null 2>&1
git clone "$TMP_HOME/remotes/service-b.git" "$REPOS_DIR/service-c" >/dev/null 2>&1

printf 'preserve\n' > "$TMP_HOME/outside-sentinel"
if zsh -fc "$source_personal; proj ../outside service-b" >/dev/null 2>&1; then
    echo "expected traversal project name to fail" >&2
    exit 1
fi
if zsh -fc "$source_personal; proj epsilon ../outside-sentinel" >/dev/null 2>&1; then
    echo "expected traversal repository name to fail" >&2
    exit 1
fi
grep -qx 'preserve' "$TMP_HOME/outside-sentinel"

ln -s "$TMP_HOME/outside-repo" "$PROJECTS_DIR/escape-link"
if zsh -fc "$source_personal; proj escape-link" >/dev/null 2>&1; then
    echo "expected escaping project symlink to fail" >&2
    exit 1
fi
ln -s "$TMP_HOME/source/service-b" "$REPOS_DIR/linked-service"
if zsh -fc "$source_personal; proj linked linked-service" >/dev/null 2>&1; then
    echo "expected escaping repository symlink to fail" >&2
    exit 1
fi

rp_pwd="$(zsh -fc "$source_personal; rp service-b >/dev/null; pwd")"
[[ "$rp_pwd" == "$REPOS_DIR/service-b" ]]

created_pwd="$(zsh -fc "$source_personal; proj gamma service-b >/dev/null 2>&1 || exit \$?; pwd")"
[[ "$created_pwd" == "$PROJECTS_DIR/gamma" ]]
created_branch="$(git -C "$PROJECTS_DIR/gamma/service-b" branch --show-current)"
[[ "$created_branch" == "feature/gamma" ]]

mkdir -p "$TMP_HOME/fake-bin"
real_git="$(command -v git)"
cat > "$TMP_HOME/fake-bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"$FAIL_WORKTREE_REPO"* && "$*" == *"worktree add"* ]]; then
    "$REAL_GIT" -C "$FAIL_WORKTREE_REPO" branch feature/delta origin/main
    mkdir -p "$PROJECTS_DIR/delta/service-c"
    exit 1
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP_HOME/fake-bin/git"

rollback_output=""
if rollback_output="$(PATH="$TMP_HOME/fake-bin:$PATH" REAL_GIT="$real_git" FAIL_WORKTREE_REPO="$REPOS_DIR/service-c" zsh -fc "$source_personal; proj delta service-b service-c" 2>&1)"; then
    echo "expected second worktree creation to fail" >&2
    exit 1
fi
[[ "$rollback_output" == *"worktree add failed for service-c"* ]]
[[ ! -e "$PROJECTS_DIR/delta" ]]
if git -C "$REPOS_DIR/service-b" show-ref --verify --quiet refs/heads/feature/delta; then
    echo "rollback left feature/delta in service-b" >&2
    exit 1
fi
if git -C "$REPOS_DIR/service-c" show-ref --verify --quiet refs/heads/feature/delta; then
    echo "rollback left feature/delta in service-c" >&2
    exit 1
fi

mkdir -p "$TMP_HOME/fba-copy/claude" "$TMP_HOME/.claude"
cat > "$TMP_HOME/fba-copy/claude/settings.json" <<'JSON'
{
  "fastMode": false,
  "hooks": {"baseline": true},
  "env": {"PORTABLE": "1"}
}
JSON
cat > "$TMP_HOME/.claude/settings.json" <<'JSON'
{
  "fastMode": true,
  "hooks": {"private": true},
  "env": {"PRIVATE_TOKEN": "do-not-import"},
  "mcpServers": {"private": {"url": "https://private.example"}}
}
JSON
zsh -fc "$source_personal; FBA_ROOT='$TMP_HOME/fba-copy'; claude-sync >/dev/null"
jq -e '
  .fastMode == true
  and .hooks == {"baseline": true}
  and .env == {"PORTABLE": "1"}
  and (has("mcpServers") | not)
' "$TMP_HOME/fba-copy/claude/settings.json" >/dev/null

echo "project helpers regression passed"
