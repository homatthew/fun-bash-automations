#/usr/bin/env bash
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'echo "\"${last_command}\" command filed with exit code $?."' EXIT
rp_archive_impl() {
  home="/Users/matthewho"
  for arg in "$@"; do
    if [ $# -gt 1 ]; then
      echo "mv $home/repos/${arg} $home/repos-archive/${arg}"
    fi
    mv "$home/repos/${arg}" "$home/repos-archive/${arg}"
  done
}
rp_archive_impl $@

set +e