---
name: cache-config-llm-d
description: Modify cache memory settings in existing llm-d deployments without full redeployment. Adjust GPU memory utilization, KV cache capacity, shared memory, block size, and context length to optimize performance for different workload patterns. Use when you need to tune cache settings, increase throughput, reduce latency, or support longer contexts.
---

# llm-d Cache Configuration Skill

## 📋 Command Execution Notice

**Before executing any command, I will:**
1. **Explain what the command does** - Clear description of purpose and expected outcome
2. **Show the actual command** - The exact command to be executed
3. **Explain why it's needed** - How it fits into the workflow

> ## 🔔 ALWAYS NOTIFY BEFORE CREATING RESOURCES
>
> **RULE**: Before creating ANY resource (namespaces, files, Kubernetes objects), notify the user first.
>
> **Format**: "I am about to create `<resource-type>` named `<name>` because `<reason>`. Proceeding now."
>
> **Never silently create resources.** Check existence first, then notify before acting.

## Critical Rules

1. **ALWAYS use existing skill scripts first** - Use `show-current-config.sh` and `update-cache-config.sh` before manual edits. Only perform manual edits if scripts fail due to non-standard deployment structure.

2. **Check for existing resources** - Before deployment, check for old/conflicting deployments and clean them up. Use `helm list -n ${NAMESPACE}` and `kubectl get all -n ${NAMESPACE}`.

3. **Verify cluster resources** - Check available GPU/RDMA resources before applying changes. Use `kubectl describe nodes` to verify capacity.

4. **Do NOT change cluster-level definitions** - All changes must be within the designated namespace. Never modify cluster-wide resources. Always scope commands with `-n ${NAMESPACE}`.

5. **Do NOT modify existing repository code** - Only create new files. Never edit pre-existing repository files.

6. **Script modifications** - If existing scripts need updates, copy them to your deployment directory and modify the copy. Never edit scripts in `skills/llmd-cache-config/scripts/` directly.

## Overview

Modify cache settings in existing llm-d deployments: GPU memory utilization, block size, max context length, and shared memory (SHM). Changes apply via rolling updates with automatic backups.

**For deployments with CPU offloading already enabled**: You can also tune CPU cache size and InferencePool prefix cache scorer configurations.

**Note**: Initial setup of tiered prefix cache offloading (CPU RAM, local disk, or shared storage) requires redeployment. See [`guides/tiered-prefix-cache/README.md`](../../guides/tiered-prefix-cache/README.md) for new deployments.

## When to Use

This skill enables you to tune cache performance without redeployment:

- **GPU Memory Utilization** (`-g`): Adjust GPU memory allocation (0.0-1.0) to balance throughput vs. OOM risk
- **Block Size** (`-b`): Change cache granularity (16-128 tokens) to optimize cache hit rates and memory efficiency
- **Max Context Length** (`-m`): Extend or reduce maximum context window to support longer documents or save memory
- **Shared Memory** (`-s`): Configure SHM size for multi-GPU tensor parallelism setups
- **CPU Cache Size**: Tune CPU offloading capacity for deployments with tiered caching already enabled
- **Prefix Cache Routing**: Adjust InferencePool scorer weights to optimize cache-aware request scheduling


## Workflow

### 1. Check Current Configuration

```bash
bash skills/llmd-cache-config/scripts/show-current-config.sh ${NAMESPACE}
```

### 2. Update Settings

**Preview first:**
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -g 0.90 -b 32 --dry-run
```

**Apply:**
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -g 0.90 -b 32
```

**Options:**
- `-g <value>` - GPU memory utilization (0.0-1.0)
- `-b <value>` - Block size in tokens (16-128)
- `-m <value>` - Max model length in tokens
- `-s <value>` - Shared memory size (e.g., 20Gi, 30Gi)

### 3. Verify

```bash
kubectl get pods -n ${NAMESPACE}
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep -E "gpu_memory_utilization|block_size"
```

## Tuning CPU Cache (If Already Enabled)

If your deployment already has CPU offloading enabled via OffloadingConnector or LMCache, you can tune the CPU cache size and InferencePool configuration.

