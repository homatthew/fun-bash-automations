---
name: test-dgw-kv
description: Test DGW KV server and client changes. Covers using the mho/dev-fork branch for fast server builds, client snapshot testing via consuming apps, and the full local-to-Titus workflow.
---

# Testing DGW KV Changes

This skill covers two workflows: testing **server** changes (the DGW KV service itself) and testing **client** changes (the `dgw-kv-client` library consumed by applications).

## Server Testing via `mho/dev-fork`

The `mho/dev-fork` branch exists to generate server Docker images quickly. Tests are disabled in `build.gradle` so the build only compiles and publishes images.

- **PR**: https://github.netflix.net/corp/cde-dgw-kv/pull/2140
- **Branch**: `mho/dev-fork`
- **How tests are disabled**: `dryRun = true` on all `Test` tasks in `allprojects` (discovers tests, marks them skipped in JUnit XML, never executes them)

### Quick Reference

```bash
# Get your changes onto dev-fork and push
git checkout mho/dev-fork
git merge --no-edit <your-feature-branch>   # or cherry-pick
git push origin mho/dev-fork

# Jenkins builds automatically on push. Two images are produced:
#   registry.prod.netflix.net/cde/dgw-cde-kv:mho-dev-fork        (branch tag)
#   registry.prod.netflix.net/cde/dgw-cde-kv:v2.X.Y-hNNNN.abcdef (version tag)
#
# A separate DAL image is also published to the DGW S3 registry.
```

### Getting Your Changes onto dev-fork

There are two ways to get code onto `mho/dev-fork`: cherry-picking specific commits or merging a whole branch.

#### Option A: Cherry-pick specific commits (recommended)

Use this when you want to test specific changes without bringing in everything from a branch.

```bash
git checkout mho/dev-fork
git fetch origin

# Cherry-pick one commit
git cherry-pick abc1234

# Cherry-pick a range of commits from your feature branch
git cherry-pick abc1234..def5678

# Cherry-pick all commits from a branch that aren't on master
# (useful when your branch has many commits)
git log --oneline master..mho/my-feature   # preview what you're picking
git cherry-pick master..mho/my-feature     # cherry-pick all of them

git push origin mho/dev-fork
```

If you get a conflict on `build.gradle`, resolve it and make sure the `dryRun = true` line stays in the `allprojects` block.

#### Option B: Merge a whole branch

Use this when you want everything from a feature branch.

```bash
git checkout mho/dev-fork
git merge --no-edit mho/my-feature
git push origin mho/dev-fork
```

### Keeping dev-fork in Sync with Master

