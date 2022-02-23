#/usr/bin/env bash
_rp_completions() {
    local cur opts repo_path
    repo_path="/Users/mho/repos"
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="$(ls $repo_path)"
		COMPREPLY=($(compgen -W "${opts}" ${cur}))
}

complete -F _rp_completions "/Users/mho/repos/fun-bash-automations/rp/rp.sh"
