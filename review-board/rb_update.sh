#!/usr/bin/env bash

set -e
rb_update () {(
  TMP_BRANCH=$(git branch --show-current)
  git branch "${TMP_BRANCH}" -u origin/master

  if [ -z "$1" ]; then
    commits_since_master="(git rev-list master.. --count)"
    git_log="(git log -${commits_since_master} --pretty=%B)"
    rb_id_regex="RB=([0-9]+)"
    if [[ $git_log =~ $rb_id_regex ]]
		then
			rb_id="${BASH_REMATCH[1]}"
			git review update -r "$rb_id"
		else
			git review update
		fi
  else
    git review update -r "$1"
  fi

  git branch $TMP_BRANCH -u "origin/${TMP_BRANCH}"
)}

rb_update