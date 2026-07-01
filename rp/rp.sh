#!/usr/bin/env bash
# rp - Repository navigation and archive management
# Usage:
#   rp <repo>              - cd to ~/repos/<repo>
#   rp archive <repo>...   - move repo(s) to ~/repos-archive/
#   rp unarchive <repo>... - move repo(s) back from ~/repos-archive/
#   rp list                - list all repos
#   rp archived            - list archived repos

_rp_home="${HOME}"
_rp_repos="${REPOS_DIR:-$_rp_home/repos}"
_rp_archive="${REPOS_ARCHIVE_DIR:-$_rp_home/repos-archive}"

_rp_error() {
    echo "rp: $1" >&2
    return 1
}

_rp_archive_one() {
    local repo="$1"
    local src="$_rp_repos/$repo"
    local dst="$_rp_archive/$repo"

    if [[ ! -d "$src" ]]; then
        _rp_error "repo '$repo' not found in $_rp_repos"
        return 1
    fi
    if [[ -e "$dst" ]]; then
        _rp_error "'$repo' already exists in archive"
        return 1
    fi

    # Ensure archive directory exists
    [[ -d "$_rp_archive" ]] || mkdir -p "$_rp_archive"

    echo "Archiving: $repo"
    mv "$src" "$dst" && echo "  -> $_rp_archive/$repo"
}

_rp_unarchive_one() {
    local repo="$1"
    local src="$_rp_archive/$repo"
    local dst="$_rp_repos/$repo"

    if [[ ! -d "$src" ]]; then
        _rp_error "repo '$repo' not found in $_rp_archive"
        return 1
    fi
    if [[ -e "$dst" ]]; then
        _rp_error "'$repo' already exists in repos"
        return 1
    fi

    echo "Unarchiving: $repo"
    mv "$src" "$dst" && echo "  -> $_rp_repos/$repo"
}

rp() {
    local cmd="$1"

    case "$cmd" in
        archive)
            shift
            if [[ $# -eq 0 ]]; then
                _rp_error "usage: rp archive <repo>..."
                return 1
            fi
            local failed=0
            for repo in "$@"; do
                _rp_archive_one "$repo" || ((failed++))
            done
            [[ $failed -eq 0 ]]
            ;;
        unarchive)
            shift
            if [[ $# -eq 0 ]]; then
                _rp_error "usage: rp unarchive <repo>..."
                return 1
            fi
            local failed=0
            for repo in "$@"; do
                _rp_unarchive_one "$repo" || ((failed++))
            done
            [[ $failed -eq 0 ]]
            ;;
        list|ls)
            ls "$_rp_repos"
            ;;
        archived)
            ls "$_rp_archive"
            ;;
        "")
            cd "$_rp_repos"
            ;;
        *)
            # Default: cd to the repo
            local target="$_rp_repos/$cmd"
            if [[ ! -d "$target" ]]; then
                _rp_error "repo '$cmd' not found"
                return 1
            fi
            cd "$target"
            ;;
    esac
}
