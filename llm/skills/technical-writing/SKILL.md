---
name: technical-writing
description: Use when the user asks to draft, rewrite, polish, or review technical prose such as docs, PR descriptions, design docs, runbooks, one-pagers, release notes, or engineering reports.
---

# Technical Writing

Use this as the prose quality pass for technical documents.

Canonical anti-GPT examples below come from interviewing a Pagestore Cassandra compression analysis gist (`matthewho/71c9496f3aa5b65c3194c421e620ad9c`). Prefer the author's locked voice over generic "tighten this" rewrites.

## Workflow

1. Preserve the facts. Do not invent metrics, commands, limits, error codes, owners, or outcomes.
2. Identify the artifact and reader: PR reviewer, engineering peer, leadership reader, on-call engineer, or future agent.
3. Rewrite section by section so each section can stand alone if retrieved without surrounding context.
4. Lead each section with the answer, then add context, caveats, examples, and failure cases.
5. For experiment / metrics writeups, run the **Analysis voice** rules and checklist before returning prose.
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
- Spell out acronyms on first use: **CDC (change-data-capture)**, then `CDC`.
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

### Name the Stat, Not a Category

Do not generalize a real metric into an analytical category. Category words sound smart and create ambiguity.

| Avoid (GPT category) | Prefer (named stat) |
|---|---|
| compaction capacity / compaction tax | pending compactions / `cass.compaction.pendingTasks` |
| CPU tax / CPU pressure | average CPU; worst-node peak CPU |
| the CPU mechanism is compaction-related | zstd shards show higher pending compactions and higher worst-node peak CPU together |
| disk pressure | disk used / disk busy (name which) |
| operationally meaningful / worth acting on | state the bar and the delta against it |

**Before**
> zstd level 3 consumes the most average CPU and compaction capacity.
> The CPU mechanism is compaction-related.

**After**
> zstd level 3 has the highest average CPU and pending compactions.
> zstd shards show higher pending compactions and higher worst-node peak CPU together; zstd-3 is highest on avg CPU and pending compactions.

If average CPU and worst-node peak CPU are both in the doc, say both. Do not collapse them into "CPU."

### Ban Managerial Soft Closers

Avoid: "operationally meaningful", "worth acting on", "actionable", "preliminary conclusion", "essentially the same", "substantially lower" when the number is available.

Put the number (and the success bar) in the sentence instead.

## Analysis and Experiment Voice

Use this section for Atlas analyses, capacity notes, A/B shard experiments, and similar metrics writeups.

### State the Success Bar First

Before judging regressions, define what counts.

Latency example (locked from the compression analysis):

> For MutateItems and GetItems p99.9, treat a change as discernible above 0.5 ms, and as a regression at ≥1 ms if it holds consistently. Below 0.5 ms do not call it a regression.
>
> AcquireClock is judged on percent, not absolute ms. Compression is not on the lease table, so this path should be unaffected; it is a sanity check that nothing else moved, not a primary compression metric. Within ~0.6% is fine.

Absolute ms beats percent for Mutate/Get. Percent (plus domain reason) can be right for endpoints that should be unaffected or have a very different baseline.

**Before**
> Successful-call KV p99.9 latency has no operationally meaningful regression for MutateItems, GetItems, or AcquireClock.

**After**
> MutateItems median p99.9 is 0.063 ms above control, under the 0.5 ms discernible bar. GetItems is not higher than control. AcquireClock stays within ~0.6% across shards, which matches the expectation that lease-table traffic should not feel compression.

### Validate Significance of Metrics You Choose to Show

If a column invites ranking, ask whether the gaps are distinguishable given measurement error. Fuzzy error with precise-looking numbers is misleading.

**Before** (false precision)
> Worst-node peak CPU: zstd-1 75.1%, zstd-3 73.3%, zstd-2 71.8% → implied rank zstd-1 worst.

**After** (numbers + honesty; range also fine)
> Worst-node peak CPU (temporal p99 of max-across-nodes): zstd 75.1 / 73.3 / 71.8 (≈72–75%), vs LZ4 54.8% and control 61.0%. Gaps of a few points among zstd levels on this series are not something to treat as significant.

Acceptable patterns: point estimates + honesty clause, or a shared band ("zstd ≈ 72–75%"). Unacceptable: precise per-treatment numbers that train a false ranking.

Know what the summary is. "Temporal p99 of max-across-nodes peak" is not an average, and small gaps are often noise.

