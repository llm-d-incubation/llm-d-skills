# KV-cache OOM at sampler warmup

## Signature

A sleep-mode launcher child boots, loads weights, captures CUDA graphs, then dies
at the final sampler warmup with a CUDA out-of-memory error, e.g.:

```
torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 594.00 MiB.
  GPU 0 has a total capacity of 79.18 GiB of which 538.31 MiB is free ...
```

followed by `EngineCore failed to start` and `Engine core initialization failed`.
The vLLM server (`:8000`) never binds, so the controller polls `/is_sleeping` and
gets connection-refused forever, the requester never reaches Ready, and the run
times out with 0 iterations.

## Why it happens

With `--gpu-memory-utilization 0.95` and sleep mode enabled, the cumem allocator
plus CUDA-graph private pools balloon the process to nearly the full GPU. The
final sampler-warmup softmax then has no headroom. Capping the KV cache leaves
room for warmup.

## The fix: `fma.launcher.kvCacheMemory`

The FMA launcher options string renders `--kv-cache-memory <bytes>` when
`fma.launcher.kvCacheMemory` is set. Pass it (in bytes) on BOTH standup and run:

```
--set fma.launcher.kvCacheMemory=<bytes>
```

### How to find the right value

Let the first boot fail, then read vLLM's own suggestion from the launcher child
log (from `gpu_worker.py`):

```
Replace ... with --kv-cache-memory=<bytes> to fit into requested memory
```

Use the "fit" value. If the launcher still OOMs (uneven per-GPU free memory under
tensor parallelism can leave one worker short), drop the value further and re-try.

### Two kinds of value: scenario-default vs per-model "fit" max

There are two valid ways to pick `kvCacheMemory`, and they differ by ~6x — do not
confuse them:

- **Conservative scenario default: `11259300148` (~10.49 GiB) at `maxModelLen=16000`.**
  This is what the `ocp-keda-fma-*` sibling scenarios ship. It is a small, safe cap
  that leaves ample warmup headroom and clears the OOM for 4B/8B-class models on a
  single 80GB GPU. **Use this as the starting point** (it is what Step 1 of the
  skill recommends), especially for a first run.
- **Per-model "fit" maximum (the table below): larger values at `maxModelLen=32768`.**
  These push the KV cache close to the "fit" value vLLM itself suggests, maximizing
  cache at the cost of less headroom. Use only if you need the larger context /
  cache and are willing to tune.

### Per-model "fit" values observed (single 80GB H100, maxModelLen 32768)

| Model | kvCacheMemory (bytes) | Notes |
|-------|-----------------------|-------|
| Qwen3-4B | 70519557428 | "fit" max at maxModelLen 32768; also worked at 60129542144. (The conservative `11259300148` @ 16000 above is the safer default.) |
| Qwen3-8B | 60129542144 | |
| Qwen3-14B | 46170898432 | |
| Qwen3-32B (TP=2) | 42000000000 | See `big-models.md`; TP changes per-GPU accounting. The higher "fit" value vLLM suggested OOM'd on uneven per-GPU free; 42000000000 cleared it. |

These are starting points, not guarantees — GPU model, free memory, and
`maxModelLen` all move the number. Always confirm against the child log for your
hardware.

## Related knob

The KV-cache cap in the launcher options string is the mechanism the FMA launcher
shipped for this; on current checkouts it is a first-class `--set`. See the
llm-d-benchmark PR that added the config-driven launcher memory knobs:
<https://github.com/llm-d/llm-d-benchmark/pull/1791>.
