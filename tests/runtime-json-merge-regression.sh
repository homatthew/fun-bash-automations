#!/usr/bin/env bash
set -euo pipefail

# fba-deploy projects ~/.claude/settings.json and ~/.codex/hooks.json into live
# files that other tools also write: the Claude enterprise wrapper (env, auth),
# cmux (its own hook registrations), the dotfiles private overlay (internal
# guards), and the user by hand (local alert hooks). It used to copy over them,
# silently dropping all of it every deploy.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/bin/fba-merge-runtime-json.py"
TMP="$(mktemp -d -t fba-runtime-json-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Hook registrations are kept when their script exists, so the fixtures need
# real files. gone.sh is deliberately never created.
export HOME="$TMP"
mkdir -p "$TMP/.claude/hooks" "$TMP/.cmux/hooks"
for script in bash-safety-guard.sh notify.sh beads-prime.sh dgw-write-guard.sh; do
    touch "$TMP/.claude/hooks/$script"
done
touch "$TMP/.cmux/hooks/cmux-feed.sh" "$TMP/.cmux/hooks/cmux-session-start.sh"

cat >"$TMP/repo.json" <<'JSON'
{
  "env": {"DISABLE_AUTOUPDATER": "1"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/bash-safety-guard.sh", "type": "command"}]}
    ]
  },
  "model": "repo-model",
  "permissions": {"allow": ["Bash(git status:*)"]}
}
JSON

cat >"$TMP/live.json" <<'JSON'
{
  "apiKeyHelper": "/private/helper.sh",
  "env": {"ANTHROPIC_BASE_URL": "http://gateway.internal/", "DISABLE_AUTOUPDATER": "0"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/bash-safety-guard.sh", "type": "command"}]},
      {"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/dgw-write-guard.sh", "type": "command"}]},
      {"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/gone.sh", "type": "command"}]},
      {"hooks": [{"command": "~/.cmux/hooks/cmux-feed.sh", "type": "command"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"command": "~/.claude/hooks/notify.sh", "type": "command"}]}
    ],
    "SessionStart": [
      {"hooks": [
        {"command": "~/.claude/hooks/beads-prime.sh", "type": "command"},
        {"command": "~/.cmux/hooks/cmux-session-start.sh", "type": "command"}
      ]}
    ]
  },
  "model": "stale-model",
  "permissions": {"allow": ["Bash(git status:*)", "Bash(ls:*)"]},
  "verbose": true
}
JSON

python3 "$MERGE" "$TMP/repo.json" "$TMP/live.json" >"$TMP/out.json"

python3 - "$TMP/out.json" <<'PY'
import json, sys

merged = json.load(open(sys.argv[1]))


def commands(event):
    return [h["command"] for g in merged["hooks"].get(event, []) for h in g["hooks"]]


def check(label, condition):
    if not condition:
        print(f"runtime-json merge: {label}", file=sys.stderr)
        raise SystemExit(1)


# Repo-owned keys win, live-only keys survive.
check("repo key must win", merged["model"] == "repo-model")
check("live-only key must survive", merged["apiKeyHelper"] == "/private/helper.sh")
check("live-only key must survive", merged["verbose"] is True)

# env: union, repo wins on conflict.
check("live env must survive", merged["env"]["ANTHROPIC_BASE_URL"] == "http://gateway.internal/")
check("repo env must win", merged["env"]["DISABLE_AUTOUPDATER"] == "1")

# permissions: union without duplicates.
check("permissions must union", merged["permissions"]["allow"] == ["Bash(git status:*)", "Bash(ls:*)"])

pre = commands("PreToolUse")
# A registration present on both sides must not be duplicated.
check("repo hook must appear once", pre.count("~/.claude/hooks/bash-safety-guard.sh") == 1)
# Foreign registrations survive: private overlay and third-party alike.
check("private overlay hook must survive", "~/.claude/hooks/dgw-write-guard.sh" in pre)
check("cmux hook must survive", "~/.cmux/hooks/cmux-feed.sh" in pre)
# A registration whose script is gone is a dead pointer and gets dropped.
check("dead registration must be dropped", "~/.claude/hooks/gone.sh" not in pre)

# A local opt-in to a hook this repo ships but does not register must survive:
# the portable baseline registers no alert hooks, but a machine may want them.
check("local notify opt-in must survive", commands("Stop") == ["~/.claude/hooks/notify.sh"])

# Mixed groups keep every live entry whose script exists.
sess = commands("SessionStart")
check("mixed group must keep both live hooks",
      sess == ["~/.claude/hooks/beads-prime.sh", "~/.cmux/hooks/cmux-session-start.sh"])

# Merging twice must be a no-op.
PY

python3 "$MERGE" "$TMP/repo.json" "$TMP/out.json" >"$TMP/twice.json"
if ! diff -q "$TMP/out.json" "$TMP/twice.json" >/dev/null; then
    echo "runtime-json merge: merging twice must be idempotent" >&2
    diff "$TMP/out.json" "$TMP/twice.json" >&2 || true
    exit 1
fi

# No live file yet: fba-deploy copies instead of merging.
if python3 "$MERGE" "$TMP/repo.json" "$TMP/missing.json" 2>/dev/null; then
    echo "runtime-json merge: expected failure on a missing live file" >&2
    exit 1
fi

echo "runtime json merge regression passed"
