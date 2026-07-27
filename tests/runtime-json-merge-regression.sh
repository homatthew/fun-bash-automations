#!/usr/bin/env bash
set -euo pipefail

# fba-deploy projects ~/.claude/settings.json and ~/.codex/hooks.json into live
# files that other tools also write: the Claude enterprise wrapper (env, auth),
# cmux (its own hook registrations), and the dotfiles private overlay (internal
# guards). It used to copy over them, silently dropping all of it every deploy.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE="$ROOT/bin/fba-merge-runtime-json.py"
TMP="$(mktemp -d -t fba-runtime-json-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# bash-safety-guard.sh and notify.sh are repo-owned; the rest are foreign.
managed=$'bash-safety-guard.sh\nnotify.sh\nbeads-prime.sh'

cat >"$TMP/repo.json" <<'JSON'
{
  "env": {"DISABLE_AUTOUPDATER": "1"},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/bash-safety-guard.sh", "type": "command"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"command": "~/.claude/hooks/notify.sh", "type": "command"}]}
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
      {"hooks": [{"command": "~/.cmux/hooks/cmux-feed-PreToolUse.sh", "type": "command"}]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [{"command": "~/.claude/hooks/notify.sh", "type": "command"}]}
    ],
    "PostCompact": [
      {"hooks": [{"command": "~/.cmux/hooks/cmux-feed-PostCompact.sh", "type": "command"}]}
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

printf '%s\n' "$managed" | python3 "$MERGE" "$TMP/repo.json" "$TMP/live.json" >"$TMP/out.json"

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
# A repo-owned hook registered on both sides must not be duplicated.
check("repo hook must appear once", pre.count("~/.claude/hooks/bash-safety-guard.sh") == 1)
# Foreign registrations survive: private overlay and third-party alike.
check("private overlay hook must survive", "~/.claude/hooks/dgw-write-guard.sh" in pre)
check("cmux hook must survive", "~/.cmux/hooks/cmux-feed-PreToolUse.sh" in pre)

# A whole event only the live file knows about survives.
check("live-only event must survive", commands("PostCompact") == ["~/.cmux/hooks/cmux-feed-PostCompact.sh"])

# Repo hooks registered only in the repo still land.
check("repo notify hook must land", commands("Stop") == ["~/.claude/hooks/notify.sh"])

# A group mixing repo-owned and foreign hooks keeps only the foreign entries,
# so the repo copy is not duplicated but the third-party one is not lost.
sess = commands("SessionStart")
check("mixed group must drop the managed duplicate", "~/.claude/hooks/beads-prime.sh" not in sess)
check("mixed group must keep the foreign hook", sess == ["~/.cmux/hooks/cmux-session-start.sh"])
PY

# Retiring a repo hook must still remove it downstream.
cat >"$TMP/repo-retired.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"command": "~/.claude/hooks/bash-safety-guard.sh", "type": "command"}]}]}}
JSON
printf '%s\n' "$managed" | python3 "$MERGE" "$TMP/repo-retired.json" "$TMP/live.json" >"$TMP/retired.json"
python3 - "$TMP/retired.json" <<'PY'
import json, sys
merged = json.load(open(sys.argv[1]))
stop = [h["command"] for g in merged["hooks"].get("Stop", []) for h in g["hooks"]]
if stop:
    print(f"runtime-json merge: retired repo hook must not persist, got {stop}", file=sys.stderr)
    raise SystemExit(1)
PY

# No live file yet: fba-deploy copies instead of merging.
if printf '%s\n' "$managed" | python3 "$MERGE" "$TMP/repo.json" "$TMP/missing.json" 2>/dev/null; then
    echo "runtime-json merge: expected failure on a missing live file" >&2
    exit 1
fi

echo "runtime json merge regression passed"
