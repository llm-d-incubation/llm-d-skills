---
name: clear-kv-cache-tiers-in-llm-d-deployment
description: Clears all KV / prefix cache tiers (GPU, CPU, and FS offload) on every vLLM pod in an llm-d deployment for a clean state — including both roles of a disaggregated prefill/decode setup. Use when the user wants to flush the cache, reset vLLM state, or start fresh before a test run — even if they don't say "cache" explicitly. Prefers the /reset_prefix_cache API; falls back to pod restart.
---

# Reset vLLM Cache in llm-d

## Purpose

Clear the KV / prefix cache on all vLLM pods in an llm-d deployment so the next run starts from a clean state. Prefers non-restart methods; falls back to pod restart when necessary.

---

## Step 1: Ask for Namespace and Deployment

1. Detect the current namespace and related options:
```bash
CURRENT_NS=$(oc project -q 2>/dev/null || kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "")
SUGGESTED_NS=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
  | tr ' ' '\n' | grep -iE "llm-d|inference|serving|benchmark" | grep -v "^$CURRENT_NS$" | head -5)
```

Ask the user:
> "Which namespace?
> **1. \<CURRENT_NS\>** *(current context)*
> **2–N.** \<SUGGESTED_NS\>
> *(or type any namespace)*"

Set `NAMESPACE` to the user's answer. If the user just confirms without specifying, use `CURRENT_NS` — the namespace they are currently working in.

2. List llm-d deployments (the `ROLE` column reveals a disaggregated setup):
```bash
kubectl get deployments -n $NAMESPACE -l app.kubernetes.io/part-of=llm-d \
  -o custom-columns="NAME:.metadata.name,ROLE:.spec.template.metadata.labels.llm-d\.ai/role,READY:.status.readyReplicas,DESIRED:.spec.replicas"
# If empty, broaden:
kubectl get deployments -n $NAMESPACE | grep -iE "llm-d|vllm"
```
- **One result** → use automatically, inform the user.
- **Multiple** → ask: *"Which deployment? (or 'all' to reset every vLLM pod in the namespace)"*
- **Disaggregated prefill/decode** — you see both a `…-prefill` and a `…-decode` deployment (or `ROLE=prefill` / `ROLE=decode`): **both must be reset.** Prefill pods hold KV cache too, so clearing only decode leaves stale prefill KV. Reset every role — the `all` selector below covers both in one pass, or run Steps 2–4 once per deployment.

Set `DEPLOYMENT_NAME` to the chosen deployment (used by the specific-deployment selector and the restart/patch steps). Skip it when the user picked `all`. For P/D, also capture both role names — used in Step 4:
```bash
DEPLOYMENT_NAME=<chosen deployment>
# P/D only — read the two role deployment names from the Step 1 listing:
PREFILL_DEPLOYMENT=$(kubectl get deployments -n $NAMESPACE -l llm-d.ai/role=prefill -o jsonpath='{.items[0].metadata.name}')
DECODE_DEPLOYMENT=$(kubectl get deployments -n $NAMESPACE -l llm-d.ai/role=decode -o jsonpath='{.items[0].metadata.name}')
```

Derive `LABEL_SELECTOR`. The deployment's own `matchLabels` is the most reliable source — label conventions differ across llm-d versions (`llm-d.ai/engine-type=vllm` on newer, `app.kubernetes.io/component=vllm` on older), and the hardcoded guesses below may match nothing:
```bash
# Specific deployment (works regardless of label convention):
LABEL_SELECTOR=$(kubectl get deployment -n $NAMESPACE $DEPLOYMENT_NAME -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')

# For 'all' vLLM pods in the namespace — covers BOTH prefill and decode roles.
# Try the newer engine-type label first, fall back to the older component label:
LABEL_SELECTOR="llm-d.ai/engine-type=vllm"
[ -z "$(kubectl get pods -n $NAMESPACE -l "$LABEL_SELECTOR" -o name 2>/dev/null)" ] && \
  LABEL_SELECTOR="app.kubernetes.io/component=vllm"
```

