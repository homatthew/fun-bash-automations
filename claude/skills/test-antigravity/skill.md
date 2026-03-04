---
name: test-antigravity
description: Run and test an Antigravity service locally. Covers building, starting dependencies (DynamoDB), launching the webapp, and hitting endpoints with metatron curl. Use when you need to do end-to-end testing of antigravity repos.
---

# Test Antigravity Service Locally

## When to Use
- End-to-end testing of antigravity service changes
- Testing Temporal workflows against the test namespace
- Verifying endpoints work before creating a PR

## Prerequisites Check

Before starting, verify:

```bash
# Docker must be running
docker info 2>&1 | grep "Server Version" || echo "Docker not running — run: open -a Docker"

# Metatron must be available
which metatron || echo "metatron not found"
```

If Docker isn't running, start it with `open -a Docker` and wait ~30s for the daemon.

## Step 1: Dev Setup (Build + Dependencies)

```bash
cd ~/repos/<antigravity-repo>
newt dev-setup
```

This does everything in one command:
- Creates `.venv/` with all dependencies
- Starts local DynamoDB container (required on `localhost:8000`)
- Starts metatron mesh local docker (for service-to-service auth)
- Installs pre-commit hooks

**Requires Docker running first.** If not: `open -a Docker` and wait ~30s.

If you only need to rebuild without restarting containers, use `newt build` instead.

## Step 2: Identify the App Module

Antigravity repos follow a naming convention: `antigravity-<shard>` with a Python module named `antigravity_<shard>`.

```bash
# Find the webapp entrypoint
ls */webapp.py
```

This gives you the `<module>` name (e.g., `antigravity_cass`, `antigravity_edda`, `antigravity_memcached`).

The metatron app identity is typically `antigravity.<shard>` (e.g., `antigravity.cass`). Check `newt.yml` or `appconfig.yaml` if unsure.

## Step 3: Start the Webapp

```bash
source .venv/bin/activate
ALLOW_ANONYMOUS_ACCESS=true python <module>/webapp.py
```

- Runs on `http://127.0.0.1:7101`
- `ALLOW_ANONYMOUS_ACCESS=true` — required so metatron curl works over plaintext HTTP
- Temporal connects to the test namespace automatically
- Wait for `Application startup complete.` in logs before hitting endpoints

## Step 4: Hit Endpoints with Metatron Curl

```bash
metatron curl -a antigravity.<shard> -allowPlaintext \
  -X POST "http://127.0.0.1:7101/<path>?<params>" \
  -H "Content-Type: application/json" \
  -d '<json-body>'
```

Key flags:
- `-a antigravity.<shard>` — metatron app identity
- `-allowPlaintext` — required because local server is HTTP, not HTTPS
- `-d '{}'` — empty JSON body for endpoints with default body params

### Discovering Endpoints

```bash
# List available routes from the running webapp
metatron curl -a antigravity.<shard> -allowPlaintext \
  "http://127.0.0.1:7101/openapi.json" | python -m json.tool
```

Or check the repo's route definitions directly (typically in `<module>/routes/`).

---

## Shard-Specific Reference

### antigravity-cass

- **Repo**: `~/repos/antigravity-cass`
- **Module**: `antigravity_cass`
- **Metatron app**: `antigravity.cass`

#### Discovering App Names

```python
# Run in the activated venv
from ods_metadata import ODSMetadataBulk
impacts = ODSMetadataBulk.get_availability_impact(techs=['cass'])
for i in impacts[:10]:
    print(i.appname)
```

#### Example: Fleet Recommendation (specific apps)
```bash
metatron curl -a antigravity.cass -allowPlaintext \
  -X POST "http://127.0.0.1:7101/scale/fleet-recommendation?scale_type=right_size&app_names=cass_turtle&app_names=cass_vms&export_to_spreadsheet=true" \
  -H "Content-Type: application/json" -d '{}'
```

#### Example: Fleet Recommendation (full fleet via ODS discovery)
```bash
metatron curl -a antigravity.cass -allowPlaintext \
  -X POST "http://127.0.0.1:7101/scale/fleet-recommendation?scale_type=right_size&export_to_spreadsheet=true" \
  -H "Content-Type: application/json" -d '{}'
```

#### Example: Single App Recommendation
```bash
metatron curl -a antigravity.cass -allowPlaintext \
  -X POST "http://127.0.0.1:7101/scale/recommendation/account:persistence_prod/app:cass_turtle" \
  -H "Content-Type: application/json" -d '{}'
```

---

## Common Issues

| Symptom | Fix |
|---------|-----|
| `Cannot connect to Docker daemon` | `open -a Docker`, wait 30s |
| `ConnectionRefusedError` on port 8000 | Re-run `newt dev-setup` to start DynamoDB container |
| Metatron mesh auth failures | Re-run `newt dev-setup` to start metatron mesh local docker |
| `401 Unauthorized` | Restart webapp with `ALLOW_ANONYMOUS_ACCESS=true` |
| `server gave HTTP response to HTTPS client` | Use `-allowPlaintext` flag with metatron curl |
| `WorksheetNotFound` on export | Create the worksheet in Google Sheets manually |
| App name 404 | Use real names from ODS metadata discovery |
| `WorkflowAlreadyStartedError` (409) | Previous workflow still running — wait or cancel via Temporal UI |

## Cleanup

```bash
# Stop webapp: Ctrl+C or kill the process
# Stop containers started by newt dev-setup:
docker stop dynamodb-local metatron-mesh-local 2>/dev/null
# Remove containers (optional):
docker rm dynamodb-local metatron-mesh-local 2>/dev/null
```
