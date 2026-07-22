#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-deploy-help-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/root/bin" "$TMP/root/scripts"
cp "$ROOT/bin/fba-deploy" "$TMP/root/bin/fba-deploy"
printf '%s\n' '#!/usr/bin/env bash' 'touch "$FBA_HELP_SIDE_EFFECT"' >"$TMP/root/scripts/check-push-safety.sh"
chmod +x "$TMP/root/bin/fba-deploy" "$TMP/root/scripts/check-push-safety.sh"

help_output="$(FBA_HELP_SIDE_EFFECT="$TMP/side-effect" "$TMP/root/bin/fba-deploy" --help)" ||
  fail "fba-deploy --help failed"
[[ "$help_output" == Usage:* ]] || fail "fba-deploy --help omitted usage"
[[ ! -e "$TMP/side-effect" ]] || fail "fba-deploy --help ran push-safety side effects"

echo "fba deploy help regression passed"
