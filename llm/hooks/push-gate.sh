#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

pg_now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

pg_fail() {
  echo "$*" >&2
  return 1
}

pg_duration_seconds() {
  local value="$1" number unit
  if [[ "$value" =~ ^([0-9]+)([smhd])?$ ]]; then
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-s}"
    case "$unit" in
      s) printf '%s\n' "$number" ;;
      m) printf '%s\n' "$((number * 60))" ;;
      h) printf '%s\n' "$((number * 3600))" ;;
      d) printf '%s\n' "$((number * 86400))" ;;
      *) return 1 ;;
    esac
    return 0
  fi
  return 1
}

pg_resolve_expires_at() {
  local duration="$1" seconds
  seconds=$(pg_duration_seconds "$duration") || return 1
  python3 - "$seconds" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

seconds = int(sys.argv[1])
expires = datetime.now(timezone.utc) + timedelta(seconds=seconds)
print(expires.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

pg_async_request_json() {
  local enabled="$1" mode="$2" expires="$3" max_pushes="$4" allow_rewrite="$5"
  if [[ "$enabled" != "true" ]]; then
    jq -n '{enabled:false}'
    return 0
  fi
  [[ -n "$expires" ]] || expires="8h"
  [[ -n "$max_pushes" ]] || max_pushes=20
  [[ "$max_pushes" =~ ^[0-9]+$ ]] || { pg_fail "--max-pushes must be a non-negative integer"; return 1; }
  pg_duration_seconds "$expires" >/dev/null || { pg_fail "--expires must be a duration like 8h, 30m, or 1d"; return 1; }
  jq -n \
    --arg mode "$mode" \
    --arg expires "$expires" \
    --argjson max_pushes "$max_pushes" \
    --argjson allow_rewrite "$([[ "$allow_rewrite" == "true" ]] && echo true || echo false)" \
    '{
      enabled: true,
      mode: $mode,
      expires: $expires,
      expires_at: null,
      max_pushes: $max_pushes,
      used_pushes: 0,
      allow_rewrite: $allow_rewrite,
      scope: {},
      audit: []
    }'
}

pg_async_status_json() {
  local async_json="$1" now enabled expires_at max_pushes used_pushes remaining allow_rewrite block_reason scope mode
  now=$(pg_now_utc)
  enabled=$(jq -r '.enabled // false' <<<"$async_json")
  mode=$(jq -r '.mode // ""' <<<"$async_json")
  expires_at=$(jq -r '.expires_at // ""' <<<"$async_json")
  max_pushes=$(jq -r '.max_pushes // 0' <<<"$async_json")
  used_pushes=$(jq -r '.used_pushes // 0' <<<"$async_json")
  allow_rewrite=$(jq -r '.allow_rewrite // false' <<<"$async_json")
  scope=$(jq -c '.scope // {}' <<<"$async_json")
  remaining=$((max_pushes - used_pushes))
  [[ "$remaining" -lt 0 ]] && remaining=0
  block_reason=""
  if [[ "$enabled" != "true" ]]; then
    block_reason="async lease not enabled"
  elif [[ -z "$expires_at" || "$expires_at" == "null" ]]; then
    block_reason="async lease has no expires_at; re-approve with pg"
  elif [[ "$now" > "$expires_at" ]]; then
    block_reason="async lease expired at $expires_at; re-run pg prepare and ask the user to review"
  elif [[ "$used_pushes" -ge "$max_pushes" ]]; then
    block_reason="async push budget exhausted ($used_pushes/$max_pushes); re-run pg prepare and ask the user to review"
  fi
  jq -n \
    --argjson enabled "$([[ "$enabled" == "true" ]] && echo true || echo false)" \
    --arg mode "$mode" \
    --arg expires_at "$expires_at" \
    --argjson allow_rewrite "$([[ "$allow_rewrite" == "true" ]] && echo true || echo false)" \
    --argjson max_pushes "$max_pushes" \
    --argjson used_pushes "$used_pushes" \
    --argjson remaining "$remaining" \
    --argjson scope "$scope" \
    --arg block_reason "$block_reason" \
    '{
      enabled: $enabled,
      mode: $mode,
      expires_at: (if $expires_at == "" or $expires_at == "null" then null else $expires_at end),
      allow_rewrite: $allow_rewrite,
      pushes: {
        used: $used_pushes,
        max: $max_pushes,
        remaining: $remaining
      },
      scope: $scope,
      block_reason: (if $block_reason == "" then null else $block_reason end)
    }'
}

pg_finalize_async_json() {
  local async_json="$1" mode="$2" expires expires_at
  if [[ "$(jq -r '.enabled // false' <<<"$async_json")" != "true" ]]; then
    jq -n '{enabled:false}'
    return 0
  fi
  local max_pushes
  max_pushes=$(jq -r '.max_pushes // ""' <<<"$async_json")
  [[ "$max_pushes" =~ ^[0-9]+$ ]] || { pg_fail "async_iteration.max_pushes must be a non-negative integer"; return 1; }
  expires=$(jq -r '.expires // "8h"' <<<"$async_json")
  expires_at=$(pg_resolve_expires_at "$expires") || { pg_fail "invalid async expires duration: $expires"; return 1; }
  jq -c \
    --arg mode "$mode" \
    --arg expires_at "$expires_at" \
    --argjson default_max "$([[ "$mode" == "trunk" ]] && echo 30 || echo 20)" \
    '.mode = $mode
     | .expires_at = $expires_at
     | .max_pushes = (.max_pushes // $default_max)
     | .used_pushes = (.used_pushes // 0)
     | .allow_rewrite = (.allow_rewrite // false)
     | .audit = (.audit // [])' <<<"$async_json"
}

pg_lock_acquire() {
  local name="$1" lock_root lock_dir waited=0 lock_pid
  lock_root="$(pg_store_dir)/locks"
  mkdir -p "$lock_root" || return 1
  lock_dir="$lock_root/$(pg_branch_slug "$name").lock"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [[ -r "$lock_dir/pid" ]]; then
      lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
      if [[ "$lock_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        rm -rf "$lock_dir"
        continue
      fi
    fi
    waited=$((waited + 1))
    if [[ "$waited" -gt 100 ]]; then
      pg_fail "Timed out waiting for push-gate lock: $lock_dir"
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" >"$lock_dir/pid" 2>/dev/null || true
  printf '%s\n' "$lock_dir"
}

pg_lock_release() {
  local lock_dir="$1"
  [[ -n "$lock_dir" ]] && rm -rf "$lock_dir"
}

pg_helper_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

# ------------------------------------------------------------------------
# Central lease index (SQLite)
# ------------------------------------------------------------------------
# Each repo's .git/push-gate/leases/... JSON remains the source of truth.
# This DB mirrors them across the user's machine so sessions in one repo
# can discover / verify leases in another without guessing paths.

pg_db_path() {
  printf '%s\n' "${PG_DB:-$HOME/.push-gate/leases.db}"
}

pg_db_init() {
  local db
  db=$(pg_db_path)
  mkdir -p "$(dirname "$db")" 2>/dev/null || return 1
  sqlite3 "$db" <<'SQL' 2>/dev/null
CREATE TABLE IF NOT EXISTS leases (
  repo_root TEXT NOT NULL,
  branch_ref TEXT NOT NULL,
  repo_name TEXT NOT NULL,
  branch_name TEXT NOT NULL,
  remote TEXT,
  pr_number INTEGER,
  pr_url TEXT,
  approved_anchor TEXT NOT NULL,
  base_ref TEXT,
  status TEXT NOT NULL,
  user_intent TEXT,
  agent_assertion_template TEXT,
  approved_scope_json TEXT,
  lease_file_path TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (repo_root, branch_ref)
);
CREATE INDEX IF NOT EXISTS idx_leases_status ON leases(status);
CREATE INDEX IF NOT EXISTS idx_leases_repo_name ON leases(repo_name);
-- Structured semantic brief columns. Added idempotently so older DBs
-- upgrade on first use. "duplicate column name" errors are expected
-- and silenced by the 2>/dev/null on the whole block.
ALTER TABLE leases ADD COLUMN brief_what TEXT;
ALTER TABLE leases ADD COLUMN brief_why TEXT;
ALTER TABLE leases ADD COLUMN brief_approach TEXT;
ALTER TABLE leases ADD COLUMN brief_scope TEXT;
ALTER TABLE leases ADD COLUMN brief_risks TEXT;
ALTER TABLE leases ADD COLUMN bead_ids TEXT;
ALTER TABLE leases ADD COLUMN async_json TEXT;
SQL
  return 0
}

# Write or refresh a lease row from a lease JSON file.
# Fails silently — DB is an index, not authoritative.
pg_db_upsert_lease() {
  local lease_path="$1"
  [[ -f "$lease_path" ]] || return 0
  pg_db_init || return 0
  local db
  db=$(pg_db_path)

  # Extract into shell vars via jq (each value null-safe).
  local repo_root branch_ref repo_name branch_name remote pr_number pr_url
  local anchor base_ref status intent assert scope created_at updated_at
  local brief_what brief_why brief_approach brief_scope brief_risks bead_ids async_json
  repo_root=$(jq -r '.repo_root // ""' "$lease_path")
  branch_ref=$(jq -r '.branch_ref // ""' "$lease_path")
  repo_name=$(jq -r '.repo_name // ""' "$lease_path")
  branch_name=$(jq -r '.branch_name // ""' "$lease_path")
  remote=$(jq -r '.remote // ""' "$lease_path")
  pr_number=$(jq -r '.pr_number // ""' "$lease_path")
  pr_url=$(jq -r '.pr_url // ""' "$lease_path")
  anchor=$(jq -r '.approved_anchor // ""' "$lease_path")
  base_ref=$(jq -r '.base_ref_snapshot // ""' "$lease_path")
  status=$(jq -r '.status // "active"' "$lease_path")
  intent=$(jq -r '.user_intent // ""' "$lease_path")
  assert=$(jq -r '.agent_assertion_template // ""' "$lease_path")
  scope=$(jq -c '.approved_scope // null' "$lease_path")
  created_at=$(jq -r '.created_at // ""' "$lease_path")
  updated_at=$(jq -r '.updated_at // .created_at // ""' "$lease_path")
  brief_what=$(jq -r '.brief.what // ""' "$lease_path")
  brief_why=$(jq -r '.brief.why // ""' "$lease_path")
  brief_approach=$(jq -r '.brief.approach // ""' "$lease_path")
  brief_scope=$(jq -r '.brief.scope // ""' "$lease_path")
  brief_risks=$(jq -r '.brief.risks // ""' "$lease_path")
  bead_ids=$(jq -r '.bead_ids // [] | join(",")' "$lease_path")
  async_json=$(jq -c '.async_iteration // {enabled:false}' "$lease_path")

  [[ -n "$repo_root" && -n "$branch_ref" ]] || return 0

  sqlite3 "$db" <<SQL 2>/dev/null
INSERT INTO leases (
  repo_root, branch_ref, repo_name, branch_name, remote,
  pr_number, pr_url, approved_anchor, base_ref, status,
  user_intent, agent_assertion_template, approved_scope_json,
  lease_file_path, created_at, updated_at,
  brief_what, brief_why, brief_approach, brief_scope, brief_risks, bead_ids, async_json
) VALUES (
  $(pg_sql_quote "$repo_root"), $(pg_sql_quote "$branch_ref"),
  $(pg_sql_quote "$repo_name"), $(pg_sql_quote "$branch_name"),
  $(pg_sql_quote "$remote"),
  $(pg_sql_int_or_null "$pr_number"),
  $(pg_sql_quote "$pr_url"),
  $(pg_sql_quote "$anchor"), $(pg_sql_quote "$base_ref"),
  $(pg_sql_quote "$status"),
  $(pg_sql_quote "$intent"), $(pg_sql_quote "$assert"),
  $(pg_sql_quote "$scope"),
  $(pg_sql_quote "$lease_path"),
  $(pg_sql_quote "$created_at"), $(pg_sql_quote "$updated_at"),
  $(pg_sql_quote "$brief_what"), $(pg_sql_quote "$brief_why"),
  $(pg_sql_quote "$brief_approach"), $(pg_sql_quote "$brief_scope"),
  $(pg_sql_quote "$brief_risks"), $(pg_sql_quote "$bead_ids"),
  $(pg_sql_quote "$async_json")
)
ON CONFLICT(repo_root, branch_ref) DO UPDATE SET
  repo_name = excluded.repo_name,
  branch_name = excluded.branch_name,
  remote = excluded.remote,
  pr_number = excluded.pr_number,
  pr_url = excluded.pr_url,
  approved_anchor = excluded.approved_anchor,
  base_ref = excluded.base_ref,
  status = excluded.status,
  user_intent = excluded.user_intent,
  agent_assertion_template = excluded.agent_assertion_template,
  approved_scope_json = excluded.approved_scope_json,
  lease_file_path = excluded.lease_file_path,
  updated_at = excluded.updated_at,
  brief_what = excluded.brief_what,
  brief_why = excluded.brief_why,
  brief_approach = excluded.brief_approach,
  brief_scope = excluded.brief_scope,
  brief_risks = excluded.brief_risks,
  bead_ids = excluded.bead_ids,
  async_json = excluded.async_json;
SQL
}

pg_db_set_status() {
  local repo_root="$1" branch_ref="$2" new_status="$3"
  pg_db_init || return 0
  local db now
  db=$(pg_db_path)
  now=$(pg_now_utc)
  sqlite3 "$db" <<SQL 2>/dev/null
UPDATE leases SET status = $(pg_sql_quote "$new_status"),
                  updated_at = $(pg_sql_quote "$now")
WHERE repo_root = $(pg_sql_quote "$repo_root")
  AND branch_ref = $(pg_sql_quote "$branch_ref");
SQL
}

# ------------------------------------------------------------------------
# Versioned stack-trunk store (Dolt)
# ------------------------------------------------------------------------
# Stack-trunk workflows use Dolt as the source of truth for stack manifests,
# materializations, and trunk leases. Legacy branch leases remain in the
# git-common-dir JSON files above.

pg_dolt_store_dir() {
  printf '%s\n' "${PG_STORE_DIR:-$HOME/.push-gate/dolt-store}"
}

pg_dolt_author_name() {
  printf '%s\n' "${PG_DOLT_USER_NAME:-push-gate}"
}

pg_dolt_author_email() {
  printf '%s\n' "${PG_DOLT_USER_EMAIL:-push-gate@localhost}"
}

pg_dolt_required_message() {
  cat <<'EOF'
dolt is required for stack-trunk workflows.
Install: brew install dolt
Verify: dolt version
Store: ~/.push-gate/dolt-store by default; set PG_STORE_DIR to override.
EOF
}

pg_require_dolt() {
  command -v dolt >/dev/null 2>&1 || {
    pg_fail "$(pg_dolt_required_message)"
    return 1
  }
}

pg_dolt_sql() {
  local query="$1"
  pg_require_dolt || return 1
  pg_dolt_init || return 1
  (cd "$(pg_dolt_store_dir)" && dolt sql -q "$query")
}

pg_dolt_sql_csv() {
  local query="$1"
  pg_require_dolt || return 1
  pg_dolt_init || return 1
  (cd "$(pg_dolt_store_dir)" && dolt sql -r csv -q "$query")
}

pg_dolt_sql_json() {
  local query="$1"
  pg_require_dolt || return 1
  pg_dolt_init || return 1
  (cd "$(pg_dolt_store_dir)" && dolt sql -r json -q "$query")
}

pg_compact_json_text() {
  python3 -c '
import sys

text = sys.stdin.read()
out = []
in_string = False
escaped = False

for ch in text:
    if in_string:
        if escaped:
            out.append(ch)
            escaped = False
        elif ch == "\\":
            out.append(ch)
            escaped = True
        elif ch == chr(34):
            out.append(ch)
            in_string = False
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    else:
        out.append(ch)
        if ch == chr(34):
            in_string = True

sys.stdout.write("".join(out))
' | jq -c .
}

pg_dolt_commit() {
  local msg="$1"
  pg_require_dolt || return 1
  (
    cd "$(pg_dolt_store_dir)"
    dolt add . >/dev/null 2>&1 || true
    dolt commit -m "$msg" >/dev/null 2>&1 || true
  )
}

pg_csv_unquote() {
  local value="$1"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
    value="${value//\"\"/\"}"
  fi
  printf '%s\n' "$value"
}

pg_dolt_init() {
  local dir author_name author_email
  dir=$(pg_dolt_store_dir)
  author_name=$(pg_dolt_author_name)
  author_email=$(pg_dolt_author_email)
  mkdir -p "$dir" || return 1
  if [[ ! -d "$dir/.dolt" ]]; then
    (cd "$dir" && dolt init --name "$author_name" --email "$author_email" >/dev/null) || return 1
  fi
  (
    cd "$dir"
    dolt config --local --set user.name "$author_name" >/dev/null 2>&1 || true
    dolt config --local --set user.email "$author_email" >/dev/null 2>&1 || true
    dolt sql -q '
CREATE TABLE IF NOT EXISTS repos (
  repo_key VARCHAR(512) PRIMARY KEY,
  repo_root VARCHAR(1024) NOT NULL,
  common_dir VARCHAR(1024) NOT NULL,
  repo_name VARCHAR(255) NOT NULL,
  updated_at VARCHAR(64) NOT NULL
);
CREATE TABLE IF NOT EXISTS stacks (
  repo_key VARCHAR(512) NOT NULL,
  name VARCHAR(255) NOT NULL,
  base_ref VARCHAR(512) NOT NULL,
  trunk_branch VARCHAR(512) NOT NULL,
  status VARCHAR(64) NOT NULL,
  version BIGINT NOT NULL,
  created_at VARCHAR(64) NOT NULL,
  updated_at VARCHAR(64) NOT NULL,
  PRIMARY KEY (repo_key, name)
);
CREATE TABLE IF NOT EXISTS stack_items (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  item_id VARCHAR(255) NOT NULL,
  order_index BIGINT NOT NULL,
  branch VARCHAR(512) NOT NULL,
  pr_number BIGINT,
  item_base VARCHAR(512),
  created_at VARCHAR(64) NOT NULL,
  updated_at VARCHAR(64) NOT NULL,
  PRIMARY KEY (repo_key, stack_name, item_id)
);
CREATE TABLE IF NOT EXISTS trunk_materializations (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  materialization_id VARCHAR(80) NOT NULL,
  manifest_hash VARCHAR(80) NOT NULL,
  trunk_tip VARCHAR(80) NOT NULL,
  created_at VARCHAR(64) NOT NULL,
  PRIMARY KEY (repo_key, stack_name, materialization_id)
);
CREATE TABLE IF NOT EXISTS trunk_materialization_items (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  materialization_id VARCHAR(80) NOT NULL,
  item_id VARCHAR(255) NOT NULL,
  order_index BIGINT NOT NULL,
  branch VARCHAR(512) NOT NULL,
  commit_sha VARCHAR(80) NOT NULL,
  pr_number BIGINT,
  PRIMARY KEY (repo_key, stack_name, materialization_id, item_id)
);
CREATE TABLE IF NOT EXISTS trunk_leases (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  manifest_hash VARCHAR(80) NOT NULL,
  materialization_id VARCHAR(80) NOT NULL,
  trunk_tip VARCHAR(80) NOT NULL,
  approved_scope_json TEXT,
  brief_json TEXT,
  status VARCHAR(64) NOT NULL,
  created_by VARCHAR(255) NOT NULL,
  created_at VARCHAR(64) NOT NULL,
  updated_at VARCHAR(64) NOT NULL,
  PRIMARY KEY (repo_key, stack_name)
);
CREATE TABLE IF NOT EXISTS trunk_lease_items (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  item_id VARCHAR(255) NOT NULL,
  order_index BIGINT NOT NULL,
  branch VARCHAR(512) NOT NULL,
  commit_sha VARCHAR(80) NOT NULL,
  pr_number BIGINT,
  PRIMARY KEY (repo_key, stack_name, item_id)
);
CREATE TABLE IF NOT EXISTS pending_trunk_assertions (
  repo_key VARCHAR(512) NOT NULL,
  stack_name VARCHAR(255) NOT NULL,
  branch VARCHAR(512) NOT NULL,
  remote VARCHAR(255) NOT NULL,
  source_ref VARCHAR(512) NOT NULL,
  commit_sha VARCHAR(80) NOT NULL,
  assert_flow TEXT NOT NULL,
  created_at VARCHAR(64) NOT NULL,
  PRIMARY KEY (repo_key, stack_name, branch)
);
' >/dev/null
    dolt sql -q "ALTER TABLE pending_trunk_assertions ADD COLUMN remote VARCHAR(255) NOT NULL DEFAULT 'origin';" >/dev/null 2>&1 || true
    dolt sql -q "ALTER TABLE trunk_leases ADD COLUMN async_json TEXT;" >/dev/null 2>&1 || true
  ) || return 1
}

pg_repo_key() {
  pg_git_common_dir
}

pg_store_upsert_repo() {
  local repo_key repo_root common_dir repo_name now
  repo_key=$(pg_repo_key) || return 1
  repo_root=$(pg_main_repo_path) || return 1
  common_dir=$(pg_git_common_dir) || return 1
  repo_name=$(pg_repo_name)
  now=$(pg_now_utc)
  pg_dolt_sql "
REPLACE INTO repos (repo_key, repo_root, common_dir, repo_name, updated_at)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$repo_root"), $(pg_sql_quote "$common_dir"), $(pg_sql_quote "$repo_name"), $(pg_sql_quote "$now"));
" >/dev/null
}

pg_stack_manifest_json() {
  local stack_name="$1" repo_key
  repo_key=$(pg_repo_key) || return 1
  pg_dolt_sql_csv "
SELECT JSON_OBJECT(
  'version', 1,
  'name', s.name,
  'base', s.base_ref,
  'trunk', s.trunk_branch,
  'store_version', s.version,
  'items', COALESCE((
    SELECT JSON_ARRAYAGG(JSON_OBJECT(
      'id', i.item_id,
      'branch', i.branch,
      'pr', i.pr_number,
      'base', i.item_base
    ))
    FROM (
      SELECT item_id, branch, pr_number, item_base
      FROM stack_items
      WHERE repo_key = s.repo_key AND stack_name = s.name
      ORDER BY order_index
    ) i
  ), JSON_ARRAY())
) AS manifest
FROM stacks s
WHERE s.repo_key = $(pg_sql_quote "$repo_key") AND s.name = $(pg_sql_quote "$stack_name");
" | tail -n +2 | sed 's/^"//; s/"$//; s/""/"/g' | head -1
}

pg_cmd_stack_store_init() {
  local name="" base_ref="" trunk=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --base) base_ref="$2"; shift 2 ;;
      --trunk) trunk="$2"; shift 2 ;;
      *) pg_fail "Unknown stack-store-init option: $1"; return 1 ;;
    esac
  done
  [[ -n "$name" && -n "$base_ref" && -n "$trunk" ]] || pg_fail "stack-store-init requires --name, --base, and --trunk"
  pg_store_upsert_repo || return 1
  local repo_key now existing_version version created_at
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  existing_version=$(pg_dolt_sql_csv "SELECT version FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$name");" | tail -n +2 | head -1)
  created_at=$(pg_dolt_sql_csv "SELECT created_at FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$name");" | tail -n +2 | head -1)
  version="${existing_version:-0}"
  version=$((version + 1))
  [[ -n "$created_at" ]] || created_at="$now"
  pg_dolt_sql "
REPLACE INTO stacks (repo_key, name, base_ref, trunk_branch, status, version, created_at, updated_at)
VALUES (
  $(pg_sql_quote "$repo_key"),
  $(pg_sql_quote "$name"),
  $(pg_sql_quote "$base_ref"),
  $(pg_sql_quote "$trunk"),
  'active',
  $version,
  $(pg_sql_quote "$created_at"),
  $(pg_sql_quote "$now")
);
" >/dev/null
  pg_dolt_commit "stack init $name"
  echo "Stack stored: $name"
}

pg_cmd_stack_store_add() {
  local stack_name="" item_id="" branch="" pr_number="" after="" item_base=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) stack_name="$2"; shift 2 ;;
      --id) item_id="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --pr) pr_number="$2"; shift 2 ;;
      --after) after="$2"; shift 2 ;;
      --base) item_base="$2"; shift 2 ;;
      *) pg_fail "Unknown stack-store-add option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" && -n "$branch" ]] || pg_fail "stack-store-add requires --stack, --id, and --branch"
  pg_store_upsert_repo || return 1
  local repo_key now order_index stack_exists version pr_sql base_sql created_at existing_order
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  stack_exists=$(pg_dolt_sql_csv "SELECT COUNT(*) FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  [[ "${stack_exists:-0}" != "0" ]] || pg_fail "stack not found in Dolt store: $stack_name"
  existing_order=$(pg_dolt_sql_csv "SELECT order_index FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$item_id");" | tail -n +2 | head -1)
  if [[ -n "$after" && -n "$existing_order" ]]; then
    pg_fail "stack item already exists: $item_id; use stack trunk move --stack $stack_name --id $item_id --after $after"
  fi
  if [[ -n "$after" ]]; then
    order_index=$(pg_dolt_sql_csv "SELECT order_index + 1 FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$after");" | tail -n +2 | head -1)
    [[ -n "$order_index" ]] || pg_fail "stack item not found for --after: $after"
    pg_dolt_sql "UPDATE stack_items SET order_index = order_index + 1, updated_at = $(pg_sql_quote "$now") WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND order_index >= $order_index;" >/dev/null
  else
    if [[ -n "$existing_order" ]]; then
      order_index="$existing_order"
    else
      order_index=$(pg_dolt_sql_csv "SELECT COALESCE(MAX(order_index), 0) + 1 FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
      [[ -n "$order_index" ]] || order_index=1
    fi
  fi
  pr_sql=$(pg_sql_int_or_null "$pr_number")
  if [[ -n "$item_base" ]]; then base_sql="$(pg_sql_quote "$item_base")"; else base_sql="NULL"; fi
  created_at=$(pg_dolt_sql_csv "SELECT created_at FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$item_id");" | tail -n +2 | head -1)
  [[ -n "$created_at" ]] || created_at="$now"
  pg_dolt_sql "
REPLACE INTO stack_items (repo_key, stack_name, item_id, order_index, branch, pr_number, item_base, created_at, updated_at)
VALUES (
  $(pg_sql_quote "$repo_key"),
  $(pg_sql_quote "$stack_name"),
  $(pg_sql_quote "$item_id"),
  $order_index,
  $(pg_sql_quote "$branch"),
  $pr_sql,
  $base_sql,
  $(pg_sql_quote "$created_at"),
  $(pg_sql_quote "$now")
);
UPDATE stacks SET version = version + 1, updated_at = $(pg_sql_quote "$now") WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");
" >/dev/null
  version=$(pg_dolt_sql_csv "SELECT version FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  pg_dolt_commit "stack add $stack_name/$item_id"
  echo "Stack item stored: $stack_name/$item_id (version $version)"
}

pg_stack_store_update_order() {
  local repo_key="$1" stack_name="$2" now="$3"
  shift 3
  local idx=1 item_id sql=""
  for item_id in "$@"; do
    [[ -z "$item_id" ]] && continue
    sql="${sql}UPDATE stack_items SET order_index = $idx, updated_at = $(pg_sql_quote "$now") WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$item_id");
"
    idx=$((idx + 1))
  done
  [[ -n "$sql" ]] || return 0
  pg_dolt_sql "$sql" >/dev/null
}

pg_cmd_stack_store_move() {
  local stack_name="" item_id="" after="" before="" first="false" last="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --id) item_id="$2"; shift 2 ;;
      --after) after="$2"; shift 2 ;;
      --before) before="$2"; shift 2 ;;
      --first) first="true"; shift ;;
      --last) last="true"; shift ;;
      *) pg_fail "Unknown stack-store-move option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" ]] || pg_fail "stack-store-move requires --stack and --id"
  local choices=0
  [[ -n "$after" ]] && choices=$((choices + 1))
  [[ -n "$before" ]] && choices=$((choices + 1))
  [[ "$first" == "true" ]] && choices=$((choices + 1))
  [[ "$last" == "true" ]] && choices=$((choices + 1))
  [[ "$choices" == "1" ]] || pg_fail "stack-store-move requires exactly one of --after, --before, --first, or --last"
  [[ "$after" != "$item_id" && "$before" != "$item_id" ]] || pg_fail "cannot move stack item relative to itself: $item_id"
  pg_store_upsert_repo || return 1
  local repo_key now stack_exists version found_item="false" found_target="false"
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  stack_exists=$(pg_dolt_sql_csv "SELECT COUNT(*) FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  [[ "${stack_exists:-0}" != "0" ]] || pg_fail "stack not found in Dolt store: $stack_name"

  local remaining=() new_order=() existing_id
  while IFS=, read -r existing_id; do
    [[ -z "$existing_id" ]] && continue
    existing_id=$(pg_csv_unquote "$existing_id")
    if [[ "$existing_id" == "$item_id" ]]; then
      found_item="true"
      continue
    fi
    remaining+=("$existing_id")
  done < <(pg_dolt_sql_csv "
SELECT item_id
FROM stack_items
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name")
ORDER BY order_index;
" | tail -n +2)
  [[ "$found_item" == "true" ]] || pg_fail "stack item not found: $item_id"

  if [[ "$first" == "true" ]]; then
    new_order=("$item_id" "${remaining[@]}")
  elif [[ "$last" == "true" ]]; then
    new_order=("${remaining[@]}" "$item_id")
  else
    for existing_id in "${remaining[@]}"; do
      if [[ -n "$before" && "$existing_id" == "$before" ]]; then
        new_order+=("$item_id")
        found_target="true"
      fi
      new_order+=("$existing_id")
      if [[ -n "$after" && "$existing_id" == "$after" ]]; then
        new_order+=("$item_id")
        found_target="true"
      fi
    done
    [[ "$found_target" == "true" ]] || pg_fail "stack item not found for move target: ${after:-$before}"
  fi

  pg_stack_store_update_order "$repo_key" "$stack_name" "$now" "${new_order[@]}"
  pg_dolt_sql "UPDATE stacks SET version = version + 1, updated_at = $(pg_sql_quote "$now") WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" >/dev/null
  version=$(pg_dolt_sql_csv "SELECT version FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  pg_dolt_commit "stack move $stack_name/$item_id"
  echo "Stack item moved: $stack_name/$item_id (version $version)"
}

pg_cmd_stack_store_remove() {
  local stack_name="" item_id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --id) item_id="$2"; shift 2 ;;
      *) pg_fail "Unknown stack-store-remove option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" && -n "$item_id" ]] || pg_fail "stack-store-remove requires --stack and --id"
  pg_store_upsert_repo || return 1
  local repo_key now stack_exists item_order version remaining=() existing_id
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  stack_exists=$(pg_dolt_sql_csv "SELECT COUNT(*) FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  [[ "${stack_exists:-0}" != "0" ]] || pg_fail "stack not found in Dolt store: $stack_name"
  item_order=$(pg_dolt_sql_csv "SELECT order_index FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$item_id");" | tail -n +2 | head -1)
  [[ -n "$item_order" ]] || pg_fail "stack item not found: $item_id"
  while IFS=, read -r existing_id; do
    [[ -z "$existing_id" ]] && continue
    existing_id=$(pg_csv_unquote "$existing_id")
    [[ "$existing_id" == "$item_id" ]] && continue
    remaining+=("$existing_id")
  done < <(pg_dolt_sql_csv "
SELECT item_id
FROM stack_items
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name")
ORDER BY order_index;
" | tail -n +2)
  pg_dolt_sql "DELETE FROM stack_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND item_id = $(pg_sql_quote "$item_id");" >/dev/null
  if (( ${#remaining[@]} == 0 )); then
    pg_dolt_sql "
DELETE FROM trunk_lease_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM trunk_leases WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM pending_trunk_assertions WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM trunk_materialization_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM trunk_materializations WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");
" >/dev/null
    pg_dolt_commit "stack prune $stack_name"
    echo "Stack pruned: $stack_name (removed final item $item_id)"
    return 0
  fi
  pg_stack_store_update_order "$repo_key" "$stack_name" "$now" "${remaining[@]}"
  pg_dolt_sql "UPDATE stacks SET version = version + 1, updated_at = $(pg_sql_quote "$now") WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" >/dev/null
  version=$(pg_dolt_sql_csv "SELECT version FROM stacks WHERE repo_key = $(pg_sql_quote "$repo_key") AND name = $(pg_sql_quote "$stack_name");" | tail -n +2 | head -1)
  pg_dolt_commit "stack remove $stack_name/$item_id"
  echo "Stack item removed: $stack_name/$item_id (version $version)"
}

pg_cmd_stack_store_manifest() {
  local stack_name="" format="text"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --json) format="json"; shift ;;
      *) pg_fail "Unknown stack-store-manifest option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "stack-store-manifest requires --stack NAME"
  pg_store_upsert_repo || return 1
  local manifest
  manifest=$(pg_stack_manifest_json "$stack_name")
  [[ -n "$manifest" ]] || pg_fail "stack not found in Dolt store: $stack_name"
  if [[ "$format" == "json" ]]; then
    jq -c . <<<"$manifest"
  else
    jq -r '"Stack: " + .name, "Base: " + .base, "Trunk: " + .trunk, (.items[] | "  - " + .id + ": " + .branch)' <<<"$manifest"
  fi
}

pg_cmd_stack_store_list() {
  local format="text"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) format="json"; shift ;;
      *) pg_fail "Unknown stack-store-list option: $1"; return 1 ;;
    esac
  done
  pg_store_upsert_repo || return 1
  local repo_key repo_root worktree_root stack_names='[]' stack_name manifest materialization approval prepare stacks='[]'
  repo_key=$(pg_repo_key) || return 1
  repo_root=$(pg_main_repo_path) || return 1
  worktree_root=$(pg_repo_root) || return 1
  while IFS=, read -r stack_name; do
    [[ -z "$stack_name" ]] && continue
    stack_name=$(pg_csv_unquote "$stack_name")
    stack_names=$(jq --arg name "$stack_name" '. + [$name]' <<<"$stack_names")
  done < <(pg_dolt_sql_csv "
SELECT name
FROM stacks
WHERE repo_key = $(pg_sql_quote "$repo_key") AND status = 'active'
ORDER BY updated_at DESC, name;
" | tail -n +2)

  while IFS= read -r stack_name; do
    [[ -z "$stack_name" ]] && continue
    manifest=$(pg_stack_manifest_json "$stack_name")
    [[ -n "$manifest" ]] || continue
    materialization=$(pg_trunk_latest_materialization_json "$stack_name" 2>/dev/null || echo 'null')
    approval=$(pg_trunk_check_json "$stack_name" 2>/dev/null || echo '{"allowed":false,"reason":"Unable to check trunk approval."}')
    prepare=$(pg_trunk_prepare_status_json "$stack_name")
    stacks=$(jq \
      --argjson manifest "$manifest" \
      --argjson materialization "$materialization" \
      --argjson approval "$approval" \
      --argjson prepare "$prepare" \
      '. + [{manifest:$manifest, materialization:$materialization, approval:$approval, prepare:$prepare}]' <<<"$stacks")
  done < <(jq -r '.[]' <<<"$stack_names")

  if [[ "$format" == "json" ]]; then
    jq -n --arg repo "$worktree_root" --arg store_repo "$repo_root" --arg repo_key "$repo_key" --argjson stacks "$stacks" \
      '{repo:$repo, store_repo:$store_repo, repo_key:$repo_key, stacks:$stacks}'
  else
    jq -r '.[] | .manifest.name' <<<"$stacks"
  fi
}

pg_cmd_stack_store_record_materialization() {
  local stack_name="" materialization_json=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack) stack_name="$2"; shift 2 ;;
      --json) materialization_json="$2"; shift 2 ;;
      *) pg_fail "Unknown stack-store-record-materialization option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" && -n "$materialization_json" ]] || pg_fail "stack-store-record-materialization requires --stack and --json"
  pg_store_upsert_repo || return 1
  local repo_key now materialization_id manifest_hash trunk_tip
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  materialization_id=$(jq -r '.materialization_id' <<<"$materialization_json")
  manifest_hash=$(jq -r '.manifest_hash' <<<"$materialization_json")
  trunk_tip=$(jq -r '.trunk_tip' <<<"$materialization_json")
  [[ -n "$materialization_id" && -n "$manifest_hash" && -n "$trunk_tip" ]] || pg_fail "invalid materialization json"
  pg_dolt_sql "
