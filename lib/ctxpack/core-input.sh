#!/usr/bin/env bash

resolve_base() {
  local want="${1:-}"
  if [ -n "$want" ]; then printf '%s\n' "$want"; return 0; fi
  local head_ref
  head_ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null || true)
  [ -n "$head_ref" ] || {
    for ref in refs/remotes/origin/main refs/remotes/origin/master \
               refs/heads/main refs/heads/master; do
      git show-ref -q --verify "$ref" && { head_ref="$ref"; break; }
    done
  }
  if [ -n "$head_ref" ]; then
    local mb
    mb=$(git merge-base HEAD "$head_ref" 2>/dev/null || true)
    if [ -n "$mb" ] && [ "$mb" != "$(git rev-parse HEAD)" ]; then
      printf '%s\n' "$mb"
      return 0
    fi
  fi
  printf 'HEAD\n'
}

changed_files() {
  local base="$1"
  if [ "$base" = "HEAD" ]; then
    git diff --name-only HEAD 2>/dev/null
  else
    git diff --name-only "$base"...HEAD 2>/dev/null
    git diff --name-only HEAD 2>/dev/null
  fi
  git ls-files --others --exclude-standard 2>/dev/null
}

untracked_diff() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git diff --no-index -- /dev/null "$f" 2>/dev/null || true
  done < <(git ls-files --others --exclude-standard 2>/dev/null)
}

diff_body() {
  local base="$1"
  if [ "$base" = "HEAD" ]; then
    git diff HEAD 2>/dev/null
  else
    git diff "$base"...HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
  fi
  untracked_diff
}

is_test_path() {
  case "$1" in
    */test/*|*/tests/*|*/spec/*|*_test.*|*test_*|*.test.*|*.spec.*|*Test.java|*Tests.java) return 0 ;;
    *) return 1 ;;
  esac
}

IDENT_RE='([a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*|[A-Z][a-z0-9]+[A-Z][A-Za-z0-9]*|[A-Z][A-Z0-9]*_[A-Z0-9_]+)'

is_code_path() {
  case "${1##*.}" in
    java|kt|kts|scala|groovy|gradle|ts|tsx|js|jsx|vue|py|go|rb|rs|swift|c|cc|cpp|h|hpp|cs|php|sh|bash|proto) return 0 ;;
    *) return 1 ;;
  esac
}

tokens_of() {
  grep -oE "$IDENT_RE" "$1" 2>/dev/null | sort -u || true
}
