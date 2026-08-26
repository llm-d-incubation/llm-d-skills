# Scripts

Two scripts work together. `detect-pod-config.py` figures out which pods are true peers (same role + parallelism) and emits the group labels; `gpu-health-probe.py` probes the pods and compares each one only against others in its group.

## detect-pod-config.py

Reads `kubectl get pods -o json` (a List or a single Pod) on **stdin** and prints one `<pod_name>\t<group_label>` line per pod on **stdout**, plus a human-readable summary on **stderr**. The label leads with the GPU model, then role, then parallelism, e.g. `A100-SXM4-80GB-decode-tp4`, `H100-80GB-HBM3-decode-tp2`, `H100-80GB-HBM3-prefill-tp2-dp2`.

Why: pods are comparable only to peers that do the same work on the same hardware. Different GPU models (A100 vs H100) and different parallelism (a `tp=4` pod vs a `tp=2` pod) both have different latency baselines, so they must be checked as separate groups. Feeding this script's label column into `gpu-health-probe.py --groups` guarantees that split.

**Argument:** `--nodes <file>` (recommended) — path to `kubectl get nodes -o json`. Enables GPU-hardware grouping (the primary dimension). Omit it and the label is `<role>-tp<N>` only, with a `NOTE` warning on stderr not to compare across GPU models.

**Detection sources**, in order of trust:
- **GPU model** — node label `nvidia.com/gpu.product` (GPU Operator / NFD, e.g. `NVIDIA-A100-SXM4-80GB`), else `node.kubernetes.io/instance-type`, else `unknown-gpu`. Requires `--nodes`.
- **TP/DP/PP** — container `command`/`args` (`--tensor-parallel-size=N`, `-tp N`, `--data-parallel-size`, `--pipeline-parallel-size`; also parsed out of a single shell-string `bash -c "vllm serve … "`) → env vars (`TENSOR_PARALLEL_SIZE`, …) → `nvidia.com/gpu` limit as a fallback for TP.
- **Role** — `llm-d.ai/role` / `app.kubernetes.io/role` label, else a `prefill`/`decode` substring in the pod name, else the owning workload name.

**Requirements**: Python 3.6+, stdlib only. Needs `get`/`list` on pods and (for hardware grouping) on nodes — no `exec`.

```bash
NODE_NAMES=$(kubectl get pods -n $NAMESPACE "${PODS[@]}" \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | tr '\n' ' ')
kubectl get nodes $NODE_NAMES -o json > /tmp/hc-nodes.json 2>/dev/null || echo '{}' > /tmp/hc-nodes.json
kubectl get pods -n $NAMESPACE "${PODS[@]}" -o json \
  | python3 scripts/detect-pod-config.py --nodes /tmp/hc-nodes.json > /tmp/pod-groups.tsv
# stdout (tsv):     decode-6f7c9b8d5-xq2mn <TAB> A100-SXM4-80GB-decode-tp4
# stderr (summary): decode-6f7c9b8d5-xq2mn -> A100-SXM4-80GB-decode-tp4 (gpu=A100-SXM4-80GB, node=worker-3, tp=4 [explicit], gpus/pod=4)
```

## gpu-health-probe.py

Sends an identical set of randomized requests to one or more vLLM pod endpoints, measures **time-to-first-token (TTFT)** and **time-per-output-token (TPOT)** per pod, and flags outliers against their peers in the same `--groups` label.

**Note on TP/DP:** With Tensor Parallelism or internal Data Parallelism, each pod uses multiple GPUs. This script detects pod-level anomalies (a TP/DP group underperforming), not individual GPU anomalies. Pair it with `detect-pod-config.py` so pods of different parallelism land in different `--groups`.

**Requirements**: Python 3.6+, stdlib only (no pip installs needed).

### How it makes the comparison fair

- **Same prompts for every pod** — the prompt list is drawn once (fixed seed) and reused, so prompt-length variance can't be mistaken for a performance difference.
- **Warmup discarded** — one request per pod is sent and thrown away to absorb cold-start cost (CUDA graph capture / lazy init).
- **Group-aware** — prefill and decode pods have different latency baselines, so each pod is only compared against others in its `--groups` label.
- **Two signals + absolute floor** — TTFT and TPOT; an outlier must exceed both the multiplicative threshold *and* a small wall-clock gap (scaled to the group median), preventing false positives when latency is tiny.
- **TPOT re-probe** — pods flagged on TPOT are re-probed with a fresh batch; only persistent TPOT elevation is confirmed (transient memory-pressure spikes are cleared).

### Arguments

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--endpoints` | yes | — | Space-separated local endpoint URLs (e.g. `http://localhost:18001 ...`) |
| `--pod-names` | yes | — | Pod names in the same order as `--endpoints` |
| `--groups` | no | one group | Group label per pod, e.g. `decode decode prefill`. Pods are compared only within their group |
| `--model` | yes | — | Model ID as served by vLLM (must match exactly) |
| `--requests` | no | 8 | Timed requests per pod (≥ 1); one extra warmup request is discarded |
| `--max-tokens` | no | 50 | Max tokens generated per request |
| `--threshold` | no | 2.0 | Peer outlier: flag if mean TTFT or TPOT `> threshold × group median` |
| `--api` | no | `chat` | `chat` (→ `/v1/chat/completions`) or `completions` (→ `/v1/completions`, for base models) |
| `--request-timeout` | no | 15 | Per-request HTTP timeout in seconds |
| `--no-confirm-tpot` | no | off | Skip TPOT re-probe confirmation (faster, but may flag transient spikes) |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | All pods HEALTHY |
| 1 | One or more pods SUSPICIOUS or UNHEALTHY (vs peers) |
| 2 | Fatal: no successful responses, or bad arguments |

### Example

```bash
python3 scripts/gpu-health-probe.py \
  --endpoints http://localhost:18001 http://localhost:18002 \
  --pod-names llm-d-decode-a llm-d-decode-b \
  --groups decode decode \
  --model meta-llama/Llama-3.1-70B-Instruct \
  --requests 8 --max-tokens 50 --threshold 2.0
```

### Sample output — one pod slower than its peers

```
Pod health check
  model     : Llama-3.1-70B
  api       : /v1/chat/completions
  requests  : 8 per pod (4 concurrent), 1 warmup discarded
  max_tokens: 50
  peers     : flag > 2.0x group median, floor=15% of median
  tpot check: re-probe to confirm (transient spikes cleared)

  Probing llm-d-decode-a                           ... ok  (8/8 ok, TTFT=0.031s, TPOT=0.011s)
  Probing llm-d-decode-b                           ... ok  (8/8 ok, TTFT=0.031s, TPOT=0.011s)
  Probing llm-d-decode-c                           ... ok  (8/8 ok, TTFT=0.124s, TPOT=0.048s)

====================================================================================
  Pod                                     TTFT      TPOT  Status
------------------------------------------------------------------------------------
  group 'decode'  (median TTFT=0.031s, TPOT=0.011s)
  llm-d-decode-a                        0.031s    0.011s  [ HEALTHY ]
  llm-d-decode-b                        0.031s    0.011s  [ HEALTHY ]
  llm-d-decode-c                        0.124s    0.048s  [ SUSPICIOUS (TTFT 4.0x vs peers; TPOT 4.4x vs peers) ]
====================================================================================

One or more pods flagged. Suggested next steps:
  1. Check GPU/CUDA errors in flagged pod logs:
     kubectl logs -n $NAMESPACE <pod> | grep -iE "cuda|gpu|error|OOM|exception"
  2. Check node GPU allocation:
     kubectl describe node <node> | grep -A10 'Allocated resources'
```
