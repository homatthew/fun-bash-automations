---
name: beads-cleanup
description: "Explore beads state and clean up stale issues. Use periodically or when starting a new session to keep the tracker healthy."
---

# Beads Cleanup — Hygiene & Stale Issue Triage

Review all open beads, identify stale/abandoned work, and clean up.

## Steps

### 1. Get the lay of the land

```bash
bd stats
bd list --status=open
bd list --status=in_progress
bd blocked
```

Review the output. Look for:
- Issues that have been `in_progress` with no recent activity
- Open issues that reference completed or irrelevant work
- Blocked issues whose blockers are stale or no longer relevant
- Issues with no labels (hard to filter later)

### 2. Triage each stale issue

For each issue that looks stale, run `bd show <id>` and decide:

| Situation | Action |
|-----------|--------|
| Work is done but never closed | `bd close <id>` |
| Work is no longer needed | `bd close <id> --reason="No longer relevant: <why>"` |
| Blocked by something that was closed/deleted | `bd update <id> --status=open` (remove stale dep) |
| Still valid but not urgent | `bd defer <id>` |
| Description is outdated | `bd update <id> --description="Updated description"` |
| Missing repo label | `bd label <id> add repo:<name>` |

Close in bulk when possible: `bd close <id1> <id2> <id3>`

### 3. Clean up tombstones

If there are old deleted/closed issues cluttering the DB:

```bash
bd compact --prune --dry-run    # Preview tombstone cleanup
bd compact --prune              # Remove tombstones older than 30 days
```

### 4. Report summary

Tell the user:
- How many issues were open before / after
- What was closed and why
- What was deferred
- Any issues that need human decision (ambiguous state)

## Rules

- Always show the user what you plan to close/defer before doing it
- Use `--reason` on closes so there's a paper trail
- Don't delete issues unless they're clearly junk — prefer close with reason
- If unsure about an issue, flag it for the user rather than closing
- Run `bd sync` only when the active work mode permits git side effects.
  In Local Mode or Mentor Mode, leave Beads changes unsynced and report that
  persistence is pending human review.
