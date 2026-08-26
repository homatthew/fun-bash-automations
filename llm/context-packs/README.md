# Context packs for code review

A **context pack** is everything a reviewer needs *besides* the diff. The diff
says what changed. The pack says what it is being judged against.

This directory holds the portable design. The assembler is `bin/ctxpack`; the
agent-facing entrypoint is `llm/skills/context-pack/SKILL.md`. The corpora it
reads are local files under `$SECOND_BRAIN_DIR/review` and are **not** part of
this repository — see [Boundary](#boundary).

## Why packs, and why local

Hosted review bots expose almost no steering surface. A typical config is a
dozen lines of enable-flags plus one free-text `prompt-suffix`; everything else
the bot knows, it re-derives from the diff on every run. Two consequences
follow, and both are visible in real review history:

- **It repeats findings that were already turned down.** Nobody wrote the
  rejection down anywhere the bot can read.
- **It cannot know local facts.** That an empty column family is legal. That
  `fileCount()` returns manifest metadata, not on-disk residency. That a
  component registers its button locally rather than globally. Each of those
  produced a confidently-argued, wrong finding.

A rejected finding is the most expensive artefact review produces: someone read
it, verified it, and wrote a paragraph explaining why not. Packing is mostly
about not throwing that paragraph away.

"Local" is a constraint, not an aesthetic. Everything here is derived from the
working tree, `git`, and plain text on disk — no index, no embeddings, no
service, nothing to install. Grep is the retrieval engine. That keeps the pack
reproducible, auditable, and diffable, and it means a stale pack shows up in
`git log` rather than in a silently drifting vector store.

## The design space

Nine things you can put in a pack, roughly by cost-to-build against
value-delivered. `ctxpack` implements 1–7.

| # | Layer | What it answers | Where it comes from |
|---|-------|-----------------|---------------------|
| 1 | **Claim** | What is this diff *supposed* to do? | branch name, commit subjects, ticket ID |
| 2 | **Scope ledger** | Is the diff bigger than the claim? Are there tests? | `git diff --numstat`, path partition |
| 3 | **Constitution** | What written rules apply? | `AGENTS.md`, `.agents/rules/`, ADRs, nested module files |
| 4 | **Precedent** | What do the neighbouring files already do? | token counts over sibling files |
| 5 | **History** | Has this code been churned or is it load-bearing and old? | `git log` per touched file |
| 6 | **Domain** | What do I need to know that is not in the repo? | second-brain topic folders |
| 7 | **Adjudications** | Which findings were upheld or rejected here before? | the code bible |
| 8 | **Lenses** | What checks have repeatedly found real problems here? | distilled from engineers whose judgement you trust |
| 9 | **Persona** | What will the human reviewer object to? | mined from their past comments |
| 10 | **Telemetry** | Is the premise of this change true in production? | metrics — *not implemented; see below* |

Layers 7–9 are the ones that compound. 7 is what has already been *decided*;
8 is what to *look for*; 9 is who will say it. All three are built by mining
your own history, which is why they live outside this repository.

### Bounding the corpus, and weighting it

Two rules keep a mined corpus from drowning in its own volume:

- **Only code you have touched.** `ctxpack mine scope` lists repositories where
  you have commits. Patterns from codebases you do not work in are not
  actionable, and you cannot tell a good idea from a local accident there.
- **Prefer outcome signals to size proxies.** `ctxpack mine outcomes` scores each
  author by *repair rate* — the share of their non-fix commits followed, on the
  same files, by a fix-language commit within N days — controlled against the
  baseline for the same repos. Prefer older merges when review bars were higher.

### Metric hygiene

This is the part that took two attempts to get right, so it is written down.

The first version of the corpus ranked engineers by **median commit churn**. It
was wrong in a way worth remembering: churn is trivially optimisable (chop the
diff), and when the outcome data arrived it turned out **size did not predict
repair rate at all** — the author with the best size profile had a worse repair
ratio than the one with the worst.

`ctxpack mine sizes` still exists, because the distribution is occasionally
useful context. It should not be a target.

Before adding a metric to a pack, ask two questions:

1. **What does it look like when someone optimises for it?** If the answer is
   "the number improves and nothing else does", it is a proxy, not a signal.
2. **Is it about what happened before or after the merge?** After is harder to
   game: reverts, repair commits, review rounds, deferred-work counts.

And state the confounders next to the number. Repair rate is skewed by shared
hot files and by conventional-commit `fix:` subjects; a figure quoted without
its `n` and its baseline is not a finding.

Lenses are named after the **check**, never after a person. Attribution appears
only in an `observed:` line and on quoted evidence, so a claim can be traced and
verified. The unit of reuse is the reasoning, not anyone's voice.

### 4 is the one that earns the pack

The single highest-yield finding shape observed in real review is a convention
violation stated **with the count and the call sites**:

> Every exported axios factory in `BaseService.ts` calls `setupAuthInterceptor`
> (lines 201, 216, 232, 249, 268, 296, 315, 343, 380). `bearerClient` here is a
> local factory that skips it entirely.

Accepted in one round with "good catch on the invariant". Compare the same
finding without the enumeration — "other services attach the interceptor" —
which is an opinion and gets argued.

That shape is **mechanically derivable**, which is the interesting part.
`ctxpack precedent` computes it: for each changed file, take its siblings in
the same directory with the same extension, count how many use each identifier,
and report the tokens that clear a quorum but are **absent from this file**.
That is the auth-interceptor finding, found by counting.

Two calibrations were needed to make it useful:

- **Only multi-word program identifiers count.** The first cut scored any word
  over six characters and the top hits were `without`, `storage`, `require` —
  English prose at 3/3. A convention is something a programmer *named*, which
  in every language here means a case transition or an underscore.
- **Prose files are excluded.** Counting tokens across markdown measures
  vocabulary, not convention.

Absent precedent is a **lead, not a finding**. The pack says so in its own
output: open two of the cited siblings before writing the comment. A miscounted
convention is the most irritating kind of review noise.

### 9 is missing on purpose

Telemetry is the layer with the best evidence behind it and no portable
implementation. In one observed thread the author defended leaving five
services alone, then pulled 30 days of production metrics and found the data
inverted his own premise — two of the five had the *highest* failure rates in
the fleet. No amount of static context reaches that conclusion.

Any implementation is site-specific (Atlas here, something else elsewhere), so
it stays out of the portable layer. The pack's job is to make the *absence*
visible: when a finding rests on a claim about production behaviour, say that
the claim is unverified rather than dressing it up.

## What deliberately is *not* packed

- **The full diff.** The reviewer already has it. A pack that restates it wins
  nothing and pushes the useful sections out of context.
- **Whole rule files.** The constitution section lists paths and line counts.
  Inlining 2,900 lines of `.agents/rules/` buries everything else; a reviewer
  that needs `java-style.md` can open it.
- **Commit bodies.** Frequently longer than the diff. Subjects only.
- **Auto-generated bible rules.** `harvest` collects threads; a human decides
  which generalise. A rule distilled from an unread thread is how a corpus
  turns into noise.

Every cap is printed in the output. A truncated pack that looks complete is
worse than no pack, because the reviewer cannot tell "no precedent found" from
"the miner crashed" — so a failed section prints a warning inline.

## Boundary

The mechanism is portable and lives here. The corpora are not:

| | Home | Why |
|---|---|---|
| `bin/ctxpack`, this doc, the skill | `fun-bash-automations` (public) | generic, no site detail |
| `code-bible/rules/`, `lenses/`, `personas/`, `weighting.md`, `adjudications.jsonl` | `$SECOND_BRAIN_DIR/review` (private) | internal class names, PR numbers, colleagues' words, service topology |

This follows the Open-Source Boundary rule in the repo's `AGENTS.md`. The
default resolves to `~/repos/dump/second-brain/review`; override with
`CTXPACK_BIBLE_DIR`. `ctxpack doctor` reports which corpora resolved, and every
section degrades to a one-line "(not configured)" rather than failing.

## Usage

```bash
ctxpack doctor                       # what resolved
ctxpack build --out /tmp/pack.md     # full pack for the current diff
ctxpack build --sections precedent,bible
ctxpack precedent                    # just the sibling evidence
ctxpack bible --match                # rules touching this diff
ctxpack harvest <repo> --prs 60      # append PR threads to the corpus
ctxpack mine scope                   # repos you have committed to
ctxpack mine outcomes [--repos x,y]  # repair rate per author, repo-controlled
ctxpack mine sizes --authors a@,b@ [--repos x,y]
```

`--base` overrides the diff base; the default is the merge-base with the
repository's default branch, falling back to uncommitted changes.
