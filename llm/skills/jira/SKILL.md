---
name: jira
description: Search, read, or write Netflix Jira issues. Use when user needs to find Jira issues, look up ticket details, find assigned/created tickets, create new ones, or add comments. Two approaches available - acli (simpler, for interactive use) or metatron API (for automation).
compatibility: Requires either acli (Atlassian CLI) or metatron CLI
allowed-tools: Bash(acli *) Bash(metatron curl *) Bash(jq *)
---

# Netflix Jira Guide

## Choosing an Approach

| Approach | Best For | Auth |
|----------|----------|------|
| **acli (Atlassian CLI)** | Interactive work, daily ticket management | OAuth or API token |
| **Metatron API** | Automation, scripts, CI/CD, ephemeral environments | mTLS certificates |

**Prefer the CLI for interactive use** - simpler commands, no JSON construction, handles formatting automatically.

> **Dev Workspaces:** acli is typically not authenticated. Use the Metatron API approach below, which uses mTLS certificates automatically.

---

# acli (Recommended for Interactive Use)

Uses [Atlassian CLI (acli)](https://developer.atlassian.com/cli/) - the official Atlassian CLI for Jira, Confluence, and other Atlassian products.

## Installation & Setup

```bash
# Install the CLI
brew install atlassian/acli/acli

# Authenticate via browser OAuth (recommended)
acli jira auth login --web --site netflix.atlassian.net

# Or authenticate via API token (pipe token via stdin)
echo "YOUR_API_TOKEN" | acli jira auth login --token --user your-email@netflix.com --site netflix.atlassian.net
```

## Quick Reference

| Task | Command |
|------|---------|
| Search issues | `acli jira workitem search --jql "assignee = currentUser() AND status != Done"` |
| View issue | `acli jira workitem view PROJ-123` |
| Create issue | `acli jira workitem create --project PROJ --type Task --summary "Summary"` |
| Add comment | `acli jira workitem comment create --key PROJ-123 --body "Comment text"` |
| Update comment (ADF) | `acli jira workitem comment update --key PROJ-123 --id 12345 --body-adf comment.json` |
| List comments | `acli jira workitem comment list --key PROJ-123 --json` |
| Assign issue | `acli jira workitem assign --key PROJ-123 --assignee "username"` |
| Transition | `acli jira workitem transition --key PROJ-123 --status "Done"` |
| Edit issue | `acli jira workitem edit --key PROJ-123 --summary "New title"` |
| List projects | `acli jira project list` |
| Board search | `acli jira board search` |

## Common Operations

### Create Issue

```bash
acli jira workitem create --project PROJ --type Task --summary "Title" --description "Description text"
```

With assignee:

```bash
acli jira workitem create --project PROJ --type Task --summary "Title" \
  --assignee "assignee@netflix.com" \
  --description "Description"
```

### Search Issues

```bash
acli jira workitem search --jql "project = PROJ AND status != Done"
acli jira workitem search --jql "assignee = currentUser() AND updated >= -7d"
```

### View & Update

```bash
acli jira workitem view PROJ-123                                          # View issue details
acli jira workitem transition --key PROJ-123 --status "Done"              # Transition status
acli jira workitem assign --key PROJ-123 --assignee "user@netflix.com"    # Assign to user
acli jira workitem edit --key PROJ-123 --summary "Updated title"          # Edit fields
```

### Comment Operations

```bash
# Add a plain text comment
acli jira workitem comment create --key PROJ-123 --body "Simple comment"

# Add a comment from a file (still plain text)
acli jira workitem comment create --key PROJ-123 --body-file comment.txt

# List comments (use --json to get comment IDs for update/delete)
acli jira workitem comment list --key PROJ-123
acli jira workitem comment list --key PROJ-123 --json

# Update a comment (plain text)
acli jira workitem comment update --key PROJ-123 --id 12345 --body "Updated text"

# Update a comment with ADF formatting (headings, tables, bold, links)
acli jira workitem comment update --key PROJ-123 --id 12345 --body-adf comment.json

# Delete a comment
acli jira workitem comment delete --key PROJ-123 --id 12345
```

## Formatting: Plain Text vs ADF

**Important:** Jira does NOT render Markdown. Comments posted with `--body` are plain text only — no bold, headings, or bullet lists.

For formatted comments, use **ADF (Atlassian Document Format)** — Jira's native rich text format:

- `comment create` only supports `--body` (plain text) and `--body-file` (plain text file)
- `comment update` supports `--body-adf` (ADF JSON file) for rich formatting
- **Workflow for formatted comments**: create with plain text first, get the comment ID via `comment list --json`, then update with `--body-adf`

See [references/adf-format.md](references/adf-format.md) for ADF document structure, node types, and text marks.

### Project Info

```bash
acli jira project list                             # List projects
acli jira board search                             # List boards
```

## Output Modes

Use `--json` or `--csv` for structured output:

```bash
acli jira workitem search --jql "assignee = currentUser()" --json
acli jira workitem view PROJ-123 --json
```

## Non-Interactive / Automation

Use `--yes` to skip confirmation prompts:

```bash
acli jira workitem transition --key PROJ-123 --status "Done" --yes
```

## Operations Requiring API Fallback

For operations not supported by the CLI, use the Metatron API approach documented below.

---

# Metatron API (For Automation)

Query Netflix Jira via the Atlassian API Proxy with Metatron mTLS authentication.

## Quick Reference

| Task | Command |
|------|---------|
| Search issues | `metatron curl -a connect "$JIRA/search/jql?jql=<URL-encoded-JQL>"` |
| Get issue details | `metatron curl -a connect "$JIRA/issue/{KEY}"` |
| My open issues | JQL: `assignee = currentUser() AND status != Done` |
| Current user | `metatron curl -a connect "$JIRA/myself"` |

## Authentication

Netflix uses the **Atlassian API Proxy** which handles authentication automatically via Metatron mTLS. No API tokens required.

```bash
# Base URL for all Jira API calls
JIRA="https://atlassian-api-external.dmz.build.netflix.net:8443/atlassian-api-proxy/jira/netflix/rest/api/3"

# Verify authentication works
metatron curl -a connect "$JIRA/myself" | jq .
```

The proxy uses the Spinnaker application `connect` for authentication.

**Documentation:** https://manuals.netflix.net/view/cose-core/mkdocs/main/pages/Systems/Atlassian/NTER%20Automation/Connect/connect/

## Search Issues (JQL)

Use the `/search/jql` endpoint with URL-encoded JQL in the query string:

### Basic Search

```bash
JIRA="https://atlassian-api-external.dmz.build.netflix.net:8443/atlassian-api-proxy/jira/netflix/rest/api/3"

# Search for my open issues
metatron curl -a connect "$JIRA/search/jql?jql=assignee%3DcurrentUser()%20AND%20status%21%3DDone&maxResults=50" | jq .

# Search a project (latest first)
metatron curl -a connect "$JIRA/search/jql?jql=project%3DNCP%20ORDER%20BY%20created%20DESC&maxResults=10" | jq .
```

### Select Specific Fields

```bash
metatron curl -a connect "$JIRA/search/jql?jql=assignee%3DcurrentUser()&fields=key,summary,status,created,updated&maxResults=50" | jq .
```

### Common JQL Queries

| Use Case | JQL |
|----------|-----|
| My open issues | `assignee = currentUser() AND status != Done` |
| My issues updated this week | `assignee = currentUser() AND updated >= -7d` |
| Issues I created | `reporter = currentUser()` |
| Issues in project | `project = PROJ` |
| Issues by status | `project = PROJ AND status = "In Progress"` |
| Issues created in date range | `created >= "2024-01-01" AND created <= "2024-03-31"` |
| Text search | `text ~ "search term"` |
| Issues with label | `labels = "my-label"` |
| Unassigned issues | `project = PROJ AND assignee is EMPTY` |
| High priority | `priority in (Highest, High)` |

### URL Encoding JQL

URL-encode special characters in JQL:

- Space → `%20`
- `=` → `%3D`
- `!=` → `%21%3D`
- `()` → `%28%29`

### Pagination

The response includes a `nextPageToken` for pagination:

```bash
# First page
metatron curl -a connect "$JIRA/search/jql?jql=project%3DNCP&maxResults=50" | jq .

# Next page (use nextPageToken from previous response)
metatron curl -a connect "$JIRA/search/jql?jql=project%3DNCP&maxResults=50&nextPageToken=<token>" | jq .
```

## Get Issue Details

### Full Issue

```bash
metatron curl -a connect "$JIRA/issue/NCP-123" | jq .
```

### Specific Fields Only

```bash
metatron curl -a connect "$JIRA/issue/NCP-123?fields=summary,status,assignee,description" | jq .
```

### Include Comments

```bash
metatron curl -a connect "$JIRA/issue/NCP-123?expand=renderedFields,comments" | jq .
```

## User ID Translation

The proxy supports automatic user ID translation. Use `%%userId:email@netflix.com%%` in place of user IDs:

```bash
metatron curl -a connect "$JIRA/search/jql?jql=reporter%3D%%userId:jsmith@netflix.com%%" | jq .
```

## Format Output

### List Issues as Table

```bash
metatron curl -a connect "$JIRA/search/jql?jql=assignee%3DcurrentUser()&fields=key,summary,status" | \
  jq -r '.issues[] | "\(.key)\t\(.fields.status.name)\t\(.fields.summary)"'
```

### Issues with URLs

```bash
metatron curl -a connect "$JIRA/search/jql?jql=assignee%3DcurrentUser()&fields=key,summary,status,updated" | \
  jq -r '.issues[] | "\(.fields.updated[0:10]) | https://netflix.atlassian.net/browse/\(.key) | \(.fields.status.name) | \(.fields.summary)"'
```

## Get Project Info

```bash
# List all projects you can see
metatron curl -a connect "$JIRA/project" | jq '.[].key'

# Get specific project
metatron curl -a connect "$JIRA/project/NCP" | jq .
```

## Write Operations

JIRA v3 uses **Atlassian Document Format (ADF)** for rich text fields. See [references/adf-format.md](references/adf-format.md) for headings, tables, lists, and text mark examples.

```json
{"type": "doc", "version": 1, "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Your text"}]}]}
```

### Create Issue

```bash
metatron curl -a connect -X POST "$JIRA/issue" -H "Content-Type: application/json" \
  -d '{"fields": {"project": {"key": "PROJ"}, "summary": "Title", "issuetype": {"name": "Task"}, "description": <ADF>}}'
```

### Link to Epic

Use the `parent` field (not `customfield_10008`, which is often a date field):

```bash
metatron curl -a connect -X POST "$JIRA/issue" -H "Content-Type: application/json" \
  -d '{"fields": {"project": {"key": "PROJ"}, "issuetype": {"name": "Task"}, "parent": {"key": "PROJ-123"}, "summary": "Child issue", "description": <ADF>}}'
```

To discover the correct field on your instance, inspect an existing child issue:

```bash
metatron curl -a connect "$JIRA/issue/PROJ-456?fields=parent,issuetype" | jq '.fields.parent'
```

### Update Issue

```bash
metatron curl -a connect -X PUT "$JIRA/issue/PROJ-123" -H "Content-Type: application/json" \
  -d '{"fields": {"summary": "New title"}}'
```

### Delete Issue

```bash
metatron curl -a connect -X DELETE "$JIRA/issue/PROJ-123"  # add ?deleteSubtasks=true if needed
```

### Add Comment

```bash
metatron curl -a connect -X POST "$JIRA/issue/PROJ-123/comment" -H "Content-Type: application/json" \
  -d '{"body": <ADF>}'
```

### Add Label

```bash
# Get current labels, append new one, update
LABELS=$(metatron curl -a connect "$JIRA/issue/PROJ-123?fields=labels" | jq -c '.fields.labels + ["new-label"]')
metatron curl -a connect -X PUT "$JIRA/issue/PROJ-123" -H "Content-Type: application/json" \
  -d "{\"fields\": {\"labels\": $LABELS}}"
```

## Useful Endpoints

| Endpoint | Description |
|----------|-------------|
| `/myself` | Current user info |
| `/search/jql?jql=...` | Search issues with JQL |
| `/issue/{key}` | Get issue details |
| `/project` | List projects |
| `/project/{key}` | Get project details |
| `/issue/{key}/comment` | Get issue comments |
| `/issue/{key}/transitions` | Get available transitions |

## UI URLs

| Resource | URL Pattern |
|----------|-------------|
| Issue | `https://netflix.atlassian.net/browse/{KEY}` |
| Project | `https://netflix.atlassian.net/browse/{PROJECT}` |
| JQL Search | `https://netflix.atlassian.net/issues/?jql={JQL}` |

## Sandbox Testing

For testing in non-production, use the sandbox site:

```bash
JIRA_SANDBOX="https://atlassian-api-external.dmz.build.netflix.net:8443/atlassian-api-proxy/jira/netflix-sandbox-671/rest/api/3"
metatron curl -a connect "$JIRA_SANDBOX/myself" | jq .
```

## Troubleshooting

**"unsupported protocol scheme" with `metatron curl`:** If a `$JIRA` variable fails to expand in the URL, pass the full URL inline instead of using the variable. This can happen in some shell environments.

## Notes

- API rate limits apply - avoid excessive requests
- `currentUser()` works automatically with Metatron auth
- Date formats: `YYYY-MM-DD` or relative like `-7d`, `-1w`, `-1M`
- Text search (`text ~`) searches summary, description, and comments
- The old `/search` POST endpoint is deprecated - use `/search/jql` GET instead
