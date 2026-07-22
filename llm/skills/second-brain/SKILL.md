---
name: second-brain
description: Persist reusable architectural insights in a configured knowledge repository
---

# Second Brain

Manage architectural knowledge in `SECOND_BRAIN_DIR`. Resolve it without
writing outside the selected repository:

```bash
SECOND_BRAIN_DIR="${SECOND_BRAIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/second-brain}"
```

If the directory does not exist, ask before creating it. Do not assume a
personal repository layout.

## Usage

- `/second-brain add <topic>` - Create a topic
- `/second-brain update <topic>` - Update a topic
- `/second-brain search <query>` - Search topics

## Add or Update

1. Resolve and validate `SECOND_BRAIN_DIR`.
2. Search `topics/` and the root `README.md` for the topic.
3. For a new topic, copy `_templates/topic.md` when present; otherwise create a
   concise README with Overview, How to Find, Key Insights, and Verification.
4. For an existing topic, merge new insights and preserve its structure.
5. Update the root index when present.
6. Commit only when the active work mode and user request permit it.

## Search

```bash
rg -i "<query>" "$SECOND_BRAIN_DIR/README.md" "$SECOND_BRAIN_DIR/topics"
```