Over time, `mho/dev-fork` will fall behind `master`. When you need to pick up new changes from master (e.g., dependency updates, other people's merged PRs):

#### Simple: Merge master in

```bash
git checkout mho/dev-fork
git fetch origin master
git merge --no-edit origin/master
git push origin mho/dev-fork
```

This is safe and preserves history. dev-fork will accumulate merge commits over time but that's fine — it's a throwaway build branch.

#### Clean slate: Reset to master and re-apply

If dev-fork has drifted too far or has junk you don't want:

```bash
git checkout mho/dev-fork
git fetch origin

# Reset to latest master
git reset --hard origin/master

# Re-apply the test-disable commits (the 2 commits unique to dev-fork)
git cherry-pick origin/mho/dev-fork~2..origin/mho/dev-fork

# Now cherry-pick or merge your feature work back on
git cherry-pick master..mho/my-feature   # or: git merge --no-edit mho/my-feature

git push --force-with-lease origin mho/dev-fork
```

**Note:** The `--force-with-lease` is safe here because dev-fork is a personal build branch. But double-check no one else is pushing to it.

### Waiting for the Build

```bash
# Check build status on the PR
gh pr checks 2140

# Jenkins URL:
# https://platform.builds.test.netflix.net/job/CDE-dgw-kv-build-pull-request/
```

The build runs `./gradlew devSnapshot` which compiles, builds the Docker image via Jib, and pushes to both the DGW S3 registry and the Titus registry. Two images are produced:

```
registry.prod.netflix.net/cde/dgw-cde-kv:mho-dev-fork          (branch tag, always latest)
registry.prod.netflix.net/cde/dgw-cde-kv:v2.X.Y-hNNNN.abcdef   (immutable version tag)
```

### Deploying the Image

Use the branch tag `mho-dev-fork` or the version tag from the Jenkins output to deploy via Spinnaker.

### What the CI Pipeline Does

From `.netflix/netflix.ci`:

1. `./gradlew clean alljavadoc devSnapshot` — compiles and publishes a snapshot (tests excluded via `build.gradle`)
2. `publish_dal.sh` — builds a Jib Docker tar and pushes to DGW S3 registry
3. `newt registry build && push` — pushes the server image to Titus registry

### How Tests Are Disabled

In the root `build.gradle`, inside `allprojects`:

```groovy
tasks.withType(Test).configureEach {
    timeout = Duration.ofMinutes(15)
    dryRun = true
}
```

`dryRun = true` (Gradle 8.3+) discovers all test classes and marks them as **skipped** in the JUnit XML report without executing any test code. This satisfies Jenkins' JUnit report publisher while keeping builds fast.

**Why not other approaches?**

| Approach | Problem |
|----------|---------|
| `enabled = false` | Task skipped entirely, no JUnit XML generated |
| `exclude '**/*'` | Task exits as NO-SOURCE, no XML generated |
| `-x test` on CLI | Only skips the `test` task, misses `integTest`, `smokeTest`, etc. |
| `doLast` placeholder | Never fires when task is NO-SOURCE |

### Cherry-Pick Tutorial

Cherry-picking copies commits from one branch onto another. Here's how it works in the context of dev-fork.

#### The test-disable commits

The `mho/dev-fork` branch has two commits on top of master that disable tests:

```
8fe8c685b  Disable all tests for dev-fork build branch
bdde7d52b  Exclude all test classes instead of disabling test tasks
```

#### Cherry-pick basics

```bash
# Pick a single commit by hash
git cherry-pick bdde7d52b

# Pick multiple commits (listed individually)
git cherry-pick 8fe8c685b bdde7d52b

# Pick a range (exclusive start..inclusive end)
# This picks everything AFTER abc up to and including def
git cherry-pick abc1234..def5678

# Pick all commits on a branch that aren't on master
git cherry-pick master..mho/my-feature
```

#### Common scenario: Recreate dev-fork from scratch

If you ever need to recreate the dev-fork setup on a fresh branch:

```bash
git checkout -b mho/dev-fork origin/master
git cherry-pick 8fe8c685b bdde7d52b    # apply test-disable commits
git push -u origin mho/dev-fork
```

#### Common scenario: Feature work onto dev-fork

```bash
git checkout mho/dev-fork

# Preview what you'll be picking
git log --oneline master..mho/my-feature

# Pick all feature commits
git cherry-pick master..mho/my-feature

git push origin mho/dev-fork
```

#### Handling conflicts during cherry-pick

```bash
# If a cherry-pick conflicts:
git status                    # see which files conflict
# Edit the conflicted files, resolve the markers (<<<<< ===== >>>>>)
git add <resolved-files>
git cherry-pick --continue    # finish the cherry-pick

# Or abort if you want to start over
git cherry-pick --abort
```

For `build.gradle` conflicts specifically: make sure the `exclude '**/*'` line stays inside `tasks.withType(Test).configureEach` in the `allprojects` block.

---

## Client Testing via Consuming Apps

For testing changes to the **client library** (`dgw-kv-client`, `dgw-kv-common`, `dgw-kv-proto-definition`) through a consuming SBN application deployed on Titus.

### Architecture

```
cde-dgw-kv (library)          consuming app (e.g., mhohello)
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

### Local Iteration (Fast Feedback)

Use **Gradle composite builds** to test library changes without publishing.

Add to the consuming app's `settings.gradle` (DO NOT COMMIT):

```groovy
includeBuild '../cde-dgw-kv'
```

Then:

```bash
cd ~/repos/mhohello
./gradlew build    # uses local cde-dgw-kv source
./gradlew bootRun  # run with local changes
```

For cloud infra connectivity, use Hybrid Dev (`newt dev`).

**Alternative: mavenLocal** (if composite builds don't work, e.g., incompatible Gradle versions):

```bash
cd ~/repos/cde-dgw-kv
./gradlew build publishToMavenLocal
# Note the version printed (e.g., 2.23.0-snapshot.20260225+mybranch.abc1234)

# In consuming app build.gradle, add:
# repositories { mavenLocal() }
# Then pin: implementation 'com.netflix.dgw.kv:dgw-kv-client:2.23.0-snapshot.20260225+mybranch.abc1234'
```

### Snapshot Publishing (Titus Deployment)

Rocket CI auto-publishes snapshots on non-main branches. Just pushing triggers a `devSnapshot` publish. The snapshot version is immutable and looks like:

```
2.23.0-snapshot.20260225+mho-my-hlc-change.abc1234
```

To find the published version: check Jenkins build output (`newt ci browse` in the library repo) or search Artifactory.

**Note:** Running `./gradlew devSnapshot` locally is discouraged — it loses CI traceability and subsequent runs on the same commit fail (immutable snapshots).

#### Pinning the consuming app

Three options for `build.gradle`:

```groovy
// Option A: Specific version (most predictable)
implementation 'com.netflix.dgw.kv:dgw-kv-client:2.23.0-snapshot.20260225+mho-my-hlc-change.abc1234'

// Option B: Latest snapshot (picks up newest — useful for rapid iteration)
implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.snapshot'

// Option C: latest.release (default — do NOT use for testing snapshots)
implementation 'com.netflix.dgw.kv:dgw-kv-client:latest.release'
```

Then deploy:

```bash
cd ~/repos/mhohello
./gradlew generateLock saveLock && ./gradlew build
git add -A && git commit -m "Pin dgw-kv-client to test snapshot"
git push origin main
# Jenkins builds -> Managed Delivery deploys to test env on Titus
```

### Verifying on Titus

```bash
# Watch Jenkins build
newt ci tail

# Open Spinnaker to track deployment
newt spin browse
# Navigate to Environments tab → expand Test resources
# Wait for "Up to Date" status

# Hit your endpoints via Swagger UI (link in Spinnaker instance details)
```

### Iteration Speed Guide

| Method | Speed | Fidelity | Use when |
|--------|-------|----------|----------|
| Composite build + `bootRun` | Seconds | Local only | Developing the change |
| Composite build + Hybrid Dev | Seconds | Cloud infra | Testing with real DGW shards |
| devSnapshot + Titus deploy | ~15 min | Full production path | Validating before PR |

### Finalizing

After testing:

```bash
# 1. Merge your PR on cde-dgw-kv, wait for release
# 2. Revert consuming app to latest.release
# 3. Regenerate locks: ./gradlew generateLock saveLock
# 4. Push to trigger final deployment
```

---

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
        try {
            kvClient.handshake(List.of("my_namespace")).get();
        } catch (Exception e) {
            log.warn("KV handshake failed", e);
        }
    }
}
```

## Key Classes

| Class | Package | Purpose |
|-------|---------|---------|
| `HighLevelKeyValue` | `com.netflix.dgw.kv.client.api` | Main client interface (inject this) |
| `Item` | `com.netflix.dgw.kv.protogen` | Key-value pair (note: no `v2`) |
| `PutItemsRequest` | `com.netflix.dgw.kv.v2.protogen` | Write request builder |
| `GetItemsRequest` | `com.netflix.dgw.kv.v2.protogen` | Read request builder |
| `Predicate` | `com.netflix.dgw.kv.v2.protogen` | Controls which items to match |
| `KeySet` | `com.netflix.dgw.kv.v2.protogen` | Set of keys for predicates |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| dev-fork build fails on test reports | Ensure `build.gradle` has `dryRun = true` on Test tasks (not `enabled = false` or `exclude`) |
| Composite build not substituting | Check `settings.gradle` module name matches consumer expectations |
| `Could not resolve snapshot` | Push branch to trigger Jenkins, or run `./gradlew devSnapshot` locally |
| dev-fork has merge conflicts | `git checkout mho/dev-fork && git rebase origin/master && git push --force-with-lease` |
| Docker image not appearing | Check Jenkins output for Jib/registry push errors |
| Smoke test fails on handshake | KV shard not provisioned for test env — make handshake non-fatal (`log.warn` instead of throw) |
| Push rejected on main | RocketCI updated deps — `git fetch && git rebase origin/main` then push again |
