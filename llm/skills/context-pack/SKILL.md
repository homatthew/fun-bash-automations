---
name: context-pack
description: Use before reviewing a diff, PR, or branch to assemble the local evidence a review needs beyond the diff — repo conventions, sibling precedent, domain notes, and past finding verdicts. Also use after a review round to record which findings were upheld or rejected. Triggers - "context pack", "ctxpack", "what am I judging this against", "why did the bot flag this again".
---

# Context pack

`ctxpack` assembles the evidence a review needs *besides* the diff, from local
files only. Design and rationale: `llm/context-packs/README.md`.

This is an **input to review, not a review**. The deep-review workflow is
`$code-review`; run this first and hand the pack to the reviewers as domain
context (its Phase 1c/1e).

## Build a pack

```bash
ctxpack build --out /tmp/pack.md      # current branch vs its merge-base
ctxpack build --base origin/main
ctxpack build --sections precedent,bible,constitution
```

Sections: `claim`, `scope`, `constitution`, `precedent`, `history`, `brain`,
`bible`, `lens`, `persona`. Missing corpora degrade to one line; a section that
*fails* prints a warning into the pack rather than truncating silently. Check
what resolved with `ctxpack doctor`.

## Reading the pack

**Precedent is the section that pays.** `Absent precedent` means N of M sibling
files in the same directory use an identifier that this file does not. That is
the raw material for the strongest finding shape there is — a convention
violation stated with the count:

> 9 of 11 sibling factories in `BaseService.ts` call `setupAuthInterceptor`
> (lines 201, 216, …). This one does not, so a 401 mid-pagination is not retried.

**But it is a lead, not a finding.** Open two of the cited siblings before
writing the comment. The token may be irrelevant to this file, and a miscounted
convention is worse than no comment. `Novel in this family` is the inverse
signal — an identifier the diff introduces that no sibling uses. Sometimes it
is a new pattern being smuggled in next to an established one; usually it is
just new code. Check, do not assert.

**The bible section is a filter on what to raise.** `verdict: rejected` rules
are findings already turned down *with a reason*. Read the reason. Raising the
same thing without addressing it burns a review round. `verdict: upheld` rules
are where budget is well spent.

**The lens section is what to look for.** Where the bible records what was
already *decided*, a lens is a check that has repeatedly found real problems in
this codebase — bounded loops, hot-path allocation, API surface cost, unowned
invariants, operator-at-3am reachability. The one-line title in the pack is a
reminder; open the file for the evidence and the "how to apply".

Lenses are named after the check, never a person. Do not treat them as
instructions to imitate anyone's voice — the reusable thing is the reasoning.

**The persona section is what the human will say anyway.** Pre-empting it
removes a round.

## After the review: close the loop

The corpus only compounds if verdicts get written back.

```bash
ctxpack harvest <repo> --prs 60     # pull PR threads into adjudications.jsonl
```

Harvest is append-only, deduplicated, and safe to re-run. Pass `owner/repo` to
harvest a repo you have no local clone of, and `--prs-list N,N` for PRs outside
the recent window (`sort=updated` is not monotonic in PR number, so some PRs are
unreachable by window at any size).

It records **every** root review comment and tags each with an `adjudication`:

| value | meaning |
|---|---|
| `replied` | an author wrote a verdict — read it, it may be a rejection |
| `code-changed` | the diff at that line moved afterwards (`isOutdated`) — a **silent fix** |
| `resolved` | thread closed with no reply; direction unknown |
| `pending` | none of the above *yet* — unknown, **not** refuted |

An earlier version dropped threads with no reply, reasoning that they carried no
verdict. That was wrong: the clearest findings are the least likely to be argued
with, because the author just pushes a fix — so keeping only argued threads
selects *for* contested and mistaken findings. Worse, it discarded them instead
of down-weighting, which took a full re-harvest to undo. Treat `pending` as
usable evidence at reduced confidence.

**Distillation stays manual.** When a thread produced a *reasoned* verdict that
generalises, add a rule under `$CTXPACK_BIBLE_DIR/code-bible/rules/`. Format and
the `verdict:` vocabulary are in that corpus's README. Do not auto-generate
rules from unread threads; an unfiltered corpus is noise with extra steps.

**Keep the corpus bounded and weighted.** `ctxpack mine scope` defines which
repos count (ones you have committed to). `ctxpack mine outcomes` scores authors
by repair rate — what needed fixing after merge — controlled for repo. Prefer
older merges for *patterns* and newest for *current facts*. The corpus's
`weighting.md` holds the policy.

**Do not add gameable metrics.** Commit size was tried and retired: it is
optimisable by chopping diffs and it did not predict repair rate. Before adding
any measure, ask what it looks like when someone optimises for it, and prefer
post-merge signals (reverts, repairs, review rounds, deferred-work counts).
Always quote a figure with its `n`, its baseline, and its confounders.

Write a rule when:

- a finding was **rejected with a domain fact** the diff could not show
  (an empty collection is legal here; this helper does not mean what it says);
- a finding **landed cleanly** and the shape is reusable;
- a finding was **right about the problem and wrong about the mechanism** —
  those teach phrasing.

Do not write one for a finding that was simply correct and boring.

## Boundary

The tool and docs are public (`fun-bash-automations`). The corpora are private
(`$SECOND_BRAIN_DIR/review`, default `~/repos/dump/second-brain/review`) because
they carry internal class names, PR numbers, and colleagues' words. Never move
rule or persona content into `fun-bash-automations`; see its `AGENTS.md`
Open-Source Boundary.

## Limits worth stating out loud

- Precedent is **lexical**. It counts identifiers in sibling files; it does not
  parse. It finds "this file is missing something its neighbours all have" and
  nothing subtler.
- Precedent needs a populated directory — at least 3 siblings, same extension.
  A new module in a new directory gets nothing.
- There is **no telemetry layer**. When a finding's premise is a claim about
  production behaviour, the pack cannot check it. Say the claim is unverified
  rather than dressing it up — that exact hedge, made without data, is how a
  correct finding got half-argued in the recorded history.
