#!/usr/bin/env bash

set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT
rb_merge () {(
  git checkout "${1}"
  git review dcommit

  git checkout master
  git rebase "${1}"
  git push origin master
)}

rb_merge $@
set +e