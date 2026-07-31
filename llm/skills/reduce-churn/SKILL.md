---
name: reduce-churn
description: Audit a change against its actual merge target and remove unrelated code, formatting, comment, API, and test churn before commit, push, or PR delivery. Use when finishing feature work, updating an existing PR, or reviewing a diff that may have accumulated cleanup beyond its stated claim.
---

# Reduce churn

Use this skill before delivery whenever the diff is larger than the requested behavior or the work has been iterated on by multiple agents.

## Workflow

1. Identify the actual merge target. For a PR, use its base branch; for a direct delivery, use the protected delivery branch. Fetch it if needed.
2. Compare the work to the target with the merge-base/three-dot diff:

   ```bash
   base=$(git merge-base origin/<target> HEAD)
   git diff --stat "$base"
   git diff --check "$base"
   ```

   Do not use `git diff origin/<target> HEAD` as the PR-scope comparison; that two-dot form also shows changes made on the target after the branch diverged.
3. Inspect the complete diff, then classify each hunk as:
   - required for the stated behavior;
   - required compatibility/test coverage; or
   - unrelated churn (style-only rewrites, renamed locals, reordered functions/imports, explanatory essays, dead APIs, speculative fallbacks, and opportunistic refactors).
4. Revert unrelated churn. Preserve established control flow, names, formatting, telemetry, and comments unless changing them is required by the behavior or explicitly requested. Remove a newly added API only when repository call-site search shows it has no production consumer and the removal is within scope.
5. Re-run the focused tests and lint/format checks after trimming. Inspect the final merge-base diff again. Check the working-tree diff separately so uncommitted edits are not missed.
6. Before pushing, report the target branch, merge-base, changed files, intentionally retained behavior, and any remaining non-obvious diff. Do not push while the classification is unresolved.

## Guardrails

- Keep one PR to one reviewable claim. Split an unrelated refactor instead of hiding it in a behavior change.
- Treat comments as code: retain concise contract comments; remove benchmark narratives and implementation history that do not help the next reader operate the code.
- Prefer the smallest compatible edit. Do not “improve” a line merely because a different spelling is possible.
- A smaller diff is not automatically better: retain correctness fixes, resource cleanup, observability, and tests that protect the changed contract.
- If the target branch moved during review, recompute the merge base before the final audit.

## Completion report

State:

- merge target and comparison used;
- unrelated churn removed (or why none was removed);
- verification run and result;
- whether the final diff is ready for delivery.