REPLACE INTO trunk_materializations (repo_key, stack_name, materialization_id, manifest_hash, trunk_tip, created_at)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$stack_name"), $(pg_sql_quote "$materialization_id"), $(pg_sql_quote "$manifest_hash"), $(pg_sql_quote "$trunk_tip"), $(pg_sql_quote "$now"));
DELETE FROM trunk_materialization_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND materialization_id = $(pg_sql_quote "$materialization_id");
" >/dev/null
  while IFS=$'\t' read -r item_id order_index branch commit_sha pr_number; do
    [[ -z "$item_id" ]] && continue
    local pr_sql="NULL"
    [[ "$pr_number" =~ ^[0-9]+$ ]] && pr_sql="$pr_number"
    pg_dolt_sql "
REPLACE INTO trunk_materialization_items (repo_key, stack_name, materialization_id, item_id, order_index, branch, commit_sha, pr_number)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$stack_name"), $(pg_sql_quote "$materialization_id"), $(pg_sql_quote "$item_id"), $order_index, $(pg_sql_quote "$branch"), $(pg_sql_quote "$commit_sha"), $pr_sql);
" >/dev/null
  done < <(jq -r '.items[] | [.id, .order_index, .branch, .commit, (.pr // "")] | @tsv' <<<"$materialization_json")
  pg_dolt_commit "stack materialize $stack_name"
  echo "Materialization stored: $stack_name $materialization_id"
}

pg_cmd_stack_store_branch_materialization() {
  local branch="" format="text"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --branch) branch="$2"; shift 2 ;;
      --json) format="json"; shift ;;
      *) pg_fail "Unknown stack-store-branch-materialization option: $1"; return 1 ;;
    esac
  done
  [[ -n "$branch" ]] || pg_fail "stack-store-branch-materialization requires --branch"
  pg_store_upsert_repo || return 1
  local repo_key row stack_name trunk_branch materialization_id manifest_hash trunk_tip item_id order_index commit_sha pr_number created_at
  repo_key=$(pg_repo_key) || return 1
  row=$(pg_dolt_sql_csv "
SELECT s.name, s.trunk_branch, m.materialization_id, m.manifest_hash, m.trunk_tip,
       i.item_id, i.order_index, i.commit_sha, COALESCE(i.pr_number, ''), m.created_at
FROM trunk_materialization_items i
JOIN trunk_materializations m
  ON m.repo_key = i.repo_key
 AND m.stack_name = i.stack_name
 AND m.materialization_id = i.materialization_id
JOIN stacks s
  ON s.repo_key = i.repo_key
 AND s.name = i.stack_name
WHERE i.repo_key = $(pg_sql_quote "$repo_key")
  AND i.branch = $(pg_sql_quote "$branch")
ORDER BY m.created_at DESC
LIMIT 1;
" | tail -n +2 | head -1)
  [[ -n "$row" ]] || return 1
  IFS=, read -r stack_name trunk_branch materialization_id manifest_hash trunk_tip item_id order_index commit_sha pr_number created_at <<<"$row"
  stack_name=$(pg_csv_unquote "$stack_name")
  trunk_branch=$(pg_csv_unquote "$trunk_branch")
  materialization_id=$(pg_csv_unquote "$materialization_id")
  manifest_hash=$(pg_csv_unquote "$manifest_hash")
  trunk_tip=$(pg_csv_unquote "$trunk_tip")
  item_id=$(pg_csv_unquote "$item_id")
  commit_sha=$(pg_csv_unquote "$commit_sha")
  pr_number=$(pg_csv_unquote "$pr_number")
  created_at=$(pg_csv_unquote "$created_at")
  if [[ "$format" == "json" ]]; then
    jq -n \
      --arg stack "$stack_name" \
      --arg trunk "$trunk_branch" \
      --arg materialization_id "$materialization_id" \
      --arg manifest_hash "$manifest_hash" \
      --arg trunk_tip "$trunk_tip" \
      --arg item_id "$item_id" \
      --arg order_index "$order_index" \
      --arg branch "$branch" \
      --arg commit "$commit_sha" \
      --arg pr "$pr_number" \
      --arg created_at "$created_at" \
      '{
        stack: $stack,
        trunk: $trunk,
        materialization_id: $materialization_id,
        manifest_hash: $manifest_hash,
        trunk_tip: $trunk_tip,
        item_id: $item_id,
        order_index: ($order_index | tonumber),
        branch: $branch,
        commit: $commit,
        pr: (if $pr == "" then null else ($pr | tonumber) end),
        created_at: $created_at
      }'
  else
    printf '%s\t%s\t%s\t%s\n' "$stack_name" "$trunk_branch" "$branch" "$commit_sha"
  fi
}

pg_trunk_prepare_path() {
  local stack_name="$1" repo_name
  repo_name=$(pg_repo_name)
  printf '/tmp/pg-prepare-trunk-%s-%s.json' \
    "$(pg_branch_slug "$repo_name")" "$(pg_branch_slug "$stack_name")"
}

pg_trunk_draft_path() {
  local stack_name="$1" repo_name
  repo_name=$(pg_repo_name)
  printf '/tmp/pg-approve-trunk-%s-%s.json' \
    "$(pg_branch_slug "$repo_name")" "$(pg_branch_slug "$stack_name")"
}

pg_trunk_prepare_status_json() {
  local stack_name="$1" worktree_root store_repo common_dir prepare_path state reason prepared_at=""
  local prepare_command review_command draft_command approve_saved_draft_command
  local latest_materialization prepared_materialization latest_manifest latest_tip prepared_manifest prepared_tip
  worktree_root=$(pg_repo_root) || worktree_root=""
  store_repo=$(pg_main_repo_path 2>/dev/null || printf '%s\n' "$worktree_root")
  common_dir=$(pg_git_common_dir 2>/dev/null || true)
  prepare_path=$(pg_trunk_prepare_path "$stack_name")
  if [[ -f "$prepare_path" ]]; then
    if ! jq -e . "$prepare_path" >/dev/null 2>&1; then
      state="stale"
      reason="Prepared trunk brief is not valid JSON. Re-run pg prepare-trunk."
    else
      prepared_at=$(jq -r '.prepared_at // ""' "$prepare_path" 2>/dev/null || echo "")
      latest_materialization=$(pg_trunk_latest_materialization_json "$stack_name" 2>/dev/null || true)
      prepared_materialization=$(jq -c '.materialization // null' "$prepare_path")
      latest_manifest=$(jq -r '.manifest_hash // ""' <<<"${latest_materialization:-{}}" 2>/dev/null || true)
      latest_tip=$(jq -r '.trunk_tip // ""' <<<"${latest_materialization:-{}}" 2>/dev/null || true)
      prepared_manifest=$(jq -r '.manifest_hash // ""' <<<"$prepared_materialization" 2>/dev/null || true)
      prepared_tip=$(jq -r '.trunk_tip // ""' <<<"$prepared_materialization" 2>/dev/null || true)
      if [[ -z "$latest_materialization" ]]; then
        state="stale"
        reason="Prepared trunk brief exists, but no current materialization is recorded. Re-run stack trunk materialize and pg prepare-trunk."
      elif [[ "$prepared_manifest" != "$latest_manifest" ]]; then
        state="stale"
        reason="Stack manifest changed after prepare-trunk. Re-run pg prepare-trunk."
      elif [[ "$prepared_tip" != "$latest_tip" ]]; then
        state="stale"
        reason="Stack trunk materialization changed after prepare-trunk. Re-run pg prepare-trunk."
      else
        state="ready"
        reason="Prepared trunk brief is ready for human review."
      fi
    fi
  else
    state="missing"
    reason="Agent must prepare a trunk brief before approval draft review."
  fi
  prepare_command="pg -C $(pg_shell_quote "$worktree_root") prepare-trunk --stack $(pg_shell_quote "$stack_name") --what <what> --why <why> --approach <approach>"
  review_command="pg -C $(pg_shell_quote "$worktree_root") trunk --stack $(pg_shell_quote "$stack_name")"
  draft_command="pg -C $(pg_shell_quote "$worktree_root") trunk-draft --stack $(pg_shell_quote "$stack_name") --format yaml"
  approve_saved_draft_command="pg -C $(pg_shell_quote "$worktree_root") approve-trunk --draft <draft-file> --reviewed-in-vscode"
  jq -n \
    --arg state "$state" \
    --arg reason "$reason" \
    --arg path "$prepare_path" \
    --arg prepared_at "$prepared_at" \
    --arg worktree_root "$worktree_root" \
    --arg store_repo "$store_repo" \
    --arg common_dir "$common_dir" \
    --arg prepare_command "$prepare_command" \
    --arg review_command "$review_command" \
    --arg draft_command "$draft_command" \
    --arg approve_saved_draft_command "$approve_saved_draft_command" \
    '{
      state:$state,
      reason:$reason,
      path:$path,
      prepared_at:(if $prepared_at == "" then null else $prepared_at end),
      repo_root:$worktree_root,
      target:{
        worktree_root:$worktree_root,
        store_repo:$store_repo,
        common_dir:(if $common_dir == "" then null else $common_dir end)
      },
      commands:{
        prepare:$prepare_command,
        review:$review_command,
        draft:$draft_command,
        approve_saved_draft:$approve_saved_draft_command
      }
    }'
}

pg_cmd_prepare_trunk_status() {
  local stack_name="" format="text"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --json) format="json"; shift ;;
      *) pg_fail "Unknown prepare-trunk status option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg prepare-trunk status requires --stack NAME"
  local status_json
  status_json=$(pg_trunk_prepare_status_json "$stack_name")
  if [[ "$format" == "json" ]]; then
    printf '%s\n' "$status_json"
    return 0
  fi
  jq -r '
    "Prepare-trunk: " + .state,
    "Reason: " + .reason,
    "Target: " + .target.worktree_root,
    "Prepare: " + .commands.prepare,
    "Review: " + .commands.review
  ' <<<"$status_json"
}

pg_trunk_latest_materialization_json() {
  local stack_name="$1" repo_key row materialization_id manifest_hash trunk_tip created_at
  repo_key=$(pg_repo_key) || return 1
  row=$(pg_dolt_sql_csv "
SELECT materialization_id, manifest_hash, trunk_tip, created_at
FROM trunk_materializations
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name")
ORDER BY created_at DESC
LIMIT 1;
" | tail -n +2 | head -1)
  [[ -n "$row" ]] || return 1
  IFS=, read -r materialization_id manifest_hash trunk_tip created_at <<<"$row"
  local items='[]' item_id order_index branch commit_sha pr_number
  while IFS=, read -r item_id order_index branch commit_sha pr_number; do
    [[ -z "$item_id" ]] && continue
    pr_number=$(pg_csv_unquote "$pr_number")
    items=$(jq \
      --arg id "$item_id" \
      --arg branch "$branch" \
      --arg commit "$commit_sha" \
      --arg pr "$pr_number" \
      --argjson order_index "$order_index" \
      '. + [{
        id: $id,
        order_index: $order_index,
        branch: $branch,
        commit: $commit,
        pr: (if $pr == "" then null else ($pr | tonumber) end)
      }]' <<<"$items")
  done < <(pg_dolt_sql_csv "
SELECT item_id, order_index, branch, commit_sha, COALESCE(pr_number, '')
FROM trunk_materialization_items
WHERE repo_key = $(pg_sql_quote "$repo_key")
  AND stack_name = $(pg_sql_quote "$stack_name")
  AND materialization_id = $(pg_sql_quote "$materialization_id")
ORDER BY order_index;
" | tail -n +2)
  jq -n \
    --arg stack "$stack_name" \
    --arg materialization_id "$materialization_id" \
    --arg manifest_hash "$manifest_hash" \
    --arg trunk_tip "$trunk_tip" \
    --arg created_at "$created_at" \
    --argjson items "$items" \
    '{
      stack: $stack,
      materialization_id: $materialization_id,
      manifest_hash: $manifest_hash,
      trunk_tip: $trunk_tip,
      created_at: $created_at,
      items: $items
    }'
}

