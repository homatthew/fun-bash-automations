#!/usr/bin/env bash
set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$SOURCE_DIR/$SOURCE" ;; esac
done
FBA="$(cd -P "$(dirname "$SOURCE")/../../../.." && pwd)"

exec "$FBA/lib/cursor-sub-review/spawn-cursor-pane.sh" "$@"
