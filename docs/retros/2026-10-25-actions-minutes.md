# Actions budget retrospective, 2026-10-25

## Finding and timeline (UTC)

The personal account was blocked by billing, not a failing test. The annotation
on [main run 40208833678](https://github.com/homatthew/csgo-bots/actions/runs/40208833678)
(created 15:50:23) says recent payments failed **or** the spending limit needs to
increase. This does not distinguish exhausted allowance, payment failure, or a
budget cap. At 16:17 the orchestrator investigated; at 16:18 it identified billing
and switched to local gates. No billing settings were changed by this work.

- October 14–24: estimated 1,157 weighted minutes accumulated in csgo-bots.
- October 25 10:34: PR #16 merged macOS portability coverage after local validation.
- October 25: another 1,142 weighted minutes, including 830 on macOS alone.
- By 15:50: jobs were refused; subsequent blocked jobs cost zero in this estimate.

## Personal account evidence

Read-only GitHub API snapshot through 17:13 UTC. All **69 homatthew repositories**
were queried for October runs. Only private `csgo-bots` had any: 258 runs, 258
attempts, 576 job records, 559 with executed steps. `courtside`, public
`fun-bash-automations`, and every other repo returned zero. Dirty checkouts were
not inspected or modified.

The window is October 1–25, **not a verified billing cycle**: the billing APIs
returned 404 and gh explicitly reported missing `user` scope. The reset date and
actual allowance remain unverified. Run timing API returned zero billable_ms even
for executed jobs, so it is unsuitable for this reconstruction.

Estimate: sum `ceil((completed_at-started_at)/60)` **per executed job**, then
multiply Linux ×1, Windows ×2, macOS ×10. Unassigned/step-less jobs count zero.
Timestamps can include overhead, and this is not an invoice or proof of a precise
2,000-minute limit. Raw elapsed time was 797.27 minutes; weighted estimate 2,299.
[Billing rules](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
charge the repository owner and exempt public standard runners.

| Repo / workflow / job | OS | Job records | Raw elapsed min | Weighted estimate |
| --- | --- | ---: | ---: | ---: |
| csgo-bots / ci / windows-offline | Windows | 254 | 302.33 | 912 |
| csgo-bots / ci / macos-offline | macOS | 37 | 63.95 | 830 |
| csgo-bots / ci / build-and-test | Linux | 258 | 347.77 | 464 |
| csgo-bots / ci / python-quality | Linux | 27 | 83.22 | 93 |

| Trigger | Runs | Weighted estimate |
| --- | ---: | ---: |
| pull_request | 181 | 1,622 |
| push | 68 | 623 |
| workflow_dispatch | 9 | 54 |
| schedule / API rerun attempts | 0 | 0 |

| Day in October | Linux | Windows | macOS | Total |
| --- | ---: | ---: | ---: | ---: |
| 14 | 14 | 26 | 0 | 40 |
| 15 | 14 | 38 | 0 | 52 |
| 16 | 14 | 50 | 0 | 64 |
| 18 | 95 | 254 | 0 | 349 |
| 19 | 25 | 42 | 0 | 67 |
| 20 | 21 | 40 | 0 | 61 |
| 21 | 25 | 4 | 0 | 29 |
| 22 | 25 | 46 | 0 | 71 |
| 23 | 123 | 240 | 0 | 363 |
| 24 | 21 | 40 | 0 | 61 |
| 25 | 180 | 132 | 830 | 1,142 |

## Ranked causes and agent behavior

1. **Windows on routine CI: 912 weighted minutes (40%).** Many short jobs round
   up, even when native packaging coverage was not needed for that change.
2. **macOS on routine CI: 830 (36%).** Its 83 rounded runner minutes all occurred
   today. Adding a locally validated portability job to every PR/main run made a
   rapid agent merge wave disproportionately costly.
3. **Repeated Linux checks: 557 (24%).** Both build/full-suite and Python quality
   discovery run on Linux. Installs/downloads repeat; the build job lacked pip
   caching, while macOS and python-quality already cached pip. No minute saving
   from caching or overlapping test discovery is claimed without step profiling.

These three OS totals partition 2,299; the following behavioral costs overlap them.
**53 feature-branch push runs duplicated PR-head checks: 244 weighted minutes.**
The long-lived `setup/reproducible-rise` branch alone generated 198 runs and 1,056
weighted minutes. Main generated 13 runs / 377 minutes. Stacks, rebases and small
pushes repeatedly created *new* run IDs; this is different from rerunning a run.
There were no API reruns. The final wave's main-only push/concurrency controls
already existed by this audit and must not be credited as newly added here.

There was no matrix in current CS:GO CI: four separate jobs form its fan-out.
Several jobs had no timeout; macOS had 15 minutes. Cancellation existed by the
snapshot (one empty job was explicitly superseded at 14:47). Missing cancellation
is not established as the principal historical cause. Docs had no path filter;
its avoidable cost is unquantified, not assumed to explain the outage.

## Separate payer: cozycommons

API-only snapshot around 17:20 UTC: visible repos are public `cc` and public
`.github`; the latter had no runs. The legacy org billing endpoint returned
**410 moved**, with gh mentioning `admin:org`; the newer
`/organizations/cozycommons/settings/billing/usage?year=2026&month=10` and
`/usage/summary` **succeeded with the existing token**. No scope change was needed.
The org API reports plan `free`.

Billing reports **2,223 Linux + 403 macOS raw minutes = 6,253 weighted equivalent**,
$38.324 gross, fully discounted, **$0 net**. Of that, cc is 6,251 weighted;
`demo-repository` and `curly-happiness-demo-repository` contribute one Linux minute
each but are no longer returned by the repo API. Their visibility cannot now be
verified. Public cc's standard runners consume **zero private allowance**. Against
the Free plan's 2,000 private-minute allowance, known current repos use 0%; even
conservatively charging both missing demos gives **2/2,000 = 0.1%**, leaving 1,998.
This is not 313% quota consumption. Public usage explains why cc kept running.

Per-run reconstruction: cc / CI has 237 runs, 242 attempts, 1,516 job records;
6,272 weighted equivalent (Linux 2,252, macOS 4,020). Small differences from billing
reflect timestamp estimation and reporting lag; billing is authoritative.

| Job (cc / CI) | OS | Weighted estimate |
| --- | --- | ---: |
| crowdset (macos-latest) | macOS | 2,650 |
| crowd-set (macos-latest) | macOS | 1,370 |
| crowdset (ubuntu-latest) | Linux | 492 |
| backend | Linux | 410 |
| frontend | Linux | 402 |
| crowdset-container | Linux | 275 |
| trips | Linux | 151 |
| frontend-tests | Linux | 137 |
| crowd-set (ubuntu-latest) | Linux | 119 |
| backend-tests | Linux | 109 |
| changes | Linux | 88 |
| crowd-set-container | Linux | 67 |
| compute | Linux | 2 |
| crowdset (skipped aggregator) | unassigned | 0 |

Triggers: 150 PR runs / 3,777 weighted; 87 push runs / 2,495, **all main**.
No feature-branch push duplicates (0 minutes), schedules or manual dispatches.
Five extra rerun attempts contributed 176 weighted minutes, already included above.

| October day | Linux | macOS | Total weighted equivalent |
| --- | ---: | ---: | ---: |
| 12 | 8 | 0 | 8 |
| 14 | 24 | 0 | 24 |
| 15 | 40 | 100 | 140 |
| 16 | 14 | 40 | 54 |
| 19 | 515 | 2,290 | 2,805 |
| 20 | 95 | 490 | 585 |
| 21 | 314 | 1,100 | 1,414 |
| 22 | 169 | 0 | 169 |
| 23 | 408 | 0 | 408 |
| 24 | 320 | 0 | 320 |
| 25 | 345 | 0 | 345 |

cc already selects projects, restricts push to main, has job timeouts, and cancels
superseded PRs. **No org guardrail PR is proposed:** its public-runner activity
is not burning the private allowance. Reassess before making a repo private or
adopting paid/larger runners.

## Changes and remaining user actions

- CS:GO: macOS/Windows only via workflow_dispatch; retain both Linux jobs, main-only
  push and PR triggers, workflow/ref cancellation. Add 10-minute Linux/macOS and
  5-minute Windows timeouts, pinned toolchain and pip caches. Ignore Markdown-only
  changes, not all docs: docs/refactor contains executable frozen/schema manifests.
  Keep the orchestrator's `/tmp/csgo-gate.sh` unchanged and validate against it.
- No workflow changes in other personal repos: none recorded October activity.
- Global/repo agent rules: local checks first, one complete push, expensive OSs on
  demand, no billing-blocked reruns, one targeted retry for a demonstrated flake,
  usage check before a large wave.
- Local `bin/actions-budget-watch`, daily launchd on the Mac: 50%/80% threshold
  notifications, deduplicated per observed cycle. User mode reads the allowance
  API (already weighted); org mode reads detailed usage and excludes known public
  repos, counting missing repos conservatively. Org allowance is explicitly 2,000
  from its Free plan; update the launch arguments if its plan changes. Nothing
  runs in Actions and the script never changes billing.
- Personal API monitoring is **unavailable today**, not reporting zero. The daily
  job reports that failure. Run `gh auth refresh -h github.com -s user` and retry
  `bin/actions-budget-watch --account homatthew --dry-run`. If migration leaves the
  legacy allowance endpoint unavailable, use GitHub's dashboard/budget alerts;
  the new usage report alone does not establish the personal included allowance.
- In [personal billing](https://github.com/settings/billing), check Overview for
  plan, reset date, included/used minutes and failed invoices/payment method;
  Usage filtered to Actions for Oct 1–25, grouped by repo and SKU; and Budgets and
  alerts for the Actions cap and “stop usage” setting. Download the detailed usage
  report to reconcile this estimate. If paying for more usage, choose a small
  deliberate Actions budget and alerts; otherwise keep the cap and wait for reset.
  Enable included-usage emails and budget alerts. **Only the user changes these.**

Evidence retained locally under `~/.local/share/actions-retro/2026-10-25/`: repo
inventories, all run/job API responses, per-job CSVs (`jobs.csv`, `org-jobs.csv`),
billing response, collectors and aggregate scripts. These preserve run URLs,
branches, durations, OS labels and attempts for every row without publishing raw
private-repo activity. Snapshot figures exclude subsequent guardrail delivery runs.
