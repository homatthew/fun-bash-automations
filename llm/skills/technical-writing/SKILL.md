---
name: technical-writing
description: Use when the user asks to draft, rewrite, polish, or review technical prose such as docs, PR descriptions, design docs, runbooks, one-pagers, release notes, or engineering reports.
---

# Technical Writing

Use this as the prose quality pass for technical documents.

## Workflow

1. Preserve the facts. Do not invent metrics, commands, limits, error codes, owners, or outcomes.
2. Identify the artifact and reader: PR reviewer, engineering peer, leadership reader, on-call engineer, or future agent.
3. Rewrite section by section so each section can stand alone if retrieved without surrounding context.
4. Lead each section with the answer, then add context, caveats, examples, and failure cases.
5. For experiment or metrics writeups, apply the analysis rules before returning prose.
6. Run the final checklist before returning prose.

## Prose Standard

### Make Sections Stand Alone

- Give each section a descriptive heading.
- Replace dangling references such as "this", "it", "the above", and "as mentioned earlier" with the explicit subject.
- Include enough local context for a reader who jumps straight to the section to understand the claim.

### Lead With the Answer

- Start each section with one or two direct sentences that answer the heading.
- Put the conclusion before the supporting analysis.
- Move background, caveats, and rationale after the answer.
- Do **not** open every section with a bold sentence that only paraphrases the H2. If the answer is bold, it should carry new information—or be the only prose in that section.

### Use Concrete Subjects

- Prefer active voice with a named actor: "The deployment controller restarts each pod" instead of "Pods are restarted".
- Replace vague claims with exact nouns, numbers, units, and boundaries.
- Avoid filler and weasel words such as "generally", "somewhat", "might", "pretty", and "reasonable" unless uncertainty is real and explained.
- Prefer cohesive prose over telegraphic three-word sentences. Ultra-short clauses belong in bullets; flowing sentences belong in paragraphs.
- Prefer whitespace and clear sectioning over dense walls of text.
- Do not use em dashes (—). Use periods, commas, colons, or parentheses.

### Make Facts Searchable

- Use standard Markdown headings, lists, tables, block quotes, and fenced code blocks.
- Use `code` formatting for literal flags, paths, commands, filenames, APIs, fields, and error codes.
- Use **bold** for important product names, domain terms, warnings, and identifiers a reader might search for verbatim. Do not bold every noun.
- Spell out unfamiliar acronyms on first use, then use the acronym consistently.
- Keep heading names stable when the document may be linked, cited, or indexed. Add explicit anchors only when the host format supports them.

### Show Real Operations

- Prefer runnable commands and complete examples with realistic values.
- Avoid placeholders such as `<your-service>` unless the user explicitly needs a template.
- When a command has side effects, state the side effect directly before or after the command.

### State Constraints and Failure Paths

- Document defaults, limits, valid ranges, units, and boundary behavior.
- For procedures, include common errors, what each error means, and how to recover.
- If a screenshot, diagram, video, or external link contains load-bearing information, restate the key facts in text.

### Structure Dense Information

- Use tables for comparable facts: parameters, limits, error codes, environments, versions, or trade-offs.
- Keep sections focused on one idea. Split sections that mix unrelated concepts; merge one-sentence sections that lack enough context.
- Aim for roughly 200-500 words per substantial section unless the artifact format requires shorter text.
- If a table carries the claim, give at most one or two sentences of context. Do not write a thesis paragraph that only restates the table.

## Analysis and Experiment Writing

### State the Success Bar First

Define success, regression, and measurement noise before judging the result. State
whether the threshold is absolute, relative, or both, and explain why that unit
matches the decision.

Avoid "no meaningful regression" by itself. State the observed delta and compare
it with the predeclared threshold.

### Name the Statistic

Do not replace a measured statistic with a broad category.

| Avoid | Prefer |
| --- | --- |
| resource pressure | average CPU, peak memory, or disk utilization |
| latency got worse | median p95 latency increased by the reported amount |
| reliability improved | error rate fell from the baseline to the treatment value |
| operationally meaningful | the delta exceeded the stated success bar |

