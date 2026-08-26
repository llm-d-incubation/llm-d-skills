---
name: health-check-llm-d
description: Validates the health of an already-deployed llm-d stack by probing each inference pod directly with random requests and comparing time-to-first-token (TTFT) and time-per-output-token (TPOT) latency across pods in the same group. Use this skill whenever the user wants to verify pods are all working comparably, check for slow or broken pods, detect pod outliers, run a quick sanity check after deployment, confirm uniform inference performance, or investigate inconsistent latency — even if they don't say "health check" explicitly.
---

# Health Check llm-d Stack

## Purpose

Validate that all pods in a deployed llm-d stack are performing comparably by probing each vLLM inference pod with randomized requests and measuring **TTFT** (time-to-first-token — prefill health) and **TPOT** (time-per-output-token — decode health).

A pod is flagged when its latency is a significant outlier among **its true peers** — other pods that do the exact same amount of work (**vs peers**, a single run).

> **Peers = same GPU hardware, same role, same parallelism.** Only pods on the same GPU model, in the same role, with the same TP/DP/PP share a latency baseline — an A100 differs from an H100, and a `tp=4` pod spreads each request across more GPUs than a `tp=2` pod. So the skill auto-detects all three, groups pods by `(GPU model, role, TP, DP, PP)`, and runs the outlier check independently within each group — never across groups.
>
> Because each pod is a multi-GPU unit, a flag is a **pod-level** signal (that TP/DP group as a whole is slow) — not a specific-GPU signal. Isolating which GPU inside the pod is at fault needs further investigation (e.g. `nvidia-smi` on the node).

This skill is **read-only** — it probes pods via temporary local port-forwards; it never creates, patches, or deletes a cluster resource.

---

## Step 1: Locate the Stack and Set NAMESPACE

Use the standard detection logic:

1. If the `NAMESPACE` environment variable is set, use it.
2. Otherwise run `oc project -q 2>/dev/null`.
3. If neither, ask the user.

Verify the stack is present and pods are Ready:
```bash
kubectl get pods -n $NAMESPACE
```

If pods are not all in `Running`/`Ready` state, stop and tell the user to wait for the stack to stabilize before running a health check.

---

## Step 2: Discover Inference Pods and Group Them by Hardware + Parallelism

### 2a: Find all vLLM pods

Try in order until pods are found:
```bash
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=vllm -o wide
kubectl get pods -n $NAMESPACE -l app=vllm -o wide
kubectl get pods -n $NAMESPACE -o wide | grep -i vllm
```

Build a `PODS` array from the running pods (portable across bash/zsh):
```bash
PODS=()
while IFS= read -r p; do PODS+=("$p"); done < <(
  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/component=vllm \
    --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$'
)
printf 'pod: %s\n' "${PODS[@]}"
```
> If that selector returns nothing, fall back to `-l app=vllm` or ask the user how their vLLM pods are labeled.

### 2b: Auto-group pods by GPU hardware + role + parallelism

Pods are only comparable to peers on the **same GPU hardware**, in the **same role**, with the **same parallelism** — different GPU models (A100 vs H100), prefill vs decode, and different TP/DP/PP sizes all have different latency baselines by design. `scripts/detect-pod-config.py` assigns each pod a group label leading with the GPU model, e.g. `A100-SXM4-80GB-decode-tp4`, `H100-80GB-HBM3-decode-tp2`.

GPU hardware comes from the pod's node labels, so fetch the nodes too (best-effort — needs read access to nodes):

```bash
# Fetch the specs of exactly the pods discovered above.
kubectl get pods -n $NAMESPACE "${PODS[@]}" -o json > /tmp/hc-pods.json

# Fetch the nodes those pods run on, for GPU-hardware grouping (the primary
# dimension). If node read access is denied, this falls back to '{}' and the
# detector groups by role+parallelism only, printing a note.
NODE_NAMES=$(kubectl get pods -n $NAMESPACE "${PODS[@]}" \
  -o jsonpath='{.items[*].spec.nodeName}' | tr ' ' '\n' | sort -u | tr '\n' ' ')
kubectl get nodes $NODE_NAMES -o json > /tmp/hc-nodes.json 2>/dev/null || echo '{}' > /tmp/hc-nodes.json

# Label each pod. tsv is <pod>\t<group_label> on stdout; human summary on stderr.
python3 /abs/path/to/skills/health-check-llm-d/scripts/detect-pod-config.py \
  --nodes /tmp/hc-nodes.json < /tmp/hc-pods.json > /tmp/pod-groups.tsv

# Rebuild PODS and POD_GROUPS TOGETHER from the tsv so they stay aligned.
# NOTE: do NOT name the group array GROUPS — GROUPS is a reserved bash variable.
# NOTE: no `declare -A` — macOS ships bash 3.2, which has no associative arrays.
PODS=()
POD_GROUPS=()
while IFS=$'\t' read -r pod label; do
  [ -z "$pod" ] && continue
  PODS+=("$pod")
  POD_GROUPS+=("$label")
done < /tmp/pod-groups.tsv
paste <(printf '%s\n' "${PODS[@]}") <(printf '%s\n' "${POD_GROUPS[@]}")
```

