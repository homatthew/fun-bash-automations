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
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
export PATH=$HOME/.local/bin:$HOME/repos/fun-bash-automations/bin:$PATH
if [ -d "$BUN_INSTALL/bin" ]; then
  export PATH="$BUN_INSTALL/bin:$PATH"
fi
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin
export PATH=$PATH:/usr/local/bin/
export PATH=$PATH:/Users/matthewho/.temporal

# Beads: central task memory across all repos (lives in dump repo)
export BEADS_DIR=$HOME/repos/dump/.beads
export BD_DB=$BEADS_DIR/beads.db

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
# LLM Config Sync
# ==============================================================================
# Shared instructions/skills are canonical in ~/repos/fun-bash-automations/llm.
# Use fba-deploy to project repo-owned runtime files into ~/.claude and ~/.codex.

# claude-sync: Copy ~/.claude config back to repo
claude-sync() {
    local src=~/.claude
    local dst=~/repos/fun-bash-automations/claude

    cp "$src/CLAUDE.md" "$dst/CLAUDE.md"
    cp "$src/settings.json" "$dst/settings.json"
    echo "Synced ~/.claude → $dst"
    echo "Run 'cd $dst && git diff' to review changes"
}

# fba-deploy: Project repo-owned LLM config into local runtimes.
fba-deploy() {
    "$HOME/repos/fun-bash-automations/bin/fba-deploy" "$@"
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

# push-gate: Manage durable push leases for agent pushes.
# Generates approval drafts, stamps leases, and wraps agent pushes with
# required self-assertions.
push-gate() {
    local helper="$HOME/repos/fun-bash-automations/llm/hooks/push-gate.sh"
    if [ ! -x "$helper" ]; then
        echo "push-gate helper missing: $helper"
        return 1
    fi
    bash "$helper" "$@"
}
alias pg=push-gate

# pgr - run pg against another repo without cd.
# Picks from active leases (~/.push-gate/leases.db) + ~/repos/*, uses fzf
# with the optional shortname as initial query. Example:
#   pgr skm       → fuzzy match for service-capacity-modeling
#   pgr           → pick any repo
pgr() {
    local query="${1:-}"
    local db="${HOME}/.push-gate/leases.db"
    local pick

    command -v fzf >/dev/null 2>&1 || { echo "pgr: fzf required"; return 1; }

    pick=$( {
        # Active-lease repos first (most likely target)
        if [[ -f "$db" ]] && command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$db" \
                "SELECT repo_root FROM leases WHERE status='active' ORDER BY updated_at DESC;" \
                2>/dev/null
        fi
        # Then everything under ~/repos (one level deep, git repos only)
        for d in "$HOME"/repos/*/; do
            [[ -d "$d/.git" || -f "$d/.git" ]] && printf '%s\n' "${d%/}"
        done
    } | awk '!seen[$0]++' \
      | fzf --query "$query" --select-1 --exit-0 \
            --header "Pick a repo (pg -C will run there)")

    [[ -n "$pick" ]] || return 1
    push-gate -C "$pick" "${@:2}"
}

# ssh-gate: Allow Claude to SSH into a specific host for 12 hours.
# Creates a lease file with the host and expiry timestamp.
# Usage: ssh-gate <instance-id-or-host>
ssh-gate() {
    if [ -z "$1" ]; then
        echo "Usage: ssh-gate <instance-id-or-host>"
        return 1
    fi
    local lease_file="/tmp/.claude-ssh-leases"
    local expiry=$(( $(date +%s) + 43200 ))  # 12 hours
    # Remove any existing lease for this host, then add new one
    [ -f "$lease_file" ] && grep -v "^$1 " "$lease_file" > "$lease_file.tmp" && mv "$lease_file.tmp" "$lease_file"
    echo "$1 $expiry" >> "$lease_file"
    echo "SSH lease granted for $1 (expires $(date -r $expiry '+%Y-%m-%d %H:%M'))"
}

# ssh-gate-list: Show active SSH leases.
ssh-gate-list() {
    local lease_file="/tmp/.claude-ssh-leases"
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
    local lease_file="/tmp/.claude-ssh-leases"
    [ -f "$lease_file" ] && grep -v "^$1 " "$lease_file" > "$lease_file.tmp" && mv "$lease_file.tmp" "$lease_file"
    echo "SSH lease revoked for $1"
}

alias claude-safe='/opt/nflx/bin/claude'
alias claude='claude --dangerously-skip-permissions'
alias cld='claude --dangerously-skip-permissions'
alias cldr='claude --dangerously-skip-permissions --resume'
alias codex="codex --dangerously-bypass-approvals-and-sandbox"

# ==============================================================================
# Beads (central task memory for AI agents)
# ==============================================================================
# Central DB lives in ~/repos/dump/.beads (set via BEADS_DIR above).
# All bd commands from any repo hit the same database.
# Install: brew install steveyegge/beads/bd
# Init:    cd ~/repos/dump && bd init

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
# Git Worktree Functions
# ==============================================================================
# Naming convention:
#   Branch: mho/<branch-name>
#   Path:   ~/worktrees/mho-<branch-name>

# gwt - Create a worktree with mho/ prefix
# Usage: gwt <branch-name>
# Example: gwt auth-refactor → branch mho/auth-refactor at ~/worktrees/mho-auth-refactor
gwt() {
    git rev-parse HEAD > /dev/null 2>&1 || { echo "Not in a git repo"; return 1; }

    if [[ -z "$1" ]]; then
        echo "Usage: gwt <branch-name>"
        echo "Creates: branch mho/<branch-name> at ~/worktrees/mho-<branch-name>"
        return 1
    fi

    local branch="mho/$1"
    local path=~/worktrees/mho-$1

    mkdir -p ~/worktrees
    git worktree add -b "$branch" "$path" HEAD
    echo ""
    echo "Worktree created:"
    echo "  Path:   $path"
    echo "  Branch: $branch"
    echo ""
    echo "To enter: cd $path"
}

# gwtl - List all worktrees
alias gwtl='git worktree list'

# gwtr - Remove a worktree (with fzf selection if no arg)
# Usage: gwtr [path]
gwtr() {
    git rev-parse HEAD > /dev/null 2>&1 || { echo "Not in a git repo"; return 1; }

    if [[ -n "$1" ]]; then
        git worktree remove "$1"
        return
    fi

    # Use fzf to select if available
    if command -v fzf > /dev/null 2>&1; then
        local selected=$(git worktree list | tail -n +2 |
            fzf --header "Select worktree to remove (Esc to cancel)" \
                --preview 'echo "Branch: $(git -C {1} rev-parse --abbrev-ref HEAD 2>/dev/null)"; echo ""; git -C {1} log --oneline -10 2>/dev/null' |
            awk '{print $1}')

        if [[ -n "$selected" ]]; then
            git worktree remove "$selected" && echo "Removed: $selected"
        fi
    else
        echo "Usage: gwtr <path>"
        echo "Or install fzf for interactive selection"
        git worktree list
    fi
}

# gwtp - Prune stale worktree references
alias gwtp='git worktree prune -v'

# gwtc - cd into a worktree (with fzf selection)
gwtc() {
    git rev-parse HEAD > /dev/null 2>&1 || { echo "Not in a git repo"; return 1; }

    if [[ -n "$1" ]]; then
        cd "$1"
        return
    fi

    if command -v fzf > /dev/null 2>&1; then
        local selected=$(git worktree list |
            fzf --header "Select worktree to enter" \
                --preview 'echo "Branch: $(git -C {1} rev-parse --abbrev-ref HEAD 2>/dev/null)"; echo ""; git -C {1} status -s 2>/dev/null; echo ""; git -C {1} log --oneline -5 2>/dev/null' |
            awk '{print $1}')

        if [[ -n "$selected" ]]; then
            cd "$selected"
        fi
    else
        echo "Usage: gwtc <path>"
        git worktree list
    fi
}

# gwtclean - Interactive cleanup of all worktrees in ~/worktrees
gwtclean() {
    git rev-parse HEAD > /dev/null 2>&1 || { echo "Not in a git repo"; return 1; }

    local worktrees=$(git worktree list | tail -n +2)

    if [[ -z "$worktrees" ]]; then
        echo "No worktrees to clean up."
        return 0
    fi

    echo "Current worktrees:"
    echo "$worktrees"
    echo ""

    if command -v fzf > /dev/null 2>&1; then
        local selected=$(echo "$worktrees" |
            fzf --multi --header "Select worktrees to REMOVE (Tab=select, Enter=confirm)" \
                --preview 'echo "Branch: $(git -C {1} rev-parse --abbrev-ref HEAD 2>/dev/null)"; echo ""; git -C {1} log --oneline -10 2>/dev/null' |
            awk '{print $1}')

        if [[ -z "$selected" ]]; then
            echo "No worktrees selected."
            return 0
        fi

        echo ""
        echo "Will remove:"
        echo "$selected"
        echo ""
        read "confirm?Remove these worktrees? [y/N]: "

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$selected" | while read path; do
                git worktree remove "$path" 2>/dev/null && echo "Removed: $path" || echo "Failed: $path"
            done
            git worktree prune
        else
            echo "Aborted."
        fi
    else
        read "confirm?Remove ALL worktrees? [y/N]: "
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "$worktrees" | awk '{print $1}' | while read path; do
                git worktree remove "$path" 2>/dev/null && echo "Removed: $path"
            done
            git worktree prune
        fi
    fi
}

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

# Ralph Wiggum — autonomous Claude loop
# Execution: `simple-ralph` (bash, zero deps)
# Monitoring: `ralph-watch` (Python + Rich) or `rt` (bash tail)
# See ~/repos/fun-bash-automations/bin/ for source

# ralph-tail — follow Ralph output in real time
# Works for both simple-ralph and full ralph (both write .ralph/ logs)
rt() {
  local dir="${1:-.}"
  local log="$dir/.ralph/output.log"
  local meta="$dir/.ralph/meta.json"

  # If no output.log, try to find the latest iteration log instead
  if [[ ! -f "$log" ]]; then
    local latest
    latest=$(ls -t "$dir"/.ralph/iteration-*.log 2>/dev/null | head -1 || true)
    if [[ -n "$latest" ]]; then
      log="$latest"
    elif [[ -d "$dir/.ralph" ]]; then
      echo "No logs yet in $dir/.ralph/ — waiting for Ralph to start..."
      echo "Will tail output.log when it appears."
      # Wait for output.log to appear
      while [[ ! -f "$dir/.ralph/output.log" ]]; do sleep 1; done
      log="$dir/.ralph/output.log"
    else
      echo "No .ralph/ directory in $dir"
      echo "Start Ralph first: simple-ralph plan.md"
      return 1
    fi
  fi

  # Show status header if meta.json exists
  if [[ -f "$meta" ]] && command -v jq >/dev/null 2>&1; then
    local plan iter max status
    plan=$(jq -r '.plan // empty' "$meta" 2>/dev/null | xargs basename 2>/dev/null)
    iter=$(jq -r '.iter // 0' "$meta" 2>/dev/null)
    max=$(jq -r '.max_iter // "?"' "$meta" 2>/dev/null)
    status=$(jq -r '.status // "unknown"' "$meta" 2>/dev/null)
    echo "ralph | $plan | iter $iter/$max | $status"
    echo "---"
  fi

  tail -f "$log"
}

# ralph-status — quick status check
ralph-status() {
  local dir="${1:-.}"
  local meta="$dir/.ralph/meta.json"
  if [[ ! -f "$meta" ]]; then
    echo "No Ralph session in $dir/.ralph/"
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    jq . "$meta"
  else
    cat "$meta"
  fi
  # Show status.md if present
  local status="$dir/.ralph/status.md"
  if [[ -f "$status" ]]; then
    echo ""
    echo "--- Progress ---"
    cat "$status"
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