Show the affected pods and ask the user to confirm (for P/D, confirm you see **both** roles):
```bash
kubectl get pods -n $NAMESPACE -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o wide -L llm-d.ai/role
```

Note the **vLLM version** — it decides whether the API can clear a 3-tier cache (Steps 3/3b/4 all branch on ≥ 0.24.0 vs < 0.24.0). Read it from the image tag:
```bash
kubectl get pods -n $NAMESPACE -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' | sort -u
# e.g. vllm/vllm-openai:v0.24.0  → VLLM_VERSION=0.24.0
```
If the tag is `latest` or a digest, query a pod instead: `kubectl exec … -- python -c "import vllm; print(vllm.__version__)"`.

---

## Step 2: Check Dev Mode Status

Run the dev-mode check script:
```bash
bash skills/clear-kv-cache-tiers-in-llm-d-deployment/scripts/check-dev-mode.sh
```

`VLLM_SERVER_DEV_MODE=1` is required for the `/reset_prefix_cache` endpoint. It only registers extra API routes at startup — no effect on inference speed (TPS, TTFT).

If **not enabled**, offer:
> **1. Enable dev mode** — patches the deployment and restarts pods. The restart clears the cache as a side effect. **Skill ends here.**
> **2. Restart pods now** — a plain `rollout restart` clears every tier without enabling dev mode (Step 4).
> **3. Abort**

**Option 1:**
```bash
kubectl patch deployment $DEPLOYMENT_NAME -n $NAMESPACE --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"VLLM_SERVER_DEV_MODE","value":"1"}}]'
kubectl rollout status deployment/$DEPLOYMENT_NAME -n $NAMESPACE --timeout=300s
```
Report success and stop. Future resets can use Step 3 without restarting.

**Option 2** → go to Step 4. **Option 3** → stop.

---

## Step 3: Reset via /reset_prefix_cache (Preferred)

