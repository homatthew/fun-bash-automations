# Personal zsh configuration
# This file contains personal shell settings, aliases, and functions

# Create the folder structure (run once if needed)
# mkdir -p ~/.zsh
# cd ~/.zsh
# Download the scripts
# curl -o git-completion.bash https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash
# curl -o _git https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.zsh
# compaudit | xargs chown -R "$(whoami)"
# compaudit | xargs chmod go-w

# Remove last login log
printf '\33c\e[3J'

autoload colors; colors
echo $fg[yellow]'Loaded mho ~/.zshrc'$reset_color

zstyle ':completion:*:*:git:*' script ~/.zsh/git-completion.bash
fpath=(~/.zsh $fpath)

autoload -Uz compinit && compinit
autoload bashcompinit && bashcompinit

export LSCOLORS=ExGxBxDxCxEgEdxbxgxcxd
alias ls='ls -G'

function svba() {
    local submodule="${1:-.}"

    if [ -d "$submodule/.venv" ]; then
        source "$submodule/.venv/bin/activate"
        echo "Activated: ($submodule/.venv)"
    else
        echo "Error: Virtual environment not found in '$submodule/venv'"
        return 1
    fi
}
alias svenv='source .venv/bin/activate'
alias rrc='source ~/.zshrc'

# Git aliases
alias gca='git commit --amend'
alias gcane='gca --no-edit --no-verify'
alias gpo='git push origin'
alias gpofwl='gpo --force-with-lease'
alias gpu='git push upstream'
alias gpufwl='git push upstream --force-with-lease'
alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias gb='git branch'
alias gl='git log --pretty=format:"%h %d - %an, %ar : %s" --decorate=short'
alias grb='git rebase'
alias grbc='git rebase --continue'
alias rbi='git rebase -i master'
alias squash='rbi && gca'

# General PATH exports
export GOPATH=$HOME/golang
export GOROOT=/usr/local/opt/go/libexec
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin
export PATH=$PATH:/usr/local/bin/
export PATH=$PATH:/Users/matthewho/.temporal

# rp aliases and completion
alias rp=". /Users/matthewho/repos/fun-bash-automations/rp/rp.sh"
alias rpa=". /Users/matthewho/repos/fun-bash-automations/rp/archive/rp-archive.sh"
alias rpu=". /Users/matthewho/repos/fun-bash-automations/rp/archive/rp-unarchive.sh"
source "/Users/matthewho/repos/fun-bash-automations/rp/rp-completion.sh"

# Prompt configuration
autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:git:*' formats '%b '

setopt PROMPT_SUBST
PROMPT='%F{green}%*%f %F{blue}%~%f %F{red}${vcs_info_msg_0_}%f$ '

#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# Mac OS specific
# defaults write -g com.apple.trackpad.scaling -float 5.0
# defaults write .GlobalPreferences com.apple.mouse.scaling -1
# defaults write -g ApplePressAndHoldEnabled -bool false

use-java() {
   v=$1
   sdk use java $(sdk ls java | grep 'local only' | xargs -n 1 echo | grep -E "$v\.\d+\.\d+\-zulu")
}

ytmp3() {
  if [ -z "$1" ]; then
    echo "Usage: ytmp3 <YouTube-URL>"
    return 1
  fi

  URL="$1"

  # Download best audio
  yt-dlp -f bestaudio -o "%(title)s.%(ext)s" "$URL" --no-playlist

  # Get downloaded file name
  FILE=$(yt-dlp --get-filename -f bestaudio -o "%(title)s.%(ext)s" "$URL")

  # Extract base name without extension
  BASENAME="${FILE%.*}"

  # Convert to MP3
  ffmpeg -i "$FILE" -codec:a libmp3lame -qscale:a 0 "${BASENAME}.mp3"

  # Optional: Clean up original file
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
    echo "Usage: webm_to_mp3_single <filename.webm>"
    return 1
  fi

  FILE="$1"

  if [ ! -f "$FILE" ]; then
    echo "File not found: $FILE"
    return 1
  fi

  BASENAME="${FILE%.webm}"
  OUTPUT="${BASENAME}.mp3"

  echo "Converting: $FILE → $OUTPUT"
  ffmpeg -i "$FILE" -codec:a libmp3lame -qscale:a 0 "$OUTPUT"

  echo "Conversion complete: $OUTPUT"
}


function gb_clean() {
  # Usage: gb_clean [days] [--force]
  local days force branches branch current_branch
  local protected_branches=("main" "master" "develop" "release") # add more if needed

  # Fetch latest branches from origin
  echo "Fetching latest branch information from origin..."
  git fetch origin --prune

  # Set default days to 30 if not provided
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    days="$1"
    shift
  else
    days=30
  fi

  force=0
  [[ "$1" == "--force" ]] && force=1

  current_branch=$(git rev-parse --abbrev-ref HEAD)

  # Find candidate branches
  branches=()
  for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
    # Skip protected and current branch
    skip=0
    for protected in "${protected_branches[@]}"; do
      if [[ "$branch" == "$protected" || "$branch" == $protected/* ]]; then
        skip=1
      fi
    done
    [[ "$branch" == "$current_branch" ]] && skip=1
    (( skip )) && continue

    # Get local commit date (as unix timestamp)
    local_date=$(git log -1 --format=%ct "$branch" 2>/dev/null)
    # Get upstream (origin) commit date if exists
    upstream=$(git for-each-ref --format='%(upstream:short)' "refs/heads/$branch")
    if [[ -n "$upstream" ]]; then
      remote_date=$(git log -1 --format=%ct "$upstream" 2>/dev/null)
    else
      remote_date=0
    fi

    # Use the latest of the two dates
    if (( local_date > remote_date )); then
      latest_date=$local_date
    else
      latest_date=$remote_date
    fi

    # If latest commit is older than threshold, add to list
    now=$(date +%s)
    age_days=$(( (now - latest_date) / 86400 ))
    if (( age_days > days )); then
      branches+=("$branch")
    fi
  done

  if [[ ${#branches[@]} -eq 0 ]]; then
    echo "No branches older than $days days (excluding protected branches)."
    return 0
  fi

  echo "The following branches are older than $days days (considering both local and upstream) and will be deleted (protected branches excluded):"
  for branch in "${branches[@]}"; do
    echo "  $branch"
  done

  if (( force )); then
    for branch in "${branches[@]}"; do
      git branch -D "$branch"
    done
    echo "Deleted all branches above."
  else
    echo
    echo "Proceed with deletion? [y/N/A = Yes to All]: "
    read "REPLY?Your choice: "
    if [[ "$REPLY" =~ ^[Aa]$ ]]; then
      for branch in "${branches[@]}"; do
        git branch -D "$branch"
      done
      echo "Deleted all branches above."
    elif [[ "$REPLY" =~ ^[Yy]$ ]]; then
      for branch in "${branches[@]}"; do
        read "del?Delete branch '$branch'? [y/N]: "
        if [[ "$del" =~ ^[Yy]$ ]]; then
          git branch -D "$branch"
        else
          echo "Skipped $branch"
        fi
      done
    else
      echo "Aborted."
      return 0
    fi
  fi
}

# NVM setup
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# weasyprint
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib:$DYLD_FALLBACK_LIBRARY_PATH
