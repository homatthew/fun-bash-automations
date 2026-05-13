#!/usr/bin/env bash
# Block accidental leakage of personal/Netflix-confidential content before
# pushing fun-bash-automations to public github.com/homatthew.
#
# Patterns are intentionally broad — any match exits non-zero and prints
# file:line so the developer can either fix the content or, if the match is
# intentional (e.g. skill docs naming Netflix paved-path tools), add it to
# scripts/check-push-safety.allow.
#
# Usage:
#   scripts/check-push-safety.sh            # scan tracked files
#   scripts/check-push-safety.sh --staged   # scan only staged diff content
#   scripts/check-push-safety.sh --install-hook   # write .git/hooks/pre-push
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOW_FILE="$ROOT/scripts/check-push-safety.allow"
MODE="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged" ;;
    --install-hook) MODE="install-hook" ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$MODE" == "install-hook" ]]; then
  hook="$ROOT/.git/hooks/pre-push"
  cat > "$hook" <<'HOOK'
#!/usr/bin/env bash
exec "$(git rev-parse --show-toplevel)/scripts/check-push-safety.sh"
HOOK
  chmod +x "$hook"
  echo "installed pre-push hook at $hook"
  exit 0
fi

# Patterns to flag. Each line: <label>|<extended regex>
# Keep regex strict — false positives train people to ignore.
PATTERNS=(
  'personal-email|matthewho@'
  'aws-access-key|AKIA[0-9A-Z]{16}'
  'openai-secret|sk-[A-Za-z0-9]{32,}'
  'github-pat|ghp_[A-Za-z0-9]{36}'
  'github-pat-fine|github_pat_[A-Za-z0-9_]{40,}'
  'slack-bot-token|xox[abrs]-[A-Za-z0-9-]{10,}'
  'private-key-pem|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'metatron-token|metatron[._-]?token'
  'aws-secret-key|aws[_-]?secret[_-]?access[_-]?key[[:space:]]*[:=][[:space:]]*["A-Za-z0-9/+=]'
)

# allow-list: one regex per line matching "path:pattern_label" pairs to ignore.
# Comments (#) and blanks allowed.
allow_match() {
  local file="$1" label="$2"
  [[ -f "$ALLOW_FILE" ]] || return 1
  local key="${file}:${label}"
  while IFS= read -r line; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [[ "$key" == $line || "$key" =~ $line ]]; then
      return 0
    fi
  done < "$ALLOW_FILE"
  return 1
}

if [[ "$MODE" == "staged" ]]; then
  # Scan staged diff content for added lines that match patterns.
  diff_text="$(git -C "$ROOT" diff --cached --unified=0 --no-color)"
  if [[ -z "$diff_text" ]]; then
    echo "no staged changes"
    exit 0
  fi
  files_to_scan="$(git -C "$ROOT" diff --cached --name-only --diff-filter=ACMR)"
else
  files_to_scan="$(git -C "$ROOT" ls-files)"
fi

HITS=0
while IFS= read -r file; do
  [[ -n "$file" && -f "$ROOT/$file" ]] || continue
  # Skip binaries
  if file --mime "$ROOT/$file" 2>/dev/null | grep -q "charset=binary"; then
    continue
  fi
  # Don't scan the allow-list or the scanner itself
  case "$file" in
    scripts/check-push-safety.sh|scripts/check-push-safety.allow) continue ;;
  esac

  for entry in "${PATTERNS[@]}"; do
    label="${entry%%|*}"
    regex="${entry#*|}"
    matches="$(grep -nE "$regex" "$ROOT/$file" 2>/dev/null || true)"
    [[ -z "$matches" ]] && continue
    # filter out placeholder/template literals
    matches="$(printf '%s\n' "$matches" | grep -v -F '__USER_NETFLIX_EMAIL__' || true)"
    [[ -z "$matches" ]] && continue
    if allow_match "$file" "$label"; then
      continue
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf 'LEAK  %s:%s  [%s]\n' "$file" "${line%%:*}" "$label"
      HITS=$((HITS + 1))
    done <<< "$matches"
  done
done <<< "$files_to_scan"

if [[ "$HITS" -gt 0 ]]; then
  cat <<MSG >&2

push-safety scan failed: $HITS hit(s)

Resolutions:
  - fix the content (replace personal/internal value with a placeholder or env var)
  - if intentional, append a "path:pattern-label" pattern to:
      $ALLOW_FILE
MSG
  exit 1
fi

echo "push-safety scan clean ($MODE)"
