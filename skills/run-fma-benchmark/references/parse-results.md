# Parsing result.yaml

## Where it lives

```
<WS>/<workspace-id>/results/nop-*/result.yaml
```

`<workspace-id>` is a timestamped subdir created per invocation (e.g.
`gloire-20260818-114632-003`), not a flat path under `$WS`. A summarized report
may also appear at `.../benchmark_report/result.yaml`. Confirm the file exists
before trusting a "Run complete" message:

```
find $WS -name result.yaml
```

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

## Notes

- Filter to `timing_source == dpc` when aggregating; drop any
  `kube_container_start` / `kube_pod_create` fallback iterations from the
  headline numbers (they use a different, looser anchor).
- The two anchors are both collectible offline — the harness copies the whole
  results dir, which includes the per-pod `FMARequesterInfo` dump (pod-create and
  container-start timestamps), the raw controller log, and the launcher/vLLM pod
  logs (the `Compile` vs `Load from Cache` line, which records the compile-cache
  state of each sample).
