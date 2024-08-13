# Create the folder structure
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

alias agclean='pynt clean && newt dev-setup &&  newt start-local-deps && pynt lock-deps'
alias gca='git commit --amend'
alias gcane='gca --no-edit --no-verify'
alias gpo='git push origin'
alias gpofwl='gpo --force-with-lease'
alias rb_all='~/repos/fun-bash-automations/rebase-all-branches/rebaseAllBranches.sh'
alias bcc='mint build'
alias rbcc='rb_all && testbcc'
alias rbi='git rebase -i master'
alias grb='git rebase'
alias grbc='git rebase --continue'
alias squash='rbi && gca'
alias dpl='./gradlew -PdependencyLock.includeTransitives=true -Pstatus=release generateLock saveLock'
alias qb='./gradlew build -x integTest -x smokeTest -x test'

alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias gb='git branch'
alias gl='git log --pretty=format:"%h %d - %an, %ar : %s" --decorate=short' 
alias rp=". /Users/matthewho/repos/fun-bash-automations/rp/rp.sh"
alias rpa=". /Users/matthewho/repos/fun-bash-automations/rp/archive/rp-archive.sh"
alias rpu=". /Users/matthewho/repos/fun-bash-automations/rp/archive/rp-unarchive.sh"

alias vpnk="sudo kill -SEGV $(ps auwx | grep dsAccessService | grep Ss | awk '{print $2}')"

export GOPATH=$HOME/golang
export GOROOT=/usr/local/opt/go/libexec
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin


# Crontab -e
# 0 45/60 10-5 * MON,TUE,WED,THU,FRI * osascript -e 'display notification "Take a stretch break!" with title "Break reminder" sound name "Glass"'
source "/Users/matthewho/repos/fun-bash-automations/rp/rp-completion.sh"

autoload -Uz vcs_info
precmd() { vcs_info }

zstyle ':vcs_info:git:*' formats '%b '

setopt PROMPT_SUBST
PROMPT='%F{green}%*%f %F{blue}%~%f %F{red}${vcs_info_msg_0_}%f$ '
#THIS MUST BE AT THE END OF THE FILE FOR SDKMAN TO WORK!!!
export SDKMAN_DIR="$HOME/.sdkman"
[[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]] && source "$HOME/.sdkman/bin/sdkman-init.sh"

# Mac OS specific
# defaults write .GlobalPreferences com.apple.mouse.scaling -1
# defaults write -g ApplePressAndHoldEnabled -bool false


function shard() {
  grpc -a dgwcontrol.kv -e $1 -r us-east-1 com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"shard_identity\": \"$2\"}"
}

function cluster() {
  grpc -a dgwcontrol.kv -e "$1" com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"namespaceFilters\": [ { \"physicalClusterName\": \"$2\", \"include_shard_info\": true} ]}"
}


function namespace() {
  grpc -a dgwcontrol.kv -e "$1" com.netflix.dgw.control.DgwControlService/GetNamespaces -d "{\"namespaceFilters\": [ { \"match_name\": \"$2\", \"include_shard_info\": true} ]}"
}