### Adjust CPU Cache Size

**For vLLM OffloadingConnector:**

Edit the deployment to modify `cpu_bytes_to_use` in the `--kv-transfer-config` argument:

```bash
kubectl edit deployment <model-server-name> -n ${NAMESPACE}
```

Find and modify the `cpu_bytes_to_use` value (in bytes):
```yaml
--kv-transfer-config '{"kv_connector":"OffloadingConnector","kv_role":"kv_both","kv_connector_extra_config":{"cpu_bytes_to_use":107374182400}}'
```

Example: Change from 100GB (107374182400) to 150GB (161061273600)

**For LMCache Connector:**

Edit the deployment to modify the `LMCACHE_MAX_LOCAL_CPU_SIZE` environment variable:

```bash
kubectl edit deployment <model-server-name> -n ${NAMESPACE}
```

Find and modify the environment variable (in GB):
```yaml
- name: LMCACHE_MAX_LOCAL_CPU_SIZE
  value: "200.0"  # Change to desired size in GB
```

### Tune InferencePool Prefix Cache Scorers

**What are prefix cache scorers?**
The InferencePool uses scorers to decide which server should handle each request. When CPU offloading is enabled, you configure separate scorers for GPU cache and CPU cache to help route requests to servers that already have relevant cached data.

**Tuning the configuration:**

```bash
helm upgrade llm-d-infpool -n ${NAMESPACE} -f <your-values-file> \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool --version v1.4.0
```

**Key parameters:**

1. **`lruCapacityPerServer`**: Total CPU cache capacity per server (in blocks)
   - Must be manually configured since vLLM doesn't emit CPU block metrics
   - Example: `41000` blocks = ~100GB for Qwen-32B (41,000 blocks × 2.5MB/block)
   - Calculation: 160KB/token × 16 block size = 2.5MB/block
   - Adjust based on your model's block size (check vLLM logs)

2. **Scorer weights**: Balance how the InferencePool prioritizes different factors
   - Default: queue (2.0), kv-cache-util (2.0), gpu-prefix (1.0), cpu-prefix (1.0)
   - CPU cache is a superset of GPU cache (CPU offloading copies GPU entries to CPU)
   - Combined GPU + CPU prefix scorer weight (1.0 + 1.0 = 2.0) balances with other scorers
   - Tune the ratio between GPU and CPU scorers based on your workload

See [`guides/tiered-prefix-cache/cpu/manifests/inferencepool/values.yaml`](../../guides/tiered-prefix-cache/cpu/manifests/inferencepool/values.yaml) for full configuration example.

## Common Scenarios

### Increase Cache Hit Rate
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -g 0.88 -b 32
```
Reduces GPU memory (0.95→0.88) for more cache, decreases block size (64→32) for finer matching.

### Support Longer Contexts
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -m 16384 -g 0.85 -s 30Gi
```
Increases max length (8192→16384), reduces GPU memory (0.95→0.85), increases SHM (20Gi→30Gi).

### Maximize Throughput
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -g 0.95 -b 64
```
Increases GPU memory (0.90→0.95) for more capacity, standard block size (32→64).

### Fix OOM Errors
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -g 0.85
```
Reduces GPU memory (0.95→0.85) to reduce memory pressure.

### Adjust Shared Memory for Multi-GPU
```bash
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n ${NAMESPACE} -s 50Gi
```
Increases SHM (20Gi→50Gi) based on tensor parallelism configuration.

### Manual Edits for Non-Standard Deployments
If script fails, manually edit configuration files:
1. Update `values-modelservice.yaml`: Change `--block-size` and `--gpu-memory-utilization`
2. Update `values-inferencepool.yaml`: Adjust `lruCapacityPerServer`
3. Apply: `cd deployment-dir && helmfile apply -n ${NAMESPACE}`
4. Verify: `kubectl rollout status deployment/<name> -n ${NAMESPACE}`

## Non-Standard Deployment Patterns

For deployments with custom directory structures or file naming:

**Using Scripts:**
```bash
# Specify deployment directory explicitly
bash skills/llmd-cache-config/scripts/update-cache-config.sh \
  -d deployments/your-deployment -n ${NAMESPACE} -g 0.95 -b 64
```

