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

**Edge case — if `saturation_concurrency_per_pod < 1`**: a single session already exceeds the
GPU KV pool. Every request triggers offloading; there is no "below saturation" regime. Set
`T_total = num_decoder_pods` (c=1 per pod is already above saturation on every pod) and
skip any stages below `num_decoder_pods` in the ladder.

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
T_total = saturation_concurrency_total          # fleet-level saturation anchor for stage ladder
c_knee  = round(T_total × 1.5)                 # onset of offloading: GPU first reaches 100%
                                                # Most diagnostic stage for A/B comparison:
                                                # Run A evicts blocks; Run B offloads to CPU.
                                                # The TTFT delta between runs is largest here.

target_concurrency = max(
    ceil(saturation_concurrency_per_pod × 1.5),   # 50% over saturation for reliable offloading
    10                                             # minimum for meaningful measurement
)
```

The 1.5× factor ensures you're clearly above the threshold, accounting for variability in
session lengths and the fact that not all sessions reach peak context at the same instant.
If the goal is to see *strong* offloading (large CPU hit rate), use 2×–3× instead.

### Verify working-set exceeds fleet KV capacity

Before proceeding to stage design, confirm that eviction can actually occur:

```
working_set_tokens = num_conversations × peak_context_tokens
fleet_kv_capacity  = kv_pool_tokens × num_decoder_pods

required: working_set_tokens > fleet_kv_capacity
```

If this condition is **not** met, all active sessions' KV fits within the fleet's GPU memory.
High concurrency alone will not cause eviction, and OffloadingConnector will never fire.
To fix: increase `num_conversations` until `working_set_tokens > fleet_kv_capacity`.

## Step 6 — Choose load mode and design stages

Two modes are available. Use **`benefit`** by default. Use **`fast-check`** only when the user explicitly asks for a fast or quick run.

| Mode | Goal | Stages | replay_density |
|------|------|--------|----------------|
| **benefit** *(default)* | Authoritative A/B: proves offloading improves TTFT and throughput. Both runs complete all requests; the A/B signal is TTFT reduction, `schedule_delay` decrease, and `achieved_rate` improvement at the heavy-pressure stage. | 5 | ≥ 20 |
| **fast-check** | Quick validation: confirms offloading direction with shorter stages. Use only when the user explicitly asks for a fast or quick run. | 5 | ≥ 10 |

With tiered-prefix-cache EPP (cpu-prefix-cache-scorer), requests queue rather than fail under KV pressure — both runs complete all requests regardless of OffloadingConnector.

### For `conversation_replay` — benefit mode (default)

5-stage ladder with mild-offload stage included. Uses `num_decoder_pods`× base request multiplier. Targets replay_density ≥ 20 to give CPU-cached blocks time to be re-requested.

```yaml
load:
  type: concurrent
  num_workers: <ceil(T_total × 2 / 4)>
  worker_max_concurrency: <T_total × 4 × 2>
  stages:
    - concurrency_level: <T_total ÷ 2>             # warmup: GPU fills, no offloading
      num_requests: <round(T_total × num_decoder_pods × 2.5)>
    - concurrency_level: <c_knee>                  # KNEE (1.5×T): offloading onset
      num_requests: <round(T_total × num_decoder_pods × 15)>
    - concurrency_level: <T_total × 2>             # mild sustained offloading
      num_requests: <round(T_total × num_decoder_pods × 25)>
    - concurrency_level: <T_total × 4>             # heavy offloading pressure
      num_requests: <round(T_total × num_decoder_pods × 25)>
    - concurrency_level: <T_total × 2>             # re-request: revisit sessions whose KV blocks
      num_requests: <round(T_total × num_decoder_pods × 25)>      # were offloaded in stages 3–4; exercises the
                                                    # CPU reload (cache-hit) path
```

For gpt-oss-120b (T_total=12, 8 pods, num_conversations=300):

```yaml
  num_workers: 6
  worker_max_concurrency: 96
  stages:
    - concurrency_level: 6      # T/2 — warmup
      num_requests: 240
    - concurrency_level: 18     # 1.5T — knee
      num_requests: 1440
    - concurrency_level: 24     # 2T — mild offloading
      num_requests: 2400
    - concurrency_level: 48     # 4T — heavy offloading
      num_requests: 2400
    - concurrency_level: 24     # 2T — re-request (CPU reload)
      num_requests: 2400
