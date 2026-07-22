#!/usr/bin/env bash
# Block accidental publication of credentials and environment-private content.
set -euo pipefail

DEFAULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${FBA_PUSH_SAFETY_ROOT:-$DEFAULT_ROOT}"
MODE="all"
OUTGOING_BASE=""
POLICY_FILE="${FBA_PUSH_SAFETY_POLICY_FILE:-}"

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

ROOT="$(canonical_path "$ROOT")"
ALLOW_FILE="${FBA_PUSH_SAFETY_ALLOW_FILE:-$ROOT/scripts/check-push-safety.allow}"

sha256_file() {
  if [[ -x /usr/bin/shasum ]]; then
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /usr/bin/sha256sum ]]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [[ -x /bin/sha256sum ]]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  else
    echo "push-safety: no trusted SHA-256 utility is available" >&2
    return 1
  fi
}

validate_policy_file() {
  local requested="$1" policy_path label regex extra rc
  policy_path="$(canonical_path "$requested")"
  [[ -f "$policy_path" && -r "$policy_path" ]] || {
    echo "push-safety: policy file is not readable: $requested" >&2
    return 1
  }
  case "$policy_path" in
    "$ROOT"|"$ROOT"/*)
      echo "push-safety: private policy file must be outside the repository" >&2
      return 1
      ;;
  esac
  while IFS=$'\t' read -r label regex extra || [[ -n "$label$regex$extra" ]]; do
    [[ -n "$label" && "${label:0:1}" != "#" ]] || continue
    [[ "$label" =~ ^[a-z0-9][a-z0-9-]*$ && -n "$regex" && -z "$extra" ]] || {
      echo "push-safety: invalid policy entry in $policy_path" >&2
      return 1
    }
    if [[ "" =~ $regex ]]; then
      rc=0
    else
      rc=$?
    fi
    [[ "$rc" -ne 2 ]] || {
      echo "push-safety: invalid regex for policy label $label" >&2
      return 1
    }
  done < "$policy_path"
  printf '%s\n' "$policy_path"
}

validated_trust_record() {
  local requested_path="$1" requested_hash="$2" trusted_path trusted_hash actual_hash
  [[ "$requested_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || {
    echo "FBA_NO_MISTAKES_TRUSTED_SHA256 must be a SHA-256 digest" >&2
    return 1
  }
  trusted_path="$(canonical_path "$requested_path")"
  [[ -x "$trusted_path" ]] || {
    echo "trusted no-mistakes path is not executable: $trusted_path" >&2
    return 1
  }
  trusted_hash="$(printf '%s' "$requested_hash" | tr '[:upper:]' '[:lower:]')"
  actual_hash="$(sha256_file "$trusted_path")"
  [[ "$actual_hash" == "$trusted_hash" ]] || {
    echo "trusted no-mistakes digest does not match: $trusted_path" >&2
    return 1
  }
  printf '%s\t%s\n' "$trusted_path" "$trusted_hash"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged" ;;
    --pre-push)
      MODE="pre-push"
      shift
      break
      ;;
    --outgoing)
      [[ $# -ge 2 ]] || { echo "--outgoing requires a base ref" >&2; exit 2; }
      MODE="outgoing"
      OUTGOING_BASE="$2"
      shift
      ;;
    --install-hook) MODE="install-hook" ;;
    -h|--help)
      cat <<'USAGE'
Usage: check-push-safety.sh [--staged | --outgoing <base> | --pre-push | --install-hook]

With no option, scan the tracked worktree. --pre-push reads Git ref updates
from stdin and scans every outgoing commit snapshot. --outgoing scans every
commit snapshot between <base> and HEAD.
USAGE
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
  shift
done

install_hook() {
  local hook hook_dir managed_dir existing_hook safety_hook attestation trusted_dir
  local scanner_copy allow_copy scanner_hash allow_hash
  local policy_pointer trusted_path trusted_hash configured_policy trust_record extra
  local requested_scanner_hash requested_allow_hash
  local clear_policy="${FBA_PUSH_SAFETY_CLEAR_POLICY:-0}"
  local clear_trust="${FBA_NO_MISTAKES_CLEAR_TRUST:-0}"
  requested_scanner_hash="${FBA_PUSH_SAFETY_TRUSTED_SCANNER_SHA256:-}"
  requested_allow_hash="${FBA_PUSH_SAFETY_TRUSTED_ALLOW_SHA256:-}"
  [[ "$requested_scanner_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || {
    echo "FBA_PUSH_SAFETY_TRUSTED_SCANNER_SHA256 must supply the independently audited scanner digest" >&2
    exit 1
  }
  [[ "$requested_allow_hash" =~ ^[0-9A-Fa-f]{64}$ ]] || {
    echo "FBA_PUSH_SAFETY_TRUSTED_ALLOW_SHA256 must supply the independently audited allow-list digest" >&2
    exit 1
  }
  requested_scanner_hash="$(printf '%s' "$requested_scanner_hash" | tr '[:upper:]' '[:lower:]')"
  requested_allow_hash="$(printf '%s' "$requested_allow_hash" | tr '[:upper:]' '[:lower:]')"
  scanner_hash="$(sha256_file "$ROOT/scripts/check-push-safety.sh")"
  allow_hash="$(sha256_file "$ROOT/scripts/check-push-safety.allow")"
  [[ "$scanner_hash" == "$requested_scanner_hash" && "$allow_hash" == "$requested_allow_hash" ]] || {
    echo "push-safety: source assets do not match the independently supplied digests" >&2
    exit 1
  }
  hook="$(git -C "$ROOT" rev-parse --git-path hooks/pre-push)"
  case "$hook" in
    /*) ;;
    *) hook="$ROOT/$hook" ;;
  esac
  hook_dir="$(dirname "$hook")"
  managed_dir="$hook_dir/pre-push.d"
  existing_hook="$hook_dir/pre-push.fba-existing"
  safety_hook="$managed_dir/50-push-safety"
  attestation="$managed_dir/40-no-mistakes.attestation"
  policy_pointer="$managed_dir/45-push-safety-policy"
  trusted_dir="$managed_dir/.push-safety"
  scanner_copy="$trusted_dir/check-push-safety.sh"
  allow_copy="$trusted_dir/check-push-safety.allow"
  [[ ! -L "$managed_dir" ]] || {
    echo "refusing symlinked managed hook directory: $managed_dir" >&2
    exit 1
  }
  mkdir -p "$managed_dir"
  [[ ! -L "$safety_hook" && ! -L "$attestation" && ! -L "$policy_pointer" && ! -L "$trusted_dir" ]] || {
    echo "refusing symlinked managed hook component" >&2
    exit 1
  }
  if [[ -e "$trusted_dir" && ! -d "$trusted_dir" ]]; then
    echo "refusing non-directory trusted hook assets: $trusted_dir" >&2
    exit 1
  fi
  mkdir -p "$trusted_dir"
  [[ ! -L "$scanner_copy" && ! -L "$allow_copy" ]] || {
    echo "refusing symlinked trusted hook asset" >&2
    exit 1
  }

  if [[ -e "$safety_hook" ]]; then
    [[ -f "$safety_hook" ]] || {
      echo "refusing non-regular hook component: $safety_hook" >&2
      exit 1
    }
    if ! grep -Fq '# fba-push-safety-hook' "$safety_hook" 2>/dev/null; then
      echo "refusing to replace unmanaged hook component: $safety_hook" >&2
      exit 1
    fi
  fi

  if [[ -L "$hook" ]]; then
    if [[ -e "$existing_hook" || -L "$existing_hook" ]]; then
      echo "refusing to replace unmanaged pre-push hook: $hook" >&2
      exit 1
    fi
    mv "$hook" "$existing_hook"
  elif [[ -e "$hook" ]]; then
    if ! grep -Fq '# fba-managed-pre-push-dispatcher' "$hook" 2>/dev/null; then
      if [[ -e "$existing_hook" || -L "$existing_hook" ]]; then
        echo "refusing to replace unmanaged pre-push hook: $hook" >&2
        exit 1
      fi
      mv "$hook" "$existing_hook"
    fi
  fi

  cat > "$hook" <<'HOOK'
#!/bin/sh
# fba-managed-pre-push-dispatcher
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset BASH_ENV ENV CDPATH GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
hook_dir="$(CDPATH= cd "$(dirname "$0")" && pwd -P)" || exit 1
input="$(mktemp /tmp/pre-push-input.XXXXXX)" || exit 1
trap 'rm -f "$input"' EXIT
cat > "$input" || { echo "push-safety: failed to capture pre-push input" >&2; exit 1; }
enforcement_hook="$hook_dir/pre-push.d/50-push-safety"
[ -x "$enforcement_hook" ] && [ ! -L "$enforcement_hook" ] || {
  echo "push-safety: required enforcement hook is missing or not executable" >&2
  exit 1
}
"$enforcement_hook" "$@" < "$input" || exit $?
existing_hook="$hook_dir/pre-push.fba-existing"
if [ -x "$existing_hook" ]; then
  "$existing_hook" "$@" < "$input" || exit $?
fi
for child in "$hook_dir"/pre-push.d/*; do
  [ -x "$child" ] || continue
  [ "$child" != "$enforcement_hook" ] || continue
  "$child" "$@" < "$input" || exit $?
done
HOOK
  chmod +x "$hook"

  cp "$ROOT/scripts/check-push-safety.sh" "$scanner_copy"
  cp "$ROOT/scripts/check-push-safety.allow" "$allow_copy"
  chmod 700 "$scanner_copy"
  chmod 600 "$allow_copy"
  [[ "$(sha256_file "$scanner_copy")" == "$scanner_hash" && "$(sha256_file "$allow_copy")" == "$allow_hash" ]] || {
    echo "push-safety: installed enforcement assets failed copy verification" >&2
    exit 1
  }

  {
    cat <<'HOOK'
#!/bin/sh
# fba-push-safety-hook
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset BASH_ENV ENV CDPATH GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
root="$(git rev-parse --show-toplevel)" || exit 1
hook_dir="$(CDPATH= cd "$(dirname "$0")" && pwd -P)" || exit 1
scanner="$hook_dir/.push-safety/check-push-safety.sh"
allow_file="$hook_dir/.push-safety/check-push-safety.allow"
HOOK
    printf 'expected_scanner_hash=%q\n' "$scanner_hash"
    printf 'expected_allow_hash=%q\n' "$allow_hash"
    cat <<'HOOK'
sha256_file() {
  if [ -x /usr/bin/shasum ]; then
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
  elif [ -x /usr/bin/sha256sum ]; then
    /usr/bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  elif [ -x /bin/sha256sum ]; then
    /bin/sha256sum "$1" | /usr/bin/awk '{print $1}'
  else
    echo "push-safety: no trusted SHA-256 utility is available" >&2
    return 1
  fi
}
for asset in "$scanner" "$allow_file"; do
  [ -f "$asset" ] && [ ! -L "$asset" ] || {
    echo "push-safety: trusted enforcement asset is missing or unsafe: $asset" >&2
    exit 1
  }
done
[ "$(sha256_file "$scanner")" = "$expected_scanner_hash" ] && [ "$(sha256_file "$allow_file")" = "$expected_allow_hash" ] || {
  echo "push-safety: trusted enforcement assets failed integrity verification" >&2
  exit 1
}
policy_pointer="$hook_dir/45-push-safety-policy"
policy_file=
if [ -f "$policy_pointer" ]; then
  [ ! -L "$policy_pointer" ] || exit 1
  IFS= read -r FBA_PUSH_SAFETY_POLICY_FILE < "$policy_pointer" || exit 1
  [ -n "$FBA_PUSH_SAFETY_POLICY_FILE" ] || exit 1
  policy_file="$FBA_PUSH_SAFETY_POLICY_FILE"
fi
exec /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  HOME="${HOME:-/}" \
  TMPDIR=/tmp \
  FBA_PUSH_SAFETY_ROOT="$root" \
  FBA_PUSH_SAFETY_ALLOW_FILE="$allow_file" \
  FBA_PUSH_SAFETY_POLICY_FILE="$policy_file" \
  NO_MISTAKES_GATE="${NO_MISTAKES_GATE:-}" \
  /bin/bash --noprofile --norc "$scanner" --pre-push "$@"
HOOK
  } > "$safety_hook"
  chmod +x "$safety_hook"
  [[ "$clear_policy" == "0" || "$clear_policy" == "1" ]] || {
    echo "FBA_PUSH_SAFETY_CLEAR_POLICY must be 0 or 1" >&2
    exit 1
  }
  configured_policy="${FBA_PUSH_SAFETY_POLICY_FILE:-}"
  if [[ -n "$configured_policy" ]]; then
    [[ "$clear_policy" == "0" ]] || {
      echo "cannot configure and clear the push-safety policy together" >&2
      exit 1
    }
    configured_policy="$(validate_policy_file "$configured_policy")"
    umask 077
    printf '%s\n' "$configured_policy" > "$policy_pointer"
    chmod 600 "$policy_pointer"
  elif [[ "$clear_policy" == "1" ]]; then
    rm -f "$policy_pointer"
  elif [[ -e "$policy_pointer" || -L "$policy_pointer" ]]; then
    [[ -f "$policy_pointer" && ! -L "$policy_pointer" ]] || {
      echo "push-safety: installed policy pointer is not a regular file" >&2
      exit 1
    }
    [[ "$(awk 'END {print NR}' "$policy_pointer")" == "1" ]] || {
      echo "push-safety: installed policy pointer is malformed" >&2
      exit 1
    }
    IFS= read -r configured_policy < "$policy_pointer" || {
      echo "push-safety: installed policy pointer is unreadable" >&2
      exit 1
    }
    configured_policy="$(validate_policy_file "$configured_policy")"
    umask 077
    printf '%s\n' "$configured_policy" > "$policy_pointer"
    chmod 600 "$policy_pointer"
  fi
  [[ "$clear_trust" == "0" || "$clear_trust" == "1" ]] || {
    echo "FBA_NO_MISTAKES_CLEAR_TRUST must be 0 or 1" >&2
    exit 1
  }
  trusted_path="${FBA_NO_MISTAKES_TRUSTED_PATH:-}"
  trusted_hash="${FBA_NO_MISTAKES_TRUSTED_SHA256:-}"
  if [[ -n "$trusted_path" || -n "$trusted_hash" ]]; then
    [[ "$clear_trust" == "0" ]] || {
      echo "cannot configure and clear no-mistakes trust together" >&2
      exit 1
    }
    [[ -n "$trusted_path" && -n "$trusted_hash" ]] || {
      echo "both FBA_NO_MISTAKES_TRUSTED_PATH and FBA_NO_MISTAKES_TRUSTED_SHA256 are required" >&2
      exit 1
    }
    trust_record="$(validated_trust_record "$trusted_path" "$trusted_hash")"
    umask 077
    printf '%s\n' "$trust_record" > "$attestation"
    chmod 600 "$attestation"
  elif [[ "$clear_trust" == "1" ]]; then
    rm -f "$attestation"
  elif [[ -e "$attestation" || -L "$attestation" ]]; then
    [[ -f "$attestation" && ! -L "$attestation" ]] || {
      echo "push-safety: installed no-mistakes attestation is not a regular file" >&2
      exit 1
    }
    [[ "$(awk 'END {print NR}' "$attestation")" == "1" ]] || {
      echo "push-safety: installed no-mistakes attestation is malformed" >&2
      exit 1
    }
    IFS=$'\t' read -r trusted_path trusted_hash extra < "$attestation" || {
      echo "push-safety: installed no-mistakes attestation is unreadable" >&2
      exit 1
    }
    [[ -n "$trusted_path" && -n "$trusted_hash" && -z "$extra" ]] || {
      echo "push-safety: installed no-mistakes attestation is malformed" >&2
      exit 1
    }
    trust_record="$(validated_trust_record "$trusted_path" "$trusted_hash")"
    umask 077
    printf '%s\n' "$trust_record" > "$attestation"
    chmod 600 "$attestation"
  else
    echo "warning: independent no-mistakes trust policy not supplied; protected-branch delivery will fail closed" >&2
  fi
  echo "installed composable pre-push hook at $hook"
}

if [[ "$MODE" == "install-hook" ]]; then
  install_hook
  exit 0
fi

PATTERNS=(
  'aws-access-key|AKIA[0-9A-Z]{16}'
  'openai-secret|sk-(proj-)?[A-Za-z0-9_-]{20,}'
  'github-pat|ghp_[A-Za-z0-9]{36}'
  'github-pat-fine|github_pat_[A-Za-z0-9_]{40,}'
  'slack-bot-token|xox[abrs]-[A-Za-z0-9-]{10,}'
  'private-key-pem|-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'aws-secret-key|aws[_-]?secret[_-]?access[_-]?key[[:space:]]*[:=][[:space:]]*["A-Za-z0-9/+=]'
  'absolute-home-path|(^|[^A-Za-z0-9_}$./-])/(Users|home)/[A-Za-z0-9._-]+(/|[^A-Za-z0-9._/-]|$)'
)

load_policy_patterns() {
  local policy_path label regex extra
  [[ -n "$POLICY_FILE" ]] || return 0
  policy_path="$(validate_policy_file "$POLICY_FILE")"
  while IFS=$'\t' read -r label regex extra || [[ -n "$label$regex$extra" ]]; do
    [[ -n "$label" && "${label:0:1}" != "#" ]] || continue
    PATTERNS+=("$label|$regex")
  done < "$policy_path"
}

load_policy_patterns

HITS=0

allow_match() {
  local file="$1" label="$2" content="$3" line content_regex key
  [[ -f "$ALLOW_FILE" ]] || return 1
  key="${file}:${label}"
  while IFS=$'\t' read -r line content_regex; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    if [[ "$key" == $line || "$key" =~ $line ]]; then
      if [[ -z "$content_regex" || "$content" =~ $content_regex ]]; then
        return 0
      fi
    fi
  done < "$ALLOW_FILE"
  return 1
}

scan_line() {
  local file="$1" line_no="$2" content="$3" policy_file="${4:-$1}" entry label regex
  for entry in "${PATTERNS[@]}"; do
    label="${entry%%|*}"
    regex="${entry#*|}"
    [[ "$content" =~ $regex ]] || continue
    allow_match "$policy_file" "$label" "$content" && continue
    printf 'LEAK  %s:%s  [%s]\n' "$file" "$line_no" "$label"
    HITS=$((HITS + 1))
  done
}

scan_file_stream() {
  local file="$1" policy_file="${2:-$1}" line line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    scan_line "$file" "$line_no" "$line" "$policy_file"
  done
}

scan_path() {
  local path="$1" display="${2:-$1}"
  scan_line "$display" path "$path" "$path"
}

scan_git_object_oid() {
  local file="$1" policy_file="$2" object_type="$3" oid="$4" raw normalized
  raw="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-object.XXXXXX")"
  normalized="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-normalized.XXXXXX")"
  if ! git -C "$ROOT" cat-file "$object_type" "$oid" > "$raw"; then
    rm -f "$raw" "$normalized"
    echo "push-safety: failed to read $object_type object $oid" >&2
    return 1
  fi
  if ! LC_ALL=C tr -d '\000' < "$raw" > "$normalized"; then
    rm -f "$raw" "$normalized"
    echo "push-safety: failed to normalize $object_type object $oid" >&2
    return 1
  fi
  scan_file_stream "$file" "$policy_file" < "$normalized"
  rm -f "$raw" "$normalized"
}

scan_blob_oid() {
  scan_git_object_oid "$1" "$2" blob "$3"
}

scan_disk_file() {
  local file="$1" raw
  raw="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-file.XXXXXX")"
  if ! LC_ALL=C tr -d '\000' < "$ROOT/$file" > "$raw"; then
    rm -f "$raw"
    echo "push-safety: failed to read worktree file $file" >&2
    return 1
  fi
  scan_file_stream "$file" "$file" < "$raw"
  rm -f "$raw"
}

scan_staged() {
  local entry metadata mode oid path type index_file
  if git -C "$ROOT" diff --cached --quiet --diff-filter=ACMRT; then
    echo "no staged changes"
    return
  fi
  index_file="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-index.XXXXXX")"
  if ! git -C "$ROOT" ls-files --stage -z > "$index_file"; then
    rm -f "$index_file"
    echo "push-safety: failed to enumerate the index" >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    oid="${metadata#* }"
    oid="${oid%% *}"
    scan_path "$path"
    [[ "$mode" != "160000" ]] || continue
    if ! type="$(git -C "$ROOT" cat-file -t "$oid")"; then
      rm -f "$index_file"
      echo "push-safety: failed to inspect indexed object $oid" >&2
      return 1
    fi
    [[ "$type" == "blob" ]] || continue
    scan_blob_oid "$path" "$path" "$oid"
  done < "$index_file"
  rm -f "$index_file"
}

scan_worktree() {
  local entry metadata mode path target index_file
  index_file="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-index.XXXXXX")"
  if ! git -C "$ROOT" ls-files --stage -z > "$index_file"; then
    rm -f "$index_file"
    echo "push-safety: failed to enumerate tracked files" >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    mode="${metadata%% *}"
    scan_path "$path"
    if [[ -L "$ROOT/$path" ]]; then
      if ! target="$(readlink "$ROOT/$path")"; then
        rm -f "$index_file"
        echo "push-safety: failed to read symlink $path" >&2
        return 1
      fi
      scan_line "$path" 1 "$target" "$path"
    elif [[ "$mode" == "160000" ]]; then
      continue
    elif [[ -f "$ROOT/$path" ]]; then
      scan_disk_file "$path"
    fi
  done < "$index_file"
  rm -f "$index_file"
}

scan_commit() {
  local commit="$1" entry metadata type oid path tree_file
  scan_git_object_oid ".git/commit/$commit" ".git/commit/$commit" commit "$commit"
  tree_file="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-tree.XXXXXX")"
  if ! git -C "$ROOT" ls-tree -r -z --full-tree "$commit" > "$tree_file"; then
    rm -f "$tree_file"
    echo "push-safety: failed to enumerate commit tree $commit" >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    type="$(printf '%s\n' "$metadata" | awk '{print $2}')"
    oid="$(printf '%s\n' "$metadata" | awk '{print $3}')"
    scan_path "$path" "$path@$commit"
    [[ "$type" == "blob" ]] || continue
    scan_blob_oid "$path@$commit" "$path" "$oid"
  done < "$tree_file"
  rm -f "$tree_file"
}

scan_outgoing() {
  local base="$1" commit commits
  git -C "$ROOT" rev-parse --verify "$base^{commit}" >/dev/null 2>&1 || {
    echo "push-safety: outgoing base is not a commit: $base" >&2
    return 1
  }
  if ! commits="$(git -C "$ROOT" rev-list "$base..HEAD")"; then
    echo "push-safety: failed to enumerate outgoing commits" >&2
    return 1
  fi
  while IFS= read -r commit; do
    [[ -n "$commit" ]] && scan_commit "$commit"
  done <<< "$commits"
}

process_executable() {
  local pid="$1" executable
  if [[ -e "/proc/$pid/exe" ]]; then
    executable="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
  else
    executable="$(ps -o comm= -p "$pid" 2>/dev/null | awk '{print $1}')"
  fi
  [[ -n "$executable" ]] || return 1
  canonical_path "$executable"
}

no_mistakes_attestation_file() {
  local path
  path="$(git -C "$ROOT" rev-parse --git-path hooks/pre-push.d/40-no-mistakes.attestation)"
  case "$path" in
    /*) printf '%s\n' "$path" ;;
    *) printf '%s/%s\n' "$ROOT" "$path" ;;
  esac
}

no_mistakes_push_attested() {
  [[ "${NO_MISTAKES_GATE:-}" == "1" ]] || return 1
  local attestation expected_path expected_hash actual_hash pid="$PPID" parent actual_path steps=0
  attestation="$(no_mistakes_attestation_file)"
  [[ -f "$attestation" ]] || return 1
  IFS=$'\t' read -r expected_path expected_hash < "$attestation"
  [[ -n "$expected_path" && -n "$expected_hash" && -x "$expected_path" ]] || return 1
  actual_hash="$(sha256_file "$expected_path" 2>/dev/null || true)"
  [[ "$actual_hash" == "$expected_hash" ]] || return 1
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && "$steps" -lt 4 ]]; do
    actual_path="$(process_executable "$pid" 2>/dev/null || true)"
    if [[ "${actual_path##*/}" == "git" ]]; then
      parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
      actual_path="$(process_executable "$parent" 2>/dev/null || true)"
      [[ "$actual_path" == "$expected_path" ]]
      return
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    steps=$((steps + 1))
  done
  return 1
}

