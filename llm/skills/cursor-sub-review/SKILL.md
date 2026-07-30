---
name: cursor-sub-review
description: Run an independent, read-only Cursor Agent code-review leg reliably. Use when a review needs a Cursor model such as Kimi K3 or Claude Opus, especially from Codex or another headless harness where buffered output, concurrent Cursor configuration races, or stalled reviewers must be handled safely.
---

# Cursor Sub-Review

Run one Cursor reviewer at a time with `scripts/run-review.sh`. Keep business-hypothesis formation and final finding consolidation in the parent review workflow.

## Prepare the review

Write one self-contained prompt file containing:

- the confirmed business invariant and wrong-solution boundary;
- the full diff or an absolute path to a review bundle containing it;
- changed files, PR context, and relevant domain context;
- instructions to report only introduced defects with file/line evidence;
- known verification and an explicit ban on edits and git writes.

Do not ask Cursor to reconstruct a diff from current files when the distinction between introduced and pre-existing behavior matters.

## Run one reviewer

```bash
review_skill="/absolute/path/to/cursor-sub-review"
"$review_skill/scripts/run-review.sh" \
  --workspace "$PWD" \
  --prompt /absolute/path/to/review-prompt.md \
  --model kimi-k3-high
```

The runner:

- uses read-only `ask` mode;
- enables `stream-json` and partial output so progress is observable;
- writes JSONL, stderr, exit status, and the extracted final result to a temporary result directory;
- rejects concurrent wrapper launches to avoid the shared `~/.cursor/cli-config.json` race;
- stops after a real no-progress stall or hard timeout;
- preserves failed-run diagnostics.

Read only the reported `result` file for review findings. Do not paste reasoning JSONL into the user transcript.

## Model choice and retry

Resolve exact model identifiers with `cursor-agent --list-models`. Prefer the requested model and do not silently downgrade it.

If the runner exits `124`:

1. Inspect the small stderr file and the last few JSONL event types.
2. Retry the same model once if the failure looks local or transient.
3. Use another tier only when the user permits it, and report the substitution.
4. If both attempts fail, mark that review leg unavailable; never invent findings.

Run multiple Cursor opinions sequentially. Worktrees isolate repository files but do not isolate Cursor's user-level CLI configuration.

## Consolidate

Treat Cursor output as dissent, not authority. Verify every proposed finding against the actual diff and the confirmed business invariant. Reject style-only churn, pre-existing issues, and behavior the user explicitly chose.
