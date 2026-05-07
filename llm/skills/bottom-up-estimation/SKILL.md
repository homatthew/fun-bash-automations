---
name: bottom-up-estimation
description: Estimate engineering work, timelines, LOE, milestones, roadmap plans, or "how long will this take" requests using bottom-up task decomposition instead of hallucinated calendar dates.
---

# Bottom-Up Estimation

Use this skill whenever estimating engineering effort or turning a plan into timelines.

## Hard Rules

- Do not invent calendar weeks directly.
- Separate focused engineering effort from calendar time.
- Separate implementation effort from validation, review, integration, and external waiting.
- Use `TBD` or `unknown until investigated` when evidence is missing.
- Never hide stakeholder review, source-of-truth decisions, access setup, or data reconciliation inside engineering effort.
- If the user challenges an estimate, expose the work-unit math and remove any number that cannot be defended.

## Estimation Workflow

1. **Classify the estimate**
   - Rough order of magnitude: directional planning, high uncertainty.
   - Planning estimate: task-level breakdown with evidence.
   - Commitment estimate: owned, reviewed, dependencies understood.
   - Workback: target date is fixed; estimate scope/people tradeoffs.

2. **Define done**
   - Name the deliverable.
   - State how it will be verified.
   - State what is explicitly out of scope.

3. **Break into work units**
   - Keep each unit concrete enough to estimate directly.
   - Prefer units around implementation, tests/validation, data backfill, rollout, docs, and operational support.
   - Add separate units for discovery when the code path, owner, source table, or API is unknown.

4. **Attach evidence**
   - For each unit, cite the source: code path, doc, owner statement, prior implementation, query, runbook, or known gap.
   - If there is no evidence, do not assign a precise estimate.

5. **Estimate focused effort**
   - Estimate low / likely / high focused engineering time per unit.
   - Include validation and cleanup.
   - Add risk buffer only for a named risk.

6. **Track external wait**
   - Record review latency, access requests, schema approval, stakeholder decisions, data reconciliation, and deployment gates separately.

7. **Convert to calendar last**
   - Ask for actual allocation before giving dates.
   - Use:

```text
calendar time = focused engineering effort / allocated engineering capacity + external wait
```

## Output Shape

For planning docs, use:

```markdown
## Scope
[What is being estimated and what is excluded.]

## Assumptions
- [Assumption with evidence or owner.]

## Work Breakdown
| Milestone | Work Unit | Output | Evidence | Unknowns | Focused Effort | External Wait |
| --- | --- | --- | --- | --- | --- | --- |

## Focused Effort
[Sum low / likely / high only from estimated rows. Keep TBD rows out of totals.]

## Calendar Conversion
[Only after allocation is known.]

## Confidence
[High/medium/low and why.]

## Questions Before Commitment
- [Questions blocking a commitment estimate.]
```

## Quality Bar

An estimate is defensible when:

- Every numbered effort has a named work unit.
- High-risk rows have evidence or are marked `TBD`.
- Calendar time is derived from allocation, not guessed.
- External waits are visible.
- The user can inspect the table and argue with individual rows.