pg_trunk_active_lease_json() {
  local stack_name="$1" repo_key row manifest_hash materialization_id trunk_tip status updated_at async_json
  repo_key=$(pg_repo_key) || return 1
  row=$(pg_dolt_sql_csv "
SELECT manifest_hash, materialization_id, trunk_tip, status, updated_at
FROM trunk_leases
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" | tail -n +2 | head -1)
  [[ -n "$row" ]] || return 1
  IFS=, read -r manifest_hash materialization_id trunk_tip status updated_at <<<"$row"
  async_json=$(pg_dolt_sql_json "
SELECT COALESCE(async_json, '{\"enabled\":false}') AS async_json
FROM trunk_leases
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" | jq -r '.rows[0].async_json // "{\"enabled\":false}"' | pg_compact_json_text)
  local items='[]' item_id order_index branch commit_sha pr_number
  while IFS=, read -r item_id order_index branch commit_sha pr_number; do
    [[ -z "$item_id" ]] && continue
    pr_number=$(pg_csv_unquote "$pr_number")
    items=$(jq \
      --arg id "$item_id" \
      --arg branch "$branch" \
      --arg commit "$commit_sha" \
      --arg pr "$pr_number" \
      --argjson order_index "$order_index" \
      '. + [{
        id: $id,
        order_index: $order_index,
        branch: $branch,
        commit: $commit,
        pr: (if $pr == "" then null else ($pr | tonumber) end)
      }]' <<<"$items")
  done < <(pg_dolt_sql_csv "
SELECT item_id, order_index, branch, commit_sha, COALESCE(pr_number, '')
FROM trunk_lease_items
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name")
ORDER BY order_index;
" | tail -n +2)
  jq -n \
    --arg stack "$stack_name" \
    --arg manifest_hash "$manifest_hash" \
    --arg materialization_id "$materialization_id" \
    --arg trunk_tip "$trunk_tip" \
    --arg status "$status" \
    --arg updated_at "$updated_at" \
    --argjson async_iteration "$async_json" \
    --argjson items "$items" \
    '{
      stack: $stack,
      manifest_hash: $manifest_hash,
      materialization_id: $materialization_id,
      trunk_tip: $trunk_tip,
      status: $status,
      updated_at: $updated_at,
      async_iteration: $async_iteration,
      items: $items
    }'
}

pg_trunk_check_json() {
  local stack_name="$1" materialization lease
  materialization=$(pg_trunk_latest_materialization_json "$stack_name" 2>/dev/null || true)
  if [[ -z "$materialization" ]]; then
    jq -n --arg stack "$stack_name" '{allowed:false, reason:("No materialization recorded for stack " + $stack + ". Run stack trunk materialize first.")}'
    return 0
  fi
  lease=$(pg_trunk_active_lease_json "$stack_name" 2>/dev/null || true)
  if [[ -z "$lease" ]]; then
    jq -n --arg stack "$stack_name" '{allowed:false, reason:("No active trunk lease for stack " + $stack + ". Run pg prepare-trunk, then pg trunk.")}'
    return 0
  fi
  local lease_status lease_manifest lease_tip materialization_manifest materialization_tip lease_items materialization_items
  local async_status async_enabled async_block async_allow_rewrite lease_shape materialization_shape
  local manifest current_trunk_ref scoped_trunk_ref
  lease_status=$(jq -r '.status' <<<"$lease")
  lease_manifest=$(jq -r '.manifest_hash' <<<"$lease")
  lease_tip=$(jq -r '.trunk_tip' <<<"$lease")
  materialization_manifest=$(jq -r '.manifest_hash' <<<"$materialization")
  materialization_tip=$(jq -r '.trunk_tip' <<<"$materialization")
  lease_items=$(jq -c '[.items[] | {id,branch,commit}]' <<<"$lease")
  materialization_items=$(jq -c '[.items[] | {id,branch,commit}]' <<<"$materialization")
  lease_shape=$(jq -c '[.items[] | {id,branch}]' <<<"$lease")
  materialization_shape=$(jq -c '[.items[] | {id,branch}]' <<<"$materialization")
  async_status=$(pg_async_status_json "$(jq -c '.async_iteration // {enabled:false}' <<<"$lease")")
  async_enabled=$(jq -r '.enabled' <<<"$async_status")
  async_block=$(jq -r '.block_reason // ""' <<<"$async_status")
  async_allow_rewrite=$(jq -r '.allow_rewrite // false' <<<"$async_status")
  manifest=$(pg_stack_manifest_json "$stack_name" 2>/dev/null || true)
  current_trunk_ref=$(jq -r '.trunk // ""' <<<"$manifest" 2>/dev/null || true)
  scoped_trunk_ref=$(jq -r '.scope.trunk_ref // ""' <<<"$async_status")
  if [[ "$lease_status" != "active" ]]; then
    jq -n --arg status "$lease_status" --argjson async_iteration "$async_status" '{allowed:false, reason:("Trunk lease is not active: " + $status), async_iteration:$async_iteration}'
    return 0
  fi
  if [[ "$lease_manifest" != "$materialization_manifest" ]]; then
    jq -n --argjson async_iteration "$async_status" '{allowed:false, reason:"Stack manifest changed after trunk approval. Re-run pg prepare-trunk and pg trunk.", async_iteration:$async_iteration}'
    return 0
  fi
  if [[ "$lease_shape" != "$materialization_shape" ]]; then
    jq -n --argjson async_iteration "$async_status" '{allowed:false, reason:"Stack item ids or branch names changed after trunk approval. Re-run pg prepare-trunk and pg trunk.", async_iteration:$async_iteration}'
    return 0
  fi
  if [[ -n "$scoped_trunk_ref" && -n "$current_trunk_ref" && "$scoped_trunk_ref" != "$current_trunk_ref" ]]; then
    jq -n --argjson async_iteration "$async_status" '{allowed:false, reason:"Stack private trunk ref changed after trunk approval. Re-run pg prepare-trunk and pg trunk.", async_iteration:$async_iteration}'
    return 0
  fi
  if [[ "$async_enabled" == "true" && -n "$async_block" ]]; then
    jq -n --arg reason "$async_block" --argjson async_iteration "$async_status" '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
    return 0
  fi
  if [[ "$lease_tip" != "$materialization_tip" || "$lease_items" != "$materialization_items" ]]; then
    if [[ "$async_enabled" != "true" ]]; then
      jq -n --argjson async_iteration "$async_status" '{allowed:false, reason:"Stack trunk changed after approval. Re-run pg prepare-trunk --async and pg trunk for iterative pushes.", async_iteration:$async_iteration}'
      return 0
    fi
    if [[ "$async_allow_rewrite" != "true" ]]; then
      jq -n --argjson async_iteration "$async_status" '{allowed:false, reason:"Stack trunk changed after approval, but async rewrite was not approved. Re-run pg prepare-trunk --async --allow-rewrite and pg trunk.", async_iteration:$async_iteration}'
      return 0
    fi
  fi
  jq -n --argjson lease "$lease" --argjson materialization "$materialization" \
    --argjson async_iteration "$async_status" \
    '{allowed:true, lease:$lease, materialization:$materialization, async_iteration:$async_iteration}'
}

pg_git_log_json_for_range() {
  local range="$1"
  local commits='[]' sha short subject
  while IFS=$'\t' read -r sha short subject; do
    [[ -z "$sha" ]] && continue
    commits=$(jq \
      --arg sha "$sha" \
      --arg short "$short" \
      --arg subject "$subject" \
      '. + [{sha:$sha, short:$short, subject:$subject}]' <<<"$commits")
  done < <(git log --reverse --format='%H%x09%h%x09%s' "$range" 2>/dev/null | awk 'NR <= 20')
  printf '%s\n' "$commits"
}

pg_git_changed_files_json_for_range() {
  local range="$1"
  local files='[]' status path extra change
  while IFS=$'\t' read -r status path extra; do
    [[ -z "$status" || -z "$path" ]] && continue
    if [[ -n "$extra" ]]; then
      path="$path -> $extra"
    fi
    case "$status" in
      A) change="added" ;;
      M) change="modified" ;;
      D) change="deleted" ;;
      R*) change="renamed" ;;
      C*) change="copied" ;;
      T) change="type changed" ;;
      U) change="unmerged" ;;
      *) change="$status" ;;
    esac
    files=$(jq \
      --arg change "$change" \
      --arg path "$path" \
      '. + [{change:$change, path:$path}]' <<<"$files")
  done < <(git diff --name-status "$range" 2>/dev/null | awk 'NR <= 50')
  printf '%s\n' "$files"
}

pg_json_or_yaml_file() {
  local file="$1"
  [[ -f "$file" ]] || { pg_fail "brief file not found: $file"; return 1; }
  case "$file" in
    *.json)
      jq -c . "$file"
      ;;
    *.yaml|*.yml)
      command -v yq >/dev/null 2>&1 \
        || { pg_fail "YAML brief files require yq. Use JSON or install yq."; return 1; }
      yq eval '.' "$file" --output-format=json | jq -c .
      ;;
    *)
      if jq -e . "$file" >/dev/null 2>&1; then
        jq -c . "$file"
      else
        command -v yq >/dev/null 2>&1 \
          || { pg_fail "brief file is not JSON, and yq is unavailable for YAML: $file"; return 1; }
        yq eval '.' "$file" --output-format=json | jq -c .
      fi
      ;;
  esac
}

