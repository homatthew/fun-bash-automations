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
    _rp_describe_dirs() {
        emulate -L zsh
        local root="$1" tag="$2" label="$3" dir name branch dirty desc
        local -a entries

        [[ -d "$root" ]] || return 1
        while IFS= read -r dir; do
            name="${dir##*/}"
            desc="$label"
            if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
                branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
                [[ -n "$branch" ]] || branch="detached"
                dirty="$(git -C "$dir" status --short 2>/dev/null | wc -l | tr -d ' ')"
                if [[ "$dirty" == "0" ]]; then
                    desc="$branch, clean"
                else
                    desc="$branch, $dirty changes"
                fi
            fi
            entries+=("$name:$desc")
        done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

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
    _rp_completion_dir_names() {
        local root="$1"
        [[ -d "$root" ]] || return 0
        find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null
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
