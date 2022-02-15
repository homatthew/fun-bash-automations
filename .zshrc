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

alias gprb='git pull --rebase origin master'
alias gch='git checkout'
alias rbu='/Users/mho/repos/fun-bash-automations/review-board/rb_update.sh'
alias rbc='/Users/mho/repos/fun-bash-automations/review-board/rb_create.sh'

rp-impl() {
    cd "/Users/mho/repos/${1}"
}
alias rp=rp-impl

snap-impl() {
    if [ $# -eq 1 ]; then
        ./gradlew -Dmaven.repo.local=$HOME/local-repo -Dorg.gradle.parallel=false -Pversion="${1}-SNAPSHOT" publishToMavenLocal
    else
        echo "Usage: snap {SNAPSHOT_VERSION}"
    fi

}
alias snap=snap-impl



autoload -Uz compinit && compinit
export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"
export JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk1.8.0_121.jdk/Contents/Home
