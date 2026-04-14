---
name: atlas-analysis
description: Build before/after Atlas metrics analyses with Plotly notebooks and gists. Covers phase design, skew checks, attribution discipline, query patterns, and snapshot strategy. Use when analyzing impact of a change on Cassandra or DGW KV clusters.
---

# Atlas Metrics Analysis

Build rigorous before/after metrics analyses using Atlas timeseries data, Plotly charts, and Jupyter notebooks published as GitHub gists.

## When to Use

- Analyzing impact of a change (rollout, migration, config change) on a Cassandra or DGW KV cluster
- Building a performance report with charts and phase comparisons
- Any Atlas-based before/after analysis that needs to be shared

## Methodology

Read the full methodology FIRST before writing any code:

```bash
cat ~/repos/dump/second-brain/topics/atlas-metrics-analysis-methodology/README.md
```

This covers:
- Attribution discipline (clean vs confounded signals)
- Baseline selection (stable periods only, no ramp-ups)
- Per-shard skew checks (CoV analysis)
- Layer separation (KV vs Cassandra coordination vs storage)
- Decomposition (ops/sec vs size/op vs total)
- Query reference (system, Cassandra, DGW KV queries with all tags)
- Common mistakes to avoid

## Template Scripts

```bash
# Mosaic analysis (KV-layer impact + Cassandra infra)
cat ~/repos/antigravity-core/scripts/pagestore_mosaic_analysis.py

# Shard skew analysis (per-shard breakdown, CoV convergence)
cat ~/repos/antigravity-core/scripts/pagestore_shard_skew.py

# Original schema normalization analysis (older, monolithic cluster)
cat ~/repos/antigravity-core/scripts/dgw_notebook.py
```

## Quick Start

1. **Read the methodology** (above)
2. **Define phases** with absolute date anchors. Always include a ramp-up phase if the system was recently changed.
3. **Snapshot data immediately** — Atlas retains ~15 days. Write to a durable location, not /tmp.
4. **Fetch at step=1h** for windows > 3 days. step=60s for short windows only.
5. **Check per-shard skew** before making any aggregate claims.
6. **Separate clean from confounded** signals in the TL;DR.
7. **Publish as gist** with Atlas queries in code blocks for breadcrumbs.

## Atlas Client Usage

```python
from antigravity_core.ag_metrics import AtlasClient, AtlasBucketResult, parse_atlas_time

async with AtlasClient(app_id="your-analysis-name") as client:
    results = await client.timeseries_bucketed(
        query, env="prod",
        start="2026-04-01T00:00:00Z", end="2026-04-14T00:00:00Z",
        step="1h", bucket="1d"
    )
```

## Chart Rendering

- kaleido 0.2.1 (1.x broken). Async fetch then sync render.
- `fig.to_image(format="png", width=1300, scale=1.5)` → base64 → notebook cell
- Template: `plotly_white`, phase shading, orange rollout band

## Notebook → Gist

```python
# Create
result = subprocess.run(
    ["gh", "api", "/gists", "--method", "POST", "--input", payload_path],
    env={**os.environ, "GH_HOST": "git.netflix.net"})

# Update
result = subprocess.run(
    ["gh", "api", f"/gists/{GIST_ID}", "--method", "PATCH", "--input", payload_path],
    env={**os.environ, "GH_HOST": "git.netflix.net"})
```
