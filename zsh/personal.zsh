# Personal zsh configuration
# This file contains personal shell settings, aliases, and functions

# ==============================================================================
# Oh My Zsh Configuration
# ==============================================================================
# Install oh-my-zsh if not present:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

DISABLE_AUTO_TITLE="true"
export CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1

# Auto-rename Tabby terminal tabs based on current directory
function chpwd() {
    printf '\033]2;%s\007' "${PWD##*/}"
}
# Set initial tab name on shell startup
printf '\033]2;%s\007' "${PWD##*/}"


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
# Zsh Autosuggestions (fish-like suggestions)
# ==============================================================================
# Install: brew install zsh-autosuggestions
if [ -f /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    source /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
elif [ -f ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    source ~/.zsh/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
bindkey '^ ' autosuggest-accept  # Ctrl+Space to accept suggestion

# ==============================================================================
# Zsh Syntax Highlighting (must be last plugin sourced)
# ==============================================================================
# Install: brew install zsh-syntax-highlighting
if [ -f /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    source /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
elif [ -f ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    source ~/.zsh/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

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
export GOROOT=/usr/local/opt/go/libexec
export PATH=$HOME/.local/bin:$PATH
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin
export PATH=$PATH:/usr/local/bin/
export PATH=$PATH:/Users/matthewho/.temporal

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

# rp - repository navigation (source function, then load completion)
[ -f "/Users/matthewho/repos/fun-bash-automations/rp/rp.sh" ] && source "/Users/matthewho/repos/fun-bash-automations/rp/rp.sh"
[ -f "/Users/matthewho/repos/fun-bash-automations/rp/rp-completion.sh" ] && source "/Users/matthewho/repos/fun-bash-automations/rp/rp-completion.sh"

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

# weasyprint
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_FALLBACK_LIBRARY_PATH
