---
name: kv-cache-pressure-load-designer
description: >
  Designs a benchmark load configuration (concurrency, stages, num_requests) that will drive
  GPU KV cache utilization beyond the GPU's capacity — causing cache evictions regardless of
  whether CPU/storage KV offloading is enabled. Use this skill whenever the user wants to
  stress-test the KV cache, design a workload that creates pressure on GPU memory, figure out
  the right concurrency to saturate the KV pool, or create a workload that distinguishes between
  configurations with and without KV offloading. Triggers on phrases like "what concurrency
  should I use to stress the KV cache", "how many concurrent sessions to fill the GPU memory",
  "make the KV cache kick in", "create a workload that stresses prefix caching", or "design a
  load that will cause KV evictions".
---

# KV Cache Pressure Load Designer

## What this skill does

KV cache eviction and offloading only activate when active requests collectively need more KV
memory than the GPU has. This skill analytically computes the concurrency, turn count, and
stage structure needed to exceed that threshold — without trial and error.

The output is a load configuration that will work whether or not KV offloading is enabled:
a baseline run (no offloading) will see evictions and latency spikes; an offloading run will
offload instead. The load design itself is the same for both.

## Step 1 — Collect hardware inputs

Ask for (or extract from context):

- **GPU type** (e.g., A100 80GB, H100 80GB) — look up VRAM from `references/model-kv-params.md`
- **num_GPUs_per_pod** — number of GPUs per decoder pod
- **TP** (tensor-parallel degree) — must equal num_GPUs_per_pod for single-node TP
- **num_decoder_pods** — number of decoder replicas

## Step 2 — Collect model inputs

Look up the model in `references/model-kv-params.md`. If not found, ask for:
`num_layers`, `num_kv_heads`, `head_dim`, `kv_dtype` (default: match weights dtype)

## Step 3 — Compute GPU KV pool capacity

### KV bytes per token (per pod)

```
kv_element_bytes = 1 if fp8/int8, else 2 (fp16/bf16)
kv_bytes_per_token = num_layers × 2 × num_kv_heads × head_dim × kv_element_bytes
```

With TP, each GPU holds `num_kv_heads / TP` heads, but all TP ranks form one pod, so the
per-pod cost still uses the full `num_kv_heads`.

### Free GPU memory (per pod)

```
total_gpu_memory_gib = gpu_vram_gib × num_GPUs_per_pod
weight_memory_gib    = from references/model-kv-params.md (fp16: 2B × params; fp8: halve)
overhead_gib         = 5   # CUDA graphs, activations, vLLM buffers
free_for_kv_gib      = total_gpu_memory_gib - weight_memory_gib - overhead_gib
kv_fraction          = 0.90  # vLLM default; adjust for --gpu-memory-utilization
available_kv_gib     = free_for_kv_gib × kv_fraction
```

### KV pool size in tokens

```
block_size         = 16   # vLLM default; 128 if prefix caching is enabled
available_kv_bytes = available_kv_gib × 1024³
num_blocks         = floor(available_kv_bytes / (block_size × kv_bytes_per_token))
kv_pool_tokens     = num_blocks × block_size
```

State this result: "Each decoder pod can hold ~N tokens of KV before eviction occurs."

If an empirical value is available (from vLLM startup logs: `GPU KV cache size: N blocks`,
or `vllm:num_gpu_blocks` × block_size), prefer it over the formula.

## Step 4 — Collect workload inputs

### For `conversation_replay`

- `shared_system_prompt_tokens`, `dynamic_system_prompt_tokens` (0 if unused)
- `input_tokens_per_turn`, `output_tokens_per_turn`
- `turns_per_conversation` (use max for worst-case)
- `num_conversations`
- `max_model_len` (vLLM `--max-model-len`, else `native_max_context` from model table)

```
raw_peak            = shared_prompt + dynamic_prompt + turns × (input + output)
peak_context_tokens = min(raw_peak, max_model_len)
```

Clamping to `max_model_len` is important: if the dynamic system prompt alone exceeds the
context window (common in long-context agentic workloads), unclamped `raw_peak` will be far
larger than any session can actually hold, producing a misleadingly low saturation estimate.

### For `otel_trace_replay`

- `p75_session_input_tokens` — use p75 as the representative peak context (conservative)
- `mean_events_per_session`