If average and peak values both matter, name both. If a summary is a percentile
of per-host maxima, do not call it an average.

### Validate Significance of Metrics You Choose to Show

If a column invites ranking, ask whether the gaps are distinguishable given measurement error. Fuzzy error with precise-looking numbers is misleading.

Use point estimates with an honesty clause, confidence intervals, or a shared
band when small differences are indistinguishable. Do not publish precise values
that imply a ranking the data cannot support.

### Match the Comparison to the Design

- Use before-and-after language only when the study has a valid temporal baseline.
- For simultaneous treatments, compare treatment and control within the same trusted window.
- Name confounders and explain exclusions without turning the caveat into the main result.
- Charts may show context outside the analysis window, but the prose must not treat that context as controlled evidence.

### Section Roles: TL;DR, Decision, Recommendation

TL;DR is allowed and useful. Do not let Decision and Recommendation echo it.

| Block | Owns | Does not own |
| --- | --- | --- |
| **TL;DR** | Success bar + verdict + a few skimmer findings | Evidence replay, figure deep-dive, caveats |
| **Decision** | Goal, **one pick**, accepted tradeoffs, figure/table home | Dual "or" recommendations when the goal already picks one |
| **Recommendation** | What to do / not do / follow up next | Re-proving latency or disk |

State the goal, then pick one direction. Alternatives belong as rejected options, not co-winners.

### Shape: Prose, Bullets, Captions

- Default to prose with whitespace.
- Use bullets for themes or parallel claims (endpoints, actions, caveats).
- Keep figure captions short. Put method details once near the analysis window or in caveats.
- Do not invent causal mechanisms from co-moving statistics.

### Replace Soft Conclusions

| Avoid | Prefer |
| --- | --- |
| no meaningful regression | state the delta and threshold |
| worth acting on / actionable | state the decision and evidence |
| essentially the same | state the range or uncertainty |
| the mechanism is… | name the observed co-moving statistics |
| em dash (—) | period, comma, colon, or parentheses |

## Artifact Guidance

### PR Descriptions

- Explain the problem and the chosen approach, not just the file-level diff.
- In tests, describe what the evidence proves. Avoid listing test names without interpretation.
- Include usage, migration, or rollback details when reviewers need to act.
- Add diagrams only when data flows through three or more components, ordering matters, state changes are non-obvious, or prose gets longer than five sentences.

### One-Pagers

- Make the overview answer: what is broken, what changes, and why the reader should care.
- Quantify impact when possible: latency, dollars, incidents, toil, throughput, adoption, or risk.
- Include alternatives considered with rejection reasons, not just the preferred solution.
- End with a concrete recommendation, ask, owner, or next step.

### Runbooks and Knowledge Base Articles

- Put prerequisites, permissions, environments, and expected state before commands.
- Pair happy-path steps with verification commands.
- Include failure modes next to the step where they occur.

### Experiment / Metrics Analyses

- Lead with success bars and the analysis window.
- Match before-and-after or cross-sectional language to the study design.
- TL;DR + Decision (one pick) + Recommendation (actions only).
- Name statistics, validate the significance of displayed differences, and keep captions short.

## Final Checklist

- Each section makes sense without previous sections.
- The first sentence answers the heading without only paraphrasing it in bold.
- Exact numbers, units, identifiers, defaults, and limits are explicit.
- Softeners are replaced by thresholds, deltas, ranges, or uncertainty.
- Metrics in tables can support the ranking a reader will invent; if not, add an honesty clause or show a band.
- Statistics are named; categories and causal mechanisms are not invented.
- The comparison language matches the experiment design.
- TL;DR, Decision, and Recommendation do not echo the same paragraph; Decision picks one option given the goal.
- Prose flows; bullets are for themes; no em dashes.
- Code and commands are runnable or clearly marked as templates.
- Failure modes and recovery steps sit near the relevant procedure.
- Key terms are searchable through headings, bold text, or code formatting.
- Images, diagrams, videos, and links are summarized in text.
- Tables encode comparable data instead of burying relationships in prose.
- The writing uses active voice, concrete subjects, and cohesive sentences (not telegraphic fragments).
