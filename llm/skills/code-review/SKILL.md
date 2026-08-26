---
name: code-review
description: Use when reviewing or re-reviewing a PR, branch, staged or unstaged diff, or a proposed review finding. Produces evidence-backed, author-facing findings and may use ctxreview when the user requests independent opinions.
---

# Code review

Review one defined change. Return only findings that survive an attempt to
disprove them. It is valid to find no blocking issue.

## Workflow

1. Resolve the review scope:
   - PR: inspect its title, body, commits, files, and diff with `gh`.
   - Branch: compare the merge base with the repository's default branch.
   - Staged or unstaged work: use the corresponding `git diff`.
   - If no scope is discoverable, ask what to review.
2. Gather the author's intent from the PR, commits, linked issue, and applicable
   repository instructions.
3. Build the local evidence pack:

   ```bash
   review_pack="$(mktemp "${TMPDIR:-/tmp}/ctxpack-review.XXXXXX")"
   ctxpack build --out "$review_pack"
   ```

   Read the matched code-bible rules, lenses, personas, and cited sibling
   examples before relying on them. Treat lexical precedent as a lead, not a
   finding. If the corpus is absent, continue and state what was unavailable.
4. State a short working hypothesis: the business invariant, relevant operating
   constraints, and what a wrong implementation would do. Continue unless a
   real ambiguity would materially change the review scope.
5. Review locally once by default. Run focused checks when they can settle a
   candidate finding. Do not edit the code unless the user separately asks for
   fixes.
6. For every candidate finding:
   - trace the complete path through callers and downstream consumers;
   - check expected scale, rollout, retention, ownership, and existing
     guarantees;
   - distinguish a reachable failure from a design preference or future need;
   - cite the file, line, evidence, consequence, and smallest useful fix;
   - remove the finding if its premise or impact does not survive verification.

## Independent review with ctxreview

Use `ctxreview` only when the user requests delegation, parallel review, or an
independent opinion. It owns pack construction, reviewer prompts, isolated
sessions, transcripts, and lifecycle. Do not recreate those mechanics in this
skill.

```bash
ctxreview run --legs kimi,grok,sol,opus [--base REF]
```

- Respect the prompt-size cap. Narrow or split the scope instead of forcing an
  oversized review unless the user explicitly accepts the limitation.
- Consolidate with `ctxreview --consolidate DIR`, then adjudicate every candidate
  locally. Reviewer agreement raises attention, not truth or severity.
- Use `ctxreview run --again --legs LIST` for re-review after fixes. Do not ask a reviewer to
  judge its own prior finding; reuse old legs only to explain their reasoning.
- Close a settled round with `ctxreview --close RUN` when it is no longer needed.

## Output

List immediate changes first, then future prerequisites and non-blocking
suggestions. For each item, give the location, evidence, reachable impact, and
smallest fix. If no finding survives, say so and name any important evidence
that remained unavailable.
