# Create the folder structure
# mkdir -p ~/.zsh
# cd ~/.zsh
# Download the scripts
# curl -o git-completion.bash https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.bash
# curl -o _git https://raw.githubusercontent.com/git/git/master/contrib/completion/git-completion.zsh
# compaudit | xargs chown -R "$(whoami)"
# compaudit | xargs chmod go-w
echo 'mho zshrc'
zstyle ':completion:*:*:git:*' script ~/.zsh/git-completion.bash
fpath=(~/.zsh $fpath)

autoload -Uz compinit && compinit
autoload bashcompinit && bashcompinit

export LSCOLORS=ExGxBxDxCxEgEdxbxgxcxd
alias ls='ls -G'

alias gca='git commit --amend'
alias gpo='git push origin'
alias gpofwl='gpo --force-with-lease'
alias rb_all='~/repos/fun-bash-automations/rebase-all-branches/rebaseAllBranches.sh'
alias bcc='mint build'
alias rbcc='rb_all && testbcc'
alias rbi='git rebase -i master'
alias grb='git rebase'
alias grbc='git rebase --continue'
alias squash='rbi && gca'
alias gk='rp gobblin-kafka'
alias gkj='rp gobblin-kafka-jobs'
alias gtw='rp gobblin-temporal-workers'
alias br='rp beam-runner'
alias bfa='rp beam-flink-airflow'
alias gbtest='./gradlew -PskipTestGroup=disabledOnCI build --scan'
alias gbsnap='rp gobblin && snap 0.19.0'
alias gblint='./gradlew --no-daemon javadoc findbugsMain checkstyleMain checkstyleTest checkstyleJmh '

alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias gb='git branch'
alias gl='git log --pretty=format:"%h %d - %an, %ar : %s" --decorate=short' 
alias rbu='~/repos/fun-bash-automations/review-board/rb_update.sh'
alias rbc='~/repos/fun-bash-automations/review-board/rb_create.sh'
alias rbs='~/repos/fun-bash-automations/review-board/rb_submit.sh'
source "~/repos/fun-bash-automations/rp/rp-completion.sh"
alias rp=". ~/repos/fun-bash-automations/rp/rp.sh"
alias rpa=". ~/repos/fun-bash-automations/rp/archive/rp-archive.sh"
alias rpu=". ~/repos/fun-bash-automations/rp/archive/rp-unarchive.sh"

export GOPATH=$HOME/golang
export GOROOT=/usr/local/opt/go/libexec
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin


# Crontab -e
# 0 45/60 10-5 * MON,TUE,WED,THU,FRI * osascript -e 'display notification "Take a stretch break!" with title "Break reminder" sound name "Glass"'

