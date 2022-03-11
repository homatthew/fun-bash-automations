#/usr/bin/env bash

set -e
snap_impl() {(
	if [ $# -eq 1 ]; then
		snapshot_regex="([0-9]+\.[0-9]+\.[0-9]+)"
		if [[ "$1" =~  $snapshot_regex ]]; then
			snapshot="${BASH_REMATCH[1]}"
			if [[ ! -z snapshot ]]
			then
				./gradlew -Dmaven.repo.local=$HOME/local-repo -Dorg.gradle.parallel=false -Pversion="${snapshot}-SNAPSHOT" publishToMavenLocal
				exit 0
			fi
			echo "SNAPSHOT_VERSION must follow the format $snapshot_regex"
		fi
	else
			echo "Usage: snap {SNAPSHOT_VERSION}"
	fi
)}

snap_impl $@
set +e