```

Total: 8,880 requests / 300 conversations = 29.6 replay_density.

### For `conversation_replay` — fast-check mode

Same 5-stage structure as benefit mode. Stages 2–4 use `round(T_total × 60)` requests — approximately 1/3 of full benefit, empirically validated on gpt-oss-120b (8× H100, TP=1). Use only when the user explicitly asks for a fast or quick run.

```yaml
load:
  type: concurrent
  num_workers: <ceil(T_total × 2 / 4)>
  worker_max_concurrency: <T_total × 4 × 2>
  stages:
    - concurrency_level: <T_total ÷ 2>             # warmup: GPU fills, no offloading
      num_requests: <round(T_total × num_decoder_pods × 2.5)>
    - concurrency_level: <c_knee>                  # KNEE (1.5×T): offloading onset
      num_requests: <round(T_total × num_decoder_pods × 15)>
    - concurrency_level: <T_total × 2>             # mild sustained offloading
      num_requests: <round(T_total × 60)>
    - concurrency_level: <T_total × 4>             # heavy offloading pressure
      num_requests: <round(T_total × 60)>
    - concurrency_level: <T_total × 2>             # re-request: CPU reload path
      num_requests: <round(T_total × 60)>
```

For gpt-oss-120b (T_total=12, 8 pods, num_conversations=300):

```yaml
  num_workers: 6
  worker_max_concurrency: 96
  stages:
    - concurrency_level: 6      # T/2 — warmup
      num_requests: 240
    - concurrency_level: 18     # 1.5T — knee (dominates runtime)
      num_requests: 1440
    - concurrency_level: 24     # 2T — mild offloading
      num_requests: 720
    - concurrency_level: 48     # 4T — heavy offloading
      num_requests: 720
    - concurrency_level: 24     # 2T — re-request (CPU reload)
      num_requests: 720
