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

rp_pwd="$(zsh -fc "$source_personal; rp service-b >/dev/null; pwd")"
[[ "$rp_pwd" == "$REPOS_DIR/service-b" ]]

created_pwd="$(zsh -fc "$source_personal; proj gamma service-b >/dev/null 2>&1 || exit \$?; pwd")"
[[ "$created_pwd" == "$PROJECTS_DIR/gamma" ]]
created_branch="$(git -C "$PROJECTS_DIR/gamma/service-b" branch --show-current)"
[[ "$created_branch" == "mho/gamma" ]]

echo "project helpers regression passed"
