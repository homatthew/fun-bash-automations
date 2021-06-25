#!/bin/bash

set -Eeuo pipefail

errorhandler() {
	ant smoke.tomcat
	osascript -e 'tell app "System Events" to display dialog "Clean build failed. Check build.log for more information."' &
	exit 1
}

trap errorhandler ERR

HOME='/Users/matthewho'
source $HOME/.zshenv && source $HOME/.zshrc
cd $HOME/okta/okta-core

cur_branch=$(git branch --show-current)
cur_date=$(date)
stashed=false
if [[ $(git status -s) ]] 
then
	stash_name="${cur_branch}: ${cur_date}"
	printf "\tUncommitted changes found. Stashing changes with message '${stash_name}'\n"
	git stash push --include-untracked -m "${stash_name}"
	stashed=true
else
	printf "\tNo uncommitted changes found. No stash will be created\n"
fi

ok vpn start 
ant smoke.tomcat
ok mono infra stop # stopData
ok mono infra create && ok mono infra start # startData
ok mono build # Build (clean) & Upgrade DB
ant smoke.tomcat

if [ $stashed = true ] 
then
	printf "Found a previous stash. Popping stash off the stack.\n"
	git stash pop
else
	printf "No previous stash found.\n"
fi

parent_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
cd "$parent_path"
printf "\tBuild completed successfully!!! \n" >> cron.log
printf "=================================================================================\n" >> cron.log
osascript -e 'tell app "System Events" to display dialog "Build process completed with exit code 0"'