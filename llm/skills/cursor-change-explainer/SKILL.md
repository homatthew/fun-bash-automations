---
name: cursor-change-explainer
description: Use Cursor Agent as a read-only visual explainer for a local diff, branch, or PR. Produces one compact terminal-friendly ASCII diagram or table plus short verified bullets. Trigger when the user asks to visualize, illustrate, walk through, or explain how a code change works.
---

# Cursor Change Explainer

Use Cursor for the first visual draft. The parent agent owns scope, accuracy,
and the final answer.

## Prepare exact evidence

1. Resolve the repository, user goal, and comparison base.
2. Include committed, staged, unstaged, and relevant untracked changes.
3. Record tests that actually ran and any known uncertainty.
4. Keep confidential values out of the final explanation. Add a redaction note
   when the diff or local context contains private data.

Write a temporary prompt from `templates/prompt.md`. Replace every bracketed
field. Give Cursor exact diff commands or an absolute evidence-bundle path.
Never ask it to infer the change boundary from filenames alone.

## Run Cursor read-only

Use the sibling `cursor-sub-review` runner. It handles approval prompts,
isolated MCP state, progress, timeout, and result capture.

```bash
cursor_runner="/absolute/path/to/cursor-sub-review/scripts/run-review.sh"
"$cursor_runner" \
  --workspace "$repo" \
  --prompt "$prompt_file" \
  --model composer-2.5 \
  --output-dir "$result_dir"
```

Run one Cursor session at a time. Read only `cursor.result.md`; do not stream or
paste the reasoning transcript. Extract only the text between
`BEGIN VERIFIED DRAFT` and `END VERIFIED DRAFT`; missing markers mean the draft
failed. If the requested model is unavailable, report that instead of silently
choosing another.

## Verify and tighten

- Check every node, arrow, row, number, and behavior against the diff and code.
- Check each arrow is a real runtime transition. Keep alternative planner paths
  in separate lanes or branches.
- Remove pre-existing behavior presented as new.
- Remove duplicate bullets, generic claims, suggestions, and file-by-file churn.
- Preserve one visual only. Prefer an ASCII flow for runtime movement, a table
  for before/after behavior, a timeline for ordering, or a tree for ownership.
- Keep ASCII visuals readable in an 80-column terminal. Use Mermaid only when
  the user requests it or the destination is known to render it.
- If no visual improves understanding, return a compact before/after table.
- Follow the active `AGENTS.md`: lead with the result; use concrete names,
  mechanisms, and short bullets; cut sentences reusable in another project.

Cursor output is a draft, never a pass-through. The final answer must stand
alone. Do not include the draft markers or mention Cursor unless the user asks
how the explanation was produced.