If dev mode is confirmed, run the reset script:
```bash
export NAMESPACE="$NAMESPACE"
export VLLM_PORT="${VLLM_PORT:-8000}"
export LABEL_SELECTOR="$LABEL_SELECTOR"
export RESET_RUNNING_REQUESTS=true
export RESET_EXTERNAL=true
bash skills/clear-kv-cache-tiers-in-llm-d-deployment/scripts/reset-prefix-cache.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_PORT` | `8000` | Port vLLM listens on inside the pod |
| `RESET_RUNNING_REQUESTS` | `true` | Preempts in-flight requests; use `false` to clear cache without interrupting active work |
| `RESET_EXTERNAL` | `true` | Clears CPU offload blocks **only if** `CPUOffloadingSpec` is used (2-tier). With `TieringOffloadingSpec` (3-tier: GPU + CPU + FS): on **vLLM ≥ 0.24.0** (includes [PR #44541](https://github.com/vllm-project/vllm/pull/44541)) this drains in-flight transfers, resets the GPU primary tier, and clears the CPU tier index — but the **FS secondary tier files on disk are not deleted** (run Step 3b for those). On vLLM < 0.24.0 this is a no-op for 3-tier. `reset_external` itself is a no-op for NixL and LMCache connectors — but see the shared-store note below: NixL keeps no separate store (resetting both P/D roles suffices), whereas LMCache/Mooncake shared stores are **not** cleared by this skill. |
| `RESET_RETRY_COUNT` | `3` | How many times to retry when vLLM ≥ 0.26.0 returns `200 {"success": false}` (blocks held by in-flight transfers) |
| `RESET_RETRY_DELAY` | `2` | Seconds to wait between retries |

**Warn the user before running:** `RESET_RUNNING_REQUESTS=true` terminates in-flight requests. Ensure no active traffic is hitting the pods.

> **⚠️ Shared/external KV store (LMCache, Mooncake):** if the deployment uses one of these connectors, this reset does **not** clear the shared store — it persists across this reset and a pod restart. Flush the backing service (Redis, the Mooncake store, etc.) separately; it is outside this skill's scope. NixL is unaffected (it has no separate store — resetting both P/D roles suffices). See Important Notes.

**On success** (routing depends on tier count and vLLM version — note that a `200` does not always mean success: on vLLM ≥ 0.26.0, `200` with `{"success": false}` means blocks are still held by in-flight offload transfers; the script retries up to `RESET_RETRY_COUNT` times with `RESET_RETRY_DELAY`-second gaps and warns if still failing. Empty body means vLLM < 0.26 — treated as success. On older versions, a 3-tier cache may not have been cleared despite the `200`):
- **1-tier (GPU-only) or 2-tier (GPU + CPU, `CPUOffloadingSpec`)** — report done, the user can proceed.
- **3-tier `TieringOffloadingSpec` on vLLM ≥ 0.24.0** — continue to **Step 3b** to delete the FS tier files, then done.
- **3-tier on vLLM < 0.24.0** — the API is a **no-op** for 3-tier (GPU and CPU tiers are NOT cleared despite the `200`). Do not rely on it; go to **Step 4 (restart)** instead.

**On failure** — auto-diagnose per pod before asking the user:

| Error | Auto-fix |
|-------|----------|
| **404** — dev mode missing on pod | Patch deployment + rollout (same as Step 2 option 1). Restart clears cache — end skill. |
| **Connection refused** | Check pod status/logs. Wait up to 60s for Ready, retry once. Report OOMKilled/CrashLoop to user. |
| **RBAC / exec error** | Try port-forward: `kubectl port-forward pod/$POD -n $NAMESPACE 18000:$VLLM_PORT &`, then curl `http://localhost:18000/reset_prefix_cache?...`. |

If still failing: *"Reset failed on \<pod(s)\>: \<reason\>. Restart the pods instead (Step 4)?"*

---

## Step 3b: Clear FS Secondary Tier (3-tier TieringOffloadingSpec, vLLM ≥ 0.24.0)

**Run this immediately after Step 3 succeeds when the deployment uses `TieringOffloadingSpec`.**

**How the reset works across all 3 tiers (verified with vLLM 0.24.0):**

| Tier | After Step 3 (API) | Needs Step 3b? |
|------|--------------------|----------------|
| GPU primary | Index + data cleared | No |
| CPU mmap (`/dev/shm/vllm_offload*.mmap`) | **Index cleared** by API — raw bytes remain in file, but the hash→block mapping is gone so no cache hits can be served from it | No (do NOT delete or zero this file while vLLM is running — it is mmap'd into the process) |
| FS secondary (`root_dir` path) | **Raw files persist** — the API does not delete them | **Yes** — needed to reclaim disk/memory space AND to prevent warm cache on pod restart when FS tier is PVC-backed |

Verify after Step 3: `vllm:external_prefix_cache_hits_total` should stay at `0` for new requests, confirming the CPU mmap index was cleared.

### 3b-1: Locate the FS secondary tier path

The path is the `root_dir` of each `fs`-type secondary tier in the pod's `--kv-transfer-config`. Read it straight from the pod spec — that config is the source of truth, not a guessed mount path:

```bash
# POD_NAMES is not carried over from earlier steps (the scripts set it in a
# subprocess), so derive it here from the same selector used in Step 1.
POD_NAMES=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

for POD in $POD_NAMES; do
  echo "=== $POD ==="
  # Extract every root_dir from the container command/args (the --kv-transfer-config JSON)
  FS_TIER_PATHS=$(kubectl get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{.spec.containers[*].command} {.spec.containers[*].args}' \
    | grep -oE '"root_dir"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' | sort -u)

  if [ -z "$FS_TIER_PATHS" ]; then
    echo "  No fs secondary tier in --kv-transfer-config — Step 3b not needed (1-tier GPU-only or 2-tier GPU+CPU; no FS tier)."
  else
    for p in $FS_TIER_PATHS; do
      kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "if [ -d \"$p\" ]; then echo \"  FS_TIER_PATH=$p\"; du -sh \"$p\" 2>/dev/null; else echo \"  configured path $p not present in pod\"; fi"
    done
  fi

  # CPU mmap is informational — its index was cleared by the API; do NOT delete this file
  kubectl exec -n "$NAMESPACE" "$POD" -- sh -c 'echo "  CPU mmap (index cleared by API, do not delete):"; ls -lh /dev/shm/vllm_offload*.mmap 2>/dev/null || echo "  (not found)"' 2>/dev/null
done
```

### 3b-2: Clear the FS tier files

Re-derives the `root_dir` per pod (self-contained) and deletes everything under it. `find … -mindepth 1 -delete` removes subdirectories and dotfiles (vLLM writes per-model subdirs, which a `rm -rf $p/*` glob would leave behind) and reports honestly when the tier was already empty. The `[ -n "$p" ]` check keeps `find` from ever running against an empty path:

```bash
POD_NAMES=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

for POD in $POD_NAMES; do
  FS_TIER_PATHS=$(kubectl get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{.spec.containers[*].command} {.spec.containers[*].args}' \
    | grep -oE '"root_dir"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/' | sort -u)
  for p in $FS_TIER_PATHS; do
    [ -n "$p" ] || continue
    echo -n "Clearing FS secondary tier $p on $POD ... "
    kubectl exec -n "$NAMESPACE" "$POD" -- sh -c "find \"$p\" -mindepth 1 -delete 2>/dev/null; echo OK"
  done
done
```

> **PVC-backed FS tier:** Run Step 3b before any pod restart to prevent the new pod from re-reading those files and starting warm. With tmpfs (`emptyDir medium: Memory`), the files disappear on pod death — Step 3b is only needed for in-session disk space reclaim.

---

## Step 4: Restart vLLM Pods

Use this step when either:
- **Step 3 could not run** — dev mode couldn't be enabled, or the API failed on every pod (works on any version), OR
- **The deployment runs vLLM < 0.24.0** — the API is a no-op for a 3-tier `TieringOffloadingSpec` cache, so a restart is the only way to wipe every tier.

The version distinction matters for 3-tier setups: on **vLLM < 0.24.0** a restart is the *only* way to get a clean cache — the CPU mmap data in `/dev/shm/vllm_offload*.mmap` and the secondary tiers survive the API call. On **vLLM ≥ 0.24.0**, Step 3 + Step 3b already gives a clean cache for benchmark runs (CPU mmap index cleared — verified by `vllm:external_prefix_cache_hits_total = 0` — and FS tier files deleted), so a restart is not needed for cache clearing and is only a fallback for the first bullet. Model reload takes ~1-2 min.

```bash
kubectl rollout restart deployment/$DEPLOYMENT_NAME -n $NAMESPACE
kubectl rollout status deployment/$DEPLOYMENT_NAME -n $NAMESPACE --timeout=300s
```

**Disaggregated prefill/decode:** restart **both** deployments (the `…-prefill` and `…-decode` from Step 1) — restarting one role leaves the other's KV cache intact:
```bash
# Set in Step 1; re-derive here if running standalone. Guard against empty so we never no-op silently.
: "${PREFILL_DEPLOYMENT:=$(kubectl get deployments -n $NAMESPACE -l llm-d.ai/role=prefill -o jsonpath='{.items[0].metadata.name}')}"
: "${DECODE_DEPLOYMENT:=$(kubectl get deployments -n $NAMESPACE -l llm-d.ai/role=decode -o jsonpath='{.items[0].metadata.name}')}"
for D in "$PREFILL_DEPLOYMENT" "$DECODE_DEPLOYMENT"; do
  [ -n "$D" ] || { echo "WARNING: a role deployment name is empty — check Step 1"; continue; }
  kubectl rollout restart deployment/$D -n $NAMESPACE
done
for D in "$PREFILL_DEPLOYMENT" "$DECODE_DEPLOYMENT"; do
  [ -n "$D" ] || continue
  kubectl rollout status deployment/$D -n $NAMESPACE --timeout=300s
done
```

Report success once rollout completes. The user can proceed immediately — no further verification needed.

---

## Step 5: Verification (Optional)

These are live gauges — they reflect current state without sending any requests:

```bash
POD=$(kubectl get pods -n $NAMESPACE -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NAMESPACE $POD -- \
  curl -s http://localhost:${VLLM_PORT:-8000}/metrics \
  | grep -E "vllm:kv_cache_usage_perc|vllm:cpu_kv_cache_usage_perc|vllm:external_prefix_cache_hits_total" \
  | grep -v "HELP\|TYPE"
```

| Method | Expected `kv_cache_usage_perc` | Expected `external_prefix_cache_hits_total` |
|--------|-------------------------------|---------------------------------------------|
| Step 3 (1-tier or 2-tier; also 3-tier on vLLM ≥ 0.24.0) | `0.0` | `0.0` — CPU tier index cleared (2/3-tier) |
| Step 3 + Step 3b (3-tier) | `0.0` | `0.0` + FS tier files deleted |
| Step 4 (pod restart) | `0.0` | `0.0` |

> Do **not** use `prefix_cache_hits_total` / `prefix_cache_queries_total` — these counters accumulate since pod start and never reset. Do **not** send requests to verify: that defeats the purpose of clearing the cache before a benchmark run.

---

## Important Notes

- **Disaggregated prefill/decode**: prefill and decode run as **separate deployments**, each with its own GPU/CPU/FS tiers. Reset **both roles** (Step 1 flags this) — clearing only decode leaves prefill's KV cache populated.
- **NixL connector**: a point-to-point KV *transport*, not a persistent store — transferred blocks live in each worker's own GPU/CPU/FS cache. Resetting **both** prefill and decode pods (Steps 3 + 3b on each) fully clears NixL-moved KV. `reset_external` itself is a no-op, but nothing beyond the per-worker reset is needed.
- **LMCache / Mooncake stores**: genuine shared/external KV stores that persist independently of the workers. `reset_external=true` does NOT clear them, and neither does a worker pod restart. Clear them by restarting or flushing their backing service (Redis, the Mooncake store, etc.) — **outside this skill's scope**.
- **Tier terminology** — the tier count is the number of cache levels:
  - **1-tier**: GPU KV cache only (no offloading configured).
  - **2-tier**: GPU + CPU (`CPUOffloadingSpec`) — the CPU tier is a host-DRAM mmap file at `/dev/shm/vllm_offload*.mmap`.
  - **3-tier**: GPU + CPU + **FS secondary tier** (`TieringOffloadingSpec`, the `root_dir` in the config).

  The FS tier is just a filesystem path — disk-backed (PVC) or memory-backed (tmpfs / `emptyDir medium: Memory`); either way Step 3b clears it with `find … -delete`. A memory-backed FS tier is sometimes loosely called a "memory tier," but it is still the FS `root_dir` and Step 3b handles it the same way.
- **CPU/memory offloading**: Step 3 with `reset_external=true` clears the CPU cache **only when `CPUOffloadingSpec` is used** (2-tier). For `TieringOffloadingSpec` (3-tier: GPU + CPU + FS), behavior is version-dependent:
  - **vLLM < 0.24.0**: `reset_external=true` is a no-op — neither GPU nor secondary tier is cleared. A pod restart (Step 4) is the only way to get a clean cache.
  - **vLLM ≥ 0.24.0** ([PR #44541](https://github.com/vllm-project/vllm/pull/44541)): the API drains in-flight transfers, resets the GPU primary tier, and clears the CPU mmap index (so no cache hits can be served from CPU data — verified by `vllm:external_prefix_cache_hits_total = 0`). Run Step 3b to also delete the FS secondary tier files. No pod restart is needed.
- **In-flight requests**: `reset_running_requests=true` terminates active requests. Use `false` to clear the cache without disrupting ongoing work.
- **Dev mode security**: `VLLM_SERVER_DEV_MODE=1` exposes internal endpoints. Disable after use in production-like environments.
- **Pod restarts**: Step 3 does not restart pods. Enabling dev mode (Step 2 option 1) does — but that clears the cache as a side effect, so no further reset is needed.