**Manual Updates:**
1. Locate your ModelService and InferencePool values files
2. Edit ModelService values for `--block-size` and `--gpu-memory-utilization`
3. **Important**: When changing block size, recalculate InferencePool cache capacities:
   - Formula: `new_capacity = old_capacity × (old_block_size / new_block_size)`
   - Example: 32→64 blocks: GPU cache 31,250→15,625, CPU cache 41,000→20,500
4. Apply changes: `cd deployment-dir && helmfile apply -n ${NAMESPACE}`

## Validation and Rollback

### Validate Configuration Consistency

Before applying changes, verify:
```bash
# Check block size consistency
kubectl get deployment -n ${NAMESPACE} -o yaml | grep "block-size"

# Verify cache capacity calculations
kubectl get inferencepool -n ${NAMESPACE} -o yaml | grep "lruCapacityPerServer"

# Check SHM allocation
kubectl get pods -n ${NAMESPACE} -o yaml | grep -A 2 "shm"
```

### Rollback Procedure

If changes cause issues:
```bash
# Automatic backups are created in deployments/<name>/backups/
cd deployments/<name>/backups/

# Restore from backup
cp backup-DDMMYYYY-HHMMSS/ms-values.yaml ../ms-values.yaml
cp backup-DDMMYYYY-HHMMSS/gaie-values.yaml ../gaie-values.yaml

# Reapply
cd ..
helmfile apply -n ${NAMESPACE}

# Verify rollback
kubectl rollout status deployment/<name> -n ${NAMESPACE}
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep -E "gpu_memory_utilization|block_size"
```

## Monitoring

### Monitoring Commands
```bash
# KV Cache Usage
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep "kv_cache_usage"

# GPU Memory
kubectl exec <pod> -n ${NAMESPACE} -- nvidia-smi

# Cache Hit Rate
kubectl logs -l inferencepool=<pool> -n ${NAMESPACE} | grep "cache_hit_rate"
```

## Troubleshooting Guidance

For detailed troubleshooting guidance, see [TROUBLESHOOTING.md](./references/TROUBLESHOOTING.md).


## Pre-Deployment Checklist

Before applying cache configuration changes:

1. **Check for old deployments** ask user before cleanup:
   ```bash
   helm list -n ${NAMESPACE}
   kubectl get all -n ${NAMESPACE}
   ```
   If old deployments exist, **ask user**: "Found old deployments [list]. Should I clean them up?"
   Only proceed with cleanup after user approval.

2. **Verify cluster resources**:
   ```bash
   kubectl describe nodes | grep -A 5 "Allocated resources"
   kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.allocatable."nvidia\.com/gpu"
   ```

3. **Check current configuration**:
   ```bash
   bash skills/llmd-cache-config/scripts/show-current-config.sh ${NAMESPACE}
   ```

4. **Preview changes with --dry-run**:
   ```bash
   bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -g 0.95 --dry-run
   ```

## Safety Guidelines

- ✅ **NEVER delete resources without user approval**
- ✅ Check for conflicting deployments, ask before cleanup
- ✅ Verify sufficient cluster resources (GPU, RDMA, memory)
- ✅ Always check current config first
- ✅ Use `--dry-run` to preview changes
- ✅ Automatic backups created in `deployments/<name>/backups/`
- ✅ Rolling updates maintain availability
- ✅ Verify settings in pod logs after changes

### Guides
- **[Tiered Prefix Cache](../../guides/tiered-prefix-cache/README.md)**: Comprehensive guide on prefix cache offloading strategies
  - **[CPU Offloading](../../guides/tiered-prefix-cache/cpu/README.md)**: Initial setup requires redeployment; tuning can be done on existing deployments
  - **[Storage Offloading](../../guides/tiered-prefix-cache/storage/README.md)**: Requires redeployment
- **[Inference Scheduling](../../guides/inference-scheduling/README.md)**: Prefix-aware request scheduling optimizations

## Scripts Reference

See [scripts/README.md](scripts/README.md) for detailed documentation.