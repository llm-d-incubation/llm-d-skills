# Triaging a `stopped` / never-`is_sleeping` instance

## The signature

The controller creates the instance, then polls `GET :8000/is_sleeping` and gets
connection-refused indefinitely; the launcher reports the instance as `stopped`;
the requester never reaches Ready; the run times out with 0 iterations. This one
signature has **at least four distinct root causes**. The `stopped` state and the
missing `is_sleeping` 200 are symptoms, not the cause — they only tell you the
forked vLLM child never bound `:8000`.

## Attribution: read the child log

The controller log only shows the symptom. The actual failure is in the launcher
**child** log inside the launcher pod at `/tmp/launcher-*-vllm-*.log` (not
container stdout). Those logs rotate as instances recycle, so freeze one:

```
LP=$(kubectl get pods -n $NS -l app.kubernetes.io/component=launcher -o name | head -1)
kubectl exec -n $NS ${LP#pod/} -c inference-server -- \
  bash -c 'mkdir -p /tmp/frozen; while true; do for f in /tmp/launcher-*-vllm-*.log; do [ -e "$f" ] && cp -n "$f" /tmp/frozen/$(basename "$f").$(date +%s); done; sleep 1; done' &
# then, after a recycle:
kubectl cp $NS/${LP#pod/}:/tmp/frozen ./child-logs -c inference-server
```

## The four root causes

| Cause | Child-log tell | Fix |
|-------|----------------|-----|
| KV-cache OOM at sampler warmup | `torch.OutOfMemoryError ... Tried to allocate ...` then `EngineCore failed to start` | Cap KV cache — `kv-cache-oom.md`. Tracked at <https://github.com/llm-d/llm-d-benchmark/pull/1791>. |
| Launcher SA lacks `patch pods` (RBAC) | state-change-reflector container: `(403) ... cannot patch resource "pods"` | Current checkouts provision the launcher SA + Role at standup. Tracked at <https://github.com/llm-d/llm-d-benchmark/pull/1799>. On an old checkout, apply a Role granting `pods: get,patch` bound to the launcher SA. |
| Broken / incomplete hub download or full PVC | `Not enough free disk space ... 0.00 MB free` / `OSError: [Errno 122] Disk quota exceeded` | Free the PVC and load from the complete staged local copy via `fma.launcher.loadModelFromLocalDir` — `big-models.md`. |
| Wake / bind race or slow cold boot | No crash in the child log; boot simply does not finish binding `:8000` within the harness patience window | Pre-warm the shared compile cache, or (last resort) `fma.launcher.enforceEager=true` to skip compile/capture. |

## Rule

Never attribute this signature from the controller log alone. Freeze and read the
child log first — the fix differs entirely by cause. If the child log was lost to
rotation, re-run and capture it before proposing a fix.
