---
name: kv-offload-load-designer
description: >
  Designs a benchmark load configuration (concurrency, stages, num_requests) that will trigger
  GPU KV cache offloading on an llm-d deployment with OffloadingConnector. Use this skill whenever
  the user wants to stress-test KV cache offloading, design a workload that causes CPU KV offload
  to activate, figure out the right concurrency to saturate the KV pool, or verify that cpu-offload
  is actually doing work under load — even if they don't use the words "kv cache" or "offloading"
  explicitly. Triggers on phrases like "what concurrency should I use to stress the KV cache",
  "design a load that exercises offloading", "how many concurrent sessions to fill the GPU memory",
  "make the cpu kv cache kick in", or "create a workload that stresses prefix caching".
---

# KV-Offload Load Designer

## What this skill does

GPU KV cache offloading (OffloadingConnector) only activates when the GPU KV pool is under
pressure — i.e., when active requests collectively need more KV memory than the GPU has.
This skill computes the exact concurrency, turn count, and stage structure needed to reliably
push past that threshold, so experiments actually exercise the offloading path rather than
running below the pressure point.

## Step 1 — Collect hardware inputs

Ask for (or extract from context):

- **GPU type** (e.g., A100 80GB, H100 80GB) — look up VRAM from `references/model-kv-params.md`
- **num_GPUs_per_pod** — number of GPUs in each decoder pod
- **TP** (tensor-parallel degree) — must equal num_GPUs_per_pod for single-node TP
- **num_decoder_pods** — how many decoder replicas are in the stack

If TP > 1, the model is sharded: each GPU holds `num_kv_heads / TP` KV heads, which reduces
per-GPU KV bytes per token by the same factor. However, the KV pool is **per pod** (all TP
ranks together), so the effective capacity is still computed per pod.

## Step 2 — Collect model inputs

Look up the model in `references/model-kv-params.md`. If not found, ask for:
- `num_layers`
- `num_kv_heads`
- `head_dim`
- `kv_dtype` (fp16, bf16, fp8_e5m2, fp8_e4m3, int8) — default: same as model weights dtype

## Step 3 — Compute GPU KV pool capacity

### 3a. KV bytes per token (per pod, all layers)

```
kv_element_bytes = 1 if fp8/int8, else 2 (fp16/bf16)
kv_bytes_per_token = num_layers × 2 × num_kv_heads × head_dim × kv_element_bytes
```

The factor of 2 is for K and V caches. With TP, each GPU holds `num_kv_heads / TP` heads;
since all TP ranks together form one pod, the per-pod cost is still the full `num_kv_heads`.

### 3b. Free GPU memory (per pod)

```
total_gpu_memory_gib = gpu_vram_gib × num_GPUs_per_pod
weight_memory_gib    = estimate from references/model-kv-params.md (fp16 rule: 2B × params)
                       adjust for actual dtype (fp8 → halve, fp4 → quarter)
overhead_gib         = 5   # CUDA graphs, activations, vLLM buffers
free_for_kv_gib      = total_gpu_memory_gib - weight_memory_gib - overhead_gib
kv_fraction          = 0.90  # vLLM default; adjust if --gpu-memory-utilization was changed
available_kv_gib     = free_for_kv_gib × kv_fraction
```

### 3c. KV pool size in tokens

```
block_size           = 16   # vLLM default (use 128 if prefix caching is enabled)
available_kv_bytes   = available_kv_gib × 1024³
num_blocks           = floor(available_kv_bytes / (block_size × kv_bytes_per_token))
kv_pool_tokens       = num_blocks × block_size
```

State this result clearly: "Each decoder pod can hold ~N tokens of KV across all active
requests before offloading kicks in."

## Step 4 — Collect workload inputs

### For `conversation_replay` workload

Ask for (or extract from the workload config):
- `shared_system_prompt_tokens` — static shared system prompt length (tokens)
- `dynamic_system_prompt_tokens` — mean dynamic system prompt length (tokens); 0 if not used
- `input_tokens_per_turn` — mean input per turn
- `output_tokens_per_turn` — mean output per turn (generated)
- `turns_per_conversation` — mean (or max for worst-case)
- `num_conversations` — total distinct conversation contexts
- `max_model_len` — effective context window; use the vLLM `--max-model-len` flag value if
  set, otherwise default to `native_max_context` from `references/model-kv-params.md`

