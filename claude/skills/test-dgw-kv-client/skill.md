---
name: test-dgw-kv-client
description: Test local DGW KV High Level Client (HLC) changes against a consuming SBN app deployed on Titus. Covers the full workflow from local iteration to snapshot publishing to Titus deployment.
---

# Testing DGW KV Client Changes on Titus

Workflow for making changes to the DGW KV Java client (`cde-dgw-kv`) and testing them through a consuming SBN application deployed on Titus via Managed Delivery.

## Architecture

```
cde-dgw-kv (library)          mhohello (consuming app)
┌──────────────────┐           ┌──────────────────────┐
│ dgw-kv-client    │──snapshot──▶ build.gradle         │
│ dgw-kv-common    │    or      │   implementation     │
│ dgw-kv-proto-def │ composite  │   'dgw-kv-client:X'  │
└──────────────────┘  build     └──────────┬───────────┘
                                           │
                                     push to main
                                           │
                                    Jenkins builds
                                           │
                                  Managed Delivery
                                           │
                                    Titus (test env)
```

## Phase 1: Local Iteration (Fast Feedback)

Use **Gradle composite builds** to test library changes without publishing.

### Setup

```bash
# Clone both repos side by side
cd ~/repos
# cde-dgw-kv should already be cloned
# consuming app (e.g., mhohello) should already be cloned
```

### Composite Build (Recommended)

Temporarily add to the consuming app's `settings.gradle`:

```groovy
// DO NOT COMMIT — local dev only
includeBuild '../cde-dgw-kv'
```

This makes Gradle substitute the binary `dgw-kv-client` dependency with the local source. Changes to `cde-dgw-kv` are picked up on every build — no publishing needed.

```bash
# In the consuming app
./gradlew build    # uses local cde-dgw-kv source
./gradlew bootRun  # run with local changes
```

### Alternative: mavenLocal

If composite builds don't work (e.g., incompatible Gradle versions):

```bash
# In cde-dgw-kv
./gradlew build publishToMavenLocal
# Note the version printed (e.g., 2.23.0-snapshot.20260225+mybranch.abc1234)

# In consuming app build.gradle, add:
# repositories { mavenLocal() }
# Then pin: implementation 'com.netflix.dgw.kv:dgw-kv-client:2.23.0-snapshot.20260225+mybranch.abc1234'
```

### Hybrid Dev (Local Code, Cloud Infra)

For testing against real DGW KV shards without deploying to Titus:

```bash
# In consuming app with composite build configured
./gradlew bootRun
# OR use Hybrid Dev for mesh/metatron connectivity:
newt dev
```

This runs your code locally but connects to real Netflix mesh infrastructure.

## Phase 2: Snapshot Publishing (Titus Deployment)

To deploy on Titus, the library must be published to Artifactory.

### Step 1: Push library changes

```bash
cd ~/repos/cde-dgw-kv
git checkout -b mho/my-hlc-change
# ... make changes ...
git add -A && git commit -m "HLC: description of change"
git push origin mho/my-hlc-change
```

### Step 2: Publish a devSnapshot

Rocket CI auto-publishes snapshots on non-main branches. The `.netflix/netflix.ci` script runs `./gradlew devSnapshot` for feature branches and `./gradlew candidate` for main. Just pushing your branch triggers a snapshot publish.

The snapshot is published to `libs-snapshots-local` with an immutable version like:
```
2.23.0-snapshot.20260225+mho-my-hlc-change.abc1234
```

You can also run `./gradlew devSnapshot` locally, but this is discouraged — it loses CI traceability and subsequent runs on the same commit fail (immutable snapshots).

To find the published version: check Jenkins build output (`newt ci browse` in the library repo) or search Artifactory.

### Step 3: Pin consuming app to snapshot

Three options:

```groovy
// Option A: Specific version (most predictable)
implementation 'com.netflix.dgw.kv:dgw-kv-client:2.23.0-snapshot.20260225+mho-my-hlc-change.abc1234'

// Option B: Latest snapshot (picks up newest — useful for rapid iteration)
implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.snapshot'

// Option C: latest.release (default — do NOT use for testing snapshots)
implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.release'
```

