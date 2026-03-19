---
name: capacity-explain
description: Explain a Cassandra capacity recommendation from antigravity desires JSON. Takes the desires payload (from antigravity or the capacity modeling API) and produces a plain-English explanation of what the planner recommends, why, and what was rejected. Use when someone asks "why is the planner recommending X" or "explain the capacity plan for <app>".
---

# Capacity Explain

Given a Cassandra desires payload, explain the capacity recommendation in plain English.

## Step 1: Get the desires JSON

If the user hasn't provided it, ask for the desires JSON (from antigravity's `/explain` endpoint or the capacity modeling API). It should have `desires`, `extra_model_arguments`, and optionally `context` (app name, region, Atlas links).

## Step 2: Run the library

Write this script to `/tmp/explain_cass.py`, write the payload to `/tmp/cass_desires.json`, then run from `~/repos/service-capacity-modeling`:

```python
import json
from collections import defaultdict
from service_capacity_modeling.capacity_planner import planner
from service_capacity_modeling.models.plan_comparison import compare_plans
from service_capacity_modeling.interface import CapacityDesires

payload = json.loads(open("/tmp/cass_desires.json").read())
desires = CapacityDesires.model_validate(payload["desires"])
extra = payload.get("extra_model_arguments", {})
region = (payload.get("regions") or [None])[0] or payload.get("context", {}).get("region", "us-east-1")
app_name = payload.get("context", {}).get("app_name", "unknown")

explained = planner.plan_certain_explained(
    "org.netflix.cassandra", region, desires,
    extra_model_arguments=extra,
    num_results=10,
)

baseline = planner.extract_baseline_plan(
    "org.netflix.cassandra", region, desires,
    extra_model_arguments=extra,
) if desires.current_clusters else None

compare_plans(baseline, explained.plans[0]) if baseline and explained.plans else None

top = explained.plans[0]
z = top.candidate_clusters.zonal[0]

print(f"app={app_name}  region={region}\n")

# CURRENT CLUSTER
if baseline:
    bz = baseline.candidate_clusters.zonal[0]
    delta = top.candidate_clusters.total_annual_cost - baseline.candidate_clusters.total_annual_cost
    print(f"=== CURRENT CLUSTER ===")
    print(f"  {bz.count}x {bz.instance.name}  cost=${baseline.candidate_clusters.total_annual_cost:,.0f}/yr")
    if desires.current_clusters and desires.current_clusters.zonal:
        cur = desires.current_clusters.zonal[0]
        if cur.cpu_utilization:
            print(f"  CPU util: {cur.cpu_utilization.low:.1f}–{cur.cpu_utilization.high:.1f}%  (mid {cur.cpu_utilization.mid:.1f}%)")
        if cur.disk_utilization_gib:
            node_disk = bz.instance.drive.size_gib if bz.instance.drive else None
            cap = f" of {node_disk:.0f} GiB/node capacity" if node_disk else ""
            print(f"  Disk util: {cur.disk_utilization_gib.mid:.0f} GiB/node used{cap}")
        if cur.network_utilization_mbps:
            print(f"  Net util:  {cur.network_utilization_mbps.mid:.0f} Mbps/node (mid)")
    print(f"  vs recommendation: ${delta:+,.0f}/yr ({'savings' if delta < 0 else 'increase'})\n")

# TOP RECOMMENDATION
print(f"=== TOP RECOMMENDATION ===")
print(f"  {z.count}x {z.instance.name}  cost=${top.candidate_clusters.total_annual_cost:,.0f}/yr  rank={top.rank:.0f}")
key_params = ("effective_disk_per_node_gib", "cassandra.storage_buffer_ratio",
              "cassandra.compute_buffer_ratio", "cassandra.heap.gib", "rank_penalties")
for k in key_params:
    if k in z.cluster_params:
        print(f"  {k}: {z.cluster_params[k]}")
print()

# PREFERRED FAMILY ANALYSIS — for each preferred family: ranked or rejected + why
plan_by_family: dict = {}
for p in explained.plans:
    fam = p.candidate_clusters.zonal[0].instance.family
    if fam not in plan_by_family:
        plan_by_family[fam] = p

family_excuses: dict = defaultdict(list)
for e in explained.excuses:
    family_excuses[e.instance.rsplit(".", 1)[0]].append(e)

print(f"=== PREFERRED FAMILY ALTERNATIVES ===")
cur_family = bz.instance.family if baseline else None

for fam, trait in sorted(explained.family_graph.traits.items()):
    disk = f"{trait.local_disk_gib_per_vcpu:.0f} GiB/vCPU local" if trait.local_disk_gib_per_vcpu else "EBS"
    cost = f"${trait.cost_per_vcpu_annual:.0f}/vCPU/yr" if trait.cost_per_vcpu_annual else ""
    hw = f"{trait.memory_gib_per_vcpu:.1f} GiB/vCPU  {disk}  {cost}"

    if fam in plan_by_family:
        p = plan_by_family[fam]
        z2 = p.candidate_clusters.zonal[0]
        rank_pos = list(plan_by_family.keys()).index(fam) + 1
        penalties = z2.cluster_params.get("rank_penalties", {})
        pen = f"  penalties={dict(penalties)}" if penalties else ""
        marker = " ← CURRENT" if fam == cur_family else ""
        print(f"  {fam:8s} ✓ rank #{rank_pos:2d}  {z2.count}x {z2.instance.name:20s}"
              f"  ${p.candidate_clusters.total_annual_cost:>10,.0f}/yr{pen}{marker}")
        print(f"           hw: {hw}")
    else:
        fam_exc = family_excuses.get(fam, [])
        if fam_exc:
            bn_counts: dict = defaultdict(int)
            for fe in fam_exc:
                bn_counts[str(fe.bottleneck or "none")] += 1
            top_bn = max(bn_counts, key=bn_counts.get)
            sample = next(fe for fe in fam_exc if str(fe.bottleneck or "none") == top_bn)
            best = min(fam_exc, key=lambda e: e.instance)
            print(f"  {fam:8s} ✗ rejected [{top_bn}] ({bn_counts[top_bn]} shapes)")
            print(f"           e.g. {best.instance}: {sample.reason[:65]}")
            print(f"           hw: {hw}")
        else:
            print(f"  {fam:8s} — not evaluated  hw: {hw}")
print()

# TOPOLOGY LOCK
req = extra.get("required_cluster_size")
if req:
    locked = [e for e in explained.excuses if "required" in e.reason.lower() or "!=" in e.reason]
    locked_fams = set(e.instance.rsplit(".", 1)[0] for e in locked)
    print(f"=== TOPOLOGY LOCK ===")
    print(f"  required_cluster_size={req} — only {req}-node topologies accepted per zone")
    print(f"  {len(locked)} rejections across {len(locked_fams)} families due to wrong node count")
    print()

# REJECTION SUMMARY
by_bn: dict = defaultdict(int)
for e in explained.excuses:
    by_bn[str(e.bottleneck or "none")] += 1
print(f"=== REJECTION SUMMARY (all {len(explained.excuses)} excuses) ===")
for bn, count in sorted(by_bn.items(), key=lambda x: -x[1]):
    print(f"  [{bn}] {count}")
```