pg_normalize_item_briefs_json() {
  local raw="${1:-}"
  if [[ -z "$raw" ]]; then
    printf '[]\n'
    return 0
  fi
  jq -c '
    if type == "array" then .
    elif has("item_briefs") then .item_briefs
    else error("item brief file must be an array or object with item_briefs")
    end
    | map({
        id: (.id // error("item brief missing id")),
        summary: (.summary // .what // null),
        motivation: (.motivation // .why // null),
        approach: (.approach // null),
        scope: (.scope // null),
        risks: (.risks // null),
        testing: (.testing // .verification // null),
        what: (.what // .summary // null),
        why: (.why // .motivation // null),
        verification: (.verification // .testing // null)
      })
  ' <<<"$raw"
}

pg_validate_trunk_item_briefs() {
  local materialization="$1" item_briefs="$2"
  jq -e --argjson materialization "$materialization" --argjson item_briefs "$item_briefs" '
    def ids(a): [a[] | .id] | sort;
    def filled:
      if type == "array" then length > 0 and all(.[]; type == "string" and length > 0)
      elif type == "string" then length > 0
      else false
      end;
    (ids($materialization.items) == ids($item_briefs))
    and all($item_briefs[]; (.what | filled) and (.why | filled) and (.approach | filled))
  ' >/dev/null <<<"{}"
}

pg_trunk_stack_items_json() {
  local stack_name="$1" materialization="$2" item_briefs="${3:-[]}"
  local manifest base_ref base_commit previous_commit details='[]'
  manifest=$(pg_stack_manifest_json "$stack_name" 2>/dev/null || true)
  base_ref=$(jq -r '.base // ""' <<<"${manifest:-{}}" 2>/dev/null || echo "")
  if [[ -n "$base_ref" ]]; then
    base_commit=$(git rev-parse --verify "$base_ref" 2>/dev/null || true)
  else
    base_commit=""
  fi

  local id order_index branch commit_sha pr_number review_base review_base_label range subject body commits files stat shortstat
  while IFS=$'\t' read -r id order_index branch commit_sha pr_number; do
    [[ -z "$id" ]] && continue
    review_base="$previous_commit"
    review_base_label="$previous_commit"
    if [[ -z "$review_base" ]]; then
      review_base="$base_commit"
      review_base_label="$base_ref"
    fi
    if [[ -z "$review_base" ]]; then
      review_base=$(git rev-parse --verify "${commit_sha}^" 2>/dev/null || true)
      review_base_label="${commit_sha}^"
    fi
    if [[ -n "$review_base" ]]; then
      range="${review_base}..${commit_sha}"
      commits=$(pg_git_log_json_for_range "$range")
      files=$(pg_git_changed_files_json_for_range "$range")
      stat=$(git diff --stat "$range" 2>/dev/null | awk 'NR <= 30')
      shortstat=$(git diff --shortstat "$range" 2>/dev/null | sed 's/^ *//')
    else
      range="$commit_sha"
      commits=$(jq -n --arg sha "$commit_sha" --arg short "${commit_sha:0:12}" --arg subject "$(git log -1 --format='%s' "$commit_sha" 2>/dev/null || echo "")" '[{sha:$sha, short:$short, subject:$subject}]')
      files='[]'
      stat=""
      shortstat=""
    fi
    subject=$(git log -1 --format='%s' "$commit_sha" 2>/dev/null || echo "")
    body=$(git log -1 --format='%b' "$commit_sha" 2>/dev/null | awk 'NF && n < 40 { print; n++ }' || true)
    details=$(jq \
      --arg id "$id" \
      --argjson order_index "$order_index" \
      --arg branch "$branch" \
      --arg pointer_commit "$commit_sha" \
      --arg pr "$pr_number" \
      --arg base_commit "$review_base" \
      --arg base_label "$review_base_label" \
      --arg range "$range" \
      --arg pointer_subject "$subject" \
      --arg pointer_body "$body" \
      --arg stat "$stat" \
      --arg shortstat "$shortstat" \
      --argjson item_briefs "$item_briefs" \
      --argjson commits "$commits" \
      --argjson files "$files" \
      --arg id_for_brief "$id" \
      '
      ($item_briefs | map(select(.id == $id_for_brief)) | first // {}) as $item_brief
      | . + [{
        id: $id,
        order_index: $order_index,
        branch: $branch,
        pr: (if $pr == "" then null else ($pr | tonumber) end),
        description: {
          summary: ($item_brief.summary // $item_brief.what // $pointer_subject // null),
          motivation: ($item_brief.motivation // $item_brief.why // null),
          approach: ($item_brief.approach // null),
          scope: ($item_brief.scope // null),
          risks: ($item_brief.risks // null),
          testing: ($item_brief.testing // $item_brief.verification // null)
        },
        brief: {
          what: ($item_brief.what // $item_brief.summary // $pointer_subject // null),
          why: ($item_brief.why // $item_brief.motivation // null),
          approach: ($item_brief.approach // null),
          risks: ($item_brief.risks // null),
          verification: ($item_brief.verification // $item_brief.testing // null)
        },
        pointer_commit: $pointer_commit,
        pointer_subject: $pointer_subject,
        pointer_body: (if $pointer_body == "" then null else $pointer_body end),
        base_commit: (if $base_commit == "" then null else $base_commit end),
        base_label: (if $base_label == "" then null else $base_label end),
        range: $range,
        contained_commits: $commits,
        changed_files: (
          $files
          | sort_by(.change)
          | group_by(.change)
          | map({change: .[0].change, paths: map(.path)})
        ),
        stat: (if $stat == "" then null else $stat end),
        shortstat: (if $shortstat == "" then null else $shortstat end)
      }]' <<<"$details")
    previous_commit="$commit_sha"
  done < <(jq -r '.items[] | [.id, .order_index, .branch, .commit, (.pr // "")] | @tsv' <<<"$materialization")
  printf '%s\n' "$details"
}

pg_cmd_prepare_trunk() {
  if [[ "${1:-}" == "status" ]]; then
    shift
    pg_cmd_prepare_trunk_status "$@"
    return $?
  fi
  local stack_name="" what="" why="" approach="" scope="" risks="" item_briefs_file="" item_briefs_raw="" item_briefs="[]"
  local async_enabled="false" async_expires="" async_max_pushes="" async_allow_rewrite="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --what) what="$2"; shift 2 ;;
      --why) why="$2"; shift 2 ;;
      --approach) approach="$2"; shift 2 ;;
      --scope) scope="$2"; shift 2 ;;
      --risks) risks="$2"; shift 2 ;;
      --item-briefs|--item-brief-file) item_briefs_file="$2"; shift 2 ;;
      --low-stakes)
        async_enabled="true"
        [[ -n "$async_expires" ]] || async_expires="1h"
        [[ -n "$async_max_pushes" ]] || async_max_pushes="5"
        shift
        ;;
      --async) async_enabled="true"; shift ;;
      --expires) async_expires="$2"; shift 2 ;;
      --max-pushes) async_max_pushes="$2"; shift 2 ;;
      --allow-rewrite) async_allow_rewrite="true"; shift ;;
      *) pg_fail "Unknown prepare-trunk option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg prepare-trunk requires --stack NAME"
  local missing=()
  [[ -z "$what" || "$what" == "<"* ]] && missing+=("--what")
  [[ -z "$why" || "$why" == "<"* ]] && missing+=("--why")
  [[ -z "$approach" || "$approach" == "<"* ]] && missing+=("--approach")
  if [[ ${#missing[@]} -gt 0 ]]; then
    pg_fail "pg prepare-trunk requires --what, --why, and --approach."
    return 1
  fi
  local repo_root materialization path
  repo_root=$(pg_repo_root) || { pg_fail "not in a git repo"; return 1; }
  materialization=$(pg_trunk_latest_materialization_json "$stack_name") \
    || { pg_fail "No materialization recorded for stack $stack_name. Run stack trunk materialize first."; return 1; }
  if [[ -n "$item_briefs_file" ]]; then
    item_briefs_raw=$(pg_json_or_yaml_file "$item_briefs_file") || return 1
    item_briefs=$(pg_normalize_item_briefs_json "$item_briefs_raw") || return 1
    pg_validate_trunk_item_briefs "$materialization" "$item_briefs" \
      || { pg_fail "item briefs must contain exactly one entry per stack item, and each needs what, why, and approach."; return 1; }
  fi
  path=$(pg_trunk_prepare_path "$stack_name")
  local async_json
  async_json=$(pg_async_request_json "$async_enabled" "trunk" "${async_expires:-8h}" "${async_max_pushes:-30}" "$async_allow_rewrite") || return 1
  jq -n \
    --arg repo_root "$repo_root" \
    --arg stack "$stack_name" \
    --arg what "$what" \
    --arg why "$why" \
    --arg approach "$approach" \
    --arg scope "$scope" \
    --arg risks "$risks" \
    --arg at "$(pg_now_utc)" \
    --argjson materialization "$materialization" \
    --argjson item_briefs "$item_briefs" \
    --argjson async_iteration "$async_json" \
    '{
      repo_root: $repo_root,
      stack: $stack,
      what: $what,
      why: $why,
      approach: $approach,
      scope: (if $scope == "" then null else $scope end),
      risks: (if $risks == "" then null else $risks end),
      item_briefs: $item_briefs,
      prepared_at: $at,
      materialization: $materialization,
      async_iteration: $async_iteration
    }' >"$path"
  echo "Prepared trunk brief written: $path"
  echo "Now ask the user to run:  pg -C $repo_root trunk --stack $stack_name"
}

pg_render_trunk_summary() {
  local draft="$1"
  jq -r '
    def item_bullets($label; $value):
      if ($value | type) == "array" then
        "    - " + $label + ":",
        ($value[] | "      - " + .)
      else
        "    - " + $label + ": " + (($value // "") | tostring)
      end;
    def desc: .description // {
      summary: .brief.what,
      motivation: .brief.why,
      approach: .brief.approach,
      scope: .brief.scope,
      risks: .brief.risks,
      testing: .brief.verification
    };
    "Stack trunk approval",
    "",
    "Stack: " + .stack,
    (if ((.async_iteration.scope.trunk_ref // "") != "") then "Private trunk ref: " + .async_iteration.scope.trunk_ref else empty end),
    "Trunk tip: " + .materialization.trunk_tip,
    "Manifest hash: " + .materialization.manifest_hash,
    (if (.async_iteration.enabled // false) then
      "Async iteration: enabled"
      + "\n  Expires: " + ((.async_iteration.expires_at // .async_iteration.expires // "") | tostring)
      + "\n  Pushes: " + ((.async_iteration.used_pushes // 0) | tostring) + "/" + ((.async_iteration.max_pushes // 0) | tostring)
      + "\n  Rewrite: " + (if (.async_iteration.allow_rewrite // false) then "allowed" else "denied" end)
      + "\n  Scope: same stack, private trunk ref, manifest hash, item ids, and item branches"
    else
      "Async iteration: disabled"
    end),
    "",
    "Description:",
    "  Summary: " + (desc.summary // ""),
    "  Motivation: " + (desc.motivation // ""),
    "  Approach: " + (desc.approach // ""),
    "",
    "Items:",
    (if (((.stack_items // .item_details // [])) | length) > 0 then
      ((.stack_items // .item_details)[] |
        "  - Stack item: " + .id
          + (if (.pr // null) == null then "" else " (#" + (.pr | tostring) + ")" end)
          + ":",
        item_bullets("Summary"; (desc.summary // .brief.what)),
        item_bullets("Motivation"; (desc.motivation // .brief.why)),
        item_bullets("Approach"; (desc.approach // .brief.approach)),
        (if ((desc.scope // "") != "") then item_bullets("Scope"; desc.scope) else empty end),
        (if ((desc.risks // .brief.risks // "") != "") then item_bullets("Risks"; (desc.risks // .brief.risks)) else empty end),
        (if ((desc.testing // .brief.verification // "") != "") then item_bullets("Testing"; (desc.testing // .brief.verification)) else empty end),
        "    - Branch: " + .branch,
        "    - Pointer commit: " + ((.pointer_commit // .commit)[0:12]) + " " + (.pointer_subject // .subject // ""),
        "    - Base: " + ((.base_label // .review_base_label // .base_commit // .review_base // "(unknown)") | tostring)
          + (if ((.base_commit // .review_base // "") != "") then " @ " + ((.base_commit // .review_base)[0:12]) else "" end),
        "    - Diff: " + (.shortstat // "no diff"),
        (if (((.contained_commits // .commits // [])) | length) > 0 then
          "    - Contained commits:",
          ((.contained_commits // .commits)[] | "      - " + .short + " " + .subject)
        else empty end),
        (if ((.changed_files // []) | length) > 0 then
          "    - Changed files:",
          (.changed_files[] | "      - " + .change + ":", (.paths[0:12][] | "        - " + .), (if (.paths | length) > 12 then "        - ... " + (((.paths | length) - 12) | tostring) + " more" else empty end))
        else empty end),
        (if ((.pointer_body // .body // "") != "") then "    - Pointer commit body:\n" + ((.pointer_body // .body) | split("\n") | map("      " + .) | join("\n")) else empty end)
      )
    else
      (.materialization.items[] | "  - " + .id + " " + .branch + " @ " + (.commit[0:12]))
    end)
  ' "$draft"
}

pg_cmd_trunk() {
  local stack_name=""
  local assume_yes="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) assume_yes="true"; shift ;;
      --stack|--name) stack_name="$2"; shift 2 ;;
      *) pg_fail "Unknown trunk option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg trunk requires --stack NAME"
  local prepare_path draft_file script_file materialization stack_items what why approach scope risks async_json trunk_ref manifest_json
  prepare_path=$(pg_trunk_prepare_path "$stack_name")
  [[ -f "$prepare_path" ]] || pg_fail "No prepared trunk brief for $stack_name. Run pg prepare-trunk first."
  materialization=$(pg_trunk_latest_materialization_json "$stack_name") || {
    pg_fail "No materialization recorded for stack $stack_name. Run stack trunk materialize first."
    return 1
  }
  local item_briefs
  item_briefs=$(jq -c '.item_briefs // []' "$prepare_path")
  stack_items=$(pg_trunk_stack_items_json "$stack_name" "$materialization" "$item_briefs")
  what=$(jq -r '.what // ""' "$prepare_path")
  why=$(jq -r '.why // ""' "$prepare_path")
  approach=$(jq -r '.approach // ""' "$prepare_path")
  scope=$(jq -r '.scope // ""' "$prepare_path")
  risks=$(jq -r '.risks // ""' "$prepare_path")
  async_json=$(jq -c '.async_iteration // {enabled:false}' "$prepare_path")
  manifest_json=$(pg_stack_manifest_json "$stack_name" 2>/dev/null || echo '{}')
  trunk_ref=$(jq -r '.trunk // ""' <<<"$manifest_json")
  draft_file=$(pg_trunk_draft_path "$stack_name")
  script_file="${draft_file%.json}.sh"
  jq -n \
    --arg repo_key "$(pg_repo_key)" \
    --arg repo_root "$(pg_repo_root)" \
    --arg common_dir "$(pg_git_common_dir)" \
    --arg stack "$stack_name" \
    --arg what "$what" \
    --arg why "$why" \
    --arg approach "$approach" \
    --arg scope "$scope" \
    --arg risks "$risks" \
    --arg trunk_ref "$trunk_ref" \
    --arg created_by "${USER:-unknown}" \
    --arg created_at "$(pg_now_utc)" \
    --argjson materialization "$materialization" \
    --argjson stack_items "$stack_items" \
    --argjson async_iteration "$async_json" \
    '{
      schema_version: 1,
      stack: $stack,
      description: {
        summary: $what,
        motivation: $why,
        approach: $approach,
        scope: (if $scope == "" then null else $scope end),
        risks: (if $risks == "" then null else $risks end),
        testing: null
      },
      stack_items: $stack_items,
      approved_scope: null,
      repo_key: $repo_key,
      repo_root: $repo_root,
      common_dir: $common_dir,
      materialization: $materialization,
      brief: {
        what: $what,
        why: $why,
        approach: $approach,
        scope: (if $scope == "" then null else $scope end),
        risks: (if $risks == "" then null else $risks end)
      },
      async_iteration: (
        if ($async_iteration.enabled // false) then
          $async_iteration
          | .mode = "trunk"
          | .scope = {
              type: "trunk",
              stack: $stack,
              trunk_ref: $trunk_ref,
              manifest_hash: $materialization.manifest_hash,
              item_ids: ($materialization.items | map(.id)),
              item_branches: ($materialization.items | map(.branch))
            }
        else
          {enabled:false}
        end
      ),
      created_by: $created_by,
      created_at: $created_at,
      status: "active"
    }' >"$draft_file"
  cat >"$script_file" <<EOF
#!/bin/bash
set -euo pipefail
DRAFT_FILE="$draft_file"
HELPER="$(pg_helper_path)"
ASSUME_YES="$assume_yes"
editor="\${EDITOR:-vi}"
if command -v yq >/dev/null 2>&1; then
  {
    echo "# pg trunk approval draft — edit description and stack_items[].description."
    echo "# Machine fields stay below the human review text."
    yq -P eval '.' "\$DRAFT_FILE" --output-format=yaml
  } > "\$DRAFT_FILE.yaml"
  "\$editor" "\$DRAFT_FILE.yaml"
  yq eval '.' "\$DRAFT_FILE.yaml" --output-format=json > "\$DRAFT_FILE.new"
  jq empty "\$DRAFT_FILE.new"
  mv "\$DRAFT_FILE.new" "\$DRAFT_FILE"
else
  "\$editor" "\$DRAFT_FILE"
  jq empty "\$DRAFT_FILE"
fi
"\$HELPER" preview-trunk --draft "\$DRAFT_FILE"
echo
if [[ "\$ASSUME_YES" == "true" ]]; then
  echo "Proceed: yes (--yes, after editor review)"
  "\$HELPER" approve-trunk --draft "\$DRAFT_FILE"
else
  printf 'Proceed? [Y/n] '
  read -r answer
  case "\$answer" in
    ""|y|Y|yes|YES) "\$HELPER" approve-trunk --draft "\$DRAFT_FILE" ;;
    *) echo "Canceled"; exit 1 ;;
  esac
fi
EOF
  chmod +x "$script_file"
  echo "Trunk approval script: $script_file"
  echo "Draft file: $draft_file"
  if [[ "${PG_AUTO_RUN_APPROVAL:-1}" == "1" ]] && [[ -t 0 || -t 1 ]]; then
    bash "$script_file"
  fi
}

pg_cmd_trunk_draft() {
  local stack_name="" format="yaml" out_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      --format) format="$2"; shift 2 ;;
      --out) out_file="$2"; shift 2 ;;
      *) pg_fail "Unknown trunk-draft option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg trunk-draft requires --stack NAME"
  case "$format" in
    json|yaml) ;;
    *) pg_fail "pg trunk-draft --format must be json or yaml"; return 1 ;;
  esac

  local trunk_out draft_file script_file target_file
  trunk_out=$(PG_AUTO_RUN_APPROVAL=0 pg_cmd_trunk --stack "$stack_name") || return 1
  draft_file=$(printf '%s\n' "$trunk_out" | awk -F': ' '/^Draft file:/ {print $2; exit}')
  script_file=$(printf '%s\n' "$trunk_out" | awk -F': ' '/^Trunk approval script:/ {print $2; exit}')
  [[ -f "$draft_file" ]] || { pg_fail "Unable to create trunk draft for $stack_name"; return 1; }

  if [[ "$format" == "yaml" ]]; then
    command -v yq >/dev/null 2>&1 \
      || { pg_fail "YAML trunk drafts require yq. Use --format json or install yq."; return 1; }
    target_file="${out_file:-$draft_file.yaml}"
    {
      echo "# pg trunk approval draft — edit description and stack_items[].description."
      echo "# Save this file, then approve it from VS Code with Gitless: Approve Saved Draft."
      echo "# Machine fields stay below the human review text."
      yq -P eval '.' "$draft_file" --output-format=yaml
    } >"$target_file"
  else
    target_file="${out_file:-$draft_file}"
    if [[ -n "$out_file" && "$out_file" != "$draft_file" ]]; then
      cp "$draft_file" "$out_file"
    fi
  fi

  jq -n \
    --arg stack "$stack_name" \
    --arg format "$format" \
    --arg draft_file "$target_file" \
    --arg json_draft_file "$draft_file" \
    --arg script_file "$script_file" \
    '{
      stack: $stack,
      format: $format,
      draft_file: $draft_file,
      json_draft_file: $json_draft_file,
      script_file: (if $script_file == "" then null else $script_file end)
    }'
}

pg_cmd_preview_trunk() {
  local draft=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft) draft="$2"; shift 2 ;;
      *) pg_fail "Unknown preview-trunk option: $1"; return 1 ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"
  pg_render_trunk_summary "$draft"
}

pg_cmd_approve_trunk() {
  local draft=""
  local reviewed_in_vscode="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft) draft="$2"; shift 2 ;;
      --reviewed-in-vscode) reviewed_in_vscode="true"; shift ;;
      *) pg_fail "Unknown approve-trunk option: $1"; return 1 ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"
  local cleanup_draft="" normalized_draft=""
  trap 'rm -f "${cleanup_draft:-}" "${normalized_draft:-}"' RETURN
  case "$draft" in
    *.yaml|*.yml)
      command -v yq >/dev/null 2>&1 \
        || { pg_fail "YAML trunk drafts require yq. Use JSON or install yq."; return 1; }
      cleanup_draft=$(mktemp "${TMPDIR:-/tmp}/pg-trunk-yaml-draft.XXXXXX")
      yq eval '.' "$draft" --output-format=json >"$cleanup_draft" || {
        rm -f "$cleanup_draft"
        pg_fail "Draft YAML failed to parse: $draft"
        return 1
      }
      draft="$cleanup_draft"
      ;;
  esac
  normalized_draft=$(mktemp "${TMPDIR:-/tmp}/pg-trunk-draft.XXXXXX")
  jq '
    def from_brief:
      {
        summary: .brief.what,
        motivation: .brief.why,
        approach: .brief.approach,
        scope: .brief.scope,
        risks: .brief.risks,
        testing: .brief.verification
      };
    .description = (from_brief + (.description // {}))
    | .brief = {
        what: .description.summary,
        why: .description.motivation,
        approach: .description.approach,
        scope: .description.scope,
        risks: .description.risks
      }
    | .stack_items = ((.stack_items // []) | map(
        .description = (from_brief + (.description // {}))
        | .brief = {
            what: .description.summary,
            why: .description.motivation,
            approach: .description.approach,
            risks: .description.risks,
            verification: .description.testing
          }
      ))
  ' "$draft" >"$normalized_draft" || {
    rm -f "$normalized_draft"
    pg_fail "Draft file is not valid JSON: $draft"
    return 1
  }
  mv "$normalized_draft" "$draft"
  local brief_what brief_why brief_approach
  brief_what=$(jq -r '.brief.what // ""' "$draft")
  brief_why=$(jq -r '.brief.why // ""' "$draft")
  brief_approach=$(jq -r '.brief.approach // ""' "$draft")
  if [[ -z "$brief_what" || -z "$brief_why" || -z "$brief_approach" ]]; then
    pg_fail "Approval blocked: trunk brief requires brief.what, brief.why, and brief.approach."
    return 1
  fi
  local missing_item_briefs
  missing_item_briefs=$(jq -r '
    def filled:
      if type == "array" then length > 0 and all(.[]; type == "string" and length > 0)
      elif type == "string" then length > 0
      else false
      end;
    [
      (.stack_items // [])[]
      | select(
          ((.brief.what // null) | filled | not)
          or ((.brief.why // null) | filled | not)
          or ((.brief.approach // null) | filled | not)
        )
      | .id
    ]
    | join(", ")
  ' "$draft")
  if [[ -n "$missing_item_briefs" ]]; then
    pg_fail "Approval blocked: each stack item requires brief.what, brief.why, and brief.approach. Missing: $missing_item_briefs"
    return 1
  fi
  if [[ ! -t 0 && "$reviewed_in_vscode" != "true" ]]; then
    pg_fail "Blocked: pg approve-trunk requires an interactive terminal, unless the saved draft was reviewed and submitted from VS Code with --reviewed-in-vscode."
    return 1
  fi
  local stack_name repo_key now materialization_id manifest_hash trunk_tip brief_json scope_json created_by async_json
  stack_name=$(jq -r '.stack' "$draft")
  local current_materialization draft_materialization
  current_materialization=$(pg_trunk_latest_materialization_json "$stack_name") \
    || { pg_fail "No materialization recorded for stack $stack_name. Run stack trunk materialize first."; return 1; }
  draft_materialization=$(jq -c '.materialization' "$draft")
  if [[ "$(jq -c '{manifest_hash,trunk_tip,items:[.items[] | {id,branch,commit}]}' <<<"$current_materialization")" != "$(jq -c '{manifest_hash,trunk_tip,items:[.items[] | {id,branch,commit}]}' <<<"$draft_materialization")" ]]; then
    pg_fail "Stack trunk changed after the approval draft was created. Re-run pg prepare-trunk and pg trunk."
    return 1
  fi
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  materialization_id=$(jq -r '.materialization.materialization_id' "$draft")
  manifest_hash=$(jq -r '.materialization.manifest_hash' "$draft")
  trunk_tip=$(jq -r '.materialization.trunk_tip' "$draft")
  brief_json=$(jq -c '.brief' "$draft")
  scope_json=$(jq -c '.approved_scope // null' "$draft")
  created_by=$(jq -r '.created_by // "unknown"' "$draft")
  async_json=$(pg_finalize_async_json "$(jq -c '.async_iteration // {enabled:false}' "$draft")" "trunk" | jq -c .) || return 1
  jq --argjson async_iteration "$async_json" '.async_iteration = $async_iteration' \
    "$draft" >"$draft.tmp" && mv "$draft.tmp" "$draft"
  pg_dolt_sql "
REPLACE INTO trunk_leases (repo_key, stack_name, manifest_hash, materialization_id, trunk_tip, approved_scope_json, brief_json, async_json, status, created_by, created_at, updated_at)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$stack_name"), $(pg_sql_quote "$manifest_hash"), $(pg_sql_quote "$materialization_id"), $(pg_sql_quote "$trunk_tip"), $(pg_sql_quote "$scope_json"), $(pg_sql_quote "$brief_json"), $(pg_sql_quote "$async_json"), 'active', $(pg_sql_quote "$created_by"), $(pg_sql_quote "$now"), $(pg_sql_quote "$now"));
DELETE FROM trunk_lease_items WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" >/dev/null
  local item_id order_index branch commit_sha pr_number pr_sql
  while IFS=$'\t' read -r item_id order_index branch commit_sha pr_number; do
    [[ -z "$item_id" ]] && continue
    pr_sql=$(pg_sql_int_or_null "$pr_number")
    pg_dolt_sql "
REPLACE INTO trunk_lease_items (repo_key, stack_name, item_id, order_index, branch, commit_sha, pr_number)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$stack_name"), $(pg_sql_quote "$item_id"), $order_index, $(pg_sql_quote "$branch"), $(pg_sql_quote "$commit_sha"), $pr_sql);
" >/dev/null
  done < <(jq -r '.materialization.items[] | [.id, .order_index, .branch, .commit, (.pr // "")] | @tsv' "$draft")
  pg_dolt_commit "trunk lease $stack_name"
  rm -f "$(pg_trunk_prepare_path "$stack_name")"
  trap - RETURN
  rm -f "$cleanup_draft" "$normalized_draft"
  echo "Trunk lease approved: $stack_name"
}

pg_cmd_check_trunk() {
  local stack_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      *) pg_fail "Unknown check-trunk option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg check-trunk requires --stack NAME"
  pg_trunk_check_json "$stack_name"
}

pg_cmd_revoke_trunk() {
  local stack_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stack|--name) stack_name="$2"; shift 2 ;;
      *) pg_fail "Unknown revoke-trunk option: $1"; return 1 ;;
    esac
  done
  [[ -n "$stack_name" ]] || pg_fail "pg revoke-trunk requires --stack NAME"
  local repo_key now
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  pg_dolt_sql "
UPDATE trunk_leases
SET status = 'revoked', updated_at = $(pg_sql_quote "$now")
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
DELETE FROM pending_trunk_assertions
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" >/dev/null
  pg_dolt_commit "revoke trunk lease $stack_name"
  echo "Revoked trunk lease for $stack_name"
}

pg_trunk_record_pending_assertion() {
  local stack_name="$1" branch="$2" remote="$3" source_ref="$4" commit_sha="$5" assert_flow="$6" repo_key now
  repo_key=$(pg_repo_key) || return 1
  now=$(pg_now_utc)
  pg_dolt_sql "
REPLACE INTO pending_trunk_assertions (repo_key, stack_name, branch, remote, source_ref, commit_sha, assert_flow, created_at)
VALUES ($(pg_sql_quote "$repo_key"), $(pg_sql_quote "$stack_name"), $(pg_sql_quote "$branch"), $(pg_sql_quote "$remote"), $(pg_sql_quote "$source_ref"), $(pg_sql_quote "$commit_sha"), $(pg_sql_quote "$assert_flow"), $(pg_sql_quote "$now"));
" >/dev/null
}

pg_trunk_clear_pending_assertion() {
  local stack_name="$1" branch="$2" repo_key
  repo_key=$(pg_repo_key) || return 0
  pg_dolt_sql "DELETE FROM pending_trunk_assertions WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name") AND branch = $(pg_sql_quote "$branch");" >/dev/null || true
}

pg_trunk_record_async_success() {
  local stack_name="$1" branch="$2" remote="$3" source_ref="$4" commit_sha="$5" assert_flow="$6"
  local repo_key async_json updated
  repo_key=$(pg_repo_key) || return 1
  async_json=$(pg_dolt_sql_json "
SELECT COALESCE(async_json, '{\"enabled\":false}') AS async_json
FROM trunk_leases
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" | jq -r '.rows[0].async_json // "{\"enabled\":false}"' | pg_compact_json_text)
  [[ "$(jq -r '.enabled // false' <<<"$async_json")" == "true" ]] || return 0
  updated=$(jq -c \
    --arg branch "$branch" \
    --arg remote "$remote" \
    --arg source_ref "$source_ref" \
    --arg pushed_head "$commit_sha" \
    --arg assert_flow "$assert_flow" \
    --arg timestamp "$(pg_now_utc)" \
    '.used_pushes = ((.used_pushes // 0) + 1)
     | .audit = ((.audit // []) + [{
         stack: .scope.stack,
         branch: $branch,
         remote: $remote,
         source_ref: $source_ref,
         pushed_head: $pushed_head,
         timestamp: $timestamp,
         assertion_summary: ($assert_flow | gsub("[\r\n]+"; " | "))
       }])' <<<"$async_json")
  pg_dolt_sql "
UPDATE trunk_leases
SET async_json = $(pg_sql_quote "$updated"),
    updated_at = $(pg_sql_quote "$(pg_now_utc)")
WHERE repo_key = $(pg_sql_quote "$repo_key") AND stack_name = $(pg_sql_quote "$stack_name");
" >/dev/null
  pg_dolt_commit "trunk async push $stack_name"
}

pg_trunk_pending_allows_push() {
  local branch="$1" remote="$2" source_ref="$3" commit_sha="$4" repo_key row stack_name
  repo_key=$(pg_repo_key) || return 1
  row=$(pg_dolt_sql_csv "
SELECT stack_name
FROM pending_trunk_assertions
WHERE repo_key = $(pg_sql_quote "$repo_key")
  AND branch = $(pg_sql_quote "$branch")
  AND remote = $(pg_sql_quote "$remote")
  AND commit_sha = $(pg_sql_quote "$commit_sha")
LIMIT 1;
" 2>/dev/null | tail -n +2 | head -1)
  [[ -n "$row" ]] || return 1
  stack_name="$row"
  local check allowed
  check=$(pg_trunk_check_json "$stack_name")
  allowed=$(jq -r '.allowed' <<<"$check")
  [[ "$allowed" == "true" ]] || return 1
  jq -e --arg branch "$branch" --arg commit "$commit_sha" \
    '.materialization.items[] | select(.branch == $branch and .commit == $commit)' <<<"$check" >/dev/null \
    && return 0

  local manifest trunk_branch trunk_tip
  manifest=$(pg_stack_manifest_json "$stack_name" 2>/dev/null || true)
  trunk_branch=$(jq -r '.trunk // ""' <<<"$manifest" 2>/dev/null || true)
  trunk_tip=$(jq -r '.materialization.trunk_tip // ""' <<<"$check")
  [[ -n "$trunk_branch" && "$branch" == "$trunk_branch" && "$commit_sha" == "$trunk_tip" ]]
}

pg_cmd_push_trunk() {
  local stack_name="$1" assert_flow="$2" remote="$3" branch="$4" source_ref="$5" force_with_lease="$6" set_upstream="$7"
  [[ -n "$assert_flow" ]] || pg_fail "pg push --trunk-stack requires --assert-flow."
  [[ -n "$branch" ]] || pg_fail "pg push --trunk-stack requires --branch."
  [[ -n "$source_ref" ]] || pg_fail "pg push --trunk-stack requires --source-ref."
  remote="${remote:-origin}"
  local commit_sha check allowed reason refspec result use_upstream="false" lock_dir=""
  lock_dir=$(pg_lock_acquire "trunk-$stack_name") || return 1
  cleanup_trunk_lock() {
    [[ -n "$lock_dir" ]] && pg_lock_release "$lock_dir"
  }
  trap cleanup_trunk_lock EXIT
  commit_sha=$(git rev-parse --verify "${source_ref}^{commit}") \
    || { cleanup_trunk_lock; trap - EXIT; pg_fail "source ref is not a commit: $source_ref"; return 1; }
  check=$(pg_trunk_check_json "$stack_name")
  allowed=$(jq -r '.allowed' <<<"$check")
  if [[ "$allowed" != "true" ]]; then
    reason=$(jq -r '.reason' <<<"$check")
    cleanup_trunk_lock
    trap - EXIT
    pg_fail "$reason"
    return 1
  fi
  if ! jq -e --arg branch "$branch" --arg commit "$commit_sha" \
    '.materialization.items[] | select(.branch == $branch and .commit == $commit)' <<<"$check" >/dev/null; then
    local manifest trunk_branch trunk_tip
    manifest=$(pg_stack_manifest_json "$stack_name" 2>/dev/null || true)
    trunk_branch=$(jq -r '.trunk // ""' <<<"$manifest" 2>/dev/null || true)
    trunk_tip=$(jq -r '.materialization.trunk_tip // ""' <<<"$check")
    [[ -n "$trunk_branch" && "$branch" == "$trunk_branch" && "$commit_sha" == "$trunk_tip" ]] \
      || { cleanup_trunk_lock; trap - EXIT; pg_fail "Trunk lease for $stack_name does not approve $branch at $commit_sha"; return 1; }
  fi
  pg_trunk_record_pending_assertion "$stack_name" "$branch" "$remote" "$source_ref" "$commit_sha" "$assert_flow"
  cleanup_trunk_pending() {
    pg_trunk_clear_pending_assertion "$stack_name" "$branch"
    cleanup_trunk_lock
  }
  trap cleanup_trunk_pending EXIT
  refspec="$source_ref:$branch"
  [[ "$set_upstream" == "true" ]] && use_upstream="true"
  if [[ "$force_with_lease" == "true" && "$use_upstream" == "true" ]]; then
    git push --force-with-lease -u "$remote" "$refspec"
  elif [[ "$force_with_lease" == "true" ]]; then
    git push --force-with-lease "$remote" "$refspec"
  elif [[ "$use_upstream" == "true" ]]; then
    git push -u "$remote" "$refspec"
  else
    git push "$remote" "$refspec"
  fi
  result=$?
  pg_trunk_clear_pending_assertion "$stack_name" "$branch"
  if [[ "$result" == "0" ]]; then
    pg_trunk_record_async_success "$stack_name" "$branch" "$remote" "$source_ref" "$commit_sha" "$assert_flow"
  fi
  trap - EXIT
  cleanup_trunk_lock
  return "$result"
}

# Shell-quote a string for SQL: escape single quotes and wrap in quotes.
pg_sql_quote() {
  local s="$1"
  s="${s//\'/\'\'}"
  printf "'%s'" "$s"
}

pg_sql_int_or_null() {
  local s="$1"
  if [[ "$s" =~ ^[0-9]+$ ]]; then
    printf '%s' "$s"
  else
    printf 'NULL'
  fi
}

pg_helper_path() {
  echo "$(pg_helper_dir)/$(basename "${BASH_SOURCE[0]}")"
}

pg_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

pg_git_common_dir() {
  local common_dir repo_root
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  if [[ "$common_dir" != /* ]]; then
    repo_root=$(pg_repo_root) || return 1
    common_dir="$repo_root/$common_dir"
  fi
  echo "$common_dir"
}

pg_store_dir() {
  echo "$(pg_git_common_dir)/push-gate"
}

pg_branch_name() {
  git branch --show-current 2>/dev/null
}

pg_branch_ref() {
  local branch="${1:-}"
  if [[ -z "$branch" ]]; then
    branch=$(pg_branch_name) || return 1
  fi
  if [[ "$branch" == refs/heads/* ]]; then
    echo "$branch"
  else
    echo "refs/heads/$branch"
  fi
}

pg_branch_display() {
  local branch_ref="$1"
  echo "${branch_ref#refs/heads/}"
}

pg_branch_slug() {
  echo "$1" | tr '/: ' '___'
}

pg_shell_quote() {
  local quoted
  printf -v quoted '%q' "$1"
  printf '%s' "$quoted"
}

# Resolve the MAIN repo path even when we're inside a worktree. Worktrees
# report their own toplevel via rev-parse, but share the main repo's common
# .git directory — dirname of that is the main repo root.
pg_main_repo_path() {
  local common main_git
  common=$(pg_git_common_dir 2>/dev/null) || return 1
  case "$common" in
    /*) main_git="$common" ;;
    *)  main_git="$(pg_repo_root)/$common" ;;
  esac
  (cd "$(dirname "$main_git")" 2>/dev/null && pwd)
}

pg_repo_name() {
  local main
  main=$(pg_main_repo_path 2>/dev/null) || main="$(pg_repo_root)"
  basename "$main"
}

pg_has_remote() {
  git remote | grep -qx "$1"
}

pg_branch_upstream_remote() {
  local branch="${1:-}"
  local upstream=""
  [[ -n "$branch" ]] || return 1
  upstream=$(git rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || true)
  if [[ -n "$upstream" && "$upstream" == */* ]]; then
    echo "${upstream%%/*}"
    return 0
  fi
  return 1
}

pg_remote_url() {
  git remote get-url "$1" 2>/dev/null || true
}

pg_remote_repo_spec() {
  local remote="$1"
  local url
  url=$(pg_remote_url "$remote")
  [[ -n "$url" ]] || return 0
  python3 - "$url" <<'PY'
import re, sys

url = sys.argv[1]
patterns = [
    r'^(?:https?|ssh|git)://(?:[^@/]+@)?([^/]+)/([^/]+)/([^/]+?)(?:\.git)?/?$',
    r'^(?:[^@]+@)?([^:]+):([^/]+)/([^/]+?)(?:\.git)?/?$',
]
for pattern in patterns:
    match = re.match(pattern, url)
    if match:
        host, owner, repo = match.groups()
        print(f"{host}/{owner}/{repo}")
        raise SystemExit(0)
print("")
PY
}

pg_remote_viewer_permission() {
  local remote="$1"
  local repo_spec
  repo_spec=$(pg_remote_repo_spec "$remote")
  [[ -n "$repo_spec" ]] || return 0
  gh repo view "$repo_spec" --json viewerPermission 2>/dev/null | jq -r '.viewerPermission // empty' 2>/dev/null || true
}

pg_remote_is_writable() {
  local remote="$1"
  local permission
  permission=$(pg_remote_viewer_permission "$remote")
  case "$permission" in
    ADMIN|MAINTAIN|WRITE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pg_default_pr_repo() {
  local repo_spec remote
  if pg_has_remote upstream; then
    repo_spec=$(pg_remote_repo_spec upstream)
    if [[ -n "$repo_spec" ]]; then
      echo "$repo_spec"
      return 0
    fi
  fi
  if pg_has_remote origin; then
    repo_spec=$(pg_remote_repo_spec origin)
    if [[ -n "$repo_spec" ]]; then
      echo "$repo_spec"
      return 0
    fi
  fi
  remote=$(git remote | head -n1)
  [[ -n "$remote" ]] || return 1
  repo_spec=$(pg_remote_repo_spec "$remote")
  [[ -n "$repo_spec" ]] || return 1
  echo "$repo_spec"
}

pg_default_remote() {
  local branch="${1:-}"
  local branch_ref="" existing_lease="" lease_remote="" upstream_remote="" remote
  if [[ -n "$branch" ]]; then
    branch_ref=$(pg_branch_ref "$branch")
    existing_lease=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
    if [[ -n "$existing_lease" ]]; then
      lease_remote=$(echo "$existing_lease" | jq -r '.remote // empty')
      if [[ -n "$lease_remote" ]]; then
        echo "$lease_remote"
        return 0
      fi
    fi
    upstream_remote=$(pg_branch_upstream_remote "$branch" || true)
    if [[ -n "$upstream_remote" ]]; then
      echo "$upstream_remote"
      return 0
    fi
  else
    branch=$(pg_branch_name || true)
    if [[ -n "$branch" ]]; then
      upstream_remote=$(pg_branch_upstream_remote "$branch" || true)
      if [[ -n "$upstream_remote" ]]; then
        echo "$upstream_remote"
        return 0
      fi
    fi
  fi
  if pg_has_remote upstream && pg_remote_is_writable upstream; then
    echo "upstream"
    return 0
  fi
  if pg_has_remote origin; then
    echo "origin"
    return 0
  fi
  if pg_has_remote upstream; then
    echo "upstream"
    return 0
  fi
  remote=$(git remote | head -n1)
  [[ -n "$remote" ]] || return 1
  echo "$remote"
}

pg_upstream_ref() {
  local branch
  branch=$(pg_branch_name) || return 1
  git rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" 2>/dev/null || true
}

pg_default_base_ref_snapshot() {
  local pr_base upstream remote
  pr_base=$(pg_pr_base_ref_snapshot)
  if [[ -n "$pr_base" ]]; then
    echo "$pr_base"
    return 0
  fi
  upstream=$(pg_upstream_ref)
  if [[ -n "$upstream" ]]; then
    echo "$upstream"
    return 0
  fi
  remote=$(pg_default_remote || true)
  if [[ -n "$remote" ]] && git show-ref --verify --quiet "refs/remotes/$remote/main"; then
    echo "refs/remotes/$remote/main"
    return 0
  fi
  if [[ -n "$remote" ]] && git show-ref --verify --quiet "refs/remotes/$remote/master"; then
    echo "refs/remotes/$remote/master"
    return 0
  fi
  echo ""
}

pg_resolve_pr_base_ref() {
  local base_name="$1" remote="${2:-}"
  [[ -n "$base_name" ]] || return 1
  local candidates=()
  if [[ -n "$remote" ]]; then
    candidates+=("refs/remotes/$remote/$base_name" "$remote/$base_name")
  fi
  candidates+=(
    "$base_name"
    "refs/heads/$base_name"
    "refs/remotes/upstream/$base_name"
    "refs/remotes/origin/$base_name"
  )

  local ref
  for ref in "${candidates[@]}"; do
    if git rev-parse --verify "$ref" >/dev/null 2>&1; then
      echo "$ref"
      return 0
    fi
  done
  return 1
}

pg_pr_base_ref_snapshot() {
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local branch pr_repo raw base_name remote resolved
  branch=$(pg_branch_name 2>/dev/null || true)
  [[ -n "$branch" ]] || return 1
  pr_repo=$(pg_default_pr_repo 2>/dev/null || true)
  if [[ -n "$pr_repo" ]]; then
    raw=$(gh pr list --repo "$pr_repo" --head "$branch" --state open --json number,url,baseRefName 2>/dev/null || true)
  else
    raw=$(gh pr list --head "$branch" --state open --json number,url,baseRefName 2>/dev/null || true)
  fi
  [[ -n "$raw" ]] || return 1
  base_name=$(jq -r '.[0].baseRefName // empty' <<<"$raw" 2>/dev/null || true)
  [[ -n "$base_name" ]] || return 1
  remote=$(pg_default_remote "$branch" 2>/dev/null || true)
  resolved=$(pg_resolve_pr_base_ref "$base_name" "$remote" 2>/dev/null || true)
  [[ -n "$resolved" ]] || return 1
  echo "$resolved"
}

pg_find_pr_json() {
  local branch="$1"
  local pr_repo="${2:-}"
  local raw
  if [[ -n "$pr_repo" ]]; then
    raw=$(gh pr list --repo "$pr_repo" --head "$branch" --state open --json number,url,baseRefName 2>/dev/null || true)
  else
    raw=$(gh pr list --head "$branch" --state open --json number,url,baseRefName 2>/dev/null || true)
  fi
  if [[ -z "$raw" ]]; then
    echo "{}"
    return 0
  fi
  echo "$raw" | jq -c '.[0] // {}'
}

# "N commit(s), M file(s), +X/-Y" — quick size line for intent/assert
# templates. Pluralizes commit/file so "1 commit, 1 file" reads naturally.
pg_default_change_stats() {
  local base_ref count files added removed commit_word file_word
  base_ref=$(pg_default_base_ref_snapshot)
  [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1 || return 0
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  files=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null | grep -c . || echo 0)
  read -r added removed < <(git diff --numstat "$base_ref"..HEAD 2>/dev/null \
    | awk 'BEGIN{a=0;r=0} {a+=$1; r+=$2} END{print a" "r}')
  [[ "$count" -eq 1 ]] && commit_word=commit || commit_word=commits
  [[ "$files" -eq 1 ]] && file_word=file   || file_word=files
  printf '%s %s, %s %s, +%s/-%s\n' "$count" "$commit_word" "$files" "$file_word" "${added:-0}" "${removed:-0}"
}

# Categorize changed paths by shape. Returns a single line like:
#   "tests:6, locks:4, build:1, docs:1, prod:0"
# Production = anything not matching the other rules. An agent can be
# asked to affirm "prod:0" as a falsifiable claim.
pg_default_path_categories() {
  local base_ref
  base_ref=$(pg_default_base_ref_snapshot)
  [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1 || return 0
  git diff --name-only "$base_ref"..HEAD 2>/dev/null | awk '
    BEGIN { tests=0; locks=0; build=0; docs=0; prod=0 }
    {
      p = tolower($0)
      if (p ~ /(^|\/)(tests?|src\/test)\// || p ~ /\.test\./ || p ~ /_test\./ || p ~ /test_[^\/]+\.py$/) { tests++; next }
      if (p ~ /\.lock$/ || p ~ /(^|\/)(package-lock|yarn\.lock|pnpm-lock|poetry\.lock|cargo\.lock|gemfile\.lock)$/) { locks++; next }
      if (p ~ /(^|\/)(build\.gradle|pom\.xml|cargo\.toml|pyproject\.toml|package\.json|go\.mod|makefile|dockerfile)/ || p ~ /\.gradle$/) { build++; next }
      if (p ~ /\.(md|rst|adoc|txt)$/ || p ~ /(^|\/)(readme|changelog|license|notice)(\.|$)/) { docs++; next }
      prod++
    }
    END {
      parts = ""
      if (tests > 0) parts = parts (parts ? ", " : "") "tests:" tests
      if (locks > 0) parts = parts (parts ? ", " : "") "locks:" locks
      if (build > 0) parts = parts (parts ? ", " : "") "build:" build
      if (docs  > 0) parts = parts (parts ? ", " : "") "docs:" docs
      parts = parts (parts ? ", " : "") "prod:" prod
      print parts
    }
  '
}

# Path to a prefill file written by `pg prepare` before approval.
# Scoped by (repo, branch) so multiple branches can have concurrent
# prepares without stepping on each other.
pg_prepare_path() {
  local repo_name branch
  repo_name=$(pg_repo_name)
  branch=$(pg_branch_name 2>/dev/null || echo "unknown")
  printf '/tmp/pg-prepare-%s-%s.json' \
    "$(pg_branch_slug "$repo_name")" "$(pg_branch_slug "$branch")"
}

# pg prepare — agent's handoff. Captures rationale (what/why/approach)
# from the agent that actually did the work, so the user's approval
# draft reflects real context instead of LLM inference from commits.
# Required before `pg` will produce a draft (see pg_cmd_draft_approve).
pg_cmd_prepare() {
  local what="" why="" approach="" scope="" risks="" beads=""
  local async_enabled="false" async_expires="" async_max_pushes="" async_allow_rewrite="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --what)     what="$2"; shift 2 ;;
      --why)      why="$2"; shift 2 ;;
      --approach) approach="$2"; shift 2 ;;
      --scope)    scope="$2"; shift 2 ;;
      --risks)    risks="$2"; shift 2 ;;
      --beads)    beads="$2"; shift 2 ;;
      --low-stakes)
        async_enabled="true"
        [[ -n "$async_expires" ]] || async_expires="1h"
        [[ -n "$async_max_pushes" ]] || async_max_pushes="5"
        shift
        ;;
      --async)    async_enabled="true"; shift ;;
      --expires)  async_expires="$2"; shift 2 ;;
      --max-pushes) async_max_pushes="$2"; shift 2 ;;
      --allow-rewrite) async_allow_rewrite="true"; shift ;;
      *) pg_fail "Unknown prepare option: $1"; return 1 ;;
    esac
  done

  # Required fields — agents must state these explicitly. Empty or
  # placeholder-ish values get rejected here rather than leaking into
  # a draft.
  local missing=()
  [[ -z "$what" || "$what" == "<"* ]]         && missing+=("--what")
  [[ -z "$why" || "$why" == "<"* ]]           && missing+=("--why")
  [[ -z "$approach" || "$approach" == "<"* ]] && missing+=("--approach")
  if [[ ${#missing[@]} -gt 0 ]]; then
    local m
    local msg="pg prepare requires --what, --why, and --approach."
    msg+=$'\n'"Missing or placeholder-only:"
    for m in "${missing[@]}"; do msg+=$'\n'"  - $m"; done
    msg+=$'\n\nExample:'
    msg+=$'\n'"  pg prepare \\"
    msg+=$'\n'"    --what 'add LZ4 chunked-value repro test' \\"
    msg+=$'\n'"    --why 'reproduce size-mismatch bug from prod sync job' \\"
    msg+=$'\n'"    --approach 'standalone test + hex fixtures; no prod code changes' \\"
    msg+=$'\n'"    --risks 'dependencies.lock churn from LZ4 bump'"
    pg_fail "$msg"
    return 1
  fi

  local repo_root branch head_sha path
  repo_root=$(pg_repo_root) || { pg_fail "not in a git repo"; return 1; }
  branch=$(pg_branch_name 2>/dev/null) || { pg_fail "not on a branch"; return 1; }
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  path=$(pg_prepare_path)
  local async_json
  async_json=$(pg_async_request_json "$async_enabled" "branch" "${async_expires:-8h}" "${async_max_pushes:-20}" "$async_allow_rewrite") || return 1

  jq -n \
    --arg repo_root "$repo_root" \
    --arg branch "$branch" \
    --arg what "$what" \
    --arg why "$why" \
    --arg approach "$approach" \
    --arg scope "$scope" \
    --arg risks "$risks" \
    --arg beads "$beads" \
    --arg head "$head_sha" \
    --arg at "$(pg_now_utc)" \
    --argjson async_iteration "$async_json" \
    '{
      repo_root: $repo_root,
      branch: $branch,
      what: $what,
      why: $why,
      approach: $approach,
      scope: (if $scope == "" then null else $scope end),
      risks: (if $risks == "" then null else $risks end),
      beads: (if $beads == "" then [] else ($beads | split(",") | map(. | ascii_downcase | gsub("^ +| +$"; ""))) end),
      prepared_at: $at,
      prepared_at_head: $head,
      async_iteration: $async_iteration
    }' > "$path"

  echo "Prepared brief written: $path"
  echo "Now ask the user to run:  pg -C $repo_root    (or just 'pg' if they're cd'd in)"
}

# Run a structured semantic interview against codex. Returns YAML with
# fields: what, why, approach, scope, risks. Caller parses with yq.
# Empty output on any failure — caller falls back to simpler template.
pg_semantic_brief() {
  command -v codex >/dev/null 2>&1 || return 0
  [[ "${PG_USE_LLM:-1}" == "1" ]] || return 0

  local base_ref commits shortstat branch
  base_ref=$(pg_default_base_ref_snapshot)
  [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1 || return 0
  commits=$(git log "$base_ref"..HEAD --format='%h %s%n%b' 2>/dev/null | head -200)
  [[ -n "$commits" ]] || return 0
  shortstat=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | sed 's/^ *//')
  branch=$(pg_branch_name 2>/dev/null || echo "")

  local tmp timeout_cmd=()
  tmp=$(mktemp -t pg-brief) || return 0
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=(gtimeout 20)
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout 20)
  fi

  local prompt
  prompt=$(cat <<EOF
You are interviewing a developer about a git branch they want to push.
Produce a structured brief by reading ONLY the commits and diff stat
below. Do not invent facts.

Branch: $branch
Diff: $shortstat

Commits (subject + body):
$commits

Output EXACTLY this YAML, with each value on ONE line, under 15 words.
Use "unstated" for why if no motivation is given. Use "straightforward"
for approach if no strategy is apparent. Use "none apparent" for risks
if you cannot identify any. Do not include code fences or preamble.

what: <one line: what changes>
why: <one line: motivating reason, or "unstated">
approach: <one line: strategy/trade-off, or "straightforward">
scope: <one of: tests, prod, docs, deps, config, mixed>
risks: <one line, or "none apparent">
EOF
)

  NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 "${timeout_cmd[@]:+${timeout_cmd[@]}}" codex exec \
    -m gpt-5-nano \
    -c model_reasoning_effort='"low"' \
    --output-last-message "$tmp" \
    "$prompt" </dev/null >/dev/null 2>&1
  local rc=$?

  local brief=""
  if [[ "$rc" -eq 0 && -s "$tmp" ]]; then
    # Keep only the five known lines to strip any stray prose.
    brief=$(awk '/^(what|why|approach|scope|risks):/ {print}' "$tmp")
  fi
  rm -f "$tmp"
  printf '%s' "$brief"
}

# Best-effort multi-bullet summary of what's on this branch since the
# base. Called ONCE by pg_cmd_draft_approve and passed down to both
# default-template functions — no caching needed.
#
# If `codex` is on PATH (Netflix gateway auth via user's config.toml),
# asks gpt-5-nano at low reasoning effort for 2-3 short imperative
# bullets. Falls back to first-subject heuristic on any failure.
# Opt out with PG_USE_LLM=0. PG_DEBUG=1 logs decisions to stderr.
pg_default_change_summary() {
  local base_ref count first_subject commits tmp summary
  base_ref=$(pg_default_base_ref_snapshot)
  [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1 || {
    [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_default_change_summary: no base ref" >&2
    printf 'describe change here\n'
    return 0
  }
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  commits=$(git log "$base_ref"..HEAD --reverse --format='%s' 2>/dev/null)
  first_subject=$(printf '%s\n' "$commits" | head -1)

  if [[ -z "$first_subject" ]]; then
    [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_default_change_summary: no new commits" >&2
    printf 'no new commits\n'
    return 0
  fi

  # Short-circuit for a single commit: the LLM would just paraphrase the
  # one subject we already have. Print it verbatim and save ~7s.
  if [[ "$count" -le 1 ]]; then
    [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_default_change_summary: single-commit fast path" >&2
    printf '%s\n' "$first_subject"
    return 0
  fi

  if [[ "${PG_USE_LLM:-1}" == "1" ]] \
     && command -v codex >/dev/null 2>&1 \
     && [[ -n "$commits" ]]; then
    [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_default_change_summary: calling codex ($count commits)" >&2
    tmp=$(mktemp -t pg-summary) || tmp=""
    if [[ -n "$tmp" ]]; then
      local timeout_cmd=()
      if command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd=(gtimeout 15)
      elif command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout 15)
      fi
      local codex_err
      codex_err=$(mktemp -t pg-summary-err) || codex_err=/dev/null
      # Use :+ expansion so `set -u` doesn't trip on an empty array.
      NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 "${timeout_cmd[@]:+${timeout_cmd[@]}}" codex exec \
        -m gpt-5-nano \
        -c model_reasoning_effort='"low"' \
        --output-last-message "$tmp" \
        "Summarize the following commit subjects from one branch into 2-3 concise bullets (each <= 12 words, imperative voice). Group related commits. Output ONLY the bullets, one per line starting with '- ', no preamble, no markdown code fences:

$commits" </dev/null >/dev/null 2>"$codex_err"
      local rc=$?
      summary=$(awk 'NF{buf = buf ? buf "\n" $0 : $0} END{print buf}' "$tmp" 2>/dev/null)
      if [[ "${PG_DEBUG:-0}" == "1" ]]; then
        echo "pg_default_change_summary: codex rc=$rc, $(wc -c < "$tmp" 2>/dev/null || echo 0) bytes out" >&2
        [[ -s "$codex_err" ]] && { echo "pg_default_change_summary: codex stderr:" >&2; sed 's/^/  /' "$codex_err" >&2; }
      fi
      rm -f "$tmp" "$codex_err"
      if [[ "$rc" -eq 0 && -n "$summary" ]]; then
        printf '%s\n' "$summary"
        return 0
      fi
    fi
  else
    [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_default_change_summary: LLM skipped (PG_USE_LLM=${PG_USE_LLM:-1}, codex present=$(command -v codex >/dev/null 2>&1 && echo yes || echo no))" >&2
  fi

  # Fallback: first subject + "(+N more)".
  if [[ "$count" -le 1 ]]; then
    printf '%s\n' "$first_subject"
  else
    printf '%s (+%d more)\n' "$first_subject" "$((count - 1))"
  fi
}

# Attempt to auto-detect bead references from commit subjects/bodies on
# this branch. Looks for tokens like "bead-xxx", "[bead-xxx]", "fba-123",
# "dump-64q" — alphanumeric-slug ids used by the beads tracker. Returns
# one id per line, deduped.
pg_detect_beads() {
  local base_ref commits
  base_ref=$(pg_default_base_ref_snapshot)
  [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1 || return 0
  commits=$(git log "$base_ref"..HEAD --format='%s%n%b' 2>/dev/null)
  # Also include branch name in the scan
  commits="$commits
$(git branch --show-current 2>/dev/null)"
  printf '%s\n' "$commits" \
    | grep -oE '\b[a-z][a-z0-9-]*-[a-z0-9]{2,}\b' \
    | grep -v -E '^(git|no|yes|pr)-' \
    | awk '!seen[$0]++' \
    || true
}

# Fetch bead metadata as a readable block. Empty if bd is unavailable
# or no beads are supplied.
pg_fetch_bead_context() {
  command -v bd >/dev/null 2>&1 || return 0
  local beads="$1"
  [[ -n "$beads" ]] || return 0
  local out="" id json title notes status
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    json=$(bd show "$id" --json 2>/dev/null) || continue
    [[ -n "$json" && "$json" != "null" && "$json" != "[]" ]] || continue
    title=$(echo "$json" | jq -r '.[0].title // .title // empty' 2>/dev/null)
    notes=$(echo "$json" | jq -r '.[0].notes // .notes // empty' 2>/dev/null)
    status=$(echo "$json" | jq -r '.[0].status // .status // empty' 2>/dev/null)
    [[ -z "$title" ]] && continue
    out="$out${out:+$'\n'}${id} [${status:-unknown}] ${title}"
    if [[ -n "$notes" && "$notes" != "null" ]]; then
      # Trim to ~200 chars so a verbose bead doesn't blow up the prompt
      out="$out"$'\n'"  "$(printf '%s' "$notes" | tr '\n' ' ' | cut -c1-200)
    fi
  done <<< "$beads"
  printf '%s' "$out"
}

# user_intent is a semantic contract the LLM will evaluate strictly.
# Brief fields (what/why/approach/scope/risks) come from the LLM
# interview in pg_semantic_brief; caller extracts them and passes down.
pg_default_user_intent() {
  local branch="$1" pr_number="$2" beads_block="$3"
  local what="$4" why="$5" approach="$6" scope="$7" risks="$8"
  local target_line="new pr (unbound)"
  [[ -n "$pr_number" ]] && target_line="PR #$pr_number"

  cat <<EOF
Branch: $branch → $target_line

APPROVED CHANGE:
  · what:     ${what:-<describe what changes>}
  · why:      ${why:-<fill in: motivating bug/ask/ticket>}
  · approach: ${approach:-<fill in: architectural strategy or trade-offs>}
  · scope:    ${scope:-<tests, prod, docs, deps, config, mixed>}
  · risks:    ${risks:-<none apparent>}

RELATED BEADS:
${beads_block:-  · (none detected — add bead IDs here to ground the semantic check)}

DENIED:
  · any file outside approved_scope.paths
  · any commit not aligned with APPROVED CHANGE above
  · any new dependency not named in APPROVED CHANGE
  · any behavior change beyond APPROVED CHANGE

LIMITS: see approved_scope (paths · subjects · max_commits · max_added_lines)
EOF
}

# agent_assertion_template: terse checklist the agent types back. Each
# line is a falsifiable affirmation. LLM cross-checks against the diff.
pg_default_assert_flow() {
  local branch="$1" pr_number="$2" beads_block="$3"
  local what="$4" why="$5" approach="$6" scope="$7" risks="$8"
  local target_line="create new PR"
  [[ -n "$pr_number" ]] && target_line="update PR #$pr_number"

  cat <<EOF
Branch: $branch → $target_line

Agent affirms ALL:
  · every new commit furthers: ${what:-<the APPROVED CHANGE>}
  · no drift from why: ${why:-<stated reason>}
  · no drift from approach: ${approach:-<stated approach>}
  · no file outside approved_scope.paths
  · no new dependency beyond those in APPROVED CHANGE
  · no history rewrite
EOF
}

pg_lease_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/leases/$branch_ref.json"
}

pg_pending_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/pending/$branch_ref.json"
}

pg_log_path_for_ref() {
  local branch_ref="$1"
  echo "$(pg_store_dir)/logs/$branch_ref.jsonl"
}

pg_ensure_parent_dir() {
  mkdir -p "$(dirname "$1")"
}

pg_render_lease_summary() {
  local file="$1"
  jq -r '
    def desc: .description // {
      summary: .brief.what,
      motivation: .brief.why,
      approach: .brief.approach,
      scope: .brief.scope,
      risks: .brief.risks,
      testing: null
    };
    "Push lease approval",
    "",
    "Repo: " + .repo_name,
    "Branch: " + .branch_name,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Remote: " + .remote,
    "Anchor: " + .approved_anchor,
    (if (.async_iteration.enabled // false) then
      "Async iteration: enabled"
      + "\n  Expires: " + ((.async_iteration.expires_at // .async_iteration.expires // "") | tostring)
      + "\n  Pushes: " + ((.async_iteration.used_pushes // 0) | tostring) + "/" + ((.async_iteration.max_pushes // 0) | tostring)
      + "\n  Rewrite: " + (if (.async_iteration.allow_rewrite // false) then "allowed" else "denied" end)
    else
      "Async iteration: disabled"
    end),
    "",
    "Description:",
    "  Summary: " + (desc.summary // ""),
    "  Motivation: " + (desc.motivation // ""),
    "  Approach: " + (desc.approach // ""),
    (if ((desc.scope // "") != "") then "  Scope: " + (desc.scope | tostring) else empty end),
    (if ((desc.risks // "") != "") then "  Risks: " + (desc.risks | tostring) else empty end),
    (if ((desc.testing // "") != "") then "  Testing: " + (desc.testing | tostring) else empty end),
    "",
    "User intent:",
    (.user_intent // ""),
    "",
    "Agent says push is:",
    (.agent_assertion_template // ""),
    "",
    (if (.approved_scope // null) == null then "Approved scope: (none — single-push anchor-exact lease)" else
      "Approved scope:\n  base_ref:        " + (.approved_scope.base_ref // "") +
      "\n  paths:           " + ((.approved_scope.paths // []) | join(", ")) +
      "\n  subjects:        " + ((.approved_scope.subjects // []) | join(", ")) +
      "\n  max_commits:     " + ((.approved_scope.max_commits // 0) | tostring) +
      "\n  max_added_lines: " + ((.approved_scope.max_added_lines // 0) | tostring)
    end)
  ' "$file"
}

pg_migration_help() {
  cat <<'EOF'
Durable leases replaced minute windows.
Use `pg` or `push-gate` with no numeric argument to generate an approval draft.
Example:
  pg
  pg push --assert-flow $'update pr #123\nbranch mho/example\nno rewrite'
EOF
}

pg_parse_common_flag() {
  local arg="$1"
  [[ "$arg" =~ ^[0-9]+$ ]]
}

pg_parse_push_command() {
  local command="$1"
  python3 - "$command" <<'PY'
import json, shlex, sys

cmd = sys.argv[1]
result = {
    "is_push": False,
    "remote": None,
    "source_ref": None,
    "target_branch": None,
    "force_with_lease": False,
    "is_delete": False,
}
try:
    tokens = shlex.split(cmd)
except Exception as exc:
    result["error"] = f"Unable to parse git push command: {exc}"
    print(json.dumps(result))
    raise SystemExit(0)

git_idx = None
for i, token in enumerate(tokens):
    if token == "git":
        git_idx = i
        break
if git_idx is None or git_idx + 1 >= len(tokens) or tokens[git_idx + 1] != "push":
    print(json.dumps(result))
    raise SystemExit(0)

result["is_push"] = True
args = tokens[git_idx + 2 :]
remote = None
refspecs = []
skip_next = False
for i, token in enumerate(args):
    if skip_next:
        skip_next = False
        continue
    if token == "--":
        refspecs.extend(args[i + 1 :])
        break
    if token.startswith("-"):
        if token == "--force-with-lease":
            result["force_with_lease"] = True
        if token in {"--delete", "-d"}:
            result["is_delete"] = True
        if token in {"--repo"}:
            skip_next = True
        continue
    if remote is None:
        remote = token
    else:
        refspecs.append(token)

source_ref = None
target_branch = None
if refspecs:
    refspec = refspecs[0]
    if ":" in refspec:
      source_ref, target_branch = refspec.split(":", 1)
    else:
      source_ref = refspec
      target_branch = refspec
    if source_ref == "":
      source_ref = None
      # `:branch` colon-syntax means delete; mark for downstream skips.
      if target_branch:
        result["is_delete"] = True
    if target_branch == "HEAD" or target_branch == "":
      target_branch = None
    if source_ref and source_ref.startswith("refs/heads/"):
      source_ref = source_ref[len("refs/heads/"):]
    if target_branch and target_branch.startswith("refs/heads/"):
      target_branch = target_branch[len("refs/heads/"):]

result["remote"] = remote
result["source_ref"] = source_ref
result["target_branch"] = target_branch
print(json.dumps(result))
PY
}

pg_load_lease_for_ref() {
  local branch_ref="$1"
  local path
  path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$path" ]] || return 1
  cat "$path"
}

pg_pr_json_for_branch() {
  local branch="$1"
  local pr_repo="${2:-}"
  [[ -n "$branch" ]] || return 1
  pg_find_pr_json "$branch" "$pr_repo"
}

pg_validate_pr_binding() {
  local branch_ref="$1"
  local lease_json="$2"
  local branch_name pr_mode pr_repo expected_number expected_url actual_pr actual_number actual_url
  branch_name=$(pg_branch_display "$branch_ref")
  pr_mode=$(echo "$lease_json" | jq -r '.pr_mode')
  [[ "$pr_mode" == "bound" ]] || return 0
  pr_repo=$(echo "$lease_json" | jq -r '.pr_repo // empty')
  expected_number=$(echo "$lease_json" | jq -r '.pr_number // empty')
  expected_url=$(echo "$lease_json" | jq -r '.pr_url // empty')
  actual_pr=$(pg_pr_json_for_branch "$branch_name" "$pr_repo")
  actual_number=$(echo "$actual_pr" | jq -r '.number // empty')
  actual_url=$(echo "$actual_pr" | jq -r '.url // empty')
  if [[ -z "$actual_number" ]]; then
    pg_fail "Blocked: bound lease expects PR #$expected_number for $branch_name${pr_repo:+ in $pr_repo}, but no open PR was found. Run: pg bind-pr --auto or create a new lease."
    return 1
  fi
  if [[ -n "$expected_number" && "$expected_number" != "$actual_number" ]]; then
    pg_fail "Blocked: lease for $branch_name is bound to PR #$expected_number, but that branch now maps to PR #$actual_number. Rebind PR metadata or create a new lease."
    return 1
  fi
  if [[ -n "$expected_url" && -n "$actual_url" && "$expected_url" != "$actual_url" ]]; then
    pg_fail "Blocked: lease for $branch_name is bound to $expected_url, but that branch now maps to $actual_url. Rebind PR metadata or create a new lease."
    return 1
  fi
}

# Auto-detect a "scope" fingerprint from the current branch state relative to
# the base ref. Produces a JSON object the user can edit at approval time.
#   paths:             changed file paths as globs (literal path = glob)
#   subjects:          keyword hints from commit subjects (lowercased, tokenized)
#   max_commits:       current commit count + buffer
#   max_added_lines:   current added-line count * 1.5 + 200
# Emits "null" if no base ref is available.
pg_detect_scope() {
  local base_ref paths subjects count added buffer_commits buffer_lines
  base_ref=$(pg_default_base_ref_snapshot)
  if [[ -z "$base_ref" ]] || ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "null"
    return 0
  fi
  paths=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0))')
  subjects=$(git log --format='%s' "$base_ref"..HEAD 2>/dev/null \
    | tr 'A-Z' 'a-z' \
    | tr -c 'a-z0-9' '\n' \
    | awk 'length($0) >= 3' \
    | grep -vE '^(the|and|for|fix|add|use|new|ref|feat|chore|docs|test|into|from|with|this|that|when|where|why|how|what|also|not|but|all|any|can|did|does|has|have|had|was|were|been|being|make|made|set|get|run|put)$' \
    | sort -u \
    | jq -Rsc 'split("\n") | map(select(length > 0))')
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  added=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+' || echo 0)
  [[ -z "$added" ]] && added=0
  buffer_commits=$(( count + 3 ))
  buffer_lines=$(( added * 3 / 2 + 200 ))
  jq -n \
    --arg base "$base_ref" \
    --argjson paths "${paths:-[]}" \
    --argjson subjects "${subjects:-[]}" \
    --argjson max_commits "$buffer_commits" \
    --argjson max_added_lines "$buffer_lines" \
    '{base_ref: $base, paths: $paths, subjects: $subjects, max_commits: $max_commits, max_added_lines: $max_added_lines}'
}

# Ask an LLM whether commits new since the last push semantically
# match the user-approved intent. Re-pushes of already-published
# commits are instant-MATCH (nothing new to check). New commits that
# drift from APPROVED / hit DENIED → MISMATCH.
pg_validate_intent_match() {
  local lease_json="$1"
  local intent commits shortstat base_ref remote branch
  local since_ref since_label

  intent=$(echo "$lease_json" | jq -r '.user_intent // ""')
  if [[ -z "$intent" ]]; then
    jq -n '{allowed:true, verdict:"skip", reason:"lease has no user_intent"}'
    return 0
  fi

  base_ref=$(echo "$lease_json" | jq -r '.base_ref_snapshot // empty')
  if [[ -z "$base_ref" ]] || ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    jq -n '{allowed:true, verdict:"skip", reason:"base_ref unavailable"}'
    return 0
  fi

  # Check only commits NEW since last push: remote/branch..HEAD if the
  # remote tip exists; otherwise fall back to the approval base.
  remote=$(echo "$lease_json" | jq -r '.remote // "origin"')
  branch=$(echo "$lease_json" | jq -r '.branch_name // ""')
  if [[ -n "$branch" ]] && git rev-parse --verify "refs/remotes/$remote/$branch" >/dev/null 2>&1; then
    since_ref="refs/remotes/$remote/$branch"
    since_label="$remote/$branch"
  else
    since_ref="$base_ref"
    since_label="$base_ref (first push)"
  fi

  # For force-pushes after the approved base has advanced, remote/branch..HEAD
  # can include commits that are already on the approved base (for example a
  # mainline commit picked up by rebasing a PR branch). Those commits are not
  # new branch work and should not be judged against the PR's intent.
  commits=$(git log "$since_ref"..HEAD --not "$base_ref" --format='%h %s' 2>/dev/null)
  if [[ -z "$commits" ]]; then
    # No new commits since last push → trivial re-push, nothing to verify.
    jq -n '{allowed:true, verdict:"no-new-commits", reason:"no new commits since last push"}'
    return 0
  fi
  shortstat=$(git diff --shortstat "$since_ref"..HEAD 2>/dev/null | sed 's/^ *//')
  [[ -n "$shortstat" ]] || shortstat="no diff"

  if ! command -v codex >/dev/null 2>&1; then
    jq -n --arg r "codex not on PATH; semantic intent check cannot run. Re-run pg with updated intent or install codex." \
      '{allowed:false, verdict:"unavailable", reason:$r}'
    return 0
  fi

  local tmp codex_err timeout_cmd=()
  tmp=$(mktemp -t pg-intent) || { jq -n '{allowed:false, verdict:"error", reason:"mktemp failed"}'; return 0; }
  codex_err=$(mktemp -t pg-intent-err) || codex_err=/dev/null
  if command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=(gtimeout 20)
  elif command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout 20)
  fi

  local prompt
  prompt=$(cat <<EOF
A user pre-approved a git push with this contract. Read the APPROVED
CHANGE (what, why, approach), RELATED BEADS (linked tracker items
describing motivation and prior context), and DENIED (what must not
appear). Anything not clearly consistent with APPROVED is denied.

<contract>
$intent
</contract>

The following commits are NEW on the branch since $since_label (the
last push point, or the base if this is the first push). These are
the ONLY commits to evaluate — already-pushed commits are out of scope.

<new_commits>
$commits
</new_commits>

Task: decide if EVERY new commit is semantically consistent with the
APPROVED CHANGE in the contract — the what, the why, and the approach.

Rules:
- Respond with EXACTLY one line.
- Start with MATCH: or MISMATCH: (uppercase, colon).
- Follow with a brief rationale under 20 words.
- Be HOSTILE BY DEFAULT. Ambiguity → MISMATCH.
- MATCH when every new commit plainly furthers the APPROVED CHANGE and
  coheres with the stated why / approach / linked beads.
- MISMATCH when ANY new commit:
    · adds scope the user did not describe (new feature, refactor,
      cleanup) even if plausible-sounding
    · diverges from the approach (e.g. different algorithm than stated)
    · introduces new dependencies not named in APPROVED
    · touches production code when the approved work is test-only
    · is off-topic from the linked beads
- If unsure, choose MISMATCH and name the offending commit.
EOF
)

  NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 "${timeout_cmd[@]:+${timeout_cmd[@]}}" codex exec \
    -m gpt-5-nano \
    -c model_reasoning_effort='"low"' \
    --output-last-message "$tmp" \
    "$prompt" </dev/null >/dev/null 2>"$codex_err"
  local rc=$?

  local response reason
  response=$(awk 'NF{print; exit}' "$tmp" 2>/dev/null)
  if [[ "${PG_DEBUG:-0}" == "1" ]]; then
    echo "pg_validate_intent_match: rc=$rc, response: $response" >&2
    [[ -s "$codex_err" ]] && sed 's/^/  /' "$codex_err" >&2
  fi
  rm -f "$tmp" "$codex_err"

  if [[ "$rc" -ne 0 || -z "$response" ]]; then
    jq -n --arg r "semantic intent check failed to run (codex rc=$rc). Retry or re-run pg with updated intent." \
      '{allowed:false, verdict:"error", reason:$r}'
    return 0
  fi

  case "$response" in
    MATCH:*)
      reason=${response#MATCH: }
      jq -n --arg r "$reason" '{allowed:true, verdict:"match", reason:$r}'
      ;;
    MISMATCH:*)
      reason=${response#MISMATCH: }
      jq -n --arg r "$reason" \
        '{allowed:false, verdict:"mismatch", reason:("Blocked: branch diverges from approved intent - " + $r + ". Re-run pg to re-approve, or adjust the branch.")}'
      ;;
    *)
      jq -n --arg r "$response" \
        '{allowed:false, verdict:"unparseable", reason:("semantic intent check returned unparseable response: " + $r)}'
      ;;
  esac
}

# Validate that the current HEAD diff against lease's base_ref stays within
# the approved scope. Emits {allowed, reason}.
pg_validate_scope() {
  local lease_json="$1"
  local scope base_ref paths subjects max_commits max_added
  local changed_files count added

  scope=$(echo "$lease_json" | jq -c '.approved_scope // null')
  if [[ "$scope" == "null" ]]; then
    jq -n '{allowed:true}'
    return 0
  fi

  base_ref=$(echo "$scope" | jq -r '.base_ref // empty')
  if [[ -z "$base_ref" ]] || ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    jq -n '{allowed:true, note: "scope base_ref unavailable, skipping scope check"}'
    return 0
  fi

  # Paths allowlist
  changed_files=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null)
  local allow_paths_json allow_paths_count
  allow_paths_json=$(echo "$scope" | jq -c '.paths // []')
  allow_paths_count=$(echo "$allow_paths_json" | jq 'length')
  if [[ "$allow_paths_count" -gt 0 ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      local ok="false" pat
      while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2053
        if [[ "$f" == $pat ]] || [[ "$f" == "$pat" ]]; then
          ok="true"
          break
        fi
      done < <(echo "$allow_paths_json" | jq -r '.[]')
      if [[ "$ok" != "true" ]]; then
        jq -n --arg file "$f" '{allowed:false, reason:("Blocked: file \($file) is outside approved_scope.paths. Re-run pg prepare and ask the user to review.")}'
        return 0
      fi
    done <<<"$changed_files"
  fi

  # Commit cap
  count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
  max_commits=$(echo "$scope" | jq -r '.max_commits // 0')
  if [[ "$max_commits" -gt 0 && "$count" -gt "$max_commits" ]]; then
    jq -n --arg count "$count" --arg cap "$max_commits" '{allowed:false, reason:("Blocked: \($count) commits since base exceeds approved_scope.max_commits (\($cap)). Re-run `pg`.")}'
    return 0
  fi

  # Added-line cap
  added=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+')
  [[ -z "$added" ]] && added=0
  max_added=$(echo "$scope" | jq -r '.max_added_lines // 0')
  if [[ "$max_added" -gt 0 && "$added" -gt "$max_added" ]]; then
    jq -n --arg a "$added" --arg cap "$max_added" '{allowed:false, reason:("Blocked: \($a) added lines since base exceeds approved_scope.max_added_lines (\($cap)). Re-run `pg`.")}'
    return 0
  fi

  # Subject keyword match (every new commit must hit ≥1 approved keyword)
  local subj_count subj_list
  subj_list=$(echo "$scope" | jq -r '.subjects // [] | .[]')
  subj_count=$(echo "$scope" | jq -r '.subjects // [] | length')
  if [[ "$subj_count" -gt 0 ]]; then
    local subjects_lc
    subjects_lc=$(git log --format='%s' "$base_ref"..HEAD 2>/dev/null | tr 'A-Z' 'a-z')
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      local hit="false" kw
      while IFS= read -r kw; do
        [[ -z "$kw" ]] && continue
        if [[ "$s" == *"$kw"* ]]; then
          hit="true"
          break
        fi
      done <<<"$subj_list"
      if [[ "$hit" != "true" ]]; then
        jq -n --arg s "$s" '{allowed:false, reason:("Blocked: commit subject \"\($s)\" does not match any keyword in approved_scope.subjects. Re-run `pg` if this is intended scope expansion.")}'
        return 0
      fi
    done <<<"$subjects_lc"
  fi

  jq -n '{allowed:true}'
}

pg_validate_branch_lease_state() {
  local lease_json="$1" branch_ref="$2" remote="$3" current_head="$4"
  local lease_status lease_remote approved_anchor has_scope async_json async_status async_enabled async_block async_allow_rewrite
  local scope_result scope_allowed scope_reason

  lease_status=$(echo "$lease_json" | jq -r '.status // "active"')
  lease_remote=$(echo "$lease_json" | jq -r '.remote // ""')
  approved_anchor=$(echo "$lease_json" | jq -r '.approved_anchor // ""')
  async_json=$(echo "$lease_json" | jq -c '.async_iteration // {enabled:false}')
  async_status=$(pg_async_status_json "$async_json")
  async_enabled=$(echo "$async_status" | jq -r '.enabled')
  async_block=$(echo "$async_status" | jq -r '.block_reason // ""')
  async_allow_rewrite=$(echo "$async_status" | jq -r '.allow_rewrite // false')

  if [[ "$lease_status" != "active" ]]; then
    jq -n --arg reason "Blocked: push lease for $(pg_branch_display "$branch_ref") is not active. Run pg prepare and ask the user to review." \
      --argjson async_iteration "$async_status" \
      '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
    return 0
  fi
  if [[ -n "$remote" && -n "$lease_remote" && "$lease_remote" != "$remote" ]]; then
    jq -n --arg reason "Blocked: lease for $(pg_branch_display "$branch_ref") is scoped to remote '$lease_remote', but push targets '$remote'. Re-run pg prepare for the target remote or use the leased remote." \
      --argjson async_iteration "$async_status" \
      '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
    return 0
  fi

  if [[ "$async_enabled" == "true" && -n "$async_block" ]]; then
    jq -n --arg reason "Blocked: $async_block" --argjson async_iteration "$async_status" \
      '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
    return 0
  fi

  if [[ "$current_head" != "$approved_anchor" ]]; then
    if [[ "$async_enabled" != "true" ]]; then
      jq -n --arg reason "Blocked: HEAD changed after approval (lease anchor $approved_anchor, HEAD $current_head). Re-run pg prepare --async and ask the user to review for iterative pushes." \
        --argjson async_iteration "$async_status" \
        '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
      return 0
    fi
    if ! git merge-base --is-ancestor "$approved_anchor" "$current_head" 2>/dev/null; then
      if [[ "$async_allow_rewrite" != "true" ]]; then
        jq -n --arg reason "Blocked: branch history was rewritten after lease anchor $approved_anchor, but async rewrite was not approved. Re-run pg prepare --async --allow-rewrite and ask the user to review." \
          --argjson async_iteration "$async_status" \
          '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
        return 0
      fi
    fi
  fi

  has_scope=$(echo "$lease_json" | jq -r '.approved_scope // empty | if . == null or . == {} then "" else "1" end')
  if [[ -n "$has_scope" ]]; then
    scope_result=$(pg_validate_scope "$lease_json")
    scope_allowed=$(echo "$scope_result" | jq -r '.allowed')
    if [[ "$scope_allowed" != "true" ]]; then
      scope_reason=$(echo "$scope_result" | jq -r '.reason')
      jq -n --arg reason "$scope_reason" --argjson async_iteration "$async_status" \
        '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
      return 0
    fi
  fi

  jq -n --argjson async_iteration "$async_status" '{allowed:true, async_iteration:$async_iteration}'
}

pg_validate_push_guard() {
  local command="$1"
  local parsed is_push remote source_ref target_branch force_with_lease current_branch lease_branch branch_ref current_head
  local lease_json lease_remote lease_status approved_anchor pending_path pending_json pending_remote pending_head pending_branch_ref
  local branch_upstream

  parsed=$(pg_parse_push_command "$command")
  is_push=$(echo "$parsed" | jq -r '.is_push')
  [[ "$is_push" == "true" ]] || {
    jq -n '{allowed:true}'
    return 0
  }

  current_branch=$(pg_branch_name 2>/dev/null || true)
  current_head=$(git rev-parse HEAD 2>/dev/null || true)

  remote=$(echo "$parsed" | jq -r '.remote // empty')
  source_ref=$(echo "$parsed" | jq -r '.source_ref // empty')
  target_branch=$(echo "$parsed" | jq -r '.target_branch // empty')
  force_with_lease=$(echo "$parsed" | jq -r '.force_with_lease')
  local is_delete
  is_delete=$(echo "$parsed" | jq -r '.is_delete')
  [[ -n "$remote" ]] || remote=$(pg_default_remote 2>/dev/null || true)
  if [[ -n "$target_branch" ]]; then
    lease_branch="$target_branch"
  else
    lease_branch="$current_branch"
  fi
  if [[ -z "$lease_branch" ]]; then
    jq -n --arg reason "Blocked: detached HEAD pushes require an explicit target branch like HEAD:<branch>. Use pg push --branch <branch> --source-ref HEAD." '{allowed:false, reason:$reason}'
    return 0
  fi
  [[ -n "$target_branch" ]] || target_branch="$lease_branch"
  branch_ref=$(pg_branch_ref "$lease_branch")

  if [[ "$remote" =~ ^(origin|upstream)$ && "$target_branch" =~ ^(main|master)$ ]]; then
    jq -n --arg reason "Blocked: pushing directly to $remote/$target_branch is not allowed." '{allowed:false, reason:$reason}'
    return 0
  fi

  local pushed_commit
  if [[ -n "$source_ref" ]]; then
    pushed_commit=$(git rev-parse --verify "${source_ref}^{commit}" 2>/dev/null || true)
  else
    pushed_commit="$current_head"
  fi
  if [[ -n "$target_branch" && -n "$pushed_commit" ]] && pg_trunk_pending_allows_push "$target_branch" "$remote" "$source_ref" "$pushed_commit" 2>/dev/null; then
    jq -n '{allowed:true, verdict:"trunk-lease"}'
    return 0
  fi

  branch_upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)
  if [[ -n "$current_branch" && "$lease_branch" == "$current_branch" && "$branch_upstream" =~ ^(origin|upstream)/(main|master)$ && ! "$current_branch" =~ ^(main|master)$ ]]; then
    jq -n --arg reason "Blocked: branch '$current_branch' tracks $branch_upstream. Re-set upstream first: git branch --set-upstream-to=origin/$current_branch" '{allowed:false, reason:$reason}'
    return 0
  fi

  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  if [[ -z "$lease_json" ]]; then
    jq -n --arg reason "Blocked: git push requires a durable lease for $lease_branch. Ask the agent to run pg prepare, then ask the user to review with: pg -C $(pg_repo_root)" '{allowed:false, reason:$reason}'
    return 0
  fi

  # Deletion pushes (--delete or :branch) don't push commits, so skip the
  # ancestor + scope checks below — there's no diff to validate.
  if [[ "$is_delete" == "true" ]]; then
    jq -n '{allowed:true, verdict:"delete"}'
    return 0
  fi

  local lease_validation lease_allowed lease_reason
  lease_validation=$(pg_validate_branch_lease_state "$lease_json" "$branch_ref" "$remote" "$current_head")
  lease_allowed=$(echo "$lease_validation" | jq -r '.allowed')
  if [[ "$lease_allowed" != "true" ]]; then
    lease_reason=$(echo "$lease_validation" | jq -r '.reason')
    jq -n --arg reason "$lease_reason" --argjson async_iteration "$(echo "$lease_validation" | jq -c '.async_iteration')" \
      '{allowed:false, reason:$reason, async_iteration:$async_iteration}'
    return 0
  fi

  local pr_reason=""
  pr_reason=$(pg_validate_pr_binding "$branch_ref" "$lease_json" 2>&1 >/dev/null) || true
  if [[ -n "$pr_reason" ]]; then
    jq -n --arg reason "$pr_reason" '{allowed:false, reason:$reason}'
    return 0
  fi

  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  if [[ ! -f "$pending_path" ]]; then
    jq -n --arg reason "Blocked: git push requires a fresh self-assertion for $lease_branch. Use: pg push --branch $lease_branch --assert-flow \$'update pr line\nbranch $lease_branch\nno rewrite'" '{allowed:false, reason:$reason}'
    return 0
  fi
  pending_json=$(cat "$pending_path")
  pending_remote=$(echo "$pending_json" | jq -r '.remote')
  pending_head=$(echo "$pending_json" | jq -r '.head')
  pending_branch_ref=$(echo "$pending_json" | jq -r '.branch_ref')

  if [[ "$pending_branch_ref" != "$branch_ref" ]]; then
    jq -n --arg reason "Blocked: pending self-assertion was recorded for $pending_branch_ref, not $branch_ref. Re-run pg push." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$pending_remote" != "$remote" ]]; then
    jq -n --arg reason "Blocked: pending self-assertion targets remote '$pending_remote', but push targets '$remote'. Re-run pg push." '{allowed:false, reason:$reason}'
    return 0
  fi
  if [[ "$pending_head" != "$current_head" ]]; then
    jq -n --arg reason "Blocked: branch HEAD changed after self-assertion. Re-run pg push with updated caveman text." '{allowed:false, reason:$reason}'
    return 0
  fi

  jq -n '{allowed:true}'
}

pg_collect_changed_files_json() {
  local remote="$1"
  local branch="$2"
  local lease_json="$3"
  local compare_ref=""
  if git show-ref --verify --quiet "refs/remotes/$remote/$branch"; then
    compare_ref="refs/remotes/$remote/$branch"
  else
    compare_ref=$(echo "$lease_json" | jq -r '.base_ref_snapshot // empty')
    if [[ -z "$compare_ref" ]] || ! git rev-parse --verify "$compare_ref" >/dev/null 2>&1; then
      compare_ref=$(echo "$lease_json" | jq -r '.approved_anchor')
    fi
  fi
  git diff --name-only "$compare_ref..HEAD" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

pg_write_pending_assertion() {
  local remote="$1"
  local branch_ref="$2"
  local assert_flow="$3"
  local lease_json="$4"
  local branch_name current_head pending_path changed_files pr_number
  branch_name=$(pg_branch_display "$branch_ref")
  current_head=$(git rev-parse HEAD)
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  changed_files=$(pg_collect_changed_files_json "$remote" "$branch_name" "$lease_json")
  pr_number=$(echo "$lease_json" | jq -r '.pr_number // empty')

  pg_ensure_parent_dir "$pending_path"
  jq -n \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg head "$current_head" \
    --arg assert_flow "$assert_flow" \
    --arg overall_flow "$assert_flow" \
    --argjson files "$changed_files" \
    --arg pr_number "$pr_number" \
    --arg timestamp "$(pg_now_utc)" \
    '{
      branch_ref: $branch_ref,
      remote: $remote,
      head: $head,
      assert_flow: $assert_flow,
      agent_asserted_pr: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      agent_asserted_overall_flow: $overall_flow,
      agent_asserted_files: $files,
      timestamp: $timestamp
    }' >"$pending_path"
}

pg_append_push_log() {
  local branch_ref="$1"
  local result="$2"
  local pending_path log_path
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  log_path=$(pg_log_path_for_ref "$branch_ref")
  [[ -f "$pending_path" ]] || return 0
  pg_ensure_parent_dir "$log_path"
  jq -c --arg result "$result" --arg timestamp "$(pg_now_utc)" '. + {result:$result, logged_at:$timestamp}' "$pending_path" >>"$log_path"
}

pg_record_branch_async_success() {
  local branch_ref="$1" remote="$2" source_ref="$3" pushed_head="$4" assert_flow="$5"
  local lease_path async_enabled
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$lease_path" ]] || return 0
  async_enabled=$(jq -r '.async_iteration.enabled // false' "$lease_path")
  [[ "$async_enabled" == "true" ]] || return 0
  jq \
    --arg remote "$remote" \
    --arg source_ref "$source_ref" \
    --arg pushed_head "$pushed_head" \
    --arg assert_flow "$assert_flow" \
    --arg timestamp "$(pg_now_utc)" \
    '.async_iteration.used_pushes = ((.async_iteration.used_pushes // 0) + 1)
     | .async_iteration.audit = ((.async_iteration.audit // []) + [{
         branch: .branch_name,
         branch_ref: .branch_ref,
         remote: $remote,
         source_ref: $source_ref,
         pushed_head: $pushed_head,
         timestamp: $timestamp,
         assertion_summary: ($assert_flow | gsub("[\r\n]+"; " | "))
       }])
     | .updated_at = $timestamp' \
    "$lease_path" >"$lease_path.tmp"
  mv "$lease_path.tmp" "$lease_path"
  pg_db_upsert_lease "$lease_path" || true
}

pg_cmd_preview_draft() {
  local draft=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft)
        draft="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown preview-draft option: $1"
        return 1
        ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"
  pg_render_lease_summary "$draft"
}

pg_cmd_draft_approve() {
  local intent="" assert_flow="" remote="" branch="" pr_override="" pr_repo=""
  local approved_paths="" approved_subjects="" max_commits="" max_added_lines="" no_scope="false"
  local assume_yes="false"
  local branch_name branch_ref repo_name repo_root common_dir pr_json pr_number pr_url pr_mode approved_anchor base_ref draft_file script_file script_path scope_json
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        assume_yes="true"
        shift
        ;;
      --intent)
        intent="$2"
        shift 2
        ;;
      --assert-flow)
        assert_flow="$2"
        shift 2
        ;;
      --remote)
        remote="$2"
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      --pr)
        pr_override="$2"
        shift 2
        ;;
      --pr-repo)
        pr_repo="$2"
        shift 2
        ;;
      --approved-paths)
        approved_paths="$2"
        shift 2
        ;;
      --approved-subjects)
        approved_subjects="$2"
        shift 2
        ;;
      --max-commits)
        max_commits="$2"
        shift 2
        ;;
      --max-added-lines)
        max_added_lines="$2"
        shift 2
        ;;
      --no-scope)
        no_scope="true"
        shift
        ;;
      *)
        pg_fail "Unknown draft-approve option: $1"
        return 1
        ;;
    esac
  done

  repo_root=$(pg_repo_root) || return 1
  common_dir=$(pg_git_common_dir) || return 1
  repo_name=$(pg_repo_name)
  branch_name="${branch:-$(pg_branch_name)}"
  [[ -n "$branch_name" ]] || pg_fail "Not on a branch."
  branch_ref=$(pg_branch_ref "$branch_name")
  remote="${remote:-$(pg_default_remote "$branch_name")}"
  pr_repo="${pr_repo:-$(pg_default_pr_repo || true)}"
  approved_anchor=$(git rev-parse HEAD)
  base_ref=$(pg_default_base_ref_snapshot)

  if [[ -n "$pr_override" ]]; then
    pr_number="$pr_override"
    pr_url=""
    pr_mode="bound"
  else
    pr_json=$(pg_find_pr_json "$branch_name" "$pr_repo")
    pr_number=$(echo "$pr_json" | jq -r '.number // empty')
    pr_url=$(echo "$pr_json" | jq -r '.url // empty')
    if [[ -n "$pr_number" ]]; then
      pr_mode="bound"
    else
      pr_mode="unbound"
    fi
  fi

  # Run the semantic interview (single codex call) to extract
  # Brief inputs: prefer a prefill file written by `pg prepare` (agent
  # handoff), falling back to commit inference only for explicitly configured
  # human-only workflows. Otherwise fail fast: the agent has richer context than commits alone expose, and
  # letting pg silently infer undermines the whole semantic check.
  local _pg_what _pg_why _pg_approach _pg_scope _pg_risks
  local _pg_bead_ids _pg_bead_block _pg_prepare_path _pg_async_json
  _pg_async_json='{"enabled":false}'
  if [[ -z "$intent" || -z "$assert_flow" ]]; then
    _pg_prepare_path=$(pg_prepare_path)
    if [[ -f "$_pg_prepare_path" ]]; then
      # Use the agent's prepared brief.
      _pg_what=$(jq -r '.what // ""' "$_pg_prepare_path")
      _pg_why=$(jq -r '.why // ""' "$_pg_prepare_path")
      _pg_approach=$(jq -r '.approach // ""' "$_pg_prepare_path")
      _pg_scope=$(jq -r '.scope // ""' "$_pg_prepare_path")
      _pg_risks=$(jq -r '.risks // ""' "$_pg_prepare_path")
      _pg_bead_ids=$(jq -r '.beads[]? // empty' "$_pg_prepare_path")
      _pg_async_json=$(jq -c '.async_iteration // {enabled:false}' "$_pg_prepare_path")
      [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg: using prepared brief from $_pg_prepare_path" >&2

      # Warn if prepare is stale (HEAD moved since preparation).
      local _pg_prep_head _pg_cur_head
      _pg_prep_head=$(jq -r '.prepared_at_head // ""' "$_pg_prepare_path")
      _pg_cur_head=$(git rev-parse HEAD 2>/dev/null || echo "")
      if [[ -n "$_pg_prep_head" && "$_pg_prep_head" != "$_pg_cur_head" ]]; then
        cat >&2 <<EOF
⚠  prepared brief is stale
   prepared at HEAD: ${_pg_prep_head:0:12}
   current HEAD:     ${_pg_cur_head:0:12}
   If the agent added new commits after preparing, consider re-running
   pg prepare to refresh what/why/approach.
EOF
      fi
    elif [[ "${PG_ALLOW_INFERENCE:-0}" == "1" ]]; then
      cat >&2 <<EOF
─────────────────────────────────────────────────────────────────────
✗  PG_ALLOW_INFERENCE is no longer accepted.

Agents must run pg prepare with explicit what/why/approach before approval.
Commit-inferred briefs are not a valid workaround for the editor review flow.
─────────────────────────────────────────────────────────────────────
EOF
      pg_fail "pg prepare required before approval; PG_ALLOW_INFERENCE is disabled."
      return 1
    else
      # Fail-fast: no prepared brief, no inference opt-in → block.
      cat >&2 <<EOF
─────────────────────────────────────────────────────────────────────
✗  NO PREPARED BRIEF for this branch — approval blocked.

WHAT  pg now requires the agent (Claude, Codex, etc.) to hand off a
      semantic brief BEFORE you approve a push. The brief captures
      what the agent did, why, and the approach it chose — context
      that isn't in commit subjects.

WHY   The semantic check at push time compares new commits against
      what you approved. If the brief was inferred from commits only,
      it's a pale copy of itself — the check just re-reads the same
      commits. The agent that did the work has the real context
      (original ask, rejected approaches, caveats).

FIX   1. Ask your agent to run (in this repo):

            pg prepare \\
              --what     'short: what changes' \\
              --why      'short: motivating reason' \\
              --approach 'short: strategy and trade-offs' \\
              --risks    'short: any concern or caveat'

         The agent should invoke this at the END of its implementation,
         before telling you to run pg.

      2. Then re-run:   pg   (or pg -C <repo>)

─────────────────────────────────────────────────────────────────────
EOF
      pg_fail "pg prepare required before approval. See the message above."
      return 1
    fi
    # Bead detection still happens either way.
    if [[ -z "$_pg_bead_ids" ]]; then
      _pg_bead_ids=$(pg_detect_beads)
    fi
    _pg_bead_block=$(pg_fetch_bead_context "$_pg_bead_ids")
    if [[ -n "$_pg_bead_block" ]]; then
      _pg_bead_block=$(printf '%s\n' "$_pg_bead_block" | sed 's/^/  · /')
    fi
  fi
  [[ -n "$intent" ]] || intent=$(pg_default_user_intent "$branch_name" "$pr_number" "$_pg_bead_block" \
    "$_pg_what" "$_pg_why" "$_pg_approach" "$_pg_scope" "$_pg_risks")
  [[ -n "$assert_flow" ]] || assert_flow=$(pg_default_assert_flow "$branch_name" "$pr_number" "$_pg_bead_block" \
    "$_pg_what" "$_pg_why" "$_pg_approach" "$_pg_scope" "$_pg_risks")
  # Strip trailing whitespace per line so yq can emit literal block scalars
  # (YAML | style cannot represent trailing whitespace and falls back to "...").
  intent=$(printf '%s' "$intent" | sed 's/[[:space:]]*$//')
  assert_flow=$(printf '%s' "$assert_flow" | sed 's/[[:space:]]*$//')

  # Build approved_scope. Auto-detect then let explicit flags override.
  # --no-scope disables semantic approval (falls back to single-push anchor-exact).
  if [[ "$no_scope" == "true" ]]; then
    scope_json="null"
  else
    scope_json=$(pg_detect_scope)
    if [[ "$scope_json" != "null" ]]; then
      if [[ -n "$approved_paths" ]]; then
        scope_json=$(echo "$scope_json" | jq --arg raw "$approved_paths" '.paths = ($raw | split("\n") | map(select(length > 0)))')
      fi
      if [[ -n "$approved_subjects" ]]; then
        scope_json=$(echo "$scope_json" | jq --arg raw "$approved_subjects" '.subjects = ($raw | split("\n") | map(select(length > 0) | ascii_downcase))')
      fi
      if [[ -n "$max_commits" ]]; then
        scope_json=$(echo "$scope_json" | jq --argjson n "$max_commits" '.max_commits = $n')
      fi
      if [[ -n "$max_added_lines" ]]; then
        scope_json=$(echo "$scope_json" | jq --argjson n "$max_added_lines" '.max_added_lines = $n')
      fi
    fi
  fi

  draft_file="/tmp/pg-approve-$(pg_branch_slug "$repo_name")-$(pg_branch_slug "$branch_name").json"
  script_file="/tmp/pg-approve-$(pg_branch_slug "$repo_name")-$(pg_branch_slug "$branch_name").sh"
  script_path=$(pg_helper_path)

  jq -n \
    --arg schema_version "2" \
    --arg repo_name "$repo_name" \
    --arg repo_root "$repo_root" \
    --arg common_dir "$common_dir" \
    --arg branch_name "$branch_name" \
    --arg branch_ref "$branch_ref" \
    --arg remote "$remote" \
    --arg pr_repo "$pr_repo" \
    --arg pr_mode "$pr_mode" \
    --arg pr_number "$pr_number" \
    --arg pr_url "$pr_url" \
    --arg approved_anchor "$approved_anchor" \
    --arg base_ref_snapshot "$base_ref" \
    --arg user_intent "$intent" \
    --arg agent_assertion_template "$assert_flow" \
    --argjson approved_scope "$scope_json" \
    --arg brief_what "${_pg_what:-}" \
    --arg brief_why "${_pg_why:-}" \
    --arg brief_approach "${_pg_approach:-}" \
    --arg brief_scope "${_pg_scope:-}" \
    --arg brief_risks "${_pg_risks:-}" \
    --arg bead_ids "${_pg_bead_ids:-}" \
    --argjson async_iteration "$_pg_async_json" \
    --arg created_by "${USER:-unknown}" \
    --arg created_at "$(pg_now_utc)" \
    '{
      schema_version: ($schema_version | tonumber),
      description: {
        summary: (if $brief_what == "" then null else $brief_what end),
        motivation: (if $brief_why == "" then null else $brief_why end),
        approach: (if $brief_approach == "" then null else $brief_approach end),
        scope: (if $brief_scope == "" then null else $brief_scope end),
        risks: (if $brief_risks == "" then null else $brief_risks end),
        testing: null
      },
      user_intent: $user_intent,
      agent_assertion_template: $agent_assertion_template,
      approved_scope: $approved_scope,
      repo_name: $repo_name,
      repo_root: $repo_root,
      common_dir: $common_dir,
      branch_name: $branch_name,
      branch_ref: $branch_ref,
      remote: $remote,
      pr_repo: (if $pr_repo == "" then null else $pr_repo end),
      pr_mode: $pr_mode,
      pr_number: (if $pr_number == "" then null else ($pr_number | tonumber) end),
      pr_url: (if $pr_url == "" then null else $pr_url end),
      approved_anchor: $approved_anchor,
      base_ref_snapshot: (if $base_ref_snapshot == "" then null else $base_ref_snapshot end),
      brief: {
        what: (if $brief_what == "" then null else $brief_what end),
        why: (if $brief_why == "" then null else $brief_why end),
        approach: (if $brief_approach == "" then null else $brief_approach end),
        scope: (if $brief_scope == "" then null else $brief_scope end),
        risks: (if $brief_risks == "" then null else $brief_risks end)
      },
      bead_ids: (if $bead_ids == "" then [] else ($bead_ids | split("\n") | map(select(length > 0))) end),
      async_iteration: (
        if ($async_iteration.enabled // false) then
          $async_iteration
          | .mode = "branch"
          | .scope = {
              type: "branch",
              branch_name: $branch_name,
              branch_ref: $branch_ref,
              remote: $remote
            }
        else
          {enabled:false}
        end
      ),
      created_by: $created_by,
      created_at: $created_at,
      status: "active"
    }' >"$draft_file"

  # Build a context block the user sees as YAML comments: commit log,
  # changed files with per-file stats, and overall diff stat. This
  # frames what they're actually approving without making them type it.
  local context_block=""
  if [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    local commit_log file_stats shortstat
    commit_log=$(git log "$base_ref"..HEAD --reverse --format='#   %h %s' 2>/dev/null | head -20)
    file_stats=$(git diff --stat "$base_ref"..HEAD 2>/dev/null \
      | sed '$d' | sed 's/^/#   /' | head -15)
    shortstat=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | sed 's/^ *//')
    context_block="# ───────── what you're approving ─────────
# base: $base_ref
#
# commits:
${commit_log:-#   (none)}
#
# files (and line-change stats):
${file_stats:-#   (none)}
#
# total: ${shortstat:-(no diff)}
# ─────────────────────────────────────────
#"
  fi

  local yaml_file="${draft_file%.json}.yaml"
  cat >"$script_file" <<EOF
#!/bin/bash
set -euo pipefail

DRAFT_FILE="$draft_file"
YAML_FILE="$yaml_file"
HELPER="$script_path"
ASSUME_YES="$assume_yes"

# Context block computed at draft-approve time and baked into this
# script. Shown as comments at the top of the YAML so the user sees
# exactly what they're approving without having to look it up.
read -r -d '' CONTEXT_BLOCK <<'CTXEOF' || true
$context_block
CTXEOF

# Edit-before-approve: convert the draft JSON to YAML, open \$EDITOR on the
# YAML (easier to edit: comments, multi-line strings, no strict quoting),
# then round-trip back to JSON and validate.
# Requires yq (mikefarah); falls back to raw JSON if yq is missing.
if true; then
  editor="\${EDITOR:-vi}"
  if command -v yq >/dev/null 2>&1; then
    # JSON → YAML with a helpful header + change-context comment.
    {
      echo "# pg approval draft — edit description first."
      echo "# Then adjust user_intent, agent_assertion_template, or approved_scope if needed."
      echo "# Save + quit to continue, :cq or empty file to abort."
      echo "#"
      [ -n "\$CONTEXT_BLOCK" ] && printf '%s\n' "\$CONTEXT_BLOCK"
      yq -P eval '(.user_intent, .agent_assertion_template) style="literal"' "\$DRAFT_FILE" --output-format=yaml
    } > "\$YAML_FILE"

    cp "\$YAML_FILE" "\$YAML_FILE.bak"
    echo "Opening \$editor on \$YAML_FILE (YAML view of draft)."
    if ! "\$editor" "\$YAML_FILE"; then
      echo "Editor exited non-zero — aborting."
      mv "\$YAML_FILE.bak" "\$YAML_FILE"
      exit 1
    fi
    if [ ! -s "\$YAML_FILE" ]; then
      echo "YAML empty — aborting."
      mv "\$YAML_FILE.bak" "\$YAML_FILE"
      exit 1
    fi

    # Parse YAML → JSON into a tmp, validate, then replace draft.
    if ! yq eval '.' "\$YAML_FILE" --output-format=json > "\$DRAFT_FILE.new" 2>/dev/null; then
      echo "YAML failed to parse — restoring previous version, aborting."
      mv "\$YAML_FILE.bak" "\$YAML_FILE"
      rm -f "\$DRAFT_FILE.new"
      exit 1
    fi
    if ! jq empty "\$DRAFT_FILE.new" >/dev/null 2>&1; then
      echo "Parsed JSON is not valid — aborting."
      mv "\$YAML_FILE.bak" "\$YAML_FILE"
      rm -f "\$DRAFT_FILE.new"
      exit 1
    fi
    mv "\$DRAFT_FILE.new" "\$DRAFT_FILE"
    rm -f "\$YAML_FILE.bak"
  else
    # yq not installed — fall back to direct JSON edit.
    echo "yq not found; opening \$editor on JSON directly. Install yq for YAML editing."
    cp "\$DRAFT_FILE" "\$DRAFT_FILE.bak"
    if ! "\$editor" "\$DRAFT_FILE"; then
      echo "Editor exited non-zero — aborting."
      mv "\$DRAFT_FILE.bak" "\$DRAFT_FILE"
      exit 1
    fi
    if ! jq empty "\$DRAFT_FILE" >/dev/null 2>&1; then
      echo "Draft is no longer valid JSON — restoring previous version, aborting."
      mv "\$DRAFT_FILE.bak" "\$DRAFT_FILE"
      exit 1
    fi
    rm -f "\$DRAFT_FILE.bak"
  fi
fi

"\$HELPER" preview-draft --draft "\$DRAFT_FILE"
echo
if [[ "\$ASSUME_YES" == "true" ]]; then
  echo "Proceed: yes (--yes, after editor review)"
  "\$HELPER" approve --draft "\$DRAFT_FILE"
else
  printf 'Proceed? [Y/n] '
  read -r answer
  case "\$answer" in
    ""|y|Y|yes|YES)
      "\$HELPER" approve --draft "\$DRAFT_FILE"
      ;;
    *)
      echo "Canceled"
      exit 1
      ;;
  esac
fi
EOF
  chmod +x "$script_file"

  echo "Approval script: $script_file"
  echo "Draft file: $draft_file"

  # Auto-run the approval script unless explicitly suppressed. This gives the
  # user a single `pg` command that opens vim on the draft (intent + assert +
  # scope) then prompts y/N.
  if [[ "${PG_AUTO_RUN_APPROVAL:-1}" == "1" ]] && [[ -t 0 || -t 1 ]]; then
    bash "$script_file"
  fi
}

pg_cmd_approve() {
  local draft="" lease_path repo_root approved_anchor existing_created_at existing_created_by
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --draft)
        draft="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown approve option: $1"
        return 1
        ;;
    esac
  done
  [[ -f "$draft" ]] || pg_fail "Draft file not found: $draft"

  local normalized_draft
  normalized_draft=$(mktemp "${TMPDIR:-/tmp}/pg-approve-draft.XXXXXX")
  jq '
    def from_brief:
      {
        summary: .brief.what,
        motivation: .brief.why,
        approach: .brief.approach,
        scope: .brief.scope,
        risks: .brief.risks,
        testing: null
      };
    .description = (from_brief + (.description // {}))
    | .brief = {
        what: .description.summary,
        why: .description.motivation,
        approach: .description.approach,
        scope: .description.scope,
        risks: .description.risks
      }
  ' "$draft" >"$normalized_draft" || {
    rm -f "$normalized_draft"
    pg_fail "Draft file is not valid JSON: $draft"
    return 1
  }
  mv "$normalized_draft" "$draft"

  # Enforce that the semantic brief was actually filled in. If the LLM
  # interview failed AND the user saved without editing, the draft will
  # still carry placeholder strings. Block with a clear message so the
  # user re-edits and re-approves.
  local _pg_brief_w _pg_brief_y _pg_brief_a _pg_intent_text
  _pg_brief_w=$(jq -r '.brief.what // ""' "$draft")
  _pg_brief_y=$(jq -r '.brief.why // ""' "$draft")
  _pg_brief_a=$(jq -r '.brief.approach // ""' "$draft")
  _pg_intent_text=$(jq -r '.user_intent // ""' "$draft")
  local _pg_missing=()
  _pg_is_placeholder() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    case "$v" in
      *'<describe'*|*'<fill in'*|*'<fill'*|*'<motivating'*|*'<architectural'*) return 0 ;;
    esac
    return 1
  }
  _pg_is_placeholder "$_pg_brief_w" && _pg_missing+=("brief.what")
  _pg_is_placeholder "$_pg_brief_y" && _pg_missing+=("brief.why")
  _pg_is_placeholder "$_pg_brief_a" && _pg_missing+=("brief.approach")
  # Also scan user_intent for raw placeholder strings in case the brief
  # object was filled but the rendered intent text wasn't updated.
  case "$_pg_intent_text" in
    *'<describe'*|*'<fill in'*|*'<motivating'*|*'<architectural'*)
      _pg_missing+=("user_intent: still has <fill-in> placeholder text")
      ;;
  esac
  if [[ ${#_pg_missing[@]} -gt 0 ]]; then
    local msg="Approval blocked: the semantic brief has unfilled fields. Edit the YAML draft and replace the placeholders."
    msg+=$'\n'"Unfilled:"
    for f in "${_pg_missing[@]}"; do msg+=$'\n'"  - $f"; done
    msg+=$'\n'"Draft: $draft"
    msg+=$'\n'"To re-edit + retry: bash ${draft%.json}.sh"
    pg_fail "$msg"
    return 1
  fi

  # Require interactive terminal — prevent agents from self-approving by
  # calling this directly. Runs AFTER the brief check so the missing-
  # fields error still fires in non-tty contexts (helps agents diagnose).
  if [[ ! -t 0 ]]; then
    pg_fail "Blocked: pg approve requires an interactive terminal. Run the approval script printed by pg draft-approve instead."
    return 1
  fi

  repo_root=$(jq -r '.repo_root' "$draft")
  approved_anchor=$(jq -r '.approved_anchor' "$draft")
  git -C "$repo_root" cat-file -e "${approved_anchor}^{commit}" >/dev/null 2>&1 || pg_fail "Draft anchor commit no longer exists: $approved_anchor"

  local async_iteration
  async_iteration=$(pg_finalize_async_json "$(jq -c '.async_iteration // {enabled:false}' "$draft")" "branch") || return 1
  jq --argjson async_iteration "$async_iteration" '.async_iteration = $async_iteration' \
    "$draft" >"$draft.tmp" && mv "$draft.tmp" "$draft"

  lease_path="$(jq -r '.common_dir' "$draft")/push-gate/leases/$(jq -r '.branch_ref' "$draft").json"
  pg_ensure_parent_dir "$lease_path"
  existing_created_at=$(jq -r '.created_at // empty' "$lease_path" 2>/dev/null || true)
  existing_created_by=$(jq -r '.created_by // empty' "$lease_path" 2>/dev/null || true)

  jq \
    --arg updated_at "$(pg_now_utc)" \
    --arg created_at "${existing_created_at:-$(jq -r '.created_at' "$draft")}" \
    --arg created_by "${existing_created_by:-$(jq -r '.created_by' "$draft")}" \
    '.created_at = $created_at | .created_by = $created_by | .updated_at = $updated_at | .status = "active"' \
    "$draft" >"$lease_path"

  echo "Lease approved: $lease_path"
  pg_db_upsert_lease "$lease_path" || true
  pg_notify_approved "$draft" "$lease_path" || true

  # Consume the prepare prefill so the next approval requires a fresh
  # handoff (agents must restate rationale for each approval cycle).
  local _pg_consumed_prepare
  _pg_consumed_prepare=$(pg_prepare_path 2>/dev/null || true)
  [[ -n "$_pg_consumed_prepare" && -f "$_pg_consumed_prepare" ]] && rm -f "$_pg_consumed_prepare"
}

# Notify the initiating Claude/Codex session that the lease was approved.
# Fires three channels (each fail-silent):
#   1. Sentinel file at /tmp/pg-approved/<repo>__<branch> (polled by agents).
#   2. Threaded Slack reply on the existing notify-slack thread for this branch.
#   3. macOS terminal-notifier desktop notification.
pg_notify_approved() {
  local draft="$1" lease_path="$2"
  local repo_name branch_name pr_number key sentinel_dir sentinel_file
  repo_name=$(jq -r '.repo_name // empty' "$draft" 2>/dev/null)
  branch_name=$(jq -r '.branch_name // empty' "$draft" 2>/dev/null)
  pr_number=$(jq -r '.pr_number // empty' "$draft" 2>/dev/null)
  [[ -n "$repo_name" && -n "$branch_name" ]] || return 0

  key="${repo_name}__${branch_name}"
  key=$(printf '%s' "$key" | tr '/ ' '__')

  # 1. Sentinel file. Agents can poll this ("test -f /tmp/pg-approved/<key>")
  #    to know approval happened out-of-band.
  sentinel_dir="${PG_APPROVAL_SENTINEL_DIR:-/tmp/pg-approved}"
  mkdir -p "$sentinel_dir" 2>/dev/null || true
  sentinel_file="$sentinel_dir/$key"
  {
    printf 'approved_at=%s\n' "$(pg_now_utc)"
    printf 'lease=%s\n' "$lease_path"
    [[ -n "$pr_number" ]] && printf 'pr_number=%s\n' "$pr_number"
  } > "$sentinel_file" 2>/dev/null || true

  # 2. Slack threaded reply (same convention as notify-slack.sh).
  #    OFF by default — opt in with PG_NOTIFY_SLACK=1 when you actually want
  #    the approval to surface in the branch's Slack thread.
  local thread_dir thread_file thread_ts token chan payload msg
  thread_dir="${NOTIFY_THREAD_DIR:-/tmp/claude-slack-threads}"
  thread_file="$thread_dir/$key"
  if [[ "${PG_NOTIFY_SLACK:-0}" == "1" ]] \
     && [[ -r "$thread_file" ]] \
     && command -v security >/dev/null 2>&1; then
    thread_ts=$(cat "$thread_file" 2>/dev/null || true)
    token=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-bot-token -w 2>/dev/null || true)
    chan=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-channel -w 2>/dev/null || true)
    if [[ -n "$thread_ts" && -n "$token" && -n "$chan" ]]; then
      msg="🔐 *lease approved* for \`$branch_name\`"
      [[ -n "$pr_number" ]] && msg="$msg · PR #$pr_number"
      msg="$msg — agent may now push"
      payload=$(jq -n \
        --arg channel "$chan" \
        --arg text "$msg" \
        --arg thread_ts "$thread_ts" \
        '{channel: $channel, text: $text, thread_ts: $thread_ts, unfurl_links: false, unfurl_media: false}')
      curl -sS https://slack.com/api/chat.postMessage \
        -H "Authorization: Bearer $token" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$payload" >/dev/null 2>&1 || true
    fi
  fi

  # 3. macOS desktop notification. Click opens the canonical repo in VS Code.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v terminal-notifier >/dev/null 2>&1; then
    # Resolve the MAIN repo path (preferred click target) by walking
    # the lease/draft fields in order of specificity:
    #   1. draft.common_dir → dirname → main repo path (handles worktrees)
    #   2. lease_path        → climb up to main repo
    #   3. draft.repo_root   → worktree path (fallback)
    # This way the banner always carries -open when we can find ANY
    # plausible path.
    local click_path open_url encoded common_dir
    common_dir=$(jq -r '.common_dir // empty' "$draft" 2>/dev/null)
    if [[ -n "$common_dir" && -d "$common_dir" ]]; then
      click_path=$(cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
    fi
    if [[ -z "$click_path" && -n "$lease_path" && -f "$lease_path" ]]; then
      # lease is at <common_dir>/push-gate/leases/refs/heads/<branch>.json
      click_path=$(cd "$lease_path" 2>/dev/null; echo "")  # noop, the lease is a file not a dir
      local lease_common="${lease_path%%/push-gate/*}"
      [[ -n "$lease_common" && -d "$lease_common" ]] && click_path=$(cd "$(dirname "$lease_common")" 2>/dev/null && pwd)
    fi
    if [[ -z "$click_path" ]]; then
      click_path=$(jq -r '.repo_root // empty' "$draft" 2>/dev/null)
    fi
    if [[ -n "$click_path" ]]; then
      encoded=""
      local c i
      for ((i=0; i<${#click_path}; i++)); do
        c="${click_path:i:1}"
        case "$c" in
          [a-zA-Z0-9._~/:-]) encoded+="$c" ;;
          *) printf -v c '%%%02X' "'$c"; encoded+="$c" ;;
        esac
      done
      open_url="vscode://file$encoded"
    fi
    # Title = repo name so the user can tell WHICH repo approved when
    # multiple notifications stack. Subtitle declares the event.
    local title="${repo_name:-push-gate}"
    local subtitle="pg approved · $branch_name${pr_number:+ · PR #$pr_number}"
    local msg="agent may now push"
    if command -v alerter >/dev/null 2>&1; then
      (
        resp=$(alerter --title "$title" --subtitle "$subtitle" \
          --message "$msg" --sound Pop --timeout 60 --ignore-dnd \
          --sender "com.matthewho.claudenotify" --json 2>/dev/null)
        act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null)
        if [[ "$act" == "contentsClicked" && -n "${open_url:-}" ]]; then
          open "$open_url" >/dev/null 2>&1 || true
        fi
      ) >/dev/null 2>&1 &
    else
      local args=(
        -title "$title"
        -subtitle "$subtitle"
        -message "$msg"
        -sound Pop
        -group "pg-approval-$key"
        -sender "com.matthewho.claudenotify"
        -timeout 10
        -ignoreDnD
      )
      [[ -n "${open_url:-}" ]] && args+=(-open "$open_url")
      terminal-notifier "${args[@]}" >/dev/null 2>&1 &
    fi
  fi
}

pg_load_current_lease_json() {
  local branch_ref
  branch_ref=$(pg_branch_ref)
  pg_load_lease_for_ref "$branch_ref"
}

pg_cmd_status() {
  local lease_json branch_ref
  branch_ref=$(pg_branch_ref)
  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  if [[ -z "$lease_json" ]]; then
    echo "No lease for $(pg_branch_display "$branch_ref")"
    return 0
  fi
  echo "$lease_json" | jq -r '
    "Branch: " + .branch_name,
    "Remote: " + .remote,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Anchor: " + .approved_anchor,
    "Status: " + .status,
    "Updated: " + (.updated_at // .created_at)
  '
}

pg_cmd_show() {
  local branch="${1:-}" branch_ref lease_path
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$lease_path" ]] || pg_fail "No lease found for $(pg_branch_display "$branch_ref")"
  jq -r '
    "Branch: " + .branch_name,
    "Remote: " + .remote,
    "PR: " + (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end),
    "PR Repo: " + (.pr_repo // "(default)"),
    "Anchor: " + .approved_anchor,
    "Intent:",
    .user_intent,
    "",
    "Assertion template:",
    .agent_assertion_template
  ' "$lease_path"
}

pg_cmd_list() {
  local leases_root
  leases_root="$(pg_store_dir)/leases/refs/heads"
  if [[ ! -d "$leases_root" ]]; then
    echo "No leases"
    return 0
  fi
  find "$leases_root" -name '*.json' -print | sort | while read -r file; do
    jq -r '[.branch_name, .remote, (.pr_repo // "(default)"), (if (.pr_number // null) == null then "(unbound)" else ("#" + (.pr_number | tostring)) end), .approved_anchor] | @tsv' "$file"
  done
}

pg_cmd_check_intent() {
  local branch="${1:-}" branch_ref lease_path lease_json
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  if [[ ! -f "$lease_path" ]]; then
    jq -n --arg br "$(pg_branch_display "$branch_ref")" \
      '{allowed:false, verdict:"no-lease", reason:("No lease for " + $br + ". Run `pg` to generate one.")}'
    return 0
  fi
  lease_json=$(cat "$lease_path")
  pg_validate_intent_match "$lease_json"
}

pg_cmd_check() {
  local branch="${1:-}" branch_ref lease_path lease_json scope base_ref
  local changed count added subjects validation remote head
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  if [[ ! -f "$lease_path" ]]; then
    jq -n --arg br "$(pg_branch_display "$branch_ref")" \
      '{allowed:false, reason:("No lease for " + $br + ". Run pg prepare and ask the user to review."), async_iteration:{enabled:false}}'
    return 0
  fi
  lease_json=$(cat "$lease_path")
  remote=$(echo "$lease_json" | jq -r '.remote // ""')
  head=$(git rev-parse HEAD 2>/dev/null || echo '')
  validation=$(pg_validate_branch_lease_state "$lease_json" "$branch_ref" "$remote" "$head")

  scope=$(echo "$lease_json" | jq -c '.approved_scope // null')
  base_ref=$(echo "$scope" | jq -r '.base_ref // empty')

  if [[ -n "$base_ref" ]] && git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    changed=$(git diff --name-only "$base_ref"..HEAD 2>/dev/null \
      | jq -Rsc 'split("\n") | map(select(length > 0))')
    count=$(git rev-list --count "$base_ref"..HEAD 2>/dev/null || echo 0)
    added=$(git diff --shortstat "$base_ref"..HEAD 2>/dev/null | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+')
    [[ -z "$added" ]] && added=0
    subjects=$(git log --format='%s' "$base_ref"..HEAD 2>/dev/null \
      | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    changed='[]'; count=0; added=0; subjects='[]'
  fi

  echo "$validation" | jq \
    --argjson scope "${scope:-null}" \
    --argjson changed "${changed:-[]}" \
    --argjson subjects "${subjects:-[]}" \
    --arg count "$count" \
    --arg added "$added" \
    --arg anchor "$(echo "$lease_json" | jq -r '.approved_anchor // empty')" \
    --arg head "$head" \
    '. + {
      approved_scope: $scope,
      current: {
        head: $head,
        approved_anchor: $anchor,
        anchor_matches_head: ($head == $anchor),
        commits: ($count | tonumber),
        added_lines: ($added | tonumber),
        changed_files: $changed,
        subjects: $subjects
      }
    }'
}

pg_cmd_revoke() {
  local branch="${1:-}" branch_ref lease_path pending_path
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  pending_path=$(pg_pending_path_for_ref "$branch_ref")
  rm -f "$lease_path" "$pending_path"
  echo "Revoked lease for $(pg_branch_display "$branch_ref")"
}

pg_cmd_leases_reindex() {
  # Scan ~/repos/*/.git/push-gate/leases/... and import every lease file
  # into the DB. Idempotent — upsert by (repo_root, branch_ref).
  pg_db_init || { echo "failed to init DB"; return 1; }
  local found=0
  local root
  for root in "$HOME"/repos/*/; do
    root="${root%/}"
    [[ -d "$root/.git" || -f "$root/.git" ]] || continue
    local common
    common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || continue
    case "$common" in /*) ;; *) common="$root/$common" ;; esac
    local leases_dir="$common/push-gate/leases"
    [[ -d "$leases_dir" ]] || continue
    while IFS= read -r f; do
      pg_db_upsert_lease "$f" && found=$((found + 1))
    done < <(find "$leases_dir" -name '*.json' -type f 2>/dev/null)
  done
  echo "Reindexed $found lease(s) into $(pg_db_path)"
}

pg_cmd_leases() {
  if [[ "${1:-}" == "reindex" ]]; then
    shift
    pg_cmd_leases_reindex "$@"
    return $?
  fi
  local show_all="false" repo_filter="" format="table"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) show_all="true"; shift ;;
      --repo) repo_filter="$2"; shift 2 ;;
      --json) format="json"; shift ;;
      *)     pg_fail "Unknown leases option: $1"; return 1 ;;
    esac
  done

  pg_db_init || {
    echo "(no lease DB at $(pg_db_path))"
    return 0
  }
  local db where select_cols
  db=$(pg_db_path)

  if [[ "$show_all" == "true" ]]; then
    where="1=1"
  else
    where="status = 'active'"
  fi
  if [[ -n "$repo_filter" ]]; then
    where="$where AND repo_root = $(pg_sql_quote "$repo_filter")"
  fi

  if [[ "$format" == "json" ]]; then
    sqlite3 "$db" -json "SELECT repo_name, branch_name, status, pr_number, approved_anchor, updated_at, repo_root, async_json FROM leases WHERE $where ORDER BY updated_at DESC;" 2>/dev/null \
      | jq --arg now "$(pg_now_utc)" '
        map(
          (.async_json | fromjson? // {enabled:false}) as $a
          | . + {
              async_iteration: {
                enabled: ($a.enabled // false),
                mode: ($a.mode // "branch"),
                expires_at: ($a.expires_at // null),
                allow_rewrite: ($a.allow_rewrite // false),
                pushes: {
                  used: ($a.used_pushes // 0),
                  max: ($a.max_pushes // 0),
                  remaining: ([ (($a.max_pushes // 0) - ($a.used_pushes // 0)), 0 ] | max)
                },
                scope: ($a.scope // {}),
                block_reason: (
                  if (($a.enabled // false) | not) then "async lease not enabled"
                  elif (($a.expires_at // "") == "") then "async lease has no expires_at"
                  elif ($now > $a.expires_at) then ("async lease expired at " + $a.expires_at)
                  elif (($a.used_pushes // 0) >= ($a.max_pushes // 0)) then "async push budget exhausted"
                  else null end
                )
              }
            }
          | del(.async_json)
        )'
    return 0
  fi

  # Human-readable table via sqlite3 column mode.
  local rows
  rows=$(sqlite3 "$db" -column -header \
    "SELECT substr(repo_name, 1, 28) AS repo,
            substr(branch_name, 1, 32) AS branch,
            status,
            COALESCE('#' || pr_number, '-') AS pr,
            substr(updated_at, 1, 19) AS updated
     FROM leases WHERE $where
     ORDER BY updated_at DESC;" 2>/dev/null)
  if [[ -z "$rows" ]]; then
    echo "No leases found."
    return 0
  fi
  echo "$rows"
}

pg_cmd_doctor() {
  local branch current_branch remote
  current_branch=$(pg_branch_name)
  remote=$(pg_default_remote || true)
  branch="${current_branch:-HEAD}"
  pg_validate_push_guard "git push ${remote:+$remote }$branch" | jq -r 'if .allowed then "Push guard: ready" else .reason end'
}

pg_cmd_bind_pr() {
  local auto="false" branch branch_ref lease_path actual_pr number url pr_repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)
        auto="true"
        shift
        ;;
      --repo)
        pr_repo="$2"
        shift 2
        ;;
      *)
        pg_fail "Unknown bind-pr option: $1"
        return 1
        ;;
    esac
  done
  [[ "$auto" == "true" ]] || pg_fail "bind-pr currently supports only --auto"
  branch=$(pg_branch_name) || return 1
  branch_ref=$(pg_branch_ref "$branch")
  lease_path=$(pg_lease_path_for_ref "$branch_ref")
  [[ -f "$lease_path" ]] || pg_fail "No lease found for $branch"
  pr_repo="${pr_repo:-$(jq -r '.pr_repo // empty' "$lease_path")}"
  pr_repo="${pr_repo:-$(pg_default_pr_repo || true)}"
  actual_pr=$(pg_find_pr_json "$branch" "$pr_repo")
  number=$(echo "$actual_pr" | jq -r '.number // empty')
  url=$(echo "$actual_pr" | jq -r '.url // empty')
  [[ -n "$number" ]] || pg_fail "No open PR found for $branch"
  jq \
    --arg updated_at "$(pg_now_utc)" \
    --argjson pr_number "$number" \
    --arg pr_url "$url" \
    --arg pr_repo "$pr_repo" \
    '.pr_mode = "bound" | .pr_number = $pr_number | .pr_url = $pr_url | .pr_repo = (if $pr_repo == "" then null else $pr_repo end) | .updated_at = $updated_at' \
    "$lease_path" >"$lease_path.tmp"
  mv "$lease_path.tmp" "$lease_path"
  echo "Lease bound to PR #$number"
}

pg_cmd_push() {
  local assert_flow="" remote="" branch="" source_ref="" force_with_lease="false" set_upstream="false" trunk_stack=""
  local current_branch branch_ref lease_json pending_path result refspec use_upstream="false" lock_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --trunk-stack)
        trunk_stack="$2"
        shift 2
        ;;
      --assert-flow)
        assert_flow="$2"
        shift 2
        ;;
      --remote)
        remote="$2"
        shift 2
        ;;
      --branch)
        branch="$2"
        shift 2
        ;;
      --source-ref)
        source_ref="$2"
        shift 2
        ;;
      --force-with-lease)
        force_with_lease="true"
        shift
        ;;
      --set-upstream)
        set_upstream="true"
        shift
        ;;
      *)
        pg_fail "Unknown push option: $1"
        return 1
        ;;
    esac
  done

  if [[ -n "$trunk_stack" ]]; then
    pg_cmd_push_trunk "$trunk_stack" "$assert_flow" "$remote" "$branch" "$source_ref" "$force_with_lease" "$set_upstream"
    return $?
  fi

  [[ -n "$assert_flow" ]] || pg_fail "pg push requires --assert-flow with caveman text."
  current_branch=$(pg_branch_name || true)
  branch="${branch:-$current_branch}"
  [[ -n "$branch" ]] || pg_fail "pg push requires --branch when not on a branch."
  source_ref="${source_ref:-${current_branch:-HEAD}}"
  branch_ref=$(pg_branch_ref "$branch")
  lock_dir=$(pg_lock_acquire "$branch_ref") || return 1
  cleanup_push_lock() {
    [[ -n "$lock_dir" ]] && pg_lock_release "$lock_dir"
  }
  trap cleanup_push_lock EXIT

  lease_json=$(pg_load_lease_for_ref "$branch_ref" 2>/dev/null || true)
  [[ -n "$lease_json" ]] || { cleanup_push_lock; trap - EXIT; pg_fail "No lease found for $branch. Run pg prepare and ask the user to review first."; return 1; }
  remote="${remote:-$(echo "$lease_json" | jq -r '.remote')}"
  pending_path=$(pg_pending_path_for_ref "$branch_ref")

  # Enforce lease state directly here so pg push is strict regardless of
  # which harness-level hook ran.
  local current_head lease_validation lease_allowed lease_reason
  current_head=$(git rev-parse HEAD 2>/dev/null || true)
  lease_validation=$(pg_validate_branch_lease_state "$lease_json" "$branch_ref" "$remote" "$current_head")
  lease_allowed=$(echo "$lease_validation" | jq -r '.allowed')
  if [[ "$lease_allowed" != "true" ]]; then
    lease_reason=$(echo "$lease_validation" | jq -r '.reason')
    cleanup_push_lock
    trap - EXIT
    pg_fail "$lease_reason"
    return 1
  fi

  # Semantic intent check — LLM compares lease.user_intent to current
  # commits/diff. Fails closed if the check can't run; fails closed on
  # MISMATCH. No bypass flag by design.
  local intent_result intent_allowed intent_reason intent_verdict
  intent_result=$(pg_validate_intent_match "$lease_json")
  intent_allowed=$(echo "$intent_result" | jq -r '.allowed')
  intent_verdict=$(echo "$intent_result" | jq -r '.verdict')
  if [[ "$intent_allowed" != "true" ]]; then
    intent_reason=$(echo "$intent_result" | jq -r '.reason')
    cleanup_push_lock
    trap - EXIT
    pg_fail "$intent_reason"
    return 1
  fi
  [[ "${PG_DEBUG:-0}" == "1" ]] && echo "pg_cmd_push: intent check verdict=$intent_verdict" >&2

  pg_write_pending_assertion "$remote" "$branch_ref" "$assert_flow" "$lease_json"
  cleanup_pending() {
    rm -f "$pending_path"
    cleanup_push_lock
  }
  trap cleanup_pending EXIT

  refspec="$branch"
  if [[ "$source_ref" != "$branch" ]]; then
    refspec="$source_ref:$branch"
  fi
  if [[ "$set_upstream" == "true" ]]; then
    use_upstream="true"
  elif [[ -n "$current_branch" && "$current_branch" == "$branch" ]] && ! git rev-parse --abbrev-ref "${branch}@{upstream}" >/dev/null 2>&1; then
    use_upstream="true"
  fi

  if [[ "$force_with_lease" == "true" && "$use_upstream" == "true" ]]; then
    git push --force-with-lease -u "$remote" "$refspec"
  elif [[ "$force_with_lease" == "true" ]]; then
    git push --force-with-lease "$remote" "$refspec"
  elif [[ "$use_upstream" == "true" ]]; then
    git push -u "$remote" "$refspec"
  else
    git push "$remote" "$refspec"
  fi
  result=$?
  if [[ "$result" == "0" ]]; then
    pg_append_push_log "$branch_ref" "pushed"
    pg_record_branch_async_success "$branch_ref" "$remote" "$source_ref" "$current_head" "$assert_flow"
  fi
  trap - EXIT
  rm -f "$pending_path"
  cleanup_push_lock
  return "$result"
}


pg_main() {
  # -C <path> (git-style): run from another repo without cd. Must come
  # before the subcommand. Can be passed multiple times (last wins).
  while [[ "${1:-}" == "-C" ]]; do
    [[ -n "${2:-}" ]] || { pg_fail "-C requires a path"; return 1; }
    cd "$2" || { pg_fail "-C: cannot cd to $2"; return 1; }
    shift 2
  done

  local assume_yes="false"
  while [[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]]; do
    assume_yes="true"
    shift
  done

  # Bare `pg` → draft-approve with auto-run of the approval script. That
  # opens vim on the draft JSON (intent + assert + scope), preview, y/N,
  # approve. One vim session, no copy-paste.
  local command="${1:-draft-approve}"
  if [[ $# -gt 0 ]]; then
    shift
  fi

  if [[ "$assume_yes" == "true" ]]; then
    case "$command" in
      draft-approve|trunk)
        set -- --yes "$@"
        ;;
      *)
        pg_fail "--yes is only valid with approval commands: pg [--yes] or pg trunk --stack S --yes"
        return 1
        ;;
    esac
  fi

  if pg_parse_common_flag "$command"; then
    pg_migration_help
    return 1
  fi

  case "$command" in
    draft-approve)
      pg_cmd_draft_approve "$@"
      ;;
    prepare)
      pg_cmd_prepare "$@"
      ;;
    prepare-trunk)
      pg_cmd_prepare_trunk "$@"
      ;;
    trunk)
      pg_cmd_trunk "$@"
      ;;
    trunk-draft)
      pg_cmd_trunk_draft "$@"
      ;;
    approve)
      pg_cmd_approve "$@"
      ;;
    approve-trunk)
      pg_cmd_approve_trunk "$@"
      ;;
    preview-draft)
      pg_cmd_preview_draft "$@"
      ;;
    preview-trunk)
      pg_cmd_preview_trunk "$@"
      ;;
    push)
      pg_cmd_push "$@"
      ;;
    status)
      pg_cmd_status "$@"
      ;;
    show)
      pg_cmd_show "$@"
      ;;
    list)
      pg_cmd_list "$@"
      ;;
    leases)
      pg_cmd_leases "$@"
      ;;
    check)
      pg_cmd_check "$@"
      ;;
    check-trunk)
      pg_cmd_check_trunk "$@"
      ;;
    revoke-trunk)
      pg_cmd_revoke_trunk "$@"
      ;;
    check-intent)
      pg_cmd_check_intent "$@"
      ;;
    revoke)
      pg_cmd_revoke "$@"
      ;;
    doctor)
      pg_cmd_doctor "$@"
      ;;
    bind-pr)
      pg_cmd_bind_pr "$@"
      ;;
    stack-store-init)
      pg_cmd_stack_store_init "$@"
      ;;
    stack-store-add)
      pg_cmd_stack_store_add "$@"
      ;;
    stack-store-move)
      pg_cmd_stack_store_move "$@"
      ;;
    stack-store-remove)
      pg_cmd_stack_store_remove "$@"
      ;;
    stack-store-manifest)
      pg_cmd_stack_store_manifest "$@"
      ;;
    stack-store-list)
      pg_cmd_stack_store_list "$@"
      ;;
    stack-store-record-materialization)
      pg_cmd_stack_store_record_materialization "$@"
      ;;
    stack-store-branch-materialization)
      pg_cmd_stack_store_branch_materialization "$@"
      ;;
    guard-check)
      local command_text=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --command)
            command_text="$2"
            shift 2
            ;;
          *)
            pg_fail "Unknown guard-check option: $1"
            return 1
            ;;
        esac
      done
      pg_validate_push_guard "$command_text"
      ;;
    ""|help|--help|-h)
      cat <<'EOF'
Push-gate — agent prepares, human approves, agent pushes.

The canonical three-step flow (one command per actor):

  1. AGENT:  pg prepare --what "..." --why "..." --approach "..." [--async --expires 8h --max-pushes 20 --allow-rewrite]
             Use --low-stakes as reviewed shorthand for --async --expires 1h --max-pushes 5.
             Captures the agent's real context before handoff.

  2. HUMAN:  pg [-C <path>] [--yes]
             Opens vim on the agent's brief, review, y/N, lease written.
             --yes still opens the editor; it only skips the final y/N prompt.

  3. AGENT:  pg push --assert-flow "..."
             Scope + semantic checks run, then git push.

Status / inspection:

  pg leases                        All active leases across repos.

Useful inspection:

  pg check [branch]         Is HEAD within the approved scope? (JSON)
  pg check-trunk --stack S  Is the materialized stack trunk still approved? (JSON)
  pg check-intent [branch]  LLM: does the diff match user_intent? (JSON)
  pg show   [branch]        Full lease dump for a branch.
  pg revoke [branch]        Drop a lease (new approval required).
  pg revoke-trunk --stack S Drop a trunk lease (new approval required).

Stack trunks:

  pg prepare-trunk --stack S --what "..." --why "..." --approach "..." [--item-briefs FILE] [--async --expires 8h --max-pushes 30 --allow-rewrite]
                         Agent handoff for approving a materialized trunk.
                         --low-stakes is reviewed shorthand for --async --expires 1h --max-pushes 5.
  pg prepare-trunk status --stack S --json
                         Structured prepare-trunk state and repo-pinned next
                         commands for UIs and automation.
  pg trunk --stack S [--yes]
                         Human review/approval for the whole stack trunk.
                         --yes still opens the editor; it only skips the final y/N prompt.
                         Draft uses stack items with pointer commits, contained commits, and file groups.
  pg trunk-draft --stack S [--format yaml|json] [--out FILE]
                         Create the same review draft without opening an editor.
                         Used by VS Code so the user can review/edit the YAML
                         natively before submitting approval.
  pg push --trunk-stack S --branch B --source-ref REF --assert-flow "..."
                         Push one approved item ref, or the approved private
                         trunk ref at trunk_tip.
  Dolt is required for trunk manifests/leases:
                         brew install dolt && dolt version
                         Store defaults to ~/.push-gate/dolt-store; PG_STORE_DIR overrides it.

Internal plumbing (called by pg/stack themselves; not primary user workflow):

  pg draft-approve      First half of pg: writes the YAML draft.
  pg approve --draft F  Second half: writes the lease after y/N.
  pg approve-trunk --draft F --reviewed-in-vscode
                         Writes a trunk lease from a saved VS Code-reviewed draft.
  pg stack-store-*      Dolt-backed stack manifest/materialization storage,
                         including init/add/move/remove/materialization.
  pg preview-draft      Renders the summary the approval script shows.
  pg guard-check        Called by bash-safety-guard on every git push.

Escape hatches:

  -C <path>                Run as if pg were invoked in <path>.
  PG_USE_LLM=0             Skip LLM interview (you fill brief manually).
  PG_DEBUG=1               Print codex stderr + decision traces.
EOF
      ;;
    *)
      pg_fail "Unknown push-gate command: $command"
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  pg_main "$@"
fi
