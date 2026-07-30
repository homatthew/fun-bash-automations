#!/usr/bin/env bash
# Guards the rp/proj completion fast path.
#
# These completions used to run `git rev-parse` + `git branch --show-current` +
# `git status --short` once per directory under $REPOS_DIR. Against ~70 clones
# that measured 3.1s for `rp <TAB>` and 4.5-5.4s for `rp archive <TAB>`, paid on
# every single Tab press with no caching. The fast path reads .git/HEAD directly
# and forks nothing; `git status` is opt-in behind FBA_COMPLETION_SHOW_DIRTY.
#
# The load-bearing assertion is "the default path never invokes git" (a `git`
# stub on PATH makes any invocation fail loudly), not a wall-clock number.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d -t fba-completion-perf-XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

REAL_GIT="$(command -v git)"

export PROJECTS_DIR="$TMP_HOME/projects"
export REPOS_DIR="$TMP_HOME/repos"
export REPOS_ARCHIVE_DIR="$TMP_HOME/repos-archive"
export FBA_ROOT="$ROOT"
mkdir -p "$REPOS_DIR" "$REPOS_ARCHIVE_DIR" "$PROJECTS_DIR"

mkrepo() {
    local dir="$1" branch="$2"
    mkdir -p "$dir"
    "$REAL_GIT" -C "$dir" init -q --initial-branch="$branch" >/dev/null
    "$REAL_GIT" -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

mkrepo "$REPOS_DIR/alpha" main
mkrepo "$REPOS_DIR/beta" feature/some-work
mkrepo "$REPOS_ARCHIVE_DIR/gamma" main
mkdir -p "$REPOS_DIR/not-a-repo"

# Detached HEAD.
mkrepo "$REPOS_DIR/delta" main
"$REAL_GIT" -C "$REPOS_DIR/delta" checkout -q --detach HEAD

# Linked worktree: .git is a *file* containing "gitdir: <path>", not a directory.
"$REAL_GIT" -C "$REPOS_DIR/alpha" worktree add -q -b wt/side "$REPOS_DIR/epsilon" >/dev/null 2>&1
[[ -f "$REPOS_DIR/epsilon/.git" ]] || { echo "expected a .git file in the worktree" >&2; exit 1; }

mkdir -p "$PROJECTS_DIR/proj-one/repo-a" "$PROJECTS_DIR/proj-one/repo-b"

load='source "$FBA_ROOT/zsh/personal.zsh" >/dev/null 2>&1'

# --- branch resolution matches git, without calling git -----------------------
for probe in "alpha:main" "beta:feature/some-work" "epsilon:wt/side" "delta:detached"; do
    dir="${probe%%:*}"
    want="${probe#*:}"
    got="$(zsh -fc "$load; _fba_git_branch_fast \"$REPOS_DIR/$dir\" && print -r -- \"\$REPLY\"")"
    if [[ "$got" != "$want" ]]; then
        echo "branch mismatch for $dir: want '$want', got '$got'" >&2
        exit 1
    fi
done

# A non-repo directory must report failure rather than a bogus branch.
if zsh -fc "$load; _fba_git_branch_fast \"$REPOS_DIR/not-a-repo\"" 2>/dev/null; then
    echo "expected _fba_git_branch_fast to fail on a non-repo directory" >&2
    exit 1
fi

# --- the default path must not invoke git at all ------------------------------
# A `git` shim that always fails turns any accidental fork into a visible error.
mkdir -p "$TMP_HOME/bin"
cat > "$TMP_HOME/bin/git" <<'STUB'
#!/bin/sh
echo "FORBIDDEN_GIT_CALL $*" >&2
exit 127
STUB
chmod +x "$TMP_HOME/bin/git"

# _describe is called as `_describe -t <tag> <label> <arrayname>`; zsh dynamic
# scoping makes the caller-local array visible through the (P) flag.
describe_probe='
_describe() { shift 3; print -rl -- "${(@P)1}" }
_message() { : }
typeset -a words; words=(rp "")
integer CURRENT=2
'

nogit_out="$(PATH="$TMP_HOME/bin:$PATH" zsh -fc "
    $load
    source \"\$FBA_ROOT/rp/rp-completion.sh\" >/dev/null 2>&1
    $describe_probe
    FBA_COMPLETION_CACHE_TTL=0 _rp_describe_dirs \"$REPOS_DIR\" repositories repositories
" 2>&1)"

if [[ "$nogit_out" == *FORBIDDEN_GIT_CALL* ]]; then
    echo "default completion path forked git:" >&2
    printf '%s\n' "$nogit_out" >&2
    exit 1
fi
for want in alpha beta delta epsilon not-a-repo; do
    [[ "$nogit_out" == *"$want"* ]] || { echo "missing '$want' in completions: $nogit_out" >&2; exit 1; }
done
# Branch descriptions still arrive, read straight from .git/HEAD.
[[ "$nogit_out" == *"feature/some-work"* ]] || { echo "expected branch descriptions: $nogit_out" >&2; exit 1; }

