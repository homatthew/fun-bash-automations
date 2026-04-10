---
name: beads
description: Create and manage beads (lightweight issue tracker with dependency support) from plan breakdowns. Use when a plan has story/task breakdowns that need tracking with dependencies.
---

# Beads: Lightweight Issue Tracking with Dependencies

Use `bd` to track implementation progress across sessions. Beads survive context compaction — run `bd ready` to pick up where you left off.

## Centralized Database

Beads are stored centrally in `~/repos/dump/.beads/beads.db`. The `BD_DB` env var is set in zshrc, so `bd` commands work from any CWD without `--db`. Use `repo:<name>` labels to filter by repo.

If `BD_DB` is not set in the environment (e.g., in a fresh agent), pass explicitly:
```bash
bd --db ~/repos/dump/.beads/beads.db ready -l repo:cde-dgw-kv
```

## Creating Beads from a Plan

### 1. Create the Epic

```bash
EPIC=$(bd create "Feature Name" \
  -t epic \
  -l "repo:repo-name,feature-label" \
  -d "High-level description of the feature." \
  --silent)
```

### 2. Create Story Beads with Dependencies

```bash
# No-dep beads (foundation layer)
B1=$(bd create "Story title" \
  -l "repo:repo-name,feature-label" -p 1 --parent "$EPIC" \
  -d "What to do." \
  --acceptance "How to verify it's done." \
  --silent)

# Beads with dependencies
B3=$(bd create "Depends on B1" \
  -l "repo:repo-name,feature-label" -p 1 --parent "$EPIC" --deps "$B1" \
  -d "Description." \
  --acceptance "Acceptance criteria." \
  --silent)

# Multiple dependencies (comma-separated)
B7=$(bd create "Depends on B3 and B4" \
  --parent "$EPIC" --deps "$B3,$B4" \
  --silent)
```

### Key Flags

| Flag | Purpose |
|------|---------|
| `--parent ID` | Set parent epic |
| `--deps ID[,ID]` | Set dependency beads (comma-separated) |
| `-p N` | Priority (1=highest) |
| `-t TYPE` | Type: `epic`, `feature`, `task` (default), `bug` |
| `-l "a,b"` | Labels (comma-separated) |
| `-d "text"` | Description |
| `--acceptance "text"` | Acceptance criteria |
| `--silent` | Output only the bead ID |

## Working with Beads

### What can I work on now?

```bash
bd ready                        # All unblocked beads
bd ready -l zstd-dict           # Filter by label
bd ready --parent dump-lyq      # Filter by epic
```

### Lifecycle

```bash
bd update ID --status in_progress   # Start working
bd close ID                         # Done — unblocks dependents
bd reopen ID                        # Reopen if needed
```

### Viewing

```bash
bd list --parent EPIC           # All beads in epic
bd graph EPIC                   # Visual dependency graph
bd show ID                      # Full details of a bead
bd children EPIC                # Direct children only
```

### Searching

```bash
bd search "compression"         # Text search across all beads
bd list -l zstd-dict            # Filter by label
bd list --status open           # Filter by status
```

## Dependency Patterns for Phased Work

### Parallel Foundation → Sequential Build

```
Phase 1 (parallel):  B1, B2         (no deps)
Phase 2 (parallel):  B3→B2, B4→B2   (dep on Phase 1)
Phase 3 (serial):    B5→B4          (dep on Phase 2)
Phase 4 (converge):  B7→B3,B4,B5    (multiple deps)
Phase 5 (final):     B9→B7,B8       (integration)
```

### Diamond Pattern

When two paths converge:
```bash
B_merge=$(bd create "Merge step" --deps "$B_left,$B_right" --silent)
```

## Integration with Plan Mode

### Plan → Beads Workflow

1. **Plan mode**: Design architecture, write plan file
2. **Create beads**: Turn plan stories into tracked beads with deps
3. **Execute**: Use `bd ready` to find next work, `bd update` to track progress
4. **Survive compaction**: Agent runs `bd ready -l label` to resume

### Multi-Session Resumption

Session 1 completes Phase 1. Session 2:
```bash
bd ready -l feature-label    # Shows Phase 2 beads now unblocked
bd show BEAD_ID              # Read description for context
bd update BEAD_ID --status in_progress
# ... do work ...
bd close BEAD_ID
```

### Checking Progress

```bash
bd list --parent EPIC    # Overview of all beads
bd graph EPIC            # Visual dep graph with status
```

## Tips

- Use `--silent` in scripts to capture just the ID
- Labels like `repo:name` help filter across projects
- `bd graph` shows layers — work left-to-right through layers
- Close beads as you go — dependents auto-unblock
- Epic beads group related work; close when all children done