scan_pre_push() {
  local remote_name="${1:-origin}" remote_url="${2:-}" local_ref local_oid remote_ref remote_oid commit commits advertised_oid remote_refs advertised_refs
  local -a advertised_oids=()
  if [[ -z "$remote_url" ]]; then
    remote_url="$(git -C "$ROOT" remote get-url "$remote_name" 2>/dev/null || true)"
  fi
  while read -r local_ref local_oid remote_ref remote_oid; do
    if [[ "$remote_ref" == "refs/heads/main" && "${local_oid:-}" =~ ^0+$ ]]; then
      echo "push-safety: deleting main is not allowed" >&2
      return 1
    fi
    [[ -n "${local_oid:-}" && ! "$local_oid" =~ ^0+$ ]] || continue
    [[ "$local_oid" != "${remote_oid:-}" ]] || continue
    if [[ "$remote_ref" == "refs/heads/main" ]] && ! no_mistakes_push_attested; then
      echo "push-safety: main delivery requires the pinned no-mistakes binary" >&2
      return 1
    fi
    if [[ -z "${remote_oid:-}" || "$remote_oid" =~ ^0+$ ]]; then
      [[ -n "$remote_url" ]] || { echo "push-safety: remote URL is required for a new ref" >&2; return 1; }
      advertised_oids=()
      remote_refs="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-remote.XXXXXX")"
      advertised_refs="$(mktemp "${TMPDIR:-/tmp}/fba-push-safety-advertised.XXXXXX")"
      if ! git ls-remote --refs "$remote_url" > "$remote_refs"; then
        rm -f "$remote_refs" "$advertised_refs"
        echo "push-safety: failed to read advertised remote refs" >&2
        return 1
      fi
      if ! awk '{print $1}' "$remote_refs" | sort -u > "$advertised_refs"; then
        rm -f "$remote_refs" "$advertised_refs"
        echo "push-safety: failed to parse advertised remote refs" >&2
        return 1
      fi
      while IFS= read -r advertised_oid; do
        [[ -n "$advertised_oid" ]] && advertised_oids+=("$advertised_oid")
      done < "$advertised_refs"
      rm -f "$remote_refs" "$advertised_refs"
      if ! commits="$(git -C "$ROOT" rev-list "$local_oid" --not ${advertised_oids[@]+"${advertised_oids[@]}"})"; then
        echo "push-safety: failed to enumerate commits for new ref" >&2
        return 1
      fi
    else
      if ! commits="$(git -C "$ROOT" rev-list "$remote_oid..$local_oid")"; then
        echo "push-safety: failed to enumerate commits for updated ref" >&2
        return 1
      fi
    fi
    while IFS= read -r commit; do
      [[ -z "$commit" ]] || scan_commit "$commit"
    done <<< "$commits"
  done
}

case "$MODE" in
  all) scan_worktree ;;
  staged) scan_staged ;;
  outgoing) scan_outgoing "$OUTGOING_BASE" ;;
  pre-push) scan_pre_push "${1:-origin}" "${2:-}" ;;
esac

if [[ "$HITS" -gt 0 ]]; then
  cat <<MSG >&2

push-safety scan failed: $HITS hit(s)

Resolutions:
  - replace personal or internal content with portable placeholders
  - if intentional OSS prose or a fixture, add a narrow path:label rule to:
      $ALLOW_FILE
MSG
  exit 1
fi

echo "push-safety scan clean ($MODE)"
