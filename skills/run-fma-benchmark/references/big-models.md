# Big models: tensor parallelism, /dev/shm, local load, KV cap

A model that does not fit on one GPU (roughly >= 32B on an 80GB card) needs
several knobs together. All shipped as first-class `fma.launcher.*` /
`fma.requester.*` settings and default to single-GPU-safe values, so a smaller
model renders exactly as before when you omit them.

## Tensor parallelism + shared memory

```
--set fma.launcher.tensorParallelSize=2 \
--set fma.requester.limitsGPU=2
```

`fma.launcher.tensorParallelSize` (default 1) feeds `--tensor-parallel-size`.
When it is > 1, the launcher template also provisions a 16Gi in-memory
`/dev/shm` (an `emptyDir` with `medium: Memory`) on the launcher pod, because
tensor-parallel workers exchange over a shared-memory message queue and the pod
default 64Mi crashes NCCL at init. `fma.requester.limitsGPU` must match the TP
size so the requester reserves the right number of GPUs.

This is the mechanism from
<https://github.com/llm-d/llm-d-benchmark/pull/1857> (closed
<https://github.com/llm-d/llm-d-benchmark/issues/1853>), which added
`fma.launcher.tensorParallelSize` and the gated `/dev/shm` volume.

## Load from a staged local copy

```
--set fma.launcher.loadModelFromLocalDir=true
```

The download job stages a complete copy of the model at
`<modelMountPath>/<model.path>` on the same PVC the launcher mounts.
`fma.launcher.loadModelFromLocalDir` (default false) points the launcher at that
staged copy instead of re-resolving the repo ID through the HF hub cache — a
second, network-dependent path that can be partial or hit a full PVC. Keep
`model.name` as the repo ID regardless (it feeds the derived Helm release name; a
path there produces an invalid leading-dash release name). This is the mechanism
from <https://github.com/llm-d/llm-d-benchmark/pull/1844> (closed
<https://github.com/llm-d/llm-d-benchmark/issues/1822>).

## Enforce-eager (optional)

```
--set fma.launcher.enforceEager=true
```

`fma.launcher.enforceEager` (default false) appends `--enforce-eager`, skipping
torch.compile and CUDA-graph capture. Faster cold boot, slower steady-state
serving. Use only if cold-boot time is the constraint; it does not change the
`t_wake` hot-path metric.

## KV-cache cap

Big models still need `fma.launcher.kvCacheMemory` to leave warmup headroom — see
`kv-cache-oom.md`. Under TP the per-GPU accounting changes, so a single-GPU cap
does not transfer.

## Worked recipe: Qwen3-32B (dense) on two 80GB H100s

```
--set model.name=Qwen/Qwen3-32B \
--set model.shortName=qwen-qwen3-32b \
--set model.path=models/Qwen/Qwen3-32B \
--set model.huggingfaceId=Qwen/Qwen3-32B \
--set fma.launcher.tensorParallelSize=2 \
--set fma.requester.limitsGPU=2 \
--set fma.launcher.loadModelFromLocalDir=true \
--set fma.launcher.kvCacheMemory=42000000000
```

All model + fma `--set` flags go on BOTH standup and run. Observed with Qwen3-32B:
hot `t_wake` ~0.88-0.92s, warm ~106-111s, cold-with-launcher ~130-166s. The
`42000000000` KV cap cleared an OOM that a higher "fit" value hit on uneven
per-GPU free memory — read your own child log's suggested value and adjust down
if needed.