### No Fake Before/After for Cross-Sectional A/B

When treatments run simultaneously (p1–p5 style), the decision is **cross-shard inside one trusted window**.

- Do not write a "before the dashed line" narrative. Pre-window is usually the same experiment plus confounders; it is not a control period.
- A cutoff like "last new node + 48h" may be a motivated heuristic (e.g. TTL + gc_grace), but it is still an analysis window start, not a physical event.
- Charts may show earlier data for eyeballing; prose should not narrate before/after as the plot.
- Drop dedicated "what the dashed line means" sermons and caption reprints of the same disclaimer.

**Keep (one breath)**
> Comparisons use data after 2026-07-13 15:00 UTC (48h after the last new node; TTL + gc_grace heuristic). Cross-shard only.

### Section Roles: TL;DR, Decision, Recommendation

TL;DR is allowed and useful. Do not let Decision and Recommendation echo it.

| Block | Owns | Does not own |
|---|---|---|
| **TL;DR** | Success bar + verdict + a few skimmer findings | Evidence replay, figure deep-dive, caveats |
| **Decision** | Goal, **one pick**, accepted tradeoffs, figure/table home | Dual "or" recommendations when the goal already picks one |
| **Recommendation** | What to do / not do / follow up next | Re-proving latency or disk |

State the goal, then pick one direction. Alternatives belong as rejected options, not co-winners.

**Before** (hedged dual winner)
> zstd-1 is the strongest zstd candidate; LZ4 is the lower-CPU alternative.

**After** (goal → one pick; Slack-adjacent voice)
> Goal: cut disk without moving Mutate/Get p99.9 past our bar. We're taking the spikier per-node CPU for that disk win.
>
> Pick zstd level 1. Same ~46.5% disk reduction as zstd-2/3 vs control; lower avg CPU and pending compactions than zstd-3. LZ4 only if you refuse that CPU/peak trade for a smaller disk win (~32%). Skip zstd-3.

**Recommendation actions (not evidence replay)**
> - Move forward with zstd level 1 on that goal and accepted CPU/peak risk.
> - Do not use zstd-3.
> - Disk savings do not imply automatic horizontal downscale; run a separate CPU-headroom test before downscaling.
> - AcquireClock ~350 ms p99.9 on every shard; track outside this compression change.

### Shape: Prose, Bullets, Captions

- Default to prose with whitespace.
- Use bullets for themes or parallel claims (endpoints, actions, caveats).
- Figure captions stay short. Method detail lives once near the analysis window or in Caveats—not in every caption.
- Ranking adjectives ("strongest candidate") can stay when they match the author's voice; do not stack coach-speak, and never invent "mechanism" labels.

### Phrasing Bank (prefer / avoid)

| Avoid | Prefer |
|---|---|
| no operationally meaningful regression | under the 0.5 ms discernible bar / does not clear 1 ms |
| worth acting on / actionable | omit; state bar + delta |
| compaction capacity | pending compactions |
| CPU mechanism is… | name the co-moving stats |
| node cut | automatic horizontal downscale |
| accept some loss of CPU buffer | we're taking the spikier per-node CPU |
| essentially the same disk reduction | within ~0.7 GiB / ~46.5–46.7% vs control |
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
- Cross-sectional A/B: no before/after story.
- TL;DR + Decision (one pick) + Recommendation (actions only).
- Name stats; validate significance of displayed metrics; short captions.

## Final Checklist

- Each section makes sense without previous sections.
- The first sentence answers the heading without only paraphrasing it in bold.
- Exact numbers, units, identifiers, defaults, and limits are explicit.
- Softeners ("operationally meaningful", "essentially", "substantially") are replaced by bars and deltas.
- Metrics in tables can support the ranking a reader will invent; if not, add an honesty clause or show a band.
- Stats are named (pending compactions, worst-node peak CPU); no invented categories or "mechanism" labels.
- Cross-sectional experiments do not narrate a fake before/after.
- TL;DR, Decision, and Recommendation do not echo the same paragraph; Decision picks one option given the goal.
- Prose flows; bullets are for themes; no em dashes.
- Code and commands are runnable or clearly marked as templates.
- Failure modes and recovery steps sit near the relevant procedure.
- Key terms are searchable through headings, bold text, or code formatting.
- Images, diagrams, videos, and links are summarized in text.
- Tables encode comparable data instead of burying relationships in prose.
- The writing uses active voice, concrete subjects, and cohesive sentences (not telegraphic fragments).
