#/usr/bin/env bash
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT
rp_unarchive_impl() {
  home="/Users/mho"
  for arg in "$@"; do
    if [ $# -gt 1 ]; then
      echo "mv $home/repos-archive/${arg} $home/repos/${arg}"
    fi
    mv "$home/repos-archive/${arg}" "$home/repos/${arg}"
  done
}
rp_unarchive_impl $@