```bash
cd ~/repos/service-capacity-modeling
.tox/py312/bin/python3 /tmp/explain_cass.py
```

## Step 3: Narrate the output

Produce 4-6 sentences, plain English, no bullet points. Cover in order:

**1. Lead: cost and recommendation**
- With current cluster: "X is correctly placed / can save $Y by switching from Ax inst1 to Bx inst2"
- New provisioning: "The planner recommends Nx instance at $X/yr"

**2. What's driving the recommendation (cluster params)**
- `effective_disk_per_node_gib` ≈ instance disk → disk-bound, fitting snugly
- `storage_buffer_ratio` > 3 → significant storage headroom being maintained
- `compute_buffer_ratio` < 1.5 → CPU headroom is the constraint, not storage

**3. Walk the preferred family alternatives table**
This is the core of the explanation. For each ✓ ranked alternative, explain why it ranks below #1 (cost? penalty?). For each ✗ rejected family, explain why in plain English:
- `[cluster_size] rejected` → "r6id needs 256 nodes at 3.8 GiB/vCPU, but `required_cluster_size=32` locks the topology"
- `[memory] rejected` → "c6a/c7a nodes have only 1.9 GiB/vCPU — too small for C*'s heap requirements"
- `[disk_capacity] rejected` → "r5d provides only 34 GiB disk/vCPU; the workload needs ~X GiB/node"

**4. Explain rank penalties on the runner-up**
- `family_migration=0.10` → "the planner applies a 10% penalty to i3en because the current cluster runs on i4i — switching families requires overcoming that bias"
- Runner-up cheaper but penalized: "i3en is $33K/yr cheaper but ranks #2 because the family_migration penalty makes it appear $68K more expensive to the ranker"

**5. Use hardware traits for density comparisons**
- Don't say "i3en has more disk" — say "i3en provides 582 GiB disk/vCPU vs i4i's 218 GiB/vCPU"
- Mention cost/vCPU when explaining why a more dense family still loses: "i3en is $375/vCPU/yr vs i4i's $303/vCPU/yr"

## Example output

> **cass_dgw_kv_event_bucketer_main** is correctly placed on 32x i4i.4xlarge at $710K/yr — the planner finds no better option under the current topology lock.
>
> The cluster needs ~3,350 GiB of usable disk per node (with a 2.6x buffer on 851 GiB/node of actual usage), and i4i.4xlarge's 3,492 GiB NVMe is a near-perfect fit. i3en.3xlarge would provide far more density (582 GiB disk/vCPU vs i4i's 218 GiB/vCPU) and is $33K/yr cheaper, but it carries a 10% family_migration penalty since the current cluster runs on i4i — making it appear $68K more expensive to the ranker and pushing it to rank #2.
>
> All EBS families (r6a, m6a, m7a, r6id, m6id) are rejected outright: at their memory density they need 64–256 nodes per zone, but `required_cluster_size=32` allows only 32. Compute-optimized families (c6a, c7a) are also eliminated — at 1.9 GiB/vCPU they can't satisfy C*'s minimum heap requirements. The 88 cluster_size and 57 memory rejections account for nearly all 145 total excuses.
