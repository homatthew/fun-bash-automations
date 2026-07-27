#!/usr/bin/env python3
"""Merge a repo-owned runtime JSON file into its live counterpart.

Used by fba-deploy for ~/.claude/settings.json and ~/.codex/hooks.json. Both are
live runtime state written by things other than this repo -- the Claude
enterprise wrapper, cmux, the dotfiles overlay -- so projecting them with a
plain copy silently discarded that state on every deploy.

Merge rules:
  * top level      repo keys win; keys only the live file has are preserved
  * env            union, repo values win on conflicting keys
  * permissions    per list (allow/deny/ask), repo entries first, then live-only
  * hooks          repo registrations win; live registrations are preserved only
                   when the script they call is not repo-owned, so retiring a
                   hook in this repo still removes it downstream

Usage: repo_managed_hook_names | fba-merge-runtime-json.py <repo-json> <live-json>
Writes the merged document to stdout.
"""

import json
import os
import sys


def hook_script_name(command):
    """Basename of the script a hook entry runs, ignoring any arguments."""
    if not isinstance(command, str):
        return ""
    parts = command.strip().split()
    return os.path.basename(parts[0]) if parts else ""


def merge_hooks(repo_hooks, live_hooks, managed):
    merged = {event: list(groups) for event, groups in repo_hooks.items()}

    for event, groups in live_hooks.items():
        for group in groups:
            if not isinstance(group, dict):
                continue
            entries = group.get("hooks", [])
            foreign = [
                entry
                for entry in entries
                if hook_script_name(entry.get("command", "")) not in managed
            ]
            if not foreign:
                continue
            if len(foreign) == len(entries):
                merged.setdefault(event, []).append(group)
            else:
                merged.setdefault(event, []).append({**group, "hooks": foreign})

    return merged


def merge_lists(repo_list, live_list):
    merged = list(repo_list)
    merged.extend(item for item in live_list if item not in repo_list)
    return merged


def merge(repo, live, managed):
    merged = dict(live)

    for key, value in repo.items():
        live_value = live.get(key)

        if key == "hooks" and isinstance(value, dict):
            merged[key] = merge_hooks(
                value, live_value if isinstance(live_value, dict) else {}, managed
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
    managed = {line.strip() for line in sys.stdin if line.strip()}

    with open(repo_path) as handle:
        repo = json.load(handle)
    with open(live_path) as handle:
        live = json.load(handle)

    json.dump(merge(repo, live, managed), sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
