#!/usr/bin/env bash
# Completion for rp command (supports both bash and zsh)

_rp_completion_repos_dir() {
    printf '%s\n' "${REPOS_DIR:-$HOME/repos}"
}

_rp_completion_archive_dir() {
    printf '%s\n' "${REPOS_ARCHIVE_DIR:-$HOME/repos-archive}"
}

# Zsh completion
if [[ -n "$ZSH_VERSION" ]]; then
    # Delegates to the shared fork-free helper in zsh/personal.zsh. The previous
    # implementation ran `git rev-parse` + `git branch` + `git status` per
    # directory, which measured 3.1s for `rp <TAB>` and 4.5-5.4s for the
    # archive subcommands against ~70 clones. Set FBA_COMPLETION_SHOW_DIRTY=1
    # to get dirty counts back at that cost.
    _rp_describe_dirs() {
        emulate -L zsh
        local root="$1" tag="$2" label="$3"

        if (( $+functions[_fba_describe_checkouts] )); then
            _fba_describe_checkouts "$root" "$tag" "$label"
            return
        fi

        # Standalone fallback: names only, still no per-repo forks.
        local dir
        local -a entries
        [[ -d "$root" ]] || return 1
        for dir in "$root"/*(/N); do
            entries+=("${dir:t}:$label")
        done
        (( ${#entries[@]} )) || return 1
        _describe -t "$tag" "$label" entries
    }

    _rp_completion() {
        local repos_dir archive_dir
        local -a subcmds
        repos_dir="$(_rp_completion_repos_dir)"
        archive_dir="$(_rp_completion_archive_dir)"

        subcmds=(
            'archive:move repo to archive'
            'unarchive:restore repo from archive'
            'list:list all repos'
            'ls:list all repos'
            'archived:list archived repos'
        )

        if (( CURRENT == 2 )); then
            _describe -t commands 'rp commands' subcmds
            _rp_describe_dirs "$repos_dir" repositories 'repositories'
        elif (( CURRENT >= 3 )); then
            case "${words[2]}" in
                archive)
                    _rp_describe_dirs "$repos_dir" repositories 'repositories'
                    ;;
                unarchive)
                    _rp_describe_dirs "$archive_dir" archived-repositories 'archived repositories'
                    ;;
            esac
        fi
    }

    if (( $+functions[_fba_compdef] )); then
        _fba_compdef _rp_completion rp
    elif (( $+functions[compdef] )); then
        compdef _rp_completion rp
    fi

# Bash completion
elif [[ -n "$BASH_VERSION" ]]; then
    # Plain glob, no `find`/`basename` fork per directory.
    _rp_completion_dir_names() {
        local root="$1" dir
        [[ -d "$root" ]] || return 0
        for dir in "$root"/*/; do
            dir="${dir%/}"
            [[ -d "$dir" ]] || continue
            printf '%s\n' "${dir##*/}"
        done
    }

    _rp_completions() {
        local cur prev words cword
        _init_completion 2>/dev/null || {
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            cword=$COMP_CWORD
        }

        if [[ $cword -eq 1 ]]; then
            # First argument: subcommands + repo names
            local subcmds="archive unarchive list ls archived"
            local repos="$(_rp_completion_dir_names "$(_rp_completion_repos_dir)")"
            COMPREPLY=($(compgen -W "$subcmds $repos" -- "$cur"))
        elif [[ $cword -ge 2 ]]; then
            case "${COMP_WORDS[1]}" in
                archive)
                    COMPREPLY=($(compgen -W "$(_rp_completion_dir_names "$(_rp_completion_repos_dir)")" -- "$cur"))
                    ;;
                unarchive)
                    COMPREPLY=($(compgen -W "$(_rp_completion_dir_names "$(_rp_completion_archive_dir)")" -- "$cur"))
                    ;;
            esac
        fi
    }
    complete -F _rp_completions rp
fi
