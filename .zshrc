autoload -Uz compinit && compinit
autoload bashcompinit && bashcompinit

export LSCOLORS=ExGxBxDxCxEgEdxbxgxcxd
alias ls='ls -G'

alias gca='git commit --amend'
alias gpo='git push origin'
alias gpofwl='gpo --force-with-lease'
alias rb_all='/Users/mho/repos/fun-bash-automations/rebase-all-branches/rebaseAllBranches.sh'
alias bcc='mint build'
alias rbcc='rb_all && testbcc'
alias rbi='git rebase -i master'
alias grb='git rebase'
alias grbc='git rebase --continue'
alias squash='rbi && gca'
alias gk='rp gobblin-kafka'
alias gkj='rp gobblin-kafka-jobs'
alias gbsnap='rp gobblin && snap 0.18.0'
alias gblint='./gradlew --no-daemon javadoc findbugsMain checkstyleMain checkstyleTest checkstyleJmh '

alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias gb='git branch'
alias gl='git log --pretty=format:"%H - %an, %ar : %s"'
alias rbu='/Users/mho/repos/fun-bash-automations/review-board/rb_update.sh'
alias rbc='/Users/mho/repos/fun-bash-automations/review-board/rb_create.sh'
alias rbs='/Users/mho/repos/fun-bash-automations/review-board/rb_submit.sh'
alias snap="/Users/mho/repos/fun-bash-automations/build-scripts/gobblin-snap.sh"
source "/Users/mho/repos/fun-bash-automations/rp/rp-completion.sh"
alias rp=". /Users/mho/repos/fun-bash-automations/rp/rp.sh"
alias rpa=". /Users/mho/repos/fun-bash-automations/rp/archive/rp-archive.sh"
alias rpu=". /Users/mho/repos/fun-bash-automations/rp/archive/rp-unarchive.sh"
alias zkinspector="/Users/mho/repos/zooinspector/target/zooinspector-pkg/bin/zooinspector.sh"

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk1.8.0_121.jdk/Contents/Home
export GOPATH=$HOME/golang
export GOROOT=/usr/local/opt/go/libexec
export PATH=$PATH:$GOPATH/bin
export PATH=$PATH:$GOROOT/bin

# Crontab -e
# 0 45/60 10-5 * MON,TUE,WED,THU,FRI * osascript -e 'display notification "Take a stretch break!" with title "Break reminder" sound name "Glass"'

