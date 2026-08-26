#!/usr/bin/env bash

section_claim() {
  local base="$1"
  printf '## Claim under review\n\n'
  local branch; branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  printf -- '- Branch: `%s`   Base: `%s`\n' "$branch" "$base"
  local jira; jira=$(printf '%s' "$branch" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1 || true)
  [ -n "$jira" ] && printf -- '- Ticket: `%s`\n' "$jira"
  printf '\n### Commit subjects\n\n```\n'
  if [ "$base" = "HEAD" ]; then
    printf '(uncommitted working-tree changes; no commit messages yet)\n'
  else
    git log --format='%h %s' "$base"..HEAD | awk 'NR<=40'
  fi
  printf '```\n\n'
  printf '> A reviewer judges the diff against *this* claim. If the diff does more\n'
  printf '> than the claim says, that surplus is the first finding.\n\n'
}

section_scope() {
  local base="$1"; shift
  local files=("$@")
  printf '## Scope ledger\n\n'
  local impl=() tests=() f
  for f in "${files[@]}"; do
    if is_test_path "$f"; then tests+=("$f"); else impl+=("$f"); fi
  done
  local adds dels
  adds=$(diff_body "$base" | grep -c '^+[^+]' || true); adds="${adds:-0}"
  dels=$(diff_body "$base" | grep -c '^-[^-]' || true); dels="${dels:-0}"
  printf -- '- Files: %d implementation, %d test\n' "${#impl[@]}" "${#tests[@]}"
  printf -- '- Lines: +%s / -%s\n' "$adds" "$dels"

  local tier="1 — self-review"
  if [ "$adds" -gt 400 ] || [ "${#files[@]}" -gt 15 ]; then tier="2 — multi-model (wide diff)"; fi
  for f in "${files[@]}"; do
    case "$f" in
      *auth*|*Auth*|*secret*|*Secret*|*credential*|*crypto*|*hook*|*push*|*token*|*Token*)
        tier="2 — multi-model (sensitive surface: $f)"; break ;;
    esac
  done
  printf -- '- Suggested tier: **%s**\n\n' "$tier"
  if [ "${#tests[@]}" -eq 0 ] && [ "${#impl[@]}" -gt 0 ]; then
    printf '> **No test files changed.** Either the behaviour is already locked by an\n'
    printf '> existing test (name it) or this is the finding.\n\n'
  fi
  printf '### Implementation\n\n'
  printf '%s\n' "${impl[@]:-(none)}" | awk -v n="$MAX_FILES" \
    'NR<=n {print "- `" $0 "`"} END {if (NR>n) printf "- _(%d more not shown)_\n", NR-n}'
  printf '\n### Tests\n\n'
  printf '%s\n' "${tests[@]:-(none)}" | awk -v n="$MAX_FILES" \
    'NR<=n {print "- `" $0 "`"} END {if (NR>n) printf "- _(%d more not shown)_\n", NR-n}'
  printf '\n'
}

section_constitution() {
  printf '## Repo constitution\n\n'
  local found=0 f
  for f in AGENTS.md CLAUDE.md CONTRIBUTING.md ARCHITECTURE.md; do
    [ -f "$f" ] && { printf -- '- `%s` (%s lines)\n' "$f" "$(wc -l < "$f" | tr -d ' ')"; found=1; }
  done
  if [ -d .agents ]; then
    while IFS= read -r f; do
      printf -- '- `%s` (%s lines)\n' "$f" "$(wc -l < "$f" | tr -d ' ')"
      found=1
    done < <(find .agents -name '*.md' -type f | sort)
  fi
  while IFS= read -r f; do
    printf -- '- `%s` (module-scoped, %s lines)\n' "$f" "$(wc -l < "$f" | tr -d ' ')"
    found=1
  done < <(find . -mindepth 2 -maxdepth 3 -name AGENTS.md -not -path './.git/*' 2>/dev/null | sort)
  [ "$found" -eq 1 ] || printf -- '- (none found — the reviewer has no written convention to cite)\n'
  printf '\n> Findings that cite one of these by file and line are actionable.\n'
  printf '> Findings that cite the reviewer'"'"'s taste are churn.\n\n'
}

