# Personal zsh configuration
# This file contains personal shell settings, aliases, and functions

# ==============================================================================
# Oh My Zsh Configuration
# ==============================================================================
# Install oh-my-zsh if not present:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

# Disable auto-title from oh-my-zsh and Claude Code
DISABLE_AUTO_TITLE="true"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

# Terminal title: shows "dirname (branch)" or just "dirname" if not in git repo
# Works with Ghostty (requires shell-integration-features = no-title)
function set_terminal_title() {
    local dir="${PWD##*/}"
    local branch=$(git branch --show-current 2>/dev/null)
    if [[ -n "$branch" ]]; then
        printf '\033]2;%s (%s)\007' "$dir" "$branch"
    else
        printf '\033]2;%s\007' "$dir"
    fi
}

# Update title on directory change and shell startup
autoload -Uz add-zsh-hook
add-zsh-hook chpwd set_terminal_title
set_terminal_title


export ZSH="$HOME/.oh-my-zsh"

# Disable oh-my-zsh theme (using custom prompt below)
ZSH_THEME=""

# Plugins - add wisely, too many slow down shell startup
plugins=(
    z                # jump to frequently used directories
    fzf              # fuzzy finder integration
    history          # history aliases (h, hs, hsi)
    colored-man-pages
    command-not-found
)

# Load oh-my-zsh (skip if not installed)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

# ==============================================================================
# History Configuration (extends oh-my-zsh defaults)
# ==============================================================================
# oh-my-zsh sets HISTSIZE=50000, SAVEHIST=10000 - we increase SAVEHIST
SAVEHIST=50000

# Additional history options not set by oh-my-zsh
setopt HIST_FIND_NO_DUPS         # Don't display duplicates in search
setopt HIST_SAVE_NO_DUPS         # Don't write duplicates to history file
setopt HIST_REDUCE_BLANKS        # Remove extra blanks
setopt INC_APPEND_HISTORY        # Add commands immediately

# ==============================================================================
# Key Bindings (extends oh-my-zsh defaults)
# ==============================================================================
# History search with arrow keys (type partial command, then up/down)
# oh-my-zsh binds up/down to basic history navigation; we override for prefix search
bindkey '^[[A' history-beginning-search-backward  # Up arrow
bindkey '^[[B' history-beginning-search-forward   # Down arrow
bindkey '^P' history-beginning-search-backward
bindkey '^N' history-beginning-search-forward

# Word navigation with Option/Alt + arrow keys (macOS)
bindkey '^[[1;3C' forward-word   # Option + Right
bindkey '^[[1;3D' backward-word  # Option + Left

# Delete word backward with Option + Backspace
bindkey '^[^?' backward-kill-word

# ==============================================================================
# Completion Configuration (extends oh-my-zsh defaults)
# ==============================================================================
# Group completions by type with colored headers
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'

# Git completion (supplement oh-my-zsh)
zstyle ':completion:*:*:git:*' script ~/.zsh/git-completion.bash
fpath=(~/.zsh $fpath)