## Step 5 — Compute saturation concurrency

```
saturation_per_pod   = kv_pool_tokens / peak_context_tokens
saturation_total     = saturation_per_pod × num_decoder_pods

T_total = saturation_total          # fleet saturation anchor
c_knee  = round(T_total × 1.5)     # onset of eviction: 50% over saturation
```

**Edge case**: if `saturation_per_pod < 1`, a single session already exceeds the GPU KV pool.
Every request triggers eviction. Set `T_total = num_decoder_pods` and start stages there.

### Verify the working set exceeds fleet capacity

```
working_set_tokens = num_conversations × peak_context_tokens
fleet_kv_capacity  = kv_pool_tokens × num_decoder_pods
```

Both must hold for a meaningful pressure test:
1. `working_set_tokens > fleet_kv_capacity` — the total session data exceeds GPU KV capacity,
   so eviction can actually occur across the fleet
2. `replay_density = total_requests / num_conversations ≥ 10` — sessions are re-requested
   often enough to hit evicted (or offloaded) blocks

If condition 1 fails, increase `num_conversations` until it does. `num_conversations` must
also be ≥ 5 × max_concurrency to avoid session-lock deadlock; round up to the nearest hundred.

## Step 6 — Design the load configuration

### For `conversation_replay`

Use a 5-stage ladder. Default to **benefit** mode (replay_density ≥ 20). Use **fast-check**
mode only if the user explicitly asks for a quick run (replay_density ≥ 10).

```yaml
load:
  type: concurrent
  num_workers: <ceil(T_total × 2 / 4)>
  worker_max_concurrency: <T_total × 4 × 2>
  stages:
    - concurrency_level: <T_total ÷ 2>         # warmup: GPU fills, no eviction
      num_requests: <round(T_total × num_decoder_pods × 2.5)>
    - concurrency_level: <c_knee>              # eviction onset (1.5×T)
      num_requests: <round(T_total × num_decoder_pods × 15)>   # benefit: 15×; fast-check: 15×
    - concurrency_level: <T_total × 2>         # mild eviction
      num_requests: <round(T_total × num_decoder_pods × 25)>   # benefit: 25×; fast-check: 60 per pod
    - concurrency_level: <T_total × 4>         # heavy eviction
      num_requests: <round(T_total × num_decoder_pods × 25)>   # benefit: 25×; fast-check: 60 per pod
    - concurrency_level: <T_total × 2>         # re-request: revisit sessions whose blocks
      num_requests: <round(T_total × num_decoder_pods × 25)>   # were evicted in stages 3–4
```

### For `otel_trace_replay`

Control load via `concurrent_sessions`. A warm-up stage followed by escalating pressure:

```yaml
load:
  type: trace_session_replay
  stages:
    - concurrent_sessions: <T_total ÷ 2>       # warm-up
      session_rate: 10.0
    - concurrent_sessions: <T_total>            # eviction onset
      session_rate: 10.0
    - concurrent_sessions: <T_total × 2>        # strong eviction
      session_rate: 10.0
  num_workers: 20
  worker_max_concurrency: 1000
  base_seed: 42
```

If the dataset has fewer sessions than `concurrent_sessions × 5`, collapse to fewer stages.

## Step 7 — Produce the output

Write a concise summary covering:

1. **KV pool math** — show the key numbers so the user can verify or adjust inputs
2. **Saturation point** — the concurrency threshold where eviction begins
3. **Complete `load:` YAML** — ready to paste into the benchmark config
4. **Save the config** — ask where to write the full workload YAML (including `dataset:` and
   `load:`) if the user hasn't specified a path; write it there

## Output format

```
## KV Cache Pressure Analysis

### Hardware
- Pod config: <N>× <GPU> (<VRAM> GiB each) = <total> GiB per pod, TP=<K>
- Available for KV cache: ~<A> GiB (after weights + overhead, ×0.90 fraction)

### Model KV geometry
- KV bytes/token: <formula> = <X> bytes/token
- KV pool capacity: ~<N> tokens per pod

### Workload
- Peak context per session: ~<P> tokens
- Saturation per pod: ~<P> sessions; across <N> pods: ~<total>
- Working set: <num_conversations> × <peak> = <total> tokens (fleet capacity: <fleet_kv>)

### Load configuration
<YAML>

### Saved to
<file path>
```