Then regenerate locks:
```bash
./gradlew generateLock saveLock
./gradlew build  # verify it compiles
```

### Step 4: Deploy consuming app

```bash
git add -A && git commit -m "Pin dgw-kv-client to test snapshot"
git push origin main
# Jenkins builds → Managed Delivery deploys to test env on Titus
```

### Step 5: Verify on Titus

```bash
# Watch Jenkins build
newt ci tail

# Open Spinnaker to track deployment
newt spin browse
# Navigate to Environments tab → expand Test resources
# Wait for "Up to Date" status

# Hit your endpoints via Swagger UI (link in Spinnaker instance details)
```

## Phase 3: Iterate

For each change to the library:

| Method | Speed | Fidelity | Use when |
|--------|-------|----------|----------|
| Composite build + bootRun | Seconds | Local only | Developing the change |
| Composite build + Hybrid Dev | Seconds | Cloud infra | Testing with real DGW shards |
| devSnapshot + Titus deploy | ~15 min | Full production path | Validating before PR |

### Fast iteration loop

```bash
# 1. Make change in cde-dgw-kv
# 2. Test locally with composite build
cd ~/repos/mhohello && ./gradlew build

# 3. When ready for Titus, publish snapshot
cd ~/repos/cde-dgw-kv && ./gradlew devSnapshot
# Note the version

# 4. Pin and deploy
cd ~/repos/mhohello
# Update build.gradle with new snapshot version
./gradlew generateLock saveLock && ./gradlew build
git add -A && git commit -m "Pin dgw-kv-client snapshot: <version>"
git push origin main
```

## Phase 4: Finalize

Once testing is complete:

```bash
# 1. In cde-dgw-kv: merge PR, wait for release
# 2. In consuming app: revert to latest.release
#    implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.release'
# 3. Regenerate locks
./gradlew generateLock saveLock
# 4. Push to trigger final deployment
```

## DGW KV Client Key Classes

| Class | Package | Purpose |
|-------|---------|---------|
| `HighLevelKeyValue` | `com.netflix.dgw.kv.client.api` | Main client interface (inject this) |
| `Item` | `com.netflix.dgw.kv.protogen` | Key-value pair within a record |
| `PutItemsRequest` | `com.netflix.dgw.kv.v2.protogen` | Write request builder |
| `GetItemsRequest` | `com.netflix.dgw.kv.v2.protogen` | Read request builder |
| `Predicate` | `com.netflix.dgw.kv.v2.protogen` | Controls which items to match |
| `KeySet` | `com.netflix.dgw.kv.v2.protogen` | Set of keys for predicates |

**Important**: `Item` is in `com.netflix.dgw.kv.protogen` (no `v2`), while request/response types are in `com.netflix.dgw.kv.v2.protogen`.

## SBN Auto-Configuration

When `dgwkv.shard` is set in `application.yml` and `dgw-kv-client` is on the classpath, SBN auto-configures the `HighLevelKeyValue` bean. Just inject it:

```yaml
# application.yml
dgwkv:
  shard: <app-name>
```

```java
@Component
public class MyStore {
    private final HighLevelKeyValue kvClient;

    public MyStore(HighLevelKeyValue kvClient) {
        this.kvClient = kvClient;
        // Handshake on startup (make non-fatal if KV is optional)
        try {
            kvClient.handshake(List.of("my_namespace")).get();
        } catch (Exception e) {
            log.warn("KV handshake failed", e);
        }
    }
}
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| Composite build not substituting | Module name mismatch | Check `settings.gradle` in library matches what consumer expects |
| `Could not resolve snapshot` | Snapshot not published yet | Run `./gradlew devSnapshot` in library or wait for Jenkins |
| Smoke test fails on handshake | KV shard not provisioned | Make handshake non-fatal (log.warn instead of throw) |
| Push rejected on main | RocketCI updated deps | `git fetch && git rebase origin/main` then push again |
| `Item` import error | Wrong package | Use `com.netflix.dgw.kv.protogen.Item` (no `v2`) |

## Scope

This skill covers **client-side changes** (the `dgw-kv-client` library consumed by applications). Server-side DGW KV changes (the DGW KV service itself) have a different testing workflow not covered here.
