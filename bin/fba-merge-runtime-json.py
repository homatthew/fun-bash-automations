#!/usr/bin/env python3
"""Merge a repo-owned runtime JSON file into its live counterpart.

Used by fba-deploy for ~/.claude/settings.json and ~/.codex/hooks.json. Both are
live runtime state written by things other than this repo -- the Claude
enterprise wrapper, cmux, the dotfiles overlay, the user by hand -- so
projecting them with a plain copy silently discarded that state on every deploy.

Merge rules:
  * top level      repo keys win; keys only the live file has are preserved
  * env            union, repo values win on conflicting keys
  * permissions    per list (allow/deny/ask), repo entries first, then live-only
  * hooks          the repo's registrations are always applied; a live
                   registration is kept when the script it runs still exists on
                   disk, and dropped when it points at a script that is gone

The hook rule is deliberately about the script existing, not about who owns it.
The portable baseline intentionally registers no alert hooks, but a machine may
still opt into notify.sh locally; treating "repo ships the script but does not
register it" as a retirement would delete that opt-in on every deploy. Removing
a hook for real means removing its script.

Usage: fba-merge-runtime-json.py <repo-json> <live-json>
Writes the merged document to stdout.
"""

import json
import os
import sys


def hook_script_path(command):
    """Path of the script a hook entry runs, or "" if it is not a plain path."""
    if not isinstance(command, str):
        return ""
    parts = command.strip().split()
    if not parts or "/" not in parts[0]:
        return ""
    return os.path.expanduser(parts[0])


def registration_is_live(entry):
    path = hook_script_path(entry.get("command", ""))
    # Anything that is not a plain script path (a shell snippet, say) is left
    # alone rather than guessed at.
    return not path or os.path.exists(path)


def merge_hooks(repo_hooks, live_hooks):
    merged = {event: list(groups) for event, groups in repo_hooks.items()}
    repo_commands = {
        entry.get("command")
        for groups in repo_hooks.values()
        for group in groups
        if isinstance(group, dict)
        for entry in group.get("hooks", [])
    }

    for event, groups in live_hooks.items():
        for group in groups:
            if not isinstance(group, dict):
                continue
            keep = [
                entry
                for entry in group.get("hooks", [])
                if entry.get("command") not in repo_commands
                and registration_is_live(entry)
            ]
            if not keep:
                continue
            merged.setdefault(event, []).append({**group, "hooks": keep})

    return merged


def merge_lists(repo_list, live_list):
    merged = list(repo_list)
    merged.extend(item for item in live_list if item not in repo_list)
    return merged


def merge(repo, live):
    merged = dict(live)

    for key, value in repo.items():
        live_value = live.get(key)

        if key == "hooks" and isinstance(value, dict):
            merged[key] = merge_hooks(
                value, live_value if isinstance(live_value, dict) else {}
            )
        elif key == "env" and isinstance(value, dict) and isinstance(live_value, dict):
            combined = dict(live_value)
            combined.update(value)
            merged[key] = combined
        elif (
            key == "permissions"
            and isinstance(value, dict)
            and isinstance(live_value, dict)
        ):
            combined = dict(live_value)
            for name, entries in value.items():
                if isinstance(entries, list) and isinstance(combined.get(name), list):
                    combined[name] = merge_lists(entries, combined[name])
                else:
                    combined[name] = entries
            merged[key] = combined
        else:
            merged[key] = value

    return merged


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    repo_path, live_path = sys.argv[1], sys.argv[2]

    with open(repo_path) as handle:
        repo = json.load(handle)
    with open(live_path) as handle:
        live = json.load(handle)

    json.dump(merge(repo, live), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
