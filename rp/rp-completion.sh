#!/usr/bin/env bash
# Completion for rp command (supports both bash and zsh)

_rp_repos="/Users/matthewho/repos"
_rp_archive_dir="/Users/matthewho/repos-archive"

# Zsh completion
if [[ -n "$ZSH_VERSION" ]]; then
    _rp_completion() {
        local -a subcmds repos archived
        subcmds=(
            'archive:move repo to archive'
            'unarchive:restore repo from archive'
            'list:list all repos'
            'archived:list archived repos'
        )

        if (( CURRENT == 2 )); then
            # First argument: subcommands + repo names
            repos=("${(@f)$(ls "$_rp_repos" 2>/dev/null)}")
            _describe 'subcommand' subcmds
            _describe 'repo' repos
        elif (( CURRENT >= 3 )); then
            case "${words[2]}" in
                archive)
                    repos=("${(@f)$(ls "$_rp_repos" 2>/dev/null)}")
                    _describe 'repo' repos
                    ;;
                unarchive)
                    archived=("${(@f)$(ls "$_rp_archive_dir" 2>/dev/null)}")
                    _describe 'archived repo' archived
                    ;;
            esac
        fi
    }
    compdef _rp_completion rp

# Bash completion
elif [[ -n "$BASH_VERSION" ]]; then
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
            local subcmds="archive unarchive list archived"
            local repos="$(ls "$_rp_repos" 2>/dev/null)"
            COMPREPLY=($(compgen -W "$subcmds $repos" -- "$cur"))
        elif [[ $cword -ge 2 ]]; then
            case "${COMP_WORDS[1]}" in
                archive)
                    COMPREPLY=($(compgen -W "$(ls "$_rp_repos" 2>/dev/null)" -- "$cur"))
                    ;;
                unarchive)
                    COMPREPLY=($(compgen -W "$(ls "$_rp_archive_dir" 2>/dev/null)" -- "$cur"))
                    ;;
            esac
        fi
    }
    complete -F _rp_completions rp
fi