**Peak context per session** (at the end of a conversation):
```
raw_peak = shared_system_prompt_tokens + dynamic_system_prompt_tokens
           + turns × (input_tokens_per_turn + output_tokens_per_turn)

peak_context_tokens = min(raw_peak, max_model_len)
```

Clamping to `max_model_len` is mandatory: when the dynamic system prompt alone exceeds the
context window (common in long-context agentic workloads), `raw_peak` is far larger than what
any single session can actually hold. Using `raw_peak` unclamped would give
`saturation_per_pod < 1`, producing a target concurrency too low to trigger offloading.

### For `otel_trace_replay` workload

Ask for (or extract from the session summary JSON):
- `median_session_input_tokens` — median total input tokens per session (from summary_session_lifecycle_metrics.json → total_input_tokens.median)
- `p75_session_input_tokens` — p75 of total input tokens per session
- `mean_events_per_session` — mean number of events/turns per session
- `max_tokens_per_session` — max total tokens (if available)

Use **p75** as the representative peak context size (conservative but realistic).

## Step 5 — Compute saturation concurrency

### Per-pod saturation

```
saturation_concurrency_per_pod = kv_pool_tokens / peak_context_tokens
```

This is how many concurrent sessions, all at peak context size, would fill one pod's KV pool
exactly. In practice, not all sessions are at peak simultaneously, so this is a conservative
(lower) estimate.

### Total saturation concurrency (across all pods)

```
saturation_concurrency_total = saturation_concurrency_per_pod × num_decoder_pods
```

With a good EPP scorer (prefix-cache-scorer or cpu-prefix-cache-scorer), requests are
routed to pods that hold their KV prefix. This creates hot-spots: a single pod can see
much more than its `1/N` share of the load. Design for per-pod saturation to ensure offloading
fires even under uneven routing.

### Recommended operating concurrency

```
target_concurrency = max(
    ceil(saturation_concurrency_per_pod × 1.5),   # 50% over saturation for reliable offloading
    10                                              # minimum for meaningful measurement
)
```

The 1.5× factor ensures you're clearly above the threshold, accounting for variability in
session lengths and the fact that not all sessions reach peak context at the same instant.
If the goal is to see *strong* offloading (large CPU hit rate), use 2×–3× instead.

## Step 6 — Design the load stages

### For `conversation_replay`

Use escalating concurrency stages so results show the point where KV pressure starts:

```yaml
load:
  type: concurrent
  num_workers: <ceil(target_concurrency / 4)>
  worker_max_concurrency: <target_concurrency × 2>
  stages:
    - concurrency_level: <target_concurrency ÷ 4>
      num_requests: <target_concurrency × 5>        # ~5 conversations per slot
    - concurrency_level: <target_concurrency ÷ 2>
      num_requests: <target_concurrency × 10>
    - concurrency_level: <target_concurrency>
      num_requests: <target_concurrency × 15>
    - concurrency_level: <target_concurrency × 2>   # push well past saturation
      num_requests: <target_concurrency × 20>
```

**num_conversations** must be at least `5 × max_concurrency` to avoid session-lock deadlock
(see memory: conversation_replay_num_conversations deadlock). Round up to the nearest hundred.

### For `otel_trace_replay`

The dataset has a fixed session count, so you control load via `concurrent_sessions` and
`session_rate`. A single stage at `target_concurrency` is typical; add a lower warm-up stage
if needed:

```yaml
load:
  type: trace_session_replay
  stages:
    - concurrent_sessions: <target_concurrency ÷ 2>   # warm-up
      session_rate: 10.0
    - concurrent_sessions: <target_concurrency>        # target pressure
      session_rate: 10.0
    - concurrent_sessions: <target_concurrency × 2>   # strong offloading
      session_rate: 10.0
  num_workers: 20
  worker_max_concurrency: 1000
  base_seed: 42
```

If the dataset has fewer sessions than `concurrent_sessions × 5`, reduce stages or use
a single-stage config — the session pool will be exhausted before the warm-up is useful.

## Step 7 — Produce the output

Write a clear, self-contained summary with:

