kun_version_line() {
  local bin="$1" out="$2"
  printf '%s\n' "$out" | awk -v bin="$(basename "$bin")" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line ~ /^v?[0-9]+\.[0-9]+(\.[0-9]+)?([^0-9].*)?$/) {
        print line
        exit
      }
      prefix = "^" bin "([[:space:]]+version)?[[:space:]:=-]+v?[0-9]+\\.[0-9]+"
      if (line ~ prefix) {
        print line
        exit
      }
    }
  '
}

kun_semver_triplet() {
  local text="$1"
  if [[ "$text" =~ v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    printf '%s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

kun_same_minor_or_newer_patch_match() {
  local line="$1" match="$2" want want_major want_minor want_patch have have_major have_minor have_patch
  want=$(kun_semver_triplet "$match") || return 1
  have=$(kun_semver_triplet "$line") || return 1
  read -r want_major want_minor want_patch <<< "$want"
  read -r have_major have_minor have_patch <<< "$have"
  [[ "$have_major" == "$want_major" && "$have_minor" == "$want_minor" ]] || return 1
  (( 10#$have_patch >= 10#$want_patch ))
}

kun_version_line_matches() {
  local line="$1" match="$2" policy="${3:-}"
  case "$policy" in
    same_minor_or_newer_patch)
      kun_same_minor_or_newer_patch_match "$line" "$match"
      ;;
    ""|exact|contains)
      [[ "$line" == *"$match"* ]]
      ;;
    *)
      return 1
      ;;
  esac
}
