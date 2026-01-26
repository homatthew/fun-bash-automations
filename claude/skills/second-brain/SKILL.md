---
name: second-brain
description: Persist architectural insights to ~/repos/dump/second-brain
---

# Second Brain

Manage architectural knowledge in ~/repos/dump/second-brain/.

## Usage

- `/second-brain add <topic>` - Create new topic
- `/second-brain update <topic>` - Update existing topic
- `/second-brain search <query>` - Search existing topics

## Add Topic

1. Check it doesn't exist:
   ```bash
   ls ~/repos/dump/second-brain/topics/<topic>/ 2>/dev/null || echo "Topic available"
   ```

2. Create from template:
   ```bash
   mkdir -p ~/repos/dump/second-brain/topics/<topic>
   cp ~/repos/dump/second-brain/_templates/topic.md ~/repos/dump/second-brain/topics/<topic>/CLAUDE.md
   ```

3. Fill in all sections:
   - **Last Reviewed:** Today's date + current commit hash from `git -C ~/repos/dump/second-brain rev-parse --short HEAD`
   - **Overview:** 2-3 sentences
   - **How to Find:** Paths, grep patterns, key files
   - **Key Insights:** Non-obvious learnings
   - **Verification:** Command to check staleness

4. Add to topic index in ~/repos/dump/second-brain/CLAUDE.md

5. Commit:
   ```bash
   cd ~/repos/dump/second-brain
   git add topics/<topic>/CLAUDE.md CLAUDE.md
   git commit -m "second-brain: add <topic> - <brief description>"
   ```

## Update Topic

1. Read existing topic
2. Merge changes (preserve structure)
3. Update Last Reviewed
4. Commit: `second-brain: update <topic> - <what changed>`

## Search Topics

```bash
# Search index
grep -i "<query>" ~/repos/dump/second-brain/CLAUDE.md

# Search topic names
ls ~/repos/dump/second-brain/topics/ | grep -i "<query>"

# Full-text search
grep -ri "<query>" ~/repos/dump/second-brain/topics/
```