```

Total: 3,840 requests / 300 conversations = 12.8 replay_density. Sufficient to confirm offloading direction; not sufficient to maximize CPU hit rate.

**Replay density** — the number of times each conversation is re-requested — determines
whether CPU-offloaded blocks are ever re-loaded. CPU cache hits only occur when a session
is requested *after* its blocks were evicted to CPU.

```
replay_density = total_requests / num_conversations
fast-check: ≥ 10 — sufficient to observe TTFT benefit and confirm offloading direction
benefit:    ≥ 20 — sufficient to maximize CPU KV hit rate and throughput delta
```

With fast-check mode and num_conversations=300 (T=12):
- total = 240 + 1440 + 720 + 720 + 720 = 3,840 → replay_density = 12.8

With benefit mode (num_decoder_pods=8) and num_conversations=300 (T=12):
- total = 240 + 1440 + 2400 + 2400 + 2400 = 8,880 → replay_density = 29.6

If the data section is fixed at num_conversations=300 and replay_density ≥ 20 is required,
use benefit mode. To reach replay_density ≥ 20 with fewer requests, reduce
num_conversations to ~55 instead.

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
3. **Mode selected** — `benefit` (default) or `fast-check` (explicit request only), with rationale
4. **Complete `load:` YAML** — ready to paste into the benchmark config
5. **Metrics to watch** — tell the user how to confirm offloading is active:
   - `schedule_delay` **mean** rising sharply across concurrency stages → KV queue is building. Mean > 60s at the target stage indicates meaningful pressure; > 300s indicates heavy queuing (requests waiting several minutes before dispatch).
   - `vllm:external_prefix_cache_hit_rate` (in the `_aggregated` section of `metrics_summary.json`) — the most immediately findable CPU KV activity signal. Mean > 0 confirms the CPU KV cache is actively serving hits.
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
- **OffloadingConnector-specific metrics** (check `metrics/processed/metrics_summary.json`):
  - `vllm:external_prefix_cache_hit_rate` — **in `_aggregated`**, immediately available without per-pod inspection. Check this first. Mean > 0 confirms CPU KV cache hits are occurring.
  - `vllm:kv_offload_total_bytes_total` > 0 confirms offloading physically fired. **Per-pod only — NOT in `_aggregated`.** Look in the per-pod sections of `metrics_summary.json` or ask the run operator for the values. Zero in early-stage scrapes is expected (offloading fires at stage 3+). TB-scale values (0.5–2 TB per pod) are normal under benefit-mode loads. **This metric is not always surfaced in summary results — ask for it explicitly if you need confirmation.**
  - `vllm:kv_offload_size_count` — GPU→CPU and CPU→GPU event counts. **Per-pod only — collect explicitly** using `oc exec` or by scraping `/metrics` on each decode pod after the run. The GPU_to_CPU / CPU_to_GPU count ratio measures CPU cache reload efficiency: a ratio > 5 means most offloaded blocks were never reloaded back — increase `replay_density` next run. Pod-level variance of 3–4× in offload counts is normal with cpu-prefix-cache-scorer (routing hot-spots concentrate load); near-uniform values across pods would indicate the scorer is not routing by prefix effectively. To collect: `for POD in $(oc get pods -n $NS --no-headers | grep decode | awk '{print $1}'); do echo "=== $POD ==="; oc exec $POD -n $NS -- curl -s localhost:8000/metrics | grep kv_offload_size_count; done`
  - `vllm:kv_offload_total_time_total` — cumulative offload time; divide by event count for avg per-transfer latency (per-pod only)
  - `vllm:kv_cache_usage_perc` — should peak ≥ 95% in the offloading run before offload triggers
  - `vllm:prefix_cache_hits_total` / `vllm:prefix_cache_queries_total` — compute
    `actual_hit_rate = hits / queries` (do NOT use the raw `prefix_cache_hit_rate` counter — it
    is not a percentage)

  A successful OffloadingConnector demonstration shows:
  1. `vllm:external_prefix_cache_hit_rate` > 0 in `_aggregated` (CPU KV cache is serving hits)
  2. `kv_offload_total_bytes_total` > 0 in per-pod sections at stages 3–5 (offloading is physically active)
  3. Lower TTFT and higher `achieved_rate` in the offloading run vs baseline at the **heavy-pressure stage** (c = 4T)
  4. Higher `prefix_cache_hits_total` in the offloading run at the re-request stage

  If TTFT is higher in the offloading run despite offloading firing, the cause is low
  `replay_density` — increase `num_requests` per stage before concluding the connector
  is net-negative.

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
- **Load mode**: benefit (default) or fast-check (explicit request only) — state which and why

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
- **Stage lifecycle metrics** (`summary_session_lifecycle_metrics.json`) are generated per completed stage but may be absent for stages that end early (e.g., truncated results copy, EOF error during collection). Always verify which stages have lifecycle data before comparing TTFT across runs — missing lifecycle files for a stage do not mean the stage failed, only that per-stage summary metrics are unavailable for it.
- **Warmup stage (c = T/2) will show run-B TTFT slightly worse than run-A.** OffloadingConnector initialization and staging-buffer overhead is visible when the GPU KV pool is not yet under pressure. This reverses at the knee stage (c=1.5T) and improves further through stages 2–4. Do not flag warmup-stage TTFT as a regression.
- **Workload fit for OffloadingConnector**: the connector shows TTFT *benefit* only when
  CPU-offloaded blocks are re-requested. Two conditions must both hold:
  1. `replay_density = total_requests / num_conversations ≥ 10` — sessions are re-requested
     often enough that CPU-cached blocks get a chance to be loaded back (≥ 20 for maximum hit rate)
  2. `working_set_tokens = num_conversations × peak_context_tokens > kv_pool_tokens × num_pods`
     — the active session set exceeds total GPU KV capacity, so eviction/offload actually occurs

  If only condition 2 holds (high concurrency, low replay), the benchmark confirms offloading
  is *active* but TTFT may still be *worse* than baseline due to load/evict overhead without
  the cache-hit payoff. This is a valid result — it documents the overhead regime — but is not
  a demonstration of benefit. To demonstrate benefit, both conditions must hold.
