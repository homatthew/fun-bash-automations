#/usr/bin/env bash
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT
zero=0
rp_impl() {
	if [ $# -gt 1 ]; then
    echo "cd /Users/mho/repos/${1}"
  fi
  cd "/Users/mho/repos/${1}"
  i=0
  for arg in "$@"; do
    if [[ $i -ne $zero ]]; then
      echo "${1}: mint $arg"
      mint "$arg"
    fi
    i+=1
  done
}
rp_impl $@

set +e