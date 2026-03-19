---
name: capacity-explain
description: Explain a Cassandra capacity recommendation from antigravity desires JSON. Takes the desires payload (from antigravity or the capacity modeling API) and produces a plain-English explanation of what the planner recommends, why, and what was rejected. Use when someone asks "why is the planner recommending X" or "explain the capacity plan for <app>".
---

# Capacity Explain

Given a Cassandra desires payload, explain the capacity recommendation in plain English.

## Step 1: Get the desires JSON

If the user hasn't provided it, ask for the desires JSON (from antigravity's `/explain` endpoint or the capacity modeling API). It should have `desires`, `extra_model_arguments`, and optionally `context` (app name, region, Atlas links).

## Step 2: Run the library

Write this script to `/tmp/explain_cass.py` and run it from `~/repos/service-capacity-modeling` using the py312 tox env:

```python
import json
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
    num_results=3,
)

baseline = planner.extract_baseline_plan(
    "org.netflix.cassandra", region, desires,
    extra_model_arguments=extra,
) if desires.current_clusters else None

comparison = compare_plans(baseline, explained.plans[0]) if baseline and explained.plans else None

top = explained.plans[0]
z = top.candidate_clusters.zonal[0]

print(f"=== TOP RECOMMENDATION ===")
print(f"Instance: {z.count}x {z.instance.name}")
print(f"Annual cost: ${top.candidate_clusters.total_annual_cost:,.0f}")
print(f"Rank: {top.rank:.0f}")
params = {k: v for k, v in z.cluster_params.items()
          if k not in ("cassandra.heap.write.percent", "cassandra.heap.read.percent", "cassandra.keyspace.rf")}
print(f"Params: {json.dumps(params, indent=2)}")

if baseline:
    bz = baseline.candidate_clusters.zonal[0]
    print(f"\n=== CURRENT (BASELINE) ===")
    print(f"Instance: {bz.count}x {bz.instance.name}")
    print(f"Annual cost: ${baseline.candidate_clusters.total_annual_cost:,.0f}")
    if comparison:
        delta = top.candidate_clusters.total_annual_cost - baseline.candidate_clusters.total_annual_cost
        print(f"Annual delta: ${delta:+,.0f} ({'savings' if delta < 0 else 'increase'})")

print(f"\n=== ALL TOP PLANS ===")
for i, p in enumerate(explained.plans):
    z2 = p.candidate_clusters.zonal[0]
    penalties = z2.cluster_params.get("rank_penalties", {})
    penalty_str = f"  penalties={list(penalties.keys())}" if penalties else ""
    print(f"  {i+1}. {z2.count}x {z2.instance.name:20s}  rank={p.rank:8.0f}  cost=${p.candidate_clusters.total_annual_cost:>12,.0f}{penalty_str}")

print(f"\n=== FAMILY GRAPH TRAITS ===")
for fam, trait in sorted(explained.family_graph.traits.items()):
    disk = f"{trait.local_disk_gib_per_vcpu:.0f} GiB/vCPU local" if trait.local_disk_gib_per_vcpu else "EBS only"
    print(f"  {fam:8s}  {trait.memory_gib_per_vcpu:.1f} GiB/vCPU mem  {disk}")

print(f"\n=== TOP EXCUSES (by bottleneck) ===")
by_bottleneck: dict = {}
for e in explained.excuses:
    key = str(e.bottleneck or "none")
    by_bottleneck.setdefault(key, []).append(e)
for bottleneck, excuses in sorted(by_bottleneck.items()):
    print(f"  [{bottleneck}] {len(excuses)} rejections — e.g. {excuses[0].instance}: {excuses[0].reason[:60]}")
```

Write the payload to `/tmp/cass_desires.json`, then run:

```bash
cd ~/repos/service-capacity-modeling
.tox/py312/bin/python3 /tmp/explain_cass.py
```

## Step 3: Narrate the output

Using the script output, produce a plain-English explanation. Rules:

**Always include:**
- Lead with cost delta (savings or increase) if there's a current cluster
- State the recommendation: `Nx instance.name` at `$X/yr`
- Explain the key driver from cluster params: `storage_buffer_ratio` high → disk-bound; `compute_buffer_ratio` low → CPU idle

**Translate params to plain English:**
- `effective_disk_per_node_gib` high relative to instance disk → cluster is disk-constrained
- `storage_buffer_ratio` → how much headroom the planner is providing on storage
- `rank_penalties: {family_migration: ...}` → planner is biased toward staying on current family

**For excuse patterns:**
- Many `cluster_size` rejections → `required_cluster_size` is locking the topology
- Many `memory` rejections → small instances can't meet heap/RAM requirements
- Many `disk_capacity` rejections → workload needs dense storage

**Use family_traits for context (don't show raw numbers):**
- Compare `local_disk_gib_per_vcpu` between current and alternatives
- e.g. "i4i provides 218 GiB disk/vCPU vs i3en's 582 GiB/vCPU"

**Length:** 4-6 sentences. No bullet points in the final narrative.

## Example output

> cass_dgw_kv_pageservice_pagestore can save **$871K/yr** by switching from 64x m6id.12xlarge to 64x i4i.4xlarge — same node count, locked topology.
>
> The cluster is disk-constrained: the planner needs ~3,350 GiB of usable disk per node and i4i.4xlarge (3,492 GiB) is the smallest i4i size that fits at 64 nodes. i4i provides 218 GiB disk/vCPU vs m6id's 55 GiB, giving 4x more storage density without changing the node count.
>
> CPU is heavily over-provisioned (8% utilization). Smaller m6id sizes (4xlarge, 8xlarge) are rejected because they'd require 128–256 nodes, but `required_cluster_size=64` locks the topology.
