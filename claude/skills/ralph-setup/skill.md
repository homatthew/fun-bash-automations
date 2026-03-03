---
name: ralph-setup
description: "DEPRECATED — simple-ralph works without setup. Create .ralphrc manually if needed."
---

# Ralph Setup — DEPRECATED

The `ralph init` command was part of the full Ralph Python package, which is deprecated.

`simple-ralph` works out of the box with no setup. If you want to customize tool permissions
or iteration limits, create a `.ralphrc` file manually:

```bash
# .ralphrc — optional config for simple-ralph
RALPH_TOOLS="Edit Read Write Glob Grep Bash"
RALPH_MAX_ITER=50
RALPH_MAX_TURNS=20
```

Add `.ralphrc` and `.ralph/` to `.gitignore` if not already present.
