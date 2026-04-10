---
name: cap-plan
description: Fetch live Cassandra cluster state and surface capacity planner output into context. Given an app name, scale type, and optional scale buffers, fetches planning input via the recommendation endpoint, calls the explained capacity planner, and parses results into structured data. Narrates as Q&A. All calls are remote via metatron curl — no local library.
---

# Capacity Explain (Live)

Fetch live cluster state, call the remote capacity planner, surface everything into context, narrate as Q&A.

---

## Step 0: Gather Inputs

**Always ask:**
1. **App name** — e.g., `cass_turtle`
2. **Env** — prod or test → `persistence_prod` / `persistence_test`. Default: prod.
3. **Scale type** — what kind of recommendation?
   - `right_size` (default) — optimal instance types for an existing cluster based on historical usage
   - `live_scale` — scale a running cluster while preserving storage type (EBS vs ephemeral) and allowing high node density (can't change node count live)
   - `buffer_check` — check if the current cluster's buffer is sufficient for a proposed scale change

**Ask if not obvious:**
4. **Scale factor** — planning for future load? (e.g. `2.0` for 2× traffic). Default: none. If provided, we'll derive proper weighted buffers via `compute-scale-buffers`.
5. **Horizontal scaling** — locked to current node count, or free to explore? Default: locked. Pass `override_required_cluster_size=-1` to unlock.
6. **Specific focus** — any particular question? (e.g. "why not EBS?", "why not r6a?")

---

## Step 1: (Optional) Derive Scale Buffers

Skip this step if no scale factor is needed — go directly to Step 2 with an empty body.

If planning for future load, derive proper buffer ratios first. The `compute-scale-buffers` endpoint computes weighted ratios — writes are heavier than reads, only generates buffers when change ≥ 1.1×.

```bash
APP=<app_name>
ACCOUNT=persistence_prod
AG_CASS="https://cass.antigravity.us-east-1.prod.netflix.net:7004"

# Fetch current state (unbuffered) as old_desire
metatron curl -a antigravity.cass -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  "${AG_CASS}/scale/recommendation/plan-input/account:${ACCOUNT}/app:${APP}?duration=1w&num_candidates=10&scale_type=right_size" \
  -o /tmp/old_desire.json

# Build new_desire with scaled RPS/WPS/data
python3 -c "
import json, copy
old = json.load(open('/tmp/old_desire.json'))
new = copy.deepcopy(old)
f = <scale_factor>  # e.g. 2.0
for field in ('estimated_read_per_second', 'estimated_write_per_second'):
    iv = new['desires']['query_pattern'].get(field, {})
    if iv:
        iv.update({k: v * f for k, v in iv.items() if k in ('low','mid','high')})
iv = new['desires'].get('data_shape', {}).get('estimated_state_size_gib', {})
if iv:
    iv.update({k: v * f for k, v in iv.items() if k in ('low','mid','high')})
json.dump({'old_desire': old, 'new_desire': new}, open('/tmp/scale_req.json', 'w'))
"

# Derive weighted buffers → /tmp/plan_body.json
metatron curl -a antigravity.cass -X POST \
  -H 'Content-Type: application/json' \
  -d @/tmp/scale_req.json \
  "${AG_CASS}/scale/compute-scale-buffers" \
  -o /tmp/scale_buffers.json

python3 -c "
import json
sb = json.load(open('/tmp/scale_buffers.json'))
print(json.dumps({'buffers': sb['scale_buffers']}, indent=2))
" > /tmp/plan_body.json
```

The output `/tmp/plan_body.json` is the body for Step 2. If no scale factor, use `{}` as the body.

---

## Step 2: Fetch Planning Input

Call `plan-input` once with everything: buffers from Step 1 (if any), scale_type, horizontal scaling override — all as declared params.

```bash
AG_CASS="https://cass.antigravity.us-east-1.prod.netflix.net:7004"

metatron curl -a antigravity.cass -X POST \
  -H 'Content-Type: application/json' \
  -d @/tmp/plan_body.json \
  "${AG_CASS}/scale/recommendation/plan-input/account:${ACCOUNT}/app:${APP}?duration=1w&num_candidates=10&scale_type=right_size" \
  -o /tmp/planning_input.json
```

If no scale factor, pass empty body:
```bash
metatron curl -a antigravity.cass -X POST \
  -H 'Content-Type: application/json' -d '{}' \
  "${AG_CASS}/scale/recommendation/plan-input/account:${ACCOUNT}/app:${APP}?duration=1w&num_candidates=10&scale_type=right_size" \
  -o /tmp/planning_input.json
```

**Query params:**
- `duration=1w` — look-back window (default 14d, auto-adjusts for recent scale events)
- `num_candidates=10` — enough to see all viable families and node-count variants
- `scale_type=right_size` — sets reasonable defaults (or `live_scale`, `buffer_check`)
- `override_required_cluster_size=-1` — add this to unlock horizontal scaling

**Body** (`CapacityArgsBody`):
- `buffers` — from Step 1 (derived scale buffers) or omit
- `extra_model_args` — model overrides like `{"different_family_regret": 0.05}` or omit

Response is `PlanningInput`: `{ regions, desires, extra_model_arguments, context }` — pipe directly to Step 3.

---

## Step 3: Call antigravity-capacity Explained Endpoint

```bash
metatron curl -a antigravity.capacity -X POST \
  -H 'Content-Type: application/json' \
  -d @/tmp/planning_input.json \
  'https://capacity.antigravity.vip.us-east-1.prod.cloud.netflix.net:7004/v1/capacity/plan/certain/explained?model=org.netflix.cassandra&num_candidates=10' \
  -o /tmp/explained.json
```

Response is `dict[region, ExplainedPlans]` — one entry per region.

---

## Step 4: Parse and Display

Write to `/tmp/parse_explained.py` and run with `python3 /tmp/parse_explained.py`:

```python
import json
from collections import defaultdict

raw_input = json.load(open("/tmp/planning_input.json"))
data = json.load(open("/tmp/explained.json"))

app_name = (raw_input.get("context") or {}).get("app_name", "unknown")
extra = raw_input.get("extra_model_arguments", {})
region = "us-east-1" if "us-east-1" in data else list(data.keys())[0]
r = data[region]

plans = r["plans"]
excuses = r.get("excuses", [])
traits = r.get("family_graph", {}).get("traits", {})
edges = r.get("family_graph", {}).get("edges", [])

def fam(name): return name.rsplit(".", 1)[0]

top = plans[0] if plans else None
top_family = fam(top["candidate_clusters"]["zonal"][0]["instance"]["name"]) if top else None

print(f"\n{'='*60}")
print(f"APP: {app_name}  REGION: {region} (x{len(data)} regions)")
print(f"extra_model_arguments: {extra}")
print(f"{'='*60}\n")

# ── BASELINE ─────────────────────────────────────────────────────────────────
cur = (raw_input.get("desires") or {}).get("current_clusters", {}).get("zonal", [{}])[0]
if cur.get("cluster_instance_name"):
    cnt = cur.get("cluster_instance_count", {})
    print("BASELINE (current cluster)")
    print(f"  {cnt.get('mid', 0):.0f}x {cur['cluster_instance_name']}")
    if cur.get("cpu_utilization"):
        u = cur["cpu_utilization"]
        print(f"  cpu_util: low={u['low']:.1f}% mid={u['mid']:.1f}% high={u['high']:.1f}%")
    if cur.get("disk_utilization_gib"):
        u = cur["disk_utilization_gib"]
        print(f"  disk_util_gib: low={u['low']:.0f} mid={u['mid']:.0f} high={u['high']:.0f}")
    if cur.get("network_utilization_mbps"):
        print(f"  net_mbps: mid={cur['network_utilization_mbps']['mid']:.0f}")
    print()

# ── TOP N PLANS ───────────────────────────────────────────────────────────────
print(f"TOP {len(plans)} PLANS")
for i, p in enumerate(plans):
    z = p["candidate_clusters"]["zonal"][0]
    total = p["candidate_clusters"]["total_annual_cost"]
    annual = p["candidate_clusters"].get("annual_costs", {})
    params = z.get("cluster_params", {})
    penalties = params.get("rank_penalties", {})
    print(f"  [{i+1}] {z['count']}x {z['instance']['name']:22s}  rank={p['rank']:.0f}  total=${total:,.0f}/yr")
    for k, v in sorted(annual.items()):
        print(f"       cost[{k}]: ${float(v):,.0f}")
    for k in ("cassandra.storage_buffer_ratio", "cassandra.compute_buffer_ratio",
              "effective_disk_per_node_gib", "cassandra.heap.gib"):
        if k in params:
            print(f"       {k}: {params[k]}")
    if penalties:
        print(f"       rank_penalties: {penalties}")
print()

# ── EXCUSES BY FAMILY ─────────────────────────────────────────────────────────
family_excuses = defaultdict(list)
for e in excuses:
    family_excuses[fam(e["instance"])].append(e)

print(f"EXCUSES ({len(excuses)} total) BY FAMILY")
for f_ in sorted(family_excuses):
    ex = family_excuses[f_]
    bn_counts = defaultdict(int)
    tag_counts = defaultdict(int)
    for e in ex:
        bn_counts[str(e.get("bottleneck") or "none")] += 1
        for t in (e.get("tags") or []):
            tag_counts[str(t)] += 1
    top_bn = max(bn_counts, key=bn_counts.get)
    sample = next(e for e in ex if str(e.get("bottleneck") or "none") == top_bn)
    tags_str = ", ".join(f"{t}:{c}" for t, c in sorted(tag_counts.items()))
    print(f"  {f_:10s}  {len(ex):3d} excuses  top_bottleneck=[{top_bn}]  tags=[{tags_str}]")
    print(f"             sample: {sample['reason'][:80]}")
print()

# ── FAMILY GRAPH TRAITS ───────────────────────────────────────────────────────
ranked_families = {fam(p["candidate_clusters"]["zonal"][0]["instance"]["name"]) for p in plans}
print("FAMILY GRAPH TRAITS")
for f_, trait in sorted(traits.items()):
    disk = f"{trait['local_disk_gib_per_vcpu']:.0f} GiB/vCPU local" if trait.get("local_disk_gib_per_vcpu") else "EBS"
    cost = f"${trait['cost_per_vcpu_annual']:.0f}/vCPU/yr" if trait.get("cost_per_vcpu_annual") else ""
    ranked = "✓" if f_ in ranked_families else "✗"
    print(f"  {ranked} {f_:10s}  {trait['memory_gib_per_vcpu']:.1f} GiB/vCPU  {disk}  {cost}")
print()

# ── FAMILY GRAPH EDGES FROM WINNER ───────────────────────────────────────────
from_edges = [e for e in edges if e.get("from_family") == top_family]
if from_edges:
    print(f"FAMILY GRAPH EDGES FROM {top_family}")
    for e in from_edges:
        print(f"  -> {e['to_family']:10s}  improves={e.get('improves',[])}  degrades={e.get('degrades',[])}")
    print()

# ── REJECTION SUMMARY ────────────────────────────────────────────────────────
by_bn = defaultdict(int)
by_tag = defaultdict(int)
for e in excuses:
    by_bn[str(e.get("bottleneck") or "none")] += 1
    for t in (e.get("tags") or []):
        by_tag[str(t)] += 1
print("REJECTION SUMMARY")
print("  by bottleneck:", dict(sorted(by_bn.items(), key=lambda x: -x[1])))
print("  by tag:       ", dict(sorted(by_tag.items(), key=lambda x: -x[1])))
```

---

## Step 5: Narrate

### Structure

Start with a side-by-side comparison of current, recommended, and top contenders. Then answer the Q&A — each answer flows from the comparison.

**1. The comparison table**

Always show:
```
CURRENT:       Nx instance       $X/yr    (from BASELINE)
RECOMMENDED:   Nx instance       $Y/yr    (plan [1])
CONTENDER #2:  Nx instance       $Z/yr    (plan [2])
CONTENDER #3:  Nx instance       $W/yr    (plan [3])
```
State the relationship: same family? same count? cost delta?

**2. The one-line verdict**

One of four patterns depending on how current relates to recommended:
- **Correctly placed**: "The planner confirms the current topology — no cheaper option exists under the current constraints."
- **Family migration**: "The planner recommends switching from {current_family} to {recommended_family}, saving $X/yr. The current family ranks #{N}."
- **Vertical resize**: "The planner recommends resizing from {current_size} to {recommended_size} within the same family, saving $X/yr."
- **Overprovisioned**: "The current shape isn't in the ranked plans at all — it was rejected for {bottleneck}. The recommendation is a fundamentally different configuration."

**3. Q&A (1–3 sentences each, skip if not applicable)**

**Q1: What's driving the recommendation?**
Read `storage_buffer_ratio`, `compute_buffer_ratio`, `effective_disk_per_node_gib`. State which resource is the binding constraint and why the recommended instance fits it. If `required_cluster_size` is present, note that horizontal scale is locked.

**Q2: Why not just scale nodes?**
If topology locked: state that all other node counts are rejected. If unlocked: compare same-instance plans at different counts — state rank and cost delta, explain why the recommended count wins.

**Q3: Why not stay on the current instance/family?**
If current family is in plans: state its rank and what penalties or cost differential pushed it below #1. If current shape is in excuses: state the bottleneck that eliminated it. Use `current_shape` and `same_family` tags.

**Q4: Why not the contenders?**
For plans [2] and [3]: state what makes them rank lower than [1] — cost, penalties, oversized hardware, wrong density. Use `FAMILY GRAPH TRAITS` ratios for concrete comparisons ("r6id costs $90/vCPU vs m6id's $78/vCPU — 15% more for 2x the RAM this cluster doesn't need").

**Q5: What families are eliminated entirely and why?**
Walk rejected families in `EXCUSES BY FAMILY`. Group by bottleneck. Use trait numbers to explain:
- `cluster_size` → "At {X} GiB/vCPU memory, {family} needs {N} nodes but topology is locked to {M}"
- `memory` → "{family} has {X} GiB/vCPU — below Cassandra's heap minimum"
- `drive_type` → "EBS-only, but local disks required"

**Q6: What would happen at Nx load? (only if scale buffers applied)**
Compare buffered vs unbuffered: did the winner change? Did the count change? State the inflection point.

**Q7: What knobs could change this?**
1–2 actionable levers, phrased as `plan-input` params:
- `override_required_cluster_size=-1` → unlock horizontal scaling
- `extra_model_args: {different_family_regret: 0.05}` → reduce migration penalty
- `extra_model_args: {require_attached_disks: true}` → open EBS families

---

### Example: Family Migration (pagestore_p1)

> **Current → Recommended → Contenders:**
> ```
> CURRENT:       4x i4i.4xlarge     (not ranked — rejected for cluster_size)
> RECOMMENDED:   4x m6id.8xlarge    $43.5K/yr   rank #1
> CONTENDER #2:  4x r6id.8xlarge    $48.2K/yr   rank #2
> CONTENDER #3:  4x m6idn.8xlarge   $44.4K/yr   rank #3
> SAME FAMILY:   4x i4i.8xlarge     $54.4K/yr   rank #4
> ```
>
> **Verdict:** The planner recommends switching from i4i to m6id. The current i4i.4xlarge isn't in the ranked plans — at 4 nodes its disk density requires 8xlarge, which costs $11K/yr more than m6id.8xlarge.
>
> **Q1: What's driving it?** m6id.8xlarge wins on $/vCPU: $78/vCPU/yr vs i4i's $106/vCPU/yr. The cluster uses 474 GiB/node mid disk — m6id's 1,770 GiB NVMe per node fits this comfortably with a 3.6× storage buffer. `required_cluster_size=4` locks the topology.
>
> **Q2: Why not scale nodes?** All 241 plans are 4-node — 187 rejections are `cluster_size != 4`. The topology lock eliminates every alternative node count.
>
> **Q3: Why not stay on i4i?** i4i.4xlarge (current) is rejected because at 4 nodes the planner needs 8xlarge to fit the data — and i4i.8xlarge ranks #4 at $54K/yr, $11K more than m6id. The `family_migration` penalty doesn't appear because `right_size` defaults don't penalize migrations for this cluster.
>
> **Q4: Why not the contenders?** r6id.8xlarge (#2, $48K) has 2× the RAM (7.6 vs 3.8 GiB/vCPU) at $90/vCPU — 15% more per-vCPU for memory the cluster doesn't need. m6idn.8xlarge (#3, $44K) is nearly identical to m6id but slightly more expensive.
>
> **Q5: Eliminated families?** 187 `cluster_size` rejections dominate: EBS-only families (r6a, m6a, c6a, etc.) need 8+ nodes at their memory density but the topology is locked to 4. c6id has 54 `memory` rejections — smaller sizes can't satisfy heap requirements; only c6id.12xlarge (#8, $82K) survives.
>
> **Q7: Knobs?** `override_required_cluster_size=-1` would open horizontal scaling — EBS families at $46–63/vCPU/yr could significantly undercut m6id if allowed to run 8 nodes.

---

### Example: Correctly Placed (event_bucketer)

> **Current → Recommended → Contenders:**
> ```
> CURRENT:       32x i4i.4xlarge    $710K/yr    rank #1
> RECOMMENDED:   32x i4i.4xlarge    $710K/yr    ← same
> CONTENDER #2:  32x i3en.3xlarge   $677K/yr    (family_migration penalty)
> CONTENDER #3:  64x i4i.4xlarge    $795K/yr    (more nodes, higher cost)
> ```
>
> **Verdict:** The planner confirms the current topology. No cheaper option exists under the topology lock.
>
> **Q1: What's driving it?** Disk-bound — each node needs ~3,350 GiB (2.6× buffer on 851 GiB actual), and i4i.4xlarge's 3,492 GiB NVMe is near-perfect. `required_cluster_size=32` locks horizontal scale.
>
> **Q3: Why not stay on i4i?** It IS i4i — that's the point. The current shape is the winner.
>
> **Q4: Why not the contenders?** i3en.3xlarge (#2) is $33K cheaper but carries a 10% `family_migration` penalty — the ranker adds a virtual $68K, pushing it below i4i. 64x i4i.4xlarge (#3) costs $85K more by halving node utilization.
>
> **Q5: Eliminated families?** All EBS families rejected for `cluster_size` (need 64–256 nodes, locked to 32). c6a/c7a rejected for `memory` — 1.9 GiB/vCPU can't satisfy heap.
>
> **Q7: Knobs?** Reducing `different_family_regret` to 0.0 surfaces i3en at $33K/yr savings — tradeoff is on-demand pricing during migration.

---

## Notes

- **antigravity-cass**: `https://cass.antigravity.us-east-1.prod.netflix.net:7004`  `-a antigravity.cass`
- **antigravity-capacity**: `https://capacity.antigravity.vip.us-east-1.prod.cloud.netflix.net:7004`  `-a antigravity.capacity`
- **No local library** — all calls are remote; parse with stdlib Python only
- **Scale types** set reasonable defaults for comparison strategy + tolerances:
  - `right_size` — provisioned comparison, ±10% tolerance (is the recommendation roughly equivalent?)
  - `live_scale` — provisioned comparison, ≤1.1× tolerance, preserves storage type (only flags scale-up needs)
  - `buffer_check` — requirements comparison, ≤1.1× tolerance (does the buffered cluster meet demand?)
- **Scale buffers** — derive via `POST /scale/compute-scale-buffers` (old + new desire → weighted ratios). Pass the result in the `buffers` field of the `plan-input` body. `intent: scale` = ensure at least N× headroom on top of normal provisioning.
- **`override_required_cluster_size`** — query param on `plan-input`: pass `-1` to unlock horizontal scaling, or a specific int to force a topology.
- **`family` field** is not in the remote JSON — derive as `instance_name.rsplit(".", 1)[0]`
- **Cost categories**: `cassandra.zonal-clusters`, `cassandra.net.inter.region`, `cassandra.net.intra.region`, `cassandra.backup.s3-standard`
- **ExcuseTags**: `current_shape`, `same_family`, `size_up`, `size_down`, `different_family`
- **Bottlenecks**: `cpu`, `memory`, `disk_capacity`, `disk_iops`, `drive_type`, `cluster_size`, `cost`, `generation`
- **Configurable knobs** (pass via `extra_model_args` in the body):
  - `copies_per_region` — override RF
  - `require_attached_disks: true` — force EBS families
  - `min_storage_buffer_ratio` / `max_storage_buffer_ratio` — adaptive buffer bounds (default 2.0–4.0)
  - `min_compute_buffer_ratio` / `max_compute_buffer_ratio` — adaptive compute buffer (default 1.3–1.5)
  - `different_family_regret` — family migration penalty (default 0.10)
  - `large_instance_regret` — penalty for >8xlarge (default 0.20)
