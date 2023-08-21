#!/usr/bin/env bash

set -e

#Configurations
branch_prefix="mh"
jira_prefixes=("ETL" "GCN" "APA" "GOBBLIN")
auto_git_prune_enabled=true
auto_determine_main_or_master=true
auto_delete_resolved_branches=true

if [[ -z $branch_prefix ]]
then
	printf "ERROR: Edit the branch_prefix in the rebaseAllBranches.sh script. Then retry\n"
	exit 1
fi

deleteResolvedTickets () {
	num_branches_deleted=0
	branches=$(git branch -l "${branch_prefix}*" | sed 's/\*/ /g')
	for branch in $branches
	do
		for j_prefix in ${jira_prefixes[@]}
		do
			contains_jira_ticket_regex="($j_prefix-[0-9]+)"
			branch_name_uppercased=$(echo "${branch}" | tr '[a-z]' '[A-Z]')

			if [[ $branch_name_uppercased =~ $contains_jira_ticket_regex ]]
			then
				ticket="${BASH_REMATCH[1]}"
				if [[ -z $ticket ]]
				then
					break
				fi
				printf "\t Searching for commits that solve ${ticket}...\n"
				commits_with_ticket=$(git log -300 --grep="\[${ticket}\]")
				if [[ ! -z $commits_with_ticket ]]
				then
					printf "\t The ${ticket} jira ticket has been solved in a commit on master.\n"
					printf "\t Saving current changes on origin/${branch} before deleting\n"
					git push -u -f origin "${branch}"
					printf "\t Deleting ${branch}\n"
					git branch -D "${branch}"
					num_branches_deleted=$(($num_branches_deleted+1))
					break
				fi
			fi
		done
	done

	printf "\t FINISHED: Deleted ${num_branches_deleted} branches\n"
}

# Start of script

contains_master=false
branches=$(git branch -l | sed 's/\*/ /g')
for branch in $branches
do
	if [ "$branch" == "master" ]
	then
		contains_master=true
	fi
done

target_branch="main"
if [ $contains_master = true ]
then
	target_branch="master"
fi

prev_branch=$(git branch --show-current)
cur_date=$(date)
printf "=================================================================================\n"
printf "\t Rebasing all branches with the following prefix ${branch_prefix} onto branch ${target_branch}\n"
printf "\t \t ${cur_date}\n"
printf "=================================================================================\n"
conflicts=$(git ls-files -u)
if [[ ! -z $conflicts  ]]
then
	printf "There are existing conflicting files on this branch. Please fix this and then retry: Branch=${prev_branch} Files=${conflicts}\n"
	exit 1
fi


stashed=false
if [[ $(git status -s) ]]
then
	stash_name="${prev_branch}: ${cur_date}"
	printf "\t Uncommitted changes found. Stashing changes with message '${stash_name}'\n"
	git stash push --include-untracked -m "${stash_name}"
	stashed=true
else
	printf "\t No uncommitted changes found. No stash will be created\n"
fi

printf "=================================================================================\n"

git checkout ${target_branch}
git fetch origin

read -p "The script is going to reset HARD ${target_branch} to origin. Do you want to continue? (Y/n) "
echo    # (optional) move to a new line
if [[ ! $REPLY =~ ^[Nn]$ ]]
then
	printf "\t Updating ${target_branch} branch to be the same as origin\n"
	git reset --hard origin/${target_branch}
else
	git merge --ff-only
fi

if [ $auto_delete_resolved_branches = true ]
then
	printf "=================================================================================\n"
	printf "\t Deleting branches for tickets that have been resolved\n"
	deleteResolvedTickets
fi

branches=$(git branch -l "${branch_prefix}*" | sed 's/\*/ /g')
for branch in $branches
do
	printf "=================================================================================\n"
	printf "\t Rebasing ${branch}\n"
	git checkout $branch && git rebase ${target_branch}
	conflicts=$(git ls-files -u)
	if [[ ! -z $conflicts  ]]
	then
		printf "CONFLICTING FILES: Branch=${branch} Files=${conflicts}\n"
		exit 1
	fi

	printf "\t FINISHED: Rebasing ${branch}\n"
done

prev_branch_deleted=true
all_branches=$(git branch | sed 's/\*/ /g')
for branch in $all_branches
do
	if [[ "$branch"  == "$prev_branch" ]]
	then
		prev_branch_deleted=false
	fi
done

printf "=================================================================================\n"
if [ $prev_branch_deleted = true ]
then
	printf "\t ${prev_branch} branch has been deleted. Switching to ${target_branch}\n"
	git checkout $target_branch
else
	printf "\t Switching back to ${prev_branch}\n"
	git checkout $prev_branch
	if [ $stashed = true ]
	then
		printf "Found a previous stash. Popping stash off the stack.\n"
		git stash pop
	else
		printf "No previous stash found.\n"
	fi
fi
printf "=================================================================================\n"

if [ $auto_git_prune_enabled = true ]
then
	printf "=================================================================================\n"
	printf "\t Automatic 'git prune' enabled. \n"
	printf "\t Pruning...\n"
	rm -f .git/gc.log
	git prune
	printf "\t Pruning Complete\n"
	printf "=================================================================================\n"
fi

set +e
