# Parsing result.yaml

## Where it lives

**On FMA v0.7.0+ (current nightly), a successful run compresses its results** into
a per-run archive — there is NO loose `result.yaml` on disk:

```
<WS>/<workspace-id>/results/nop-*_1/workspace.tar.zst   # result.yaml is INSIDE this
```

`<workspace-id>` is a timestamped subdir created per invocation (e.g.
`gloire-20260818-114632-003`), not a flat path under `$WS`. Extract first:

```
tar --use-compress-program=unzstd -xf \
  <WS>/<workspace-id>/results/nop-*_1/workspace.tar.zst -C /tmp/fma-result
# then parse /tmp/fma-result/result.yaml  (a benchmark_report/result.yaml copy is also inside)
```

**`find $WS -name result.yaml` returns nothing on a clean run — that is expected,
not a failure.** Loose, uncompressed result files (including a bare `result.yaml`)
appear ONLY when the run FAILED ("collecting results uncompressed so nothing still
being written is deleted"). So: `workspace.tar.zst` present = success; loose files
present = the run errored. On older checkouts (≤ v0.6.x) the loose
`<WS>/<workspace-id>/results/nop-*/result.yaml` path applied to all runs.

## Parse path

Use the venv Python — the system Python may not have `yaml` installed. Per
iteration, the actuation data is under
`extra_metrics[0].iterations[*].launcher_infos[0]`:

- `actuation_condition` — the hot / warm / cold classification
- `timing_source` — want `dpc` (the tightest, controller-derived anchor)
- one of `t_wake` (hot), `t_instance_create` (warm), `t_cold_launcher` (cold)

Also confirm `scenario.model.name` matches the model you intended — a silent 4B
fallback (see `model-swap.md`) shows up here.

## Snippet

```python
import yaml
from collections import Counter

with open("result.yaml") as fh:
    d = yaml.safe_load(fh)

print("model:", d["scenario"]["model"]["name"])

iters = d["extra_metrics"][0]["iterations"]
mix = Counter()
for it in iters:
    li = it["launcher_infos"][0]
    cond = li["actuation_condition"]
    src = li["timing_source"]
    t = li.get("t_wake") or li.get("t_instance_create") or li.get("t_cold_launcher")
    mix[cond] += 1
    print(f"{cond:20s} src={src:6s} t={t}")

print("mix:", dict(mix))
```

## Presenting the results (Step 5b)

End a run with a compact table + synopsis, not raw lines. Aggregate per path
(median + min–max over the `dpc` iterations):

```python
import statistics as st
by = {"T_hot": ("t_wake", []), "T_warm": ("t_instance_create", []),
      "T_cold_launcher": ("t_cold_launcher", [])}
for it in iters:
    li = it["launcher_infos"][0]
    if li.get("timing_source") != "dpc":
        continue
    cond = li["actuation_condition"]
    if cond in by:
        by[cond][1].append(li[by[cond][0]])
for cond,(field,vals) in by.items():
    if vals:
        print(f"{cond:16s} n={len(vals)}  median={st.median(vals):.3f}s  "
              f"min={min(vals):.3f}s  max={max(vals):.3f}s")
```

**Table template** (one row per path that occurred):

| Path | Metric | n | Median | Min–Max | Meaning |
|------|--------|---|--------|---------|---------|
| Hot | `t_wake` | … | …s | …–…s | wake a sleeping instance (weights DRAM→GPU) |
| Warm | `t_instance_create` | … | …s | …–…s | launcher forks a new instance (warm modules) |
| Cold | `t_cold_launcher` | … | …s | …–…s | create a launcher first, then fork the instance |

Follow with a synopsis: `model`, total iterations, the hot/warm/cold split, and
a sentence noting all iterations used `timing_source=dpc` (or flagging any Kube
fallback). Define the paths in plain English for a first-time reader.

**Worked example** (Qwen3-4B, FMA v0.7.0, single 80GB GPU, verified 2026-10-21):

> **Qwen3-4B — 10 iterations** (all `timing_source=dpc`). Mix: 6 hot, 4 warm, 0 cold.
>
> | Path | Metric | n | Median | Min–Max |
> |------|--------|---|--------|---------|
> | Hot  | `t_wake` | 6 | 0.256s | 0.253–0.261s |
> | Warm | `t_instance_create` | 4 | 51.8s | 50.3–61.4s |
>
> *Hot* = a sleeping instance was woken (sub-second); *warm* = the launcher forked
> a fresh instance from preloaded modules (~tens of seconds); no *cold* path
> occurred (a launcher was always available). (Qwen3-8B on the same setup: 10 iters,
> 4 hot / 6 warm, hot ≈ 0.44s, warm ≈ 57–77s — larger model, proportionally longer.)

## Notes

- Filter to `timing_source == dpc` when aggregating; drop any
  `kube_container_start` / `kube_pod_create` fallback iterations from the
  headline numbers (they use a different, looser anchor).
- The two anchors are both collectible offline — the harness copies the whole
  results dir, which includes the per-pod `FMARequesterInfo` dump (pod-create and
  container-start timestamps), the raw controller log, and the launcher/vLLM pod
  logs (the `Compile` vs `Load from Cache` line, which records the compile-cache
  state of each sample).
