---
name: deploy-mhohello
description: Deploy mhohello to Titus test, optionally pinning a specific dgw-kv-client snapshot. Use when you need to deploy mhohello or pick up a specific client library version.
---

# Deploy mhohello

Deploy the `mhohello` application to Titus test via the `mho-deploy` Spinnaker pipeline.

## When to Use

- After pushing to `mhohello` `main` branch and Jenkins finishes building
- When you want to force a redeploy of mhohello with the current image
- After updating `dgw-kv-client` snapshot version in mhohello
- When you need to pin a specific dgw-kv-client snapshot (e.g., from your PR branch)

## Pipeline Details

- **App**: mhohello
- **Pipeline**: mho-deploy
- **Pipeline ID**: 79667fad-632a-4cb6-befc-8f9f3138c623
- **Trigger**: Jenkins job `MATTHEWHO-mhohello-build` (reads `image-server.properties`)
- **Deploys to**: Titus test (us-east-1), strategy: highlander

## Pinning a Specific dgw-kv-client Snapshot

By default mhohello uses `latest.snapshot` which could be anyone's snapshot. To pin YOUR snapshot:

### Step 1: Find your snapshot version

After the cde-dgw-kv PR branch builds successfully, find the published version:

```bash
# Check PR build status
GH_HOST=git.netflix.net gh pr checks <PR_NUMBER> --repo corp/cde-dgw-kv

# The snapshot version format is:
# 2.X.Y-snapshot.YYYYMMDDHHSS+pull.PRNUM.shortsha
#
# Find it in Jenkins build output, or search Artifactory:
# https://artifacts.netflix.com/webapp/#/artifacts/browse/tree/General/maven-oss-snapshots/com/netflix/dgw/kv/dgw-kv-client
```

### Step 2: Pin in mhohello

```bash
cd ~/repos/mhohello
```

Edit `mhohello-server/build.gradle` to pin the exact version:

```groovy
// Pin to YOUR specific snapshot (guaranteed yours)
implementation 'com.netflix.dgw.kv:dgw-kv-client:2.X.Y-snapshot.YYYYMMDD+pull.2139.abc1234'

// Or use latest.snapshot (could be someone else's)
// implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.snapshot'
```

### Step 3: Rebuild locks and push

```bash
cd ~/repos/mhohello
newt exec ./gradlew generateLock saveLock
git add mhohello-server/build.gradle dependencies.lock **/dependencies.lock
git commit -m "Pin dgw-kv-client to handshake-criticality snapshot"
git push origin main
# Jenkins builds -> triggers mho-deploy pipeline -> Titus test
```

### Step 4: Revert after testing

```bash
cd ~/repos/mhohello
# Edit build.gradle back to latest.snapshot or latest.release
newt exec ./gradlew generateLock saveLock
git add mhohello-server/build.gradle dependencies.lock **/dependencies.lock
git commit -m "Revert dgw-kv-client to latest.snapshot"
git push origin main
```

## Quick Deploy (no client change needed)

### Option A: Trigger via newt (recommended)

```bash
cd ~/repos/mhohello && newt spin start --pipeline mho-deploy
```

To wait for completion:

```bash
cd ~/repos/mhohello && newt spin start --pipeline mho-deploy --wait
```

### Option B: Empty commit to trigger full rebuild + deploy

```bash
cd ~/repos/mhohello
git commit --allow-empty -m "Trigger rebuild"
git push origin main
```

### Option C: Trigger via Spinnaker API

```bash
metatron curl -a gate -X POST \
  'https://api.spinnaker.mgmt.netflix.net:7004/pipelines/mhohello/mho-deploy'
```

## Checking Status

```bash
# Open Spinnaker in browser
cd ~/repos/mhohello && newt spin browse

# Or check via API
metatron curl -a gate \
  'https://api.spinnaker.mgmt.netflix.net:7004/applications/mhohello/pipelines?limit=1' \
  | python3 -c "import json,sys; e=json.load(sys.stdin)[0]; print(f'Status: {e[\"status\"]}, Started: {e.get(\"startTime\",\"pending\")}')"
```

## Notes

- Managed Delivery is **disabled** for mhohello — deploys only happen via this pipeline
- The pipeline has no parameters — it picks up the image from Jenkins build properties
- Hot reload: The DGW KV server (`dgwkv.mhohello` shard) picks up new server images from `mho/dev-fork` automatically — no need to redeploy mhohello for server-only changes
- For client-only changes, you need to rebuild mhohello to pick up the new `dgw-kv-client` snapshot
- `latest.snapshot` resolves at Gradle build time — whoever pushed a snapshot last wins
- To guarantee your version, always pin to the exact snapshot version string
