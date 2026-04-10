#!/usr/bin/env bash
set -euo pipefail

export BEADS_DIR="${BEADS_DIR:-$HOME/repos/dump/.beads}"
export BD_DB="${BD_DB:-$BEADS_DIR/beads.db}"

if [[ ! -f "$BD_DB" ]]; then
    exit 0
fi

if command -v bd >/dev/null 2>&1; then
    exec bd prime
fi

for candidate in \
    "$HOME/.local/bin/bd" \
    /opt/homebrew/bin/bd \
    /home/linuxbrew/.linuxbrew/bin/bd \
    /usr/local/bin/bd
do
    if [[ -x "$candidate" ]]; then
        exec "$candidate" prime
    fi
done

exit 0
