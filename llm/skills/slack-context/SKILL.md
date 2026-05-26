---
name: slack-context
description: Use when summarizing Slack activity, reading private Slack/DM threads, searching Slack with ndex-slack-private or rag-slack-prod, debugging Slack MCP auth/Transport closed failures, or turning relative Slack time ranges like last week/yesterday into concrete queries.
---

# Slack Context

Use this skill for Slack summaries, private thread reads, DM searches, and Slack MCP troubleshooting.

## Tool Choice

- Public or broadly indexed Slack search: use `rag_slack_prod`.
- Private channels, DMs, current-user searches, or exact private permalinks: use `ndex-slack-private` when its Codex MCP bridge is healthy.
- For large Slack summaries, audits, or multi-page extraction jobs, prefer the direct launcher/CLI path even when the MCP bridge is healthy. Pagination, caching, and reruns are easier to control from shell.
- If a private permalink fails through gateway/core tools with `403`, retry with `ndex-slack-private`.
- Start private Slack work with a cheap MCP health check, such as `get_channel_id("ods-kv-dev")`. If it succeeds, quick MCP calls are fine.
- If `ndex-slack-private` returns `Transport closed`, treat it as a stale Codex MCP bridge, not a Slack auth failure. Do not debug or replace tokens unless direct launcher fallback also fails.
- Preferred recovery: ask the user to start a new Codex session/thread and retest MCP. Full app restart is a last resort.
- If continuity matters, switch to direct launcher/CLI for the rest of the task:

```bash
SLACK_USER_TOKEN="$(security find-generic-password -s slack-user-token -w 2>/dev/null || security find-generic-password -s claude-slack-user-token -w)" \
  npx -y -p @netflix-internal/ndex-slack-private \
  ndex-slack-private-cli search_messages --query "@matthewho after:2026-05-17 before:2026-05-26" --count 1
```

For private thread fallback:

```bash
/Users/matthewho/repos/fun-bash-automations/bin/slack-private-thread --permalink "<permalink>"
```

Interpretation:

- MCP health check passes: use Codex MCP for quick lookups; use direct launcher for large extraction.
- MCP returns `Transport closed`, direct launcher works: Codex bridge is stale; continue with direct launcher and mention the fallback.
- MCP returns `Transport closed`, direct launcher fails too: then investigate token, scopes, package install, or Slack API errors.

## Date Ranges

Always convert relative ranges to absolute Slack query dates before searching. Use the user's local timezone unless they specify another.

- `today`: current local calendar day.
- `yesterday`: previous local calendar day.
- `last week`: previous Monday-Sunday calendar week.
- `this week`: current Monday through today.
- `last 7 days`: rolling seven calendar days through today.
- `last month`: previous calendar month.
- Slack `before:` is exclusive, so use the next-day boundary.

Example: on Tuesday 2026-05-26, "last week" means `after:2026-05-17 before:2026-05-25` for Monday 2026-05-18 through Sunday 2026-05-24. If the user explicitly includes Monday 2026-05-25, use `before:2026-05-26`.

## Search Patterns

- Prefer exact usernames, such as `from:matthewho`, over `from:me`; Slack MCPs may not resolve `me` consistently.
- For CLI health checks, prefer `@matthewho` over `from:matthewho`; the CLI may call `users.list` to resolve `from:` names and hit Slack rate limits.
- For activity summaries, search outbound and inbound:

```text
from:matthewho after:YYYY-MM-DD before:YYYY-MM-DD
to:matthewho after:YYYY-MM-DD before:YYYY-MM-DD
@matthewho after:YYYY-MM-DD before:YYYY-MM-DD
```

- Fetch full threads for relevant permalinks and dedupe by channel + thread timestamp.
- For "unresponded" summaries, treat inbound results as candidates only. Verify the thread has no later meaningful reply from Matthew before listing it as unanswered.

## Auth Checks

- Never print Slack tokens.
- Preferred Keychain service: `slack-user-token`.
- Compatibility fallback: `claude-slack-user-token`.
- Required user token prefix: `xoxp-`.
- Required scopes for search/private summaries include `search:read`, `channels:read`, `channels:history`, `groups:read`, `groups:history`, `im:read`, `im:history`, `mpim:read`, `mpim:history`, and `users:read`.

Scope check:

```bash
tok="$(security find-generic-password -s slack-user-token -w 2>/dev/null || security find-generic-password -s claude-slack-user-token -w)"
curl -sS -D - -o /tmp/slack-auth-test.json -H "Authorization: Bearer $tok" https://slack.com/api/auth.test \
  | awk 'BEGIN{IGNORECASE=1} /^x-oauth-scopes:|^HTTP\//{print}'
```

## Summary Output

- Use a work digest by default: themes/projects, decisions, asks, follow-ups, blockers.
- Keep chronological evidence inside each theme when it matters.
- Include likely in-progress/unanswered threads as a separate section.
- Summarize DMs and private channels by theme/action. Avoid direct quotes unless the user asks for exact language.

## Jira Enrichment

When linking Slack themes to Jira, avoid broad text-search false positives.

- Never treat `text ~ "<term>"` as a confirmed Jira match by itself. Jira text search can hit comments, pasted logs, app inventories, or generated reports.
- Always state why a Jira was linked: Slack URL/key mention, Jira summary, labels/components, assignee/reporter, explicit Slack thread link, or clear recent comment.
- Use confidence labels:
  - `confirmed`: Slack explicitly links the Jira/key, or Jira summary/labels/components directly match the Slack theme and ownership/scope fits.
  - `candidate`: Jira appears related but needs human confirmation.
  - `excluded`: match is only from bulk text, logs, inventories, or unrelated infrastructure names.
- Preserve scope distinctions. A name like `greenseer` may refer to an EVCache cluster (`evcache_greenseer`), a Cassandra cluster (`cass_greenseer`), an app, or an incident. Do not collapse these into one work item.
- For user work reconciliation, prefer Jira issues assigned to the user, reported by the user, on the requested source-of-truth board, or explicitly linked from Slack.
- If Slack evidence is real but no confirmed Jira exists, label it `Slack-only operational support` or `needs ticket?` instead of forcing a weak Jira mapping.

Bad pattern:

```text
Greenseer -> ODS-3553
```

Reason: `ODS-3553` only matched `evcache_greenseer` inside a bulk EVCache app inventory comment; it was not assigned to Matthew and did not represent the Cassandra Greenseer incident.

Better pattern:

```text
Greenseer / wide-row incident
Slack evidence: <thread link>
Confirmed Jira: none found
Candidates: ENGINC-7173, MSGPLATFRM-3233
Excluded: ODS-3553 (bulk EVCache inventory mention of evcache_greenseer)
Status: Slack-only operational support / needs ticket?
```