# ==============================================================================
# FZF Configuration (fuzzy finder)
# ==============================================================================
# Install fzf: brew install fzf && $(brew --prefix)/opt/fzf/install
if command -v fzf &> /dev/null; then
    # Use fd for fzf if available (faster than find)
    if command -v fd &> /dev/null; then
        export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
        export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
        export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
    fi

    # FZF options
    export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
    export FZF_CTRL_R_OPTS='--sort --exact'

    # Source fzf keybindings and completion
    [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

    # ==========================================================================
    # FZF-Git Integration
    # ==========================================================================
    # Keybindings (press Ctrl+G then the second key):
    #   Ctrl+G Ctrl+B - branches
    #   Ctrl+G Ctrl+T - tags
    #   Ctrl+G Ctrl+H - commit hashes (log)
    #   Ctrl+G Ctrl+R - remotes
    #   Ctrl+G Ctrl+S - stashes
    #   Ctrl+G Ctrl+F - files (git status)

    # Check if inside git repo
    _fzf_git_check() {
        git rev-parse HEAD > /dev/null 2>&1 || return 1
    }

    # Branches
    _fzf_git_branches() {
        _fzf_git_check || return
        git branch -a --color=always | grep -v '/HEAD\s' | sort |
        fzf --ansi --multi --tac --preview-window right:70% \
            --preview 'git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" $(sed s/^..// <<< {} | cut -d" " -f1) | head -200' |
        sed 's/^..//' | cut -d' ' -f1 | sed 's#^remotes/##'
    }

    # Tags
    _fzf_git_tags() {
        _fzf_git_check || return
        git tag --sort -version:refname |
        fzf --multi --preview-window right:70% \
            --preview 'git show --color=always {} | head -200'
    }

    # Commit hashes
    _fzf_git_hashes() {
        _fzf_git_check || return
        git log --date=short --format="%C(green)%C(bold)%cd %C(auto)%h%d %s (%an)" --graph --color=always |
        fzf --ansi --no-sort --multi --bind 'ctrl-s:toggle-sort' \
            --header 'Press CTRL-S to toggle sort' \
            --preview 'grep -o "[a-f0-9]\{7,\}" <<< {} | head -1 | xargs git show --color=always | head -200' |
        grep -o "[a-f0-9]\{7,\}" | head -1
    }

    # Remotes
    _fzf_git_remotes() {
        _fzf_git_check || return
        git remote -v | awk '{print $1 "\t" $2}' | uniq |
        fzf --tac \
            --preview 'git log --oneline --graph --date=short --color=always --pretty="format:%C(auto)%cd %h%d %s" {1}/$(git rev-parse --abbrev-ref HEAD) | head -200' |
        cut -d$'\t' -f1
    }

    # Stashes
    _fzf_git_stashes() {
        _fzf_git_check || return
        git stash list |
        fzf --no-sort --reverse -d: \
            --preview 'git show --color=always {1} | head -200' |
        cut -d: -f1
    }

    # Files (from git status)
    _fzf_git_files() {
        _fzf_git_check || return
        git -c color.status=always status --short |
        fzf --ansi --multi --preview-window right:70% \
            --preview '(git diff --color=always -- {-1} | head -500; cat {-1}) 2>/dev/null | head -500' |
        cut -c4- | sed 's/.* -> //'
    }

    # Bind Ctrl+G as a prefix key for git operations
    _fzf_git_join() {
        local item
        while read item; do
            echo -n "${(q)item} "
        done
    }

    _fzf_git_init() {
        local o
        for o in branches tags hashes remotes stashes files; do
            eval "_fzf-gt-$o-widget() { local result=\$(_fzf_git_$o | _fzf_git_join); zle reset-prompt; LBUFFER+=\$result }"
            eval "zle -N _fzf-gt-$o-widget"
        done
    }
    _fzf_git_init

    # Ctrl+G, Ctrl+<key> bindings
    bindkey -r '^g'
    bindkey '^g^b' _fzf-gt-branches-widget   # Branches
    bindkey '^g^t' _fzf-gt-tags-widget       # Tags
    bindkey '^g^h' _fzf-gt-hashes-widget     # Hashes
    bindkey '^g^r' _fzf-gt-remotes-widget    # Remotes
    bindkey '^g^s' _fzf-gt-stashes-widget    # Stashes
    bindkey '^g^f' _fzf-gt-files-widget      # Files
fi

# ==============================================================================
# Zsh Autosuggestions / Syntax Highlighting
# ==============================================================================
# Install: brew install zsh-autosuggestions zsh-syntax-highlighting
# Path differs by OS / CPU:
#   macOS Apple Silicon: /opt/homebrew/share
#   macOS Intel:         /usr/local/share
#   Linux Homebrew:      /home/linuxbrew/.linuxbrew/share
#   Debian/Ubuntu apt:   /usr/share
_source_first() {
    local f
    for f in "$@"; do
        [ -f "$f" ] && source "$f" && return 0
    done
    return 1
}

# Ghostty-over-SSH can visibly duplicate in-flight autosuggestion fragments while
# repainting the prompt. Keep suggestions, but avoid the async redraw path there.
_mho_disable_async_autosuggest=0
if (( ! ${+ZSH_AUTOSUGGEST_USE_ASYNC} )) && [[ ( "${TERM_PROGRAM:-}" == "ghostty" || "${TERM:-}" == *ghostty* ) && -n "${SSH_TTY:-${SSH_CONNECTION:-}}" ]]; then
    _mho_disable_async_autosuggest=1
fi
_source_first \
    /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /home/linuxbrew/.linuxbrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh \
    ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
if [[ "$_mho_disable_async_autosuggest" == "1" ]]; then
    unset ZSH_AUTOSUGGEST_USE_ASYNC
fi
unset _mho_disable_async_autosuggest
bindkey '^ ' autosuggest-accept  # Ctrl+Space to accept suggestion

# Syntax highlighting must be last plugin sourced.
_source_first \
    /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /home/linuxbrew/.linuxbrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh \
    ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
unset -f _source_first

# ==============================================================================
# Custom Prompt
# ==============================================================================
# Format: 23:43:17 ~/repos/project branch $
autoload -Uz vcs_info
precmd() { vcs_info }
zstyle ':vcs_info:git:*' formats '%b '
setopt PROMPT_SUBST
PROMPT='%F{green}%*%f %F{blue}%~%f %F{red}${vcs_info_msg_0_}%f$ '

# ==============================================================================
# Shell Startup
# ==============================================================================
printf '\33c\e[3J'  # Clear screen and scrollback
echo $fg[yellow]'Loaded mho ~/.zshrc'$reset_color

# ==============================================================================
# Environment Variables
# ==============================================================================
export LSCOLORS=ExGxBxDxCxEgEdxbxgxcxd
export GOPATH=$HOME/golang
# GOROOT differs per OS / install method. Prefer `go env GOROOT` when Go is
# on PATH; fall back to common install locations. Safe to leave unset if Go
# is managed by a version manager (gvm, asdf, etc.).
if command -v go >/dev/null 2>&1; then
    export GOROOT="$(go env GOROOT 2>/dev/null)"
elif [ -d /opt/homebrew/opt/go/libexec ]; then
    export GOROOT=/opt/homebrew/opt/go/libexec   # macOS Apple Silicon
elif [ -d /usr/local/opt/go/libexec ]; then
    export GOROOT=/usr/local/opt/go/libexec      # macOS Intel
elif [ -d /usr/lib/go ]; then
    export GOROOT=/usr/lib/go                    # Debian/Ubuntu
fi
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
_mho_personal_zsh="${${(%):-%x}:A}"
_mho_fba_root="${_mho_personal_zsh:h:h}"
if [ ! -x "$_mho_fba_root/bin/fba-deploy" ]; then
    _mho_fba_root="$HOME/repos/fun-bash-automations"
fi
export FBA_ROOT="${FBA_ROOT:-$_mho_fba_root}"
if [ -d "$FBA_ROOT/bin" ]; then
  export PATH=$HOME/.local/bin:$FBA_ROOT/bin:$PATH
else
  export PATH=$HOME/.local/bin:$PATH
fi
if [ -d "$BUN_INSTALL/bin" ]; then
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
export PATH=$PATH:$GOPATH/bin
[ -n "${GOROOT:-}" ] && export PATH=$PATH:$GOROOT/bin
export PATH=$PATH:/usr/local/bin/
export PATH=$PATH:$HOME/.temporal

# no-mistakes: automatically isolate gate state inside manual treehouse
# worktrees. firstmate sets NM_HOME explicitly for crewmates; this hook covers
# ad hoc `treehouse get` shells without overriding a user-chosen NM_HOME.
# `--activate` also scopes the no-mistakes git remote into worktree-local config
# so concurrent worktrees do not race on a shared gate remote.
if [[ -n "$ZSH_VERSION" ]]; then
    _fba_nm_home_chpwd() {
        emulate -L zsh
        [[ "${NM_HOME_AUTOSCOPE:-1}" == "1" ]] || return 0
        command -v nm-home >/dev/null 2>&1 || return 0

        local root treehouse_root nmh
        root=$(git rev-parse --show-toplevel 2>/dev/null) || {
            if [[ -n "${NM_HOME_AUTO:-}" ]]; then
                unset NM_HOME NM_HOME_AUTO
            fi
            return 0
        }
        root=${root:A}
        treehouse_root="${TREEHOUSE_HOME:-$HOME/.treehouse}"
        treehouse_root=${treehouse_root:A}

        if [[ "${NM_HOME_AUTOSCOPE_ALL:-0}" != "1" && "$root" != "$treehouse_root"/* ]]; then
            if [[ -n "${NM_HOME_AUTO:-}" ]]; then
                unset NM_HOME NM_HOME_AUTO
            fi
            return 0
        fi
        if [[ -n "${NM_HOME:-}" && -z "${NM_HOME_AUTO:-}" ]]; then
            return 0
        fi

        nmh=$(nm-home --for "$root" --mkdir --activate 2>/dev/null) || return 0
        export NM_HOME="$nmh"
        export NM_HOME_AUTO=1
    }

    autoload -Uz add-zsh-hook
    add-zsh-hook chpwd _fba_nm_home_chpwd
    _fba_nm_home_chpwd
fi

# ==============================================================================
# Aliases
# ==============================================================================
# Virtual environment helpers
alias svenv='source .venv/bin/activate'
alias rrc='source ~/.zshrc'

# Git aliases
alias gca='git commit --amend'
alias gcane='gca --no-edit --no-verify'
alias gpo='git push origin'
alias gpofwl='gpo --force-with-lease'
alias gpu='git push upstream'
alias gpufwl='gpu --force-with-lease'
alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias gb='git branch'
alias gl='git log --pretty=format:"%h %d - %an, %ar : %s" --decorate=short'
alias grb='git rebase'
alias grbc='git rebase --continue'
alias rbi='git rebase -i master'
alias squash='rbi && gca'

if [[ -n "$ZSH_VERSION" ]]; then
    typeset -ga _fba_pending_compdefs

    _fba_register_pending_compdefs() {
        emulate -L zsh
        (( $+functions[compdef] )) || return 1

        local spec
        for spec in "${_fba_pending_compdefs[@]}"; do
            eval "compdef $spec"
        done
        _fba_pending_compdefs=()

        if (( $+functions[add-zsh-hook] )); then
            add-zsh-hook -d precmd _fba_register_pending_compdefs 2>/dev/null || true
        fi
    }

    _fba_compdef() {
        emulate -L zsh
        if (( $+functions[compdef] )); then
            compdef "$@"
            return
        fi

        _fba_pending_compdefs+=("${(j: :)${(q)@}}")
        autoload -Uz add-zsh-hook
        if (( ! ${precmd_functions[(I)_fba_register_pending_compdefs]} )); then
            add-zsh-hook precmd _fba_register_pending_compdefs
        fi
    }
fi

# rp - repository navigation (source function, then load completion)
[ -f "$FBA_ROOT/rp/rp.sh" ] && source "$FBA_ROOT/rp/rp.sh"
[ -f "$FBA_ROOT/rp/rp-completion.sh" ] && source "$FBA_ROOT/rp/rp-completion.sh"

# ==============================================================================
# LLM Config Sync
# ==============================================================================
# Shared instructions/skills are canonical in ~/repos/fun-bash-automations/llm.
# Use fba-deploy to project repo-owned runtime files into ~/.claude and ~/.codex.

# claude-sync: Import portable Claude preferences into the repo baseline.
claude-sync() {
    local src="$HOME/.claude/settings.json"
    local dst="$FBA_ROOT/claude/settings.json"
    local tmp

    [[ -f "$src" ]] || { echo "claude-sync: missing $src" >&2; return 1; }
    [[ -f "$dst" ]] || { echo "claude-sync: missing $dst" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || { echo "claude-sync: jq is required" >&2; return 1; }

    tmp="$(mktemp "$dst.XXXXXX")" || return 1
    if ! jq -s '
        .[0] as $base | .[1] as $local |
        reduce ["alwaysThinkingEnabled", "autoUpdatesChannel", "fastMode", "showClearContextOnPlanAccept"][] as $key
          ($base; if ($local | has($key)) then .[$key] = $local[$key] else . end)
    ' "$dst" "$src" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dst"
    echo "Synced portable Claude preferences → $dst"
}

# fba-deploy: Project repo-owned LLM config into local runtimes.
fba-deploy() {
    if [ -x "$FBA_ROOT/bin/fba-deploy" ]; then
        "$FBA_ROOT/bin/fba-deploy" "$@"
    elif command -v fba-deploy >/dev/null 2>&1; then
        command fba-deploy "$@"
    else
        echo "fba-deploy missing: $FBA_ROOT/bin/fba-deploy"
        return 1
    fi
}

# Backward-compatible wrappers
claude-deploy() {
    fba-deploy --claude-only "$@"
}

codex-deploy() {
    fba-deploy --codex-only "$@"
}

# agent-refresh: project shared AGENTS + skills into both Claude and Codex homes.
agent-refresh() {
    fba-deploy --shared-only
}
alias llm-refresh=agent-refresh
alias llm-deploy=fba-deploy

_mho_format_epoch_local() {
    local epoch="$1"
    local formatted
    formatted="$(date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null)" && {
        echo "$formatted"
        return 0
    }
    formatted="$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null)" && {
        echo "$formatted"
        return 0
    }
    echo "$epoch"
}

# ssh-gate: Allow agents to SSH into specific hosts for a bounded lease.
# Creates a lease file with the host and expiry timestamp.
# Usage:
#   ssh-gate [--hours N] <instance-id-or-host>...
#   ssh-gate [--hours N] --file nodes.txt
ssh-gate() {
    local hours=12
    local hosts=()
    local host_file=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --hours)
                if [ -z "$2" ]; then
                    echo "Usage: ssh-gate [--hours N] <instance-id-or-host>..."
                    return 1
                fi
                hours="$2"
                shift 2
                ;;
            --file)
                if [ -z "$2" ]; then
                    echo "Usage: ssh-gate [--hours N] --file nodes.txt"
                    return 1
                fi
                host_file="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: ssh-gate [--hours N] <instance-id-or-host>..."
                echo "       ssh-gate [--hours N] --file nodes.txt"
                return 0
                ;;
            --)
                shift
                hosts+=("$@")
                break
                ;;
            -*)
                echo "Unknown option: $1"
                echo "Usage: ssh-gate [--hours N] <instance-id-or-host>..."
                return 1
                ;;
            *)
                hosts+=("$1")
                shift
                ;;
        esac
    done

    if ! [[ "$hours" =~ '^[0-9]+$' ]] || [ "$hours" -lt 1 ]; then
        echo "--hours must be a positive integer"
        return 1
    fi

    if [ -n "$host_file" ]; then
        if [ ! -f "$host_file" ]; then
            echo "Host file not found: $host_file"
            return 1
        fi
        while IFS= read -r host; do
            host="${host%%#*}"
            host="$(printf '%s\n' "$host" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
            [ -n "$host" ] && hosts+=("$host")
        done < "$host_file"
    fi

    if [ "${#hosts[@]}" -eq 0 ]; then
        echo "Usage: ssh-gate [--hours N] <instance-id-or-host>..."
        echo "       ssh-gate [--hours N] --file nodes.txt"
        return 1
    fi

    local lease_file="${SSH_LEASE_FILE:-/tmp/.claude-ssh-leases}"
    local expiry=$(( $(date +%s) + hours * 3600 ))
    local tmp_file="${lease_file}.tmp"
    local hosts_tmp="${lease_file}.hosts.$$"
    mkdir -p "$(dirname "$lease_file")"
    cp /dev/null "$tmp_file"
    printf '%s\n' "${hosts[@]}" > "$hosts_tmp"
    if [ -f "$lease_file" ]; then
        awk 'NR == FNR { skip[$1] = 1; next } !($1 in skip)' "$hosts_tmp" "$lease_file" > "$tmp_file"
    fi
    rm -f "$hosts_tmp"
    mv "$tmp_file" "$lease_file"
    for host in "${hosts[@]}"; do
        echo "$host $expiry" >> "$lease_file"
        echo "SSH lease granted for $host (expires $(_mho_format_epoch_local "$expiry"))"
    done
}

# ssh-gate-list: Show active SSH leases.
ssh-gate-list() {
    local lease_file="${SSH_LEASE_FILE:-/tmp/.claude-ssh-leases}"
    if [ ! -f "$lease_file" ]; then
        echo "No active SSH leases"
        return
    fi
    local now=$(date +%s)
    echo "Active SSH leases:"
    while IFS=' ' read -r host expiry; do
        if [ "$expiry" -gt "$now" ] 2>/dev/null; then
            local remaining=$(( (expiry - now) / 3600 ))
            local mins=$(( ((expiry - now) % 3600) / 60 ))
            echo "  $host  (${remaining}h ${mins}m remaining)"
        fi
    done < "$lease_file"
}

# ssh-gate-revoke: Revoke SSH lease for a specific host.
ssh-gate-revoke() {
    if [ -z "$1" ]; then
        echo "Usage: ssh-gate-revoke <instance-id-or-host>"
        return 1
    fi
    local lease_file="${SSH_LEASE_FILE:-/tmp/.claude-ssh-leases}"
    [ -f "$lease_file" ] && awk -v host="$1" '$1 != host' "$lease_file" > "$lease_file.tmp" && mv "$lease_file.tmp" "$lease_file"
    echo "SSH lease revoked for $1"
}

# ssh-command-gate: Allow one exact sensitive SSH remote command for a host.
# Host still needs a normal ssh-gate lease. This grants the command hash only.
# Usage: ssh-command-gate [--hours N] <host> -- <remote-command...>
ssh-command-gate() {
    local hours=12
    local host=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --hours)
                if [ -z "$2" ]; then
                    echo "Usage: ssh-command-gate [--hours N] <host> -- <remote-command...>"
                    return 1
                fi
                hours="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: ssh-command-gate [--hours N] <host> -- <remote-command...>"
                return 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                echo "Unknown option: $1"
                echo "Usage: ssh-command-gate [--hours N] <host> -- <remote-command...>"
                return 1
                ;;
            *)
                if [ -z "$host" ]; then
                    host="$1"
                    shift
                else
                    break
                fi
                ;;
        esac
    done

    if ! [[ "$hours" =~ '^[0-9]+$' ]] || [ "$hours" -lt 1 ]; then
        echo "--hours must be a positive integer"
        return 1
    fi
    if [ -z "$host" ] || [ "$#" -eq 0 ]; then
        echo "Usage: ssh-command-gate [--hours N] <host> -- <remote-command...>"
        return 1
    fi

    local lease_file="${SSH_COMMAND_LEASE_FILE:-/tmp/.claude-ssh-command-leases}"
    local expiry=$(( $(date +%s) + hours * 3600 ))
    local canonical_and_hash
    canonical_and_hash=$(python3 - "$@" <<'PY'
import hashlib
import shlex
import sys

joined = " ".join(sys.argv[1:])
tokens = shlex.split(joined, posix=True)
canonical = " ".join(shlex.quote(token) for token in tokens)
digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
print(f"{digest}\t{canonical}")
PY
    ) || return 1
    local command_hash="${canonical_and_hash%%$'\t'*}"
    local canonical_command="${canonical_and_hash#*$'\t'}"
    local tmp_file="${lease_file}.tmp"
    mkdir -p "$(dirname "$lease_file")"
    if [ -f "$lease_file" ]; then
        awk -F '\t' -v hash="$command_hash" -v host="$host" '!(($1 == hash) && ($3 == host))' "$lease_file" > "$tmp_file"
    else
        cp /dev/null "$tmp_file"
    fi
    mv "$tmp_file" "$lease_file"
    printf '%s\t%s\t%s\t%s\n' "$command_hash" "$expiry" "$host" "$canonical_command" >> "$lease_file"
    echo "SSH command lease granted for $host (expires $(_mho_format_epoch_local "$expiry"))"
    echo "  $canonical_command"
}

# ssh-command-gate-list: Show active exact-command SSH leases.
ssh-command-gate-list() {
    local lease_file="${SSH_COMMAND_LEASE_FILE:-/tmp/.claude-ssh-command-leases}"
    if [ ! -f "$lease_file" ]; then
        echo "No active SSH command leases"
        return
    fi
    local now=$(date +%s)
    echo "Active SSH command leases:"
    while IFS=$'\t' read -r hash expiry host command; do
        if [ "$expiry" -gt "$now" ] 2>/dev/null; then
            local remaining=$(( (expiry - now) / 3600 ))
            local mins=$(( ((expiry - now) % 3600) / 60 ))
            echo "  $host  (${remaining}h ${mins}m remaining)  $command"
        fi
    done < "$lease_file"
}

alias cld='claude'
alias cldr='claude --resume'

# ==============================================================================
# Beads task memory
# ==============================================================================
# Install: brew install steveyegge/beads/bd
# Set BD_DB explicitly when a shared database is desired.

# Quick aliases
alias bdr='bd ready'              # What's next?
alias bdl='bd list --status open' # All open tasks
alias bds='bd show'               # Show task details (bd show <id>)

# bdc - Create a beads task with repo context
# Usage: bdc "Fix chunking race condition" [-p 0]
# Auto-tags with current repo name
bdc() {
    if [[ -z "$1" ]]; then
        echo "Usage: bdc \"task title\" [-p priority]"
        return 1
    fi

    local repo_name=""
    if git rev-parse HEAD > /dev/null 2>&1; then
        repo_name=$(basename "$(git rev-parse --show-toplevel)")
    fi

    if [[ -n "$repo_name" ]]; then
        bd create "$1" --tag "repo:$repo_name" "${@:2}"
    else
        bd create "$1" "${@:2}"
    fi
}

# ==============================================================================
# Multi-Repo Project Bootstrap
# ==============================================================================
# A "project" is a folder under ${PROJECTS_DIR:-~/proj}/<name>/ holding one git
# worktree per repo, each cut from the repo's clone in ~/repos/. Worktree
# branches use ${PROJECT_BRANCH_PREFIX:-feature/}<name>.

_proj_root() {
    emulate -L zsh
    print -r -- "${PROJECTS_DIR:-$HOME/proj}"
}

_proj_repos_root() {
    emulate -L zsh
    print -r -- "${REPOS_DIR:-$HOME/repos}"
}

projl() {
    emulate -L zsh
    local root="$(_proj_root)"
    if [[ ! -d "$root" ]]; then
        echo "projl: no projects directory at $root" >&2
        return 1
    fi

    local -a projects repos
    projects=("$root"/*(/N:t))
    if (( ${#projects[@]} == 0 )); then
        echo "projl: no projects under $root"
        return 0
    fi

    local name dir
    for name in "${projects[@]}"; do
        dir="$root/$name"
        repos=("$dir"/*(/N))
        printf "%-28s %2d repos  %s\n" "$name" "${#repos[@]}" "$dir"
    done
}

_proj_usage() {
    echo "Usage:"
    echo "  proj                         select an existing project with fzf, or list projects"
    echo "  proj -l|--list               list existing projects"
    echo "  proj <project-name>          switch to an existing project"
    echo "  proj <project-name> <repo>   create project worktrees from ${REPOS_DIR:-~/repos}/<repo>"
}

_proj_summary() {
    emulate -L zsh
    local proj_dir="$1" child repo branch dirty
    echo "proj: $(basename "$proj_dir") -> $proj_dir"

    local -a children
    children=("$proj_dir"/*(/N))
    for child in "${children[@]}"; do
        git -C "$child" rev-parse --git-dir >/dev/null 2>&1 || continue
        repo="$(basename "$child")"
        branch="$(git -C "$child" branch --show-current 2>/dev/null)"
        [[ -n "$branch" ]] || branch="detached"
        dirty="$(git -C "$child" status --short 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$dirty" == "0" ]]; then
            printf "  %-28s %-24s clean\n" "$repo" "$branch"
        else
            printf "  %-28s %-24s %s changes\n" "$repo" "$branch" "$dirty"
        fi
    done
}

# proj: switch to, list, or bootstrap multi-repo projects.
proj() {
    emulate -L zsh
    local name="$1"; shift 2>/dev/null

    local root="$(_proj_root)"
    if [[ -z "$name" ]]; then
        if [[ -d "$root" ]] && command -v fzf >/dev/null 2>&1; then
            local -a projects
            projects=("$root"/*(/N:t))
            if (( ${#projects[@]} )); then
                name="$(printf "%s\n" "${projects[@]}" | fzf --prompt="proj> ")"
                [[ -n "$name" ]] || return 1
                cd "$root/$name" || return 1
                _proj_summary "$root/$name"
                return 0
            fi
        fi

        _proj_usage
        projl 2>/dev/null || true
        return 1
    fi

    if [[ "$name" == "-l" || "$name" == "--list" ]]; then
        projl
        return $?
    fi

    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "proj: project name must be a safe single path component" >&2
        return 1
    fi

    local root_canonical="${root:A}"
    local proj_dir="$root/$name"
    if [[ -e "$proj_dir" || -L "$proj_dir" ]]; then
        if [[ "${proj_dir:A}" != "$root_canonical/$name" ]]; then
            echo "proj: project path escapes $root: $name" >&2
            return 1
        fi
    fi
    if (( $# == 0 )); then
        if [[ -d "$proj_dir" ]]; then
            cd "$proj_dir" || return 1
            _proj_summary "$proj_dir"
            return 0
        fi

        echo "proj: no project at $proj_dir" >&2
        echo "proj: create it with: proj $name <repo> [<repo> ...]" >&2
        return 1
    fi

    local branch="${PROJECT_BRANCH_PREFIX:-feature/}$name" repo repo_path missing=()
    local -A seen_repos

    local repos_root="$(_proj_repos_root)"
    local repos_root_canonical="${repos_root:A}"

    for repo in "$@"; do
        if [[ ! "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "proj: repository name must be a safe single path component: $repo" >&2
            return 1
        fi
        if [[ -n "${seen_repos[$repo]:-}" ]]; then
            echo "proj: duplicate repository: $repo" >&2
            return 1
        fi
        seen_repos[$repo]=1
        repo_path="$repos_root/$repo"
        if [[ -e "$repo_path" || -L "$repo_path" ]]; then
            if [[ "${repo_path:A}" != "$repos_root_canonical/$repo" ]]; then
                echo "proj: repository path escapes $repos_root: $repo" >&2
                return 1
            fi
        fi
        git -C "$repos_root/$repo" rev-parse --git-dir >/dev/null 2>&1 || missing+=("$repo")
    done
    if (( ${#missing[@]} )); then
        echo "proj: no clone at $repos_root for: ${missing[*]}" >&2
        echo "proj: clone them before creating project worktrees." >&2
        return 1
    fi

    [[ -e "$proj_dir" || -L "$proj_dir" ]] && { echo "proj: $proj_dir already exists" >&2; return 1; }

    local -a repos refs srcs created_srcs created_dsts
    repos=("$@")
    for repo in "${repos[@]}"; do
        local src="$repos_root/$repo" ref
        git -C "$src" fetch --quiet origin || { echo "proj: fetch failed: $repo" >&2; return 1; }
        git -C "$src" remote set-head origin --auto >/dev/null 2>&1
        ref=$(git -C "$src" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
        [[ -z "$ref" ]] && ref="origin/main"
        if git -C "$src" show-ref --verify --quiet "refs/heads/$branch"; then
            echo "proj: branch already exists for $repo: $branch" >&2
            return 1
        fi
        srcs+=("$src")
        refs+=("$ref")
    done

    mkdir -p "$proj_dir" || return 1

    local idx dst
    for (( idx = 1; idx <= ${#repos[@]}; idx++ )); do
        repo="${repos[$idx]}"
        local src="${srcs[$idx]}" ref="${refs[$idx]}"
        dst="$proj_dir/$repo"
        if [[ -e "$dst" || -L "$dst" ]]; then
            echo "proj: refusing to replace existing destination: $dst" >&2
            return 1
        fi
        echo "proj: $repo -> $dst ($branch off $ref)"
        if ! git -C "$src" worktree add --no-track -b "$branch" "$dst" "$ref"; then
            local rollback_idx
            git -C "$src" worktree remove --force "$dst" >/dev/null 2>&1 || true
            if [[ "$dst" == "$proj_dir/$repo" && "${dst:h:A}" == "${proj_dir:A}" ]]; then
                rm -rf "$dst"
            fi
            git -C "$src" worktree prune >/dev/null 2>&1 || true
            git -C "$src" branch -D "$branch" >/dev/null 2>&1 || true
            for (( rollback_idx = ${#created_srcs[@]}; rollback_idx >= 1; rollback_idx-- )); do
                git -C "${created_srcs[$rollback_idx]}" worktree remove --force "${created_dsts[$rollback_idx]}" >/dev/null 2>&1 || true
                git -C "${created_srcs[$rollback_idx]}" branch -D "$branch" >/dev/null 2>&1 || true
            done
            rmdir "$proj_dir" >/dev/null 2>&1 || true
            echo "proj: worktree add failed for $repo" >&2
            return 1
        fi
        created_srcs+=("$src")
        created_dsts+=("$dst")
    done

    echo "proj: ready -> $proj_dir"
    cd "$proj_dir"
}

if [[ -n "$ZSH_VERSION" ]]; then
    _proj_describe_projects() {
        emulate -L zsh
        local root="$(_proj_root)" name dir child repo_count dirty_count dirty desc
        local -a projects

        [[ -d "$root" ]] || return 1
        for dir in "$root"/*(/N); do
            name="${dir:t}"
            repo_count=0
            dirty_count=0
            for child in "$dir"/*(/N); do
                (( repo_count++ ))
                git -C "$child" rev-parse --git-dir >/dev/null 2>&1 || continue
                dirty="$(git -C "$child" status --short 2>/dev/null)"
                [[ -n "$dirty" ]] && (( dirty_count++ ))
            done

            desc="$repo_count repos"
            if (( dirty_count )); then
                desc+=", $dirty_count dirty"
            else
                desc+=", clean"
            fi
            projects+=("$name:$desc")
        done

        (( ${#projects[@]} )) || return 1
        _describe -t projects 'projects' projects
    }

    _proj_describe_source_repos() {
        emulate -L zsh
        local repos_root="$(_proj_repos_root)" dir repo branch dirty desc
        local -a repos

        [[ -d "$repos_root" ]] || return 1
        for dir in "$repos_root"/*(/N); do
            repo="${dir:t}"
            desc="repo clone"
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
            repos+=("$repo:$desc")
        done

        (( ${#repos[@]} )) || return 1
        _describe -t repositories 'repo clones' repos
    }

    _proj_completion() {
        local -a options
        options=(
            '-l:list existing projects'
            '--list:list existing projects'
        )

        if (( CURRENT == 2 )); then
            _describe -t options 'options' options
            _proj_describe_projects
            return
        fi

        if (( CURRENT >= 3 )); then
            case "${words[2]}" in
                -l|--list)
                    return
                    ;;
            esac

            if [[ -d "$(_proj_root)/${words[2]}" ]]; then
                _message -e project-state "project exists; run 'proj ${words[2]}' to switch"
                return
            fi

            _proj_describe_source_repos
        fi
    }

    _fba_compdef _proj_completion proj
fi

# ==============================================================================
# Functions
# ==============================================================================
function svba() {
    local submodule="${1:-.}"
    if [ -d "$submodule/.venv" ]; then
        source "$submodule/.venv/bin/activate"
        echo "Activated: ($submodule/.venv)"
    else
        echo "Error: Virtual environment not found in '$submodule/.venv'"
        return 1
    fi
}

use-java() {
   v=$1
   sdk use java $(sdk ls java | grep 'local only' | xargs -n 1 echo | grep -E "$v\.\d+\.\d+\-zulu")
}

ytmp3() {
    if [ -z "$1" ]; then
        echo "Usage: ytmp3 <YouTube-URL>"
        return 1
    fi
    local URL="$1"
    yt-dlp -f bestaudio -o "%(title)s.%(ext)s" "$URL" --no-playlist
    local FILE=$(yt-dlp --get-filename -f bestaudio -o "%(title)s.%(ext)s" "$URL")
    local BASENAME="${FILE%.*}"
    ffmpeg -i "$FILE" -codec:a libmp3lame -qscale:a 0 "${BASENAME}.mp3"
    rm "$FILE"
    echo "Conversion complete: ${BASENAME}.mp3"
}

webm_to_mp3() {
    for f in *.webm; do
        if [ -f "$f" ]; then
            echo "Converting: $f"
            ffmpeg -i "$f" -codec:a libmp3lame -qscale:a 0 "${f%.webm}.mp3"
            echo "Done: ${f%.webm}.mp3"
        fi
    done
}

to_mp3() {
    if [ -z "$1" ]; then
        echo "Usage: to_mp3 <filename>"
        return 1
    fi
    local FILE="$1"
    if [ ! -f "$FILE" ]; then
        echo "File not found: $FILE"
        return 1
    fi
    local BASENAME="${FILE%.*}"
    local OUTPUT="${BASENAME}.mp3"
    echo "Converting: $FILE -> $OUTPUT"
    ffmpeg -i "$FILE" -codec:a libmp3lame -qscale:a 0 "$OUTPUT"
    echo "Conversion complete: $OUTPUT"
}

# ==============================================================================
# Git Branch Pruning (with fzf integration)
# ==============================================================================

# gbprune - Interactive branch deletion with fzf
# Usage: gbprune [--merged | --stale [days] | --all]
#   --merged  : show only branches merged into current branch
#   --stale N : show branches with no commits in N days (default: 30)
#   --all     : show all local branches
#
# In fzf: Tab to select multiple, Enter to delete selected
gbprune() {
    git rev-parse HEAD > /dev/null 2>&1 || { echo "Not in a git repo"; return 1; }
    command -v fzf > /dev/null 2>&1 || { echo "fzf required"; return 1; }

    local mode="all"
    local stale_days=30
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local protected="main|master|develop|release"

    # Parse arguments
    case "$1" in
        --merged) mode="merged" ;;
        --stale)  mode="stale"; [[ "$2" =~ ^[0-9]+$ ]] && stale_days="$2" ;;
        --all)    mode="all" ;;
        "") ;;
        *) echo "Usage: gbprune [--merged | --stale [days] | --all]"; return 1 ;;
    esac

    echo "Fetching from origin..."
    git fetch origin --prune

    local branches=""
    local now=$(date +%s)

    case "$mode" in
        merged)
            branches=$(git branch --merged | grep -vE "^\*|$protected" | sed 's/^[[:space:]]*//')
            ;;
        stale)
            for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
                [[ "$branch" =~ ^($protected)$ ]] && continue
                [[ "$branch" == "$current_branch" ]] && continue
                local last_commit=$(git log -1 --format=%ct "$branch" 2>/dev/null)
                local age_days=$(( (now - last_commit) / 86400 ))
                if (( age_days > stale_days )); then
                    branches+="$branch ($age_days days old)\n"
                fi
            done
            ;;
        all)
            branches=$(git branch | grep -vE "^\*|$protected" | sed 's/^[[:space:]]*//')
            ;;
    esac

    if [[ -z "$branches" ]]; then
        echo "No branches to prune."
        return 0
    fi

    local header="Select branches to DELETE (Tab=select, Enter=confirm, Esc=cancel)"
    [[ "$mode" == "stale" ]] && header="Branches older than $stale_days days. $header"
    [[ "$mode" == "merged" ]] && header="Merged branches. $header"

    local selected=$(echo -e "$branches" |
        fzf --multi --ansi \
            --header "$header" \
            --preview 'git log --oneline --graph --color=always -20 {1}' \
            --preview-window right:60% |
        awk '{print $1}')

    if [[ -z "$selected" ]]; then
        echo "No branches selected."
        return 0
    fi

    echo "\nBranches to delete:"
    echo "$selected" | while read branch; do echo "  $branch"; done
    echo ""
    read "confirm?Delete these branches? [y/N]: "

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$selected" | while read branch; do
            git branch -D "$branch" 2>/dev/null && echo "Deleted: $branch" || echo "Failed: $branch"
        done
    else
        echo "Aborted."
    fi
}

# gb_clean - Legacy alias for backward compatibility
alias gb_clean='gbprune --stale'

# gbdel - Quick delete branch with fzf selection
gbdel() {
    git rev-parse HEAD > /dev/null 2>&1 || return 1
    local branch=$(git branch | grep -v '^\*' | sed 's/^[[:space:]]*//' |
        fzf --preview 'git log --oneline --graph --color=always -20 {}')
    [[ -n "$branch" ]] && git branch -D "$branch"
}

# gbdelmerged - Delete all merged branches (non-interactive)
gbdelmerged() {
    git rev-parse HEAD > /dev/null 2>&1 || return 1
    local protected="main|master|develop|release"
    git branch --merged | grep -vE "^\*|$protected" | xargs -r git branch -d
    echo "Deleted merged branches."
}

# gprune - Prune remote tracking branches that no longer exist
gprune() {
    echo "Pruning stale remote tracking branches..."
    git fetch --all --prune
    git remote prune origin
    echo "Done. Run 'git branch -vv | grep gone' to see orphaned local branches."
}

# gprunelocal - Delete local branches whose remote is gone
gprunelocal() {
    git rev-parse HEAD > /dev/null 2>&1 || return 1
    local gone_branches=$(git branch -vv | grep ': gone]' | awk '{print $1}')

    if [[ -z "$gone_branches" ]]; then
        echo "No orphaned local branches."
        return 0
    fi

    echo "Local branches with deleted remotes:"
    echo "$gone_branches"
    echo ""
    read "confirm?Delete these branches? [y/N]: "

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "$gone_branches" | xargs git branch -D
    fi
}

# ==============================================================================
# SDK Managers (keep at end for proper initialization)
# ==============================================================================
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# SDKMAN - THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# weasyprint (macOS only — DYLD_* is the macOS dynamic linker). On Linux,
# ld.so uses LD_LIBRARY_PATH and package-managed libs don't need this.
if [[ "$(uname -s)" == "Darwin" ]]; then
    export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_FALLBACK_LIBRARY_PATH
fi