# proj completions share the same fast path.
proj_out="$(PATH="$TMP_HOME/bin:$PATH" zsh -fc "
    $load
    $describe_probe
    FBA_COMPLETION_CACHE_TTL=0 _proj_describe_projects
    FBA_COMPLETION_CACHE_TTL=0 _proj_describe_source_repos
" 2>&1)"
if [[ "$proj_out" == *FORBIDDEN_GIT_CALL* ]]; then
    echo "proj completion path forked git:" >&2
    printf '%s\n' "$proj_out" >&2
    exit 1
fi
[[ "$proj_out" == *"proj-one"* ]] || { echo "missing project in completions: $proj_out" >&2; exit 1; }
[[ "$proj_out" == *"2 repos"* ]] || { echo "missing repo count: $proj_out" >&2; exit 1; }

# --- dirty counts stay reachable, but only when explicitly requested ----------
dirty_out="$(zsh -fc "
    $load
    source \"\$FBA_ROOT/rp/rp-completion.sh\" >/dev/null 2>&1
    $describe_probe
    print -r -- untracked > \"$REPOS_DIR/beta/scratch.txt\"
    FBA_COMPLETION_SHOW_DIRTY=1 FBA_COMPLETION_CACHE_TTL=0 \
        _rp_describe_dirs \"$REPOS_DIR\" repositories repositories
" 2>&1)"
[[ "$dirty_out" == *"1 changes"* ]] || { echo "expected a dirty count under FBA_COMPLETION_SHOW_DIRTY: $dirty_out" >&2; exit 1; }
[[ "$dirty_out" == *"main, clean"* ]] || { echo "expected a clean marker under FBA_COMPLETION_SHOW_DIRTY: $dirty_out" >&2; exit 1; }

# --- the TTL cache serves repeat Tab presses ---------------------------------
# Second call must answer from cache even though git is unavailable *and* the
# directory gained a new entry, proving it did not re-scan.
cache_out="$(PATH="$TMP_HOME/bin:$PATH" zsh -fc "
    $load
    $describe_probe
    _fba_describe_checkouts \"$REPOS_DIR\" repositories repositories >/dev/null
    mkdir -p \"$REPOS_DIR/zeta-added-after-cache\"
    _fba_describe_checkouts \"$REPOS_DIR\" repositories repositories
" 2>&1)"
[[ "$cache_out" != *zeta-added-after-cache* ]] || { echo "expected the cached entry list: $cache_out" >&2; exit 1; }

# TTL=0 disables the cache, so the new directory shows up immediately.
uncached_out="$(PATH="$TMP_HOME/bin:$PATH" zsh -fc "
    $load
    $describe_probe
    FBA_COMPLETION_CACHE_TTL=0 _fba_describe_checkouts \"$REPOS_DIR\" repositories repositories
" 2>&1)"
[[ "$uncached_out" == *zeta-added-after-cache* ]] || { echo "expected a fresh scan with TTL=0: $uncached_out" >&2; exit 1; }

# --- FBA_COMPLETION_SHOW_DIRTY=0 must mean off, not "on with the off cache key"
# The key used ${VAR:-0} while the condition used -n "$VAR", so an explicit 0
# enabled the slow path but shared the disabled cache entry, letting dirty
# results leak into default completions and vice versa.
zero_out="$(PATH="$TMP_HOME/bin:$PATH" zsh -fc "
    $load
    source \"\$FBA_ROOT/rp/rp-completion.sh\" >/dev/null 2>&1
    $describe_probe
    FBA_COMPLETION_SHOW_DIRTY=0 FBA_COMPLETION_CACHE_TTL=0 \
        _rp_describe_dirs \"$REPOS_DIR\" repositories repositories
" 2>&1)"
if [[ "$zero_out" == *FORBIDDEN_GIT_CALL* ]]; then
    echo "FBA_COMPLETION_SHOW_DIRTY=0 must not enable the git status path:" >&2
    printf '%s\n' "$zero_out" >&2
    exit 1
fi
[[ "$zero_out" != *"changes"* ]] || { echo "FBA_COMPLETION_SHOW_DIRTY=0 must not report dirty counts: $zero_out" >&2; exit 1; }

# A dirty-enabled result must not be served from the disabled cache entry.
mixed_out="$(zsh -fc "
    $load
    source \"\$FBA_ROOT/rp/rp-completion.sh\" >/dev/null 2>&1
    $describe_probe
    print -r -- untracked > \"$REPOS_DIR/alpha/scratch2.txt\"
    FBA_COMPLETION_SHOW_DIRTY=0 _rp_describe_dirs \"$REPOS_DIR\" repositories repositories >/dev/null
    FBA_COMPLETION_SHOW_DIRTY=1 _rp_describe_dirs \"$REPOS_DIR\" repositories repositories
" 2>&1)"
[[ "$mixed_out" == *"changes"* ]] || { echo "enabling dirty counts must not hit the disabled cache entry: $mixed_out" >&2; exit 1; }

echo "completion-performance-regression: ok"