1. **KV pool math** — show the computation so the user can verify or adjust inputs
2. **Saturation point** — the concurrency threshold where offloading starts
3. **Recommended concurrency** — with rationale (1.5× for mild, 2–3× for strong offloading)
4. **Complete `load:` YAML** — ready to paste into the benchmark config
5. **Metrics to watch** — tell the user how to confirm offloading is active:
   - `schedule_delay` rising sharply as concurrency increases → KV queue building
   - **Note on cache usage metrics:** `vllm:gpu_cache_usage_perc` and `vllm:cpu_cache_usage_perc`
     measure *current occupancy* (blocks in use at this instant), NOT offload activity or hit rate.
     Neither metric reliably indicates when offloading is triggered — offloading fires when the GPU
     pool needs to free blocks for incoming requests, which can happen at any usage level.
     `cpu_cache_usage_perc = 0` on an external KV cache (OffloadingConnector) does mean no blocks
     are currently offloaded. To confirm offloading is doing useful work, prefer:
     - Per-request prefix cache hit rate metrics (if exposed by the connector)
     - TTFT and `schedule_delay` trends across concurrency stages — rising delay at the predicted
       saturation concurrency confirms KV pressure is real
     - Throughput improvement vs the no-offload baseline at the same concurrency

## Step 8 — Save the workload config

Ask the user where to save the complete workload config file (or use the path they already provided). Then write the full YAML — including `dataset:` and `load:` sections — to that path. The file should include a header comment block documenting:

- Source workload (URL or name)
- Hardware target (GPU type, num pods, TP)
- Key findings from the KV analysis (pool size, saturation threshold)
- Any changes made from the original config (especially `num_conversations` adjustments)

Do not skip this step even if the user hasn't explicitly asked to save — ask for the path if they haven't provided one.

## Output format

```
## KV Cache Pressure Analysis

### Hardware
- Pod config: <N>× <GPU> (<VRAM> GiB each) = <total> GiB per pod, TP=<K>
- Estimated weight memory: ~<W> GiB (<dtype>)
- Available for KV cache: ~<A> GiB (after weights + overhead, ×0.90 fraction)

### Model KV geometry
- KV bytes/token: <num_layers> layers × 2 × <num_kv_heads> heads × <head_dim> dims × <B> bytes = <X> bytes/token
- KV pool capacity: ~<N> tokens per pod (~<N/1024> k tokens)

### Workload
- Peak context per session: ~<P> tokens (<formula>)
- Saturation concurrency per pod: ~<P> sessions
- Saturation across <N> pods: ~<total> sessions

### Recommendation
- Target concurrency: <T> (1.5× saturation per pod)
- For strong offloading: <T2> (2–3× saturation)

### Load configuration (ready to use)
<YAML block>

### How to confirm offloading is working
- `vllm:gpu_cache_usage_perc` and `vllm:cpu_cache_usage_perc` are occupancy metrics (blocks in
  use now), not offload activity or hit-rate indicators — do not use them to infer whether
  offloading is firing; offloading can trigger at any GPU usage level
- `cpu_cache_usage_perc = 0` on an OffloadingConnector deployment does mean no blocks are
  currently offloaded
- `schedule_delay` and TTFT rising across concurrency stages: confirms KV pressure is real
- Throughput vs no-offload baseline at same concurrency: the clearest signal that offloading helps
- Per-request prefix cache hit rate (if exposed by the connector): direct measure of reuse

### Saved to
<file path written>
```

## Notes from prior experiments

- Even **without** cpu-prefix-cache-scorer in the EPP, OffloadingConnector still activates
  when the GPU KV pool fills — the offloading is vLLM-internal. The EPP scorer only affects
  how well requests are *routed* to pods that hold their CPU-cached prefix. Missing the scorer
  means offloading still helps (less eviction) but prefix reuse is sub-optimal.
- For `trace_session_replay`, the benchmark ends when all sessions finish. A very high
  concurrency means sessions complete faster but many events get cancelled mid-flight (the
  benchmark window closes). This manifests as high `events_cancelled` in session metrics —
  not a failure, just a trade-off between throughput measurement and session completion rate.
- Harness memory: loading a large HuggingFace dataset (e.g., `Exgentic/agent-llm-traces`
  unfiltered) needs `HARNESS_CPU_MEM=128Gi`; the default 64Gi OOMKills before writing results.
- The `--max-num-seqs=512` flag on OffloadingConnector pods limits the scheduler warmup to
  avoid OOM from the GPU staging buffer. This also caps the effective concurrency per pod at 512.
  If target_concurrency per pod exceeds 512, note that requests will queue.