**Show the user the detected groups** (from the detector's stderr summary) before probing — e.g. "2 pods in `A100-SXM4-80GB-decode-tp2`, 1 pod in `H100-80GB-HBM3-decode-tp4`; each group is tested separately." Detection sources: GPU model from node label `nvidia.com/gpu.product` (falls back to instance-type, else `unknown-gpu`); TP/DP/PP from container args/command → env vars → `nvidia.com/gpu` count. If the detected grouping looks wrong, the user can override any label in `POD_GROUPS` by hand.

> **If GPU hardware could not be detected** (the detector prints a `NOTE: no GPU-hardware info` line — e.g. node read access was denied), tell the user the check will group by role+parallelism only and **must not** be trusted across pods that might be on different GPU models. Offer to have them supply the hardware split manually.

Probing a pod directly (via its own port-forward) bypasses the llm-d routing layer and exercises that pod on its own — exactly what we want for a per-pod health check. `POD_GROUPS` is passed to the probe script via `--groups` (Step 5).

---

## Step 3: Determine the Model Name

Capture the model name into `MODEL_NAME` from the first pod's environment variables:
```bash
# First pod, portably (bash arrays are 0-indexed, zsh 1-indexed — don't use ${PODS[0]}).
for FIRST_POD in "${PODS[@]}"; do break; done

MODEL_NAME=$(kubectl get pod "$FIRST_POD" -n $NAMESPACE -o json | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
envs = {e['name']: e.get('value','') for c in d['spec']['containers'] for e in c.get('env',[])}
print(envs.get('MODEL_ID') or envs.get('MODEL_NAME') or envs.get('VLLM_MODEL',''))
")
echo "detected MODEL_NAME='$MODEL_NAME'"
```

If `MODEL_NAME` came back empty, briefly port-forward the first pod to query `/v1/models`:
```bash
kubectl port-forward "pod/$FIRST_POD" 18000:8000 -n $NAMESPACE &
PF_PID=$!; sleep 2
MODEL_NAME=$(curl -s http://localhost:18000/v1/models | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")
kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null
echo "detected MODEL_NAME='$MODEL_NAME'"
```

Show `MODEL_NAME` to the user and confirm before proceeding.

---

## Step 4: Set Health Check Parameters

Confirm these parameters with the user, using defaults if they don't want to change anything:

| Parameter | Default | Description |
|-----------|---------|-------------|
| Requests per pod | 8 | Inference requests sent to each pod (plus 1 discarded warmup) |
| Max tokens | 50 | Max tokens generated per request (shorter = faster check) |
| Peer threshold | 2.0× | Flag a pod if its mean TTFT **or** TPOT exceeds this multiple of its group median |
| API type | `chat` | `chat` for instruct/chat models; `completions` for base models with no chat template |

The probe sends the **same** prompt set to every pod (fair comparison), discards one warmup request per pod (avoids cold-start bias), and measures both TTFT and TPOT.

Set the parameters as shell variables (defaults shown — override any per the table above), so the probe command in Step 5 can reference them:
```bash
REQUESTS=8
MAX_TOKENS=50
PEER_THRESHOLD=2.0
API=chat          # use 'completions' for base models without a chat template
```

With 8 requests and 4 concurrent per pod, a full check across a handful of pods typically completes in under 3 minutes.

---

## Step 5: Run Health Probes

Use `scripts/gpu-health-probe.py` located alongside this skill file.

### 5a: Start port-forwards (one per pod)

Assign a unique local port starting at 18001. Start each port-forward in the background and record its PID (reuse the `PODS` array from Step 2 — `POD_GROUPS` was already built there):

```bash
PF_PIDS=()
LOCAL_PORTS=()
PORT=18001

# Portable loop (no ${!PODS[@]} / 0-index assumptions, which break under zsh):
for pod in "${PODS[@]}"; do
  kubectl port-forward "pod/$pod" ${PORT}:8000 -n $NAMESPACE >/dev/null 2>&1 &
  PF_PIDS+=($!)
  LOCAL_PORTS+=($PORT)
  PORT=$((PORT + 1))
done

# Wait for tunnels to establish
sleep 5
```

> If the container serves on a port other than 8000, adjust the `:8000` target. Confirm with `kubectl get pod <pod> -n $NAMESPACE -o jsonpath='{.spec.containers[*].ports[*].containerPort}'` if unsure.

### 5b: Run the probe script

Substitute the absolute path to this skill's `scripts/` directory. Pass the `POD_GROUPS` built in Step 2b via `--groups` so each parallelism group is evaluated on its own. The `$API` set in Step 4 selects `chat` (instruct models) vs `completions` (base models with no chat template).

```bash
python3 /abs/path/to/skills/health-check-llm-d/scripts/gpu-health-probe.py \
  --endpoints $(printf "http://localhost:%s " "${LOCAL_PORTS[@]}") \
  --pod-names "${PODS[@]}" \
  --groups "${POD_GROUPS[@]}" \
  --model "$MODEL_NAME" \
  --requests $REQUESTS \
  --max-tokens $MAX_TOKENS \
  --threshold $PEER_THRESHOLD \
  --api "$API"
PROBE_EXIT=$?
```

The script exits `0` (all healthy), `1` (one or more pods flagged), or `2` (fatal — e.g., no pod responded; check the model name and `--api`).

### 5c: Kill all port-forwards

```bash
for pid in "${PF_PIDS[@]}"; do
  kill $pid 2>/dev/null
done
wait "${PF_PIDS[@]}" 2>/dev/null
```

Always kill port-forwards even if the probe script fails.

---

## Step 6: Report Results and Recommend Actions

Present the probe script's health table to the user. Each status is one of:

- **HEALTHY** — TTFT and TPOT are within the normal range vs peers in the same group.
- **SUSPICIOUS** — an outlier vs peers. The status line names which metric:
  - A high **TTFT** points to a slow prefill/compute path.
  - A high **TPOT** points to slow token generation (decode).
  - Either can indicate a throttled or faulty GPU, a hardware fault, or a competing workload sharing the node.
  - With TP/DP, a flagged pod means the entire GPU group on that pod is underperforming — individual GPU isolation requires further investigation (e.g., `nvidia-smi` on the node).
- **UNHEALTHY** — the pod returned errors on all probes. The pod may be misconfigured, or (if *every* pod is UNHEALTHY) the model name or `--api` type is wrong.

If the script prints a **"fewer than 3 responsive pods"** note for a group, tell the user that peer-based detection is unreliable for that group and results should be treated as indicative only. This is expected when grouping by parallelism splits a small deployment into groups of 1–2 pods (e.g. a single `tp=4` pod has no peers to compare against) — peer comparison fundamentally needs ≥3 like-configured pods, so for those groups report the raw TTFT/TPOT numbers and note that no outlier judgment can be made.

**If any pods are SUSPICIOUS or UNHEALTHY**, suggest the following investigation steps:

1. Check for GPU-level errors in pod logs:
   ```bash
   kubectl logs -n $NAMESPACE <pod> | grep -iE "cuda|gpu|error|OOM|exception|failed"
   ```

2. Check node-level GPU resource allocation:
   ```bash
   kubectl describe node <node-name> | grep -A10 "Allocated resources"
   ```

3. Check if a GPU is being shared or throttled:
   ```bash
   kubectl get pod <pod> -n $NAMESPACE -o json | \
     python3 -c "import sys,json; d=json.load(sys.stdin); \
     [print(c['name'], c.get('resources',{})) for c in d['spec']['containers']]"
   ```

4. **STOP and ask the user before doing anything.** Present your findings and explicitly ask:
   > "Pod `<pod>` is flagged as SUSPICIOUS. Should I restart it?"
   Wait for the user's explicit approval before proceeding. Never restart automatically.

   If the user approves, restart the flagged pod and re-run the health check:
   ```bash
   kubectl rollout restart deployment/<deployment-name> -n $NAMESPACE
   ```

---

## Step 7: Reset KV Cache (Always Ask)

Always ask the user at the end of every run — the health check sends requests that populate the cache:

> "The health check populated the KV cache. Would you like to reset it now?"

Wait for the user's answer. If yes, invoke the `clear-kv-cache-tiers-in-llm-d-deployment` skill, passing the `NAMESPACE` from Step 1. If no, stop.

---

## Execution Rules

1. **Read-only** — do not create, patch, or delete any Kubernetes resource.
2. **Always kill port-forwards** — track PIDs and clean them up in Step 5c, even on failure.
3. **Scope to $NAMESPACE** — no operations outside the target namespace.
4. **Handle individual pod failures gracefully** — if one port-forward dies early, record that pod as failed and continue probing the rest.
5. **Show live progress** — print each pod name as probing begins.

---

## What Not To Do

1. **Do NOT restart pods** — report findings only; the user decides on remediation.
2. **Do NOT modify any cluster resource** — this skill is diagnostic, not repair.
3. **Do NOT confuse this with benchmarking** — for full throughput/latency benchmarks, use the `run-llm-d-benchmark` skill instead. This skill is a quick pass/fail sanity check.

---

## When to Use This Skill

- After deploying llm-d to verify all pods came up performing comparably
- When inference latency is inconsistently high (possible pod outlier)
- Before running a benchmark to confirm all pods are at baseline
- After a node maintenance event or GPU driver update
- As a quick diagnostic when users report inconsistent latency across requests

---

## Prerequisites

- `kubectl` configured with access to the cluster
- Python 3.6+ available locally (stdlib only — no pip installs needed)
- The llm-d stack must already be deployed with all pods in `Running` state
- Optional but recommended: read access to `nodes` (for GPU-hardware grouping via node labels). Without it, the check groups by role+parallelism only and cannot separate different GPU models.

---

## Security Considerations

- All operations are scoped to the target namespace
- Port-forwards are bound to localhost only and cleaned up after the check
- No cluster-level changes
- No credentials or model weights are accessed — only the inference HTTP API