# Count sibling precedent rather than judging it by taste.
section_precedent() {
  local base="$1"; shift
  local files=("$@")
  printf '## Sibling precedent\n\n'
  printf 'Counted over files in the same directory with the same extension.\n'
  printf 'Quorum: a token used by >=%s%% of siblings (min %s) counts as convention.\n\n' \
    "$PRECEDENT_QUORUM" "$PRECEDENT_MIN"

  local tmp="$WORK/precedent"; mkdir -p "$tmp"
  local added="$tmp/added"
  diff_body "$base" | grep '^+[^+]' | cut -c2- > "$added" || true
  local any=0 blocks=0 f
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    is_test_path "$f" && continue
    is_code_path "$f" || continue
    if [ "$blocks" -ge 15 ]; then
      printf '_(precedent capped at 15 files; re-run on a narrower diff for the rest)_\n\n'
      break
    fi
    local dir ext
    dir=$(dirname "$f"); ext="${f##*.}"
    local siblings=()
    while IFS= read -r s; do
      [ "$s" = "$f" ] && continue
      siblings+=("$s")
    done < <(find "$dir" -maxdepth 1 -type f -name "*.${ext}" 2>/dev/null | sort | head -"$MAX_SIBLINGS")
    local m=${#siblings[@]}
    [ "$m" -ge "$PRECEDENT_MIN" ] || continue

    : > "$tmp/sibtokens"
    local s
    for s in "${siblings[@]}"; do tokens_of "$s" >> "$tmp/sibtokens"; done
    sort "$tmp/sibtokens" | uniq -c | sort -rn > "$tmp/counts"
    local need=$(( m * PRECEDENT_QUORUM / 100 ))
    [ "$need" -lt "$PRECEDENT_MIN" ] && need="$PRECEDENT_MIN"
    tokens_of "$f" > "$tmp/mine"
    local absent
    absent=$(awk -v need="$need" '$1 >= need { print $2 }' "$tmp/counts" \
      | grep -vxF -f "$tmp/mine" 2>/dev/null | head -12 || true)
    local novel
    novel=$(grep -oE "$IDENT_RE" "$added" 2>/dev/null \
      | grep -xF -f "$tmp/mine" 2>/dev/null | sort | uniq -c | sort -rn \
      | awk '{print $2"\t"$1}' \
      | grep -vF -f <(awk '{print $2}' "$tmp/counts") 2>/dev/null \
      | awk 'NR<=10' || true)

    if [ -n "$absent" ] || [ -n "$novel" ]; then
      any=1; blocks=$((blocks+1))
      printf '### `%s`  (%d siblings in `%s`)\n\n' "$f" "$m" "$dir"
      if [ -n "$absent" ]; then
        printf '**Absent precedent** — used by >=%d/%d siblings, not by this file:\n\n' "$need" "$m"
        local t
        while IFS= read -r t; do
          local c; c=$(awk -v k="$t" '$2==k{print $1}' "$tmp/counts")
          printf -- '- `%s` — %s/%d siblings\n' "$t" "$c" "$m"
        done <<< "$absent"
        printf '\n'
      fi
      if [ -n "$novel" ]; then
        printf '**Novel in this family** — introduced here, 0 siblings use it:\n\n'
        printf '%s\n' "$novel" | awk -F'\t' '{printf "- `%s` — %s use(s) in the diff\n", $1, $2}'
        printf '\n'
      fi
    fi
  done
  [ "$any" -eq 1 ] || printf '(no directory in this diff had enough siblings to establish precedent)\n\n'
  printf '> Absent precedent is a *lead*, not a finding. Open two of the cited\n'
  printf '> siblings before writing the comment — the token may be irrelevant here,\n'
  printf '> and a miscounted convention is the most annoying kind of review noise.\n\n'
}

section_history() {
  local base="$1"; shift
  local files=("$@")
  printf '## History on the touched files\n\n'
  local f n=0
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    n=$((n+1))
    [ "$n" -gt 20 ] && { printf -- '- … (%d more files not shown)\n' $(( ${#files[@]} - 20 )); break; }
    printf '### `%s`\n\n```\n' "$f"
    git log -n 4 --format='%h %ad %an  %s' --date=short -- "$f" 2>/dev/null || true
    printf '```\n\n'
  done
  printf '> A file rewritten three times this quarter is a design smell the diff\n'
  printf '> may be repeating. A file untouched for two years deserves more caution.\n\n'
}
