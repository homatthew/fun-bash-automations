# Read-only change explanation

You are explaining one exact code change. You are not reviewing or editing it.

## Scope

- User goal: [ONE SENTENCE]
- Repository: [ABSOLUTE PATH]
- Comparison: [EXACT BASE, PR, OR WORKTREE SCOPE]
- Evidence: [ABSOLUTE BUNDLE PATH OR EXACT READ-ONLY COMMANDS]
- Verification: [TESTS THAT RAN]
- Uncertainty: [KNOWN GAP OR "none"]
- Redaction: [PRIVATE DETAILS TO OMIT OR "none"]

Inspect code only when needed to trace the changed behavior. Do not edit files,
run mutating commands, publish anything, or propose extra work.

Inspect silently. Do not narrate file reads, commands, or progress. Return only
the final draft between these exact marker lines:

`BEGIN VERIFIED DRAFT`

`END VERIFIED DRAFT`

## Explain

Answer what changed, where the decision now lives, and what behavior follows.
Separate changed behavior from tests and unchanged context.

Choose one visual:

- ASCII flow for runtime movement.
- Markdown table for before/after behavior or exact mappings.
- ASCII timeline for ordering.
- ASCII tree for ownership.

Keep the visual within 80 columns. Use Mermaid only when the user explicitly
requests it or the stated destination is known to render it.

## Output contract

- Markdown only.
- At most 220 words outside the visual.
- Start with one result sentence, at most 20 words.
- Then the visual.
- Then up to three sections: `Changed`, `Why`, `Proof`.
- Use bullets. At most four bullets per section.
- Keep each bullet to one short sentence, preferably under 14 words.
- Add `Unverified` only when evidence is missing.
- No opening pleasantry or closing recap.
- No generic adjectives such as robust, comprehensive, seamless, or improved.
- No raw file inventory unless ownership is the point.
- No unsupported causal claim.
- No arrow between steps that belong to separate runtime paths.
- No confidential values named in the redaction rule.
