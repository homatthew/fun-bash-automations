# Actions budget retrospective, 2026-10-25

## Finding and timeline (UTC)

**Confirmed cause: homatthew's Free included Actions allowance ran out against a
$0 budget (“Usage blocked”).** The user read the billing UI for October 1–25:
Linux 519 min / $3.11, Windows 449 min / $4.49, macOS 3-core 70.9 min / $4.40,
storage under $0.01; gross $12.00, billed $0. The included allowance is about $12
(2,000 baseline Linux minutes). No billing settings were changed by this work.

The annotation on [main run 40208833678](https://github.com/homatthew/csgo-bots/actions/runs/40208833678)
(created 15:50:23) reports payment/limit blockage. At 16:17 the orchestrator
investigated; at 16:18 it identified billing and switched to local gates.

- October 14–24: estimated 1,157 weighted minutes accumulated in csgo-bots.
- October 25 10:34: PR #16 merged macOS portability coverage after local validation.
- October 25: another estimated 1,142 weighted minutes, including an estimated 830 on macOS.
- By 15:50: jobs were refused; subsequent blocked jobs cost zero in this estimate.

## Personal account evidence

Read-only GitHub API snapshot through 17:13 UTC. All **69 homatthew repositories**
were queried for October runs. Only private `csgo-bots` had any: 258 runs, 258
attempts, 576 job records, 559 with executed steps. Public `fun-bash-automations` and every other repo returned zero. Dirty checkouts were
not inspected or modified.

Billing UI figures above are authoritative; API timings below attribute the
activity, not the invoice. The personal billing APIs returned 404 with missing
`user` scope, which limits unattended monitoring but no longer leaves the incident
cause unknown. Run timing API returned zero billable_ms for executed jobs.
October is the UI reporting window; exact reset date should still be checked.

Estimate: sum `ceil((completed_at-started_at)/60)` **per executed job**, then
multiply Linux ×1, Windows ×2, macOS ×10. Unassigned/step-less jobs count zero.
Timestamps can include overhead, and this is not an invoice or proof of a precise
2,000-minute limit. Current SKU dollar prices differ from the historical OS
multipliers; use $12.00 for the actual allowance accounting. Raw elapsed time was 797.27 minutes; weighted estimate 2,299.
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

1. **Windows on routine CI: 449 billed-usage minutes / $4.49 (37% of cost).**
   About 898 weighted equivalent; job timestamps estimate 912. Many short jobs
   round up, even when native packaging coverage is not needed for the change.
2. **macOS on routine CI: 70.9 minutes / $4.40 (37% of cost).** About 709 weighted
   equivalent; timestamps estimate 830. Only 7% of raw billed-usage minutes caused
   37% of cost. Adding portability coverage to every PR/main run amplified today's
   rapid agent wave, which cost $5.80 overall. October 18 cost $1.86 and October 23
   $1.94; most other days were under $0.40.
3. **Repeated Linux checks: 519 minutes / $3.11 (26% of cost).** Timestamps estimate
   557 weighted. Build/full-suite and Python quality both discover tests. The build
   job lacked pip caching; macOS and python-quality already cached pip. No exact
   savings from caching or overlapping discovery are claimed without profiling.

The timestamp estimates partition 2,299; the following behavioral costs overlap them.
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

The user's billing UI confirms **2,223 Linux min / $13.34 + 403 macOS min /
$24.99 = $38.33 gross, $0 billed**. API detail agrees before display rounding:
$38.324 gross, fully discounted; 6,253 historical weighted equivalent. cc is public
and standard runners are free, so it consumes **0% of the 2,000 private-minute
allowance**. Its budget is also $0 / blocked, but public standard runs remain free.
It is not at risk unless visibility or runner class changes. If cc became private,
the October 1–25 activity represents roughly $38 of gross usage before the included
allowance, with macOS 65% of gross cost.

API detail assigns 6,251 weighted equivalent to cc and one Linux minute each to
`demo-repository` and `curly-happiness-demo-repository`, which no longer appear in
the repo inventory. All are fully discounted. The watchdog conservatively counts
these two unknown-visibility minutes: an upper bound of 2/2,000 (0.1%), not a
claim that public cc used private allowance.

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
superseded PRs. Current main already removed macOS from the routine Crowdset
matrix. Per the user's request, add only a separate on-demand macOS portability
workflow and the corresponding instruction; leave required Linux gates unchanged.

## Policy: use less, never pay more

- CS:GO: all hosted Linux/Windows jobs are workflow_dispatch-only; default checks use the existing
  private-only `mini-csgo` runner, labels `[self-hosted, macOS, ARM64, csgo-mac]`.
  Keep workflow/ref cancellation. Hosted Linux/Windows timeouts are 10/5 minutes;
  the self-hosted Mac is bounded at 20 minutes. Preserve pinned toolchain/pip caches. Ignore only README.md and AGENTS.md changes; docs/ contains frozen and tested
  Markdown contracts as well as executable manifests.
  Keep the orchestrator's `/tmp/csgo-gate.sh` unchanged and validate against it.
- No workflow changes in other personal repos: none recorded October activity.
- Global/repo agent rules: local checks first, one complete push, hosted expensive OSs on
  demand, no CI reruns, no OS matrices on PRs,
  usage check before a large wave. Keep both $0 budgets permanently; no paid
  runners or nightly expensive OS jobs.
- Local `bin/actions-budget-watch`, daily launchd on the Mac: 50%/80% threshold
  notifications, deduplicated per observed cycle. Both modes read detailed billing usage, sum gross dollars
  for private/unknown repos and exclude known public repos. Each uses the confirmed
  $12 included allowance; update launch arguments if either plan changes. Dollar
  accounting follows current SKU prices instead of historical OS multipliers. Nothing
  runs in Actions and the script never changes billing.
- Personal billing API access remains scoped out, so the watchdog falls back to
  per-run private-repo jobs: per-job rounded minutes weighted Linux 1x, Windows 2x,
  macOS 10x against 2,000. Completed jobs are cached locally; rerun attempts are
  included. It labels estimates clearly, excludes self-hosted/public runs, and
  never interprets API failure as zero. Estimates may alert early; billing UI is
  authoritative. A daily check can miss a same-day burst, so pre-wave checks and
  manual-only expensive runners remain essential. No additional scope is needed
  for this fallback. The Mac must be logged in for launchd notifications.
- In [personal billing](https://github.com/settings/billing), confirm the reset date and current included balance;
  Usage filtered to Actions for Oct 1–25, grouped by repo and SKU; and Budgets and
  alerts for the Actions cap and “stop usage” setting. Download the detailed usage
  report to reconcile this estimate. **Leave both $0 budgets unchanged.** Enable
  included-usage/budget notifications if available, and wait for the allowance
  reset to resume private hosted CI. Do not pay for extra minutes or runners.
- The user has registered `mini-csgo` under `~/actions-runner/csgo-bots` as a
  launchd user service, scoped to private csgo-bots only. This work changes only
  workflow routing, not its installation. Use unique per-run checkouts, in-repo
  venvs and runner.temp scratch; clean up only those job-owned paths. No sudo or
  global brew/pip installs. The real self-hosted run at f350dd1 passed after the
  timeout fix; the user will confirm zero self-hosted charges in billing.
- Python quality, frozen-check, discovery and goldens pass on the Mac and are
  consolidated into its default job. The pinned
  SourcePawn compiler is a Linux ELF executable; build/bootstrap/prepare also use
  GNU `sha256sum` and `mv --target-directory`. Retain Linux compilation/packaging
  coverage only on manual dispatch until a reviewed container-based alternative is
  chosen. No hosted runner is required for normal private-repo PR/main checks.
- The first mini-csgo job successfully checked out, created its venv and ran tests,
  then reached the original 10-minute limit while tests were still passing.
  Cleanup succeeded. The Mac-only limit was raised to 20 minutes; no hosted limit
  or billing budget was increased, and no unchanged CI run was retried.
- The other private repo with CI uses its own separately registered Mac runner.
  Its Python 3.12 contract tests run there by default. Optional Ubuntu/Windows checks require
  workflow_dispatch with `hosted_os_matrix: true`; no hosted macOS matrix remains.
- **Private homatthew repos default to their own registered Mac runner; hosted
  runners are dispatch-only.** Personal accounts cannot share repository runners.
  A new private repo with CI needs a separate runner registration, not another
  repo's label. Existing runner services are not installed or reconfigured here.
- **Never route cozycommons/cc or any public repo to this Mac runner.** Public fork
  PRs must never execute code on the user's machine. If the user chooses to make
  csgo-bots public, remove self-hosted routing first. Public visibility remains a
  user option, not an automatic change.



Evidence retained locally under `~/.local/share/actions-retro/2026-10-25/`: repo
inventories, all run/job API responses, per-job CSVs (`jobs.csv`, `org-jobs.csv`),
billing response, collectors and aggregate scripts. These preserve run URLs,
branches, durations, OS labels and attempts for every row without publishing raw
private-repo activity. Snapshot figures exclude subsequent guardrail delivery runs.
