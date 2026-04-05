# Troubleshooting Guidance

## Common Issues

### Deployment Issues

#### Helm Secret Conflict
**Symptom**: `Secret "xxx" exists and cannot be imported into the current release: invalid ownership metadata`

**Root Cause**: Secret was owned by a previous Helm release with a different name. Helm tracks resource ownership via annotations and cannot automatically adopt resources from other releases.

**Solution**:
```bash
# Delete the conflicting secret
kubectl delete secret <secret-name> -n ${NAMESPACE}

# Then retry helmfile apply
helmfile apply -n ${NAMESPACE}
```

**Prevention**: Clean up old deployments before creating new ones with different release names.

#### Pods Pending - Insufficient Resources
**Symptom**: `0/X nodes available: Y Insufficient nvidia.com/gpu, Z Insufficient rdma/ib`

**Root Cause**: Insufficient GPU or RDMA resources in cluster.

**Solutions**:

1. **Check resources first**:
   ```bash
   kubectl describe nodes | grep -A 5 "Allocated resources"
   kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.allocatable."nvidia\.com/gpu"
   ```

2. **Clean up old deployments** (ask user first):
   ```bash
   helm list -n ${NAMESPACE}
   # Ask user: "Found releases [X, Y]. Should I uninstall them?"
   # Only after approval: helm uninstall <release> -n ${NAMESPACE}
   ```

3. **Scale down replicas**:
   ```bash
   kubectl scale deployment <prefill-deployment> --replicas=1 -n ${NAMESPACE}
   kubectl scale deployment <decode-deployment> --replicas=2 -n ${NAMESPACE}
   ```

4. **Make RDMA optional** (edit values file, comment out `rdma/ib` from resources)

#### Script Can't Find Deployment Files
**Symptom**: `Error: Could not find ModelService values file`

**Root Cause**: Script auto-detection expects standard file patterns but deployment uses different structure.

**Solutions**:

1. **For standard deployments**:
   ```bash
   bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -g 0.95
   ```

2. **For custom directory structures**:
   ```bash
   # Specify deployment directory explicitly
   bash skills/llmd-cache-config/scripts/update-cache-config.sh \
     -d deployments/your-deployment -n ${NAMESPACE} -g 0.95 -b 64
   ```

3. **For non-standard file naming**:
   - Manually edit the values files
   - Follow the manual update procedure in SKILL.md

### Configuration Issues

#### InferencePool Cache Capacity Mismatch After Block Size Change
**Symptom**: After changing block size, cache hit rates drop or InferencePool routing becomes inefficient.

**Root Cause**: When block size changes, the InferencePool cache capacities (`lruCapacityPerServer`) must be recalculated. The script may not automatically update these values.

**Solution**:
```bash
# Manual calculation formula:
# new_capacity = old_capacity × (old_block_size / new_block_size)

# Example: Changing from block size 32 to 64
# GPU cache: 31,250 × (32/64) = 15,625 blocks
# CPU cache: 41,000 × (32/64) = 20,500 blocks

# Edit your InferencePool values file
# Update lruCapacityPerServer for both gpu-prefix-cache-scorer and cpu-prefix-cache-scorer
```

**Verification**:
```bash
# Check InferencePool configuration
kubectl get inferencepool -n ${NAMESPACE} -o yaml | grep -A 5 "lruCapacityPerServer"

# Verify block size in ModelService
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep "block_size"
```

#### Block Size Inconsistency Between ModelService and InferencePool
**Symptom**: Cache routing inefficiency, unexpected cache misses.

**Root Cause**: ModelService and InferencePool have different block size configurations.

**Solution**:
```bash
# Check ModelService block size
kubectl get deployment -n ${NAMESPACE} -o yaml | grep "block-size"

# Check InferencePool configuration
kubectl get inferencepool -n ${NAMESPACE} -o yaml | grep -A 10 "prefixCacheScorers"

# Ensure both use the same block size
# Update both configurations to match
```

### Runtime Issues

#### OOM Errors
**Symptom**: Pods crash with out-of-memory errors.

**Solutions**:
```bash
# Reduce GPU memory utilization
bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -g 0.85

# Reduce max model length
bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -m 4096

# Check actual GPU memory usage
kubectl exec <pod> -n ${NAMESPACE} -- nvidia-smi
```

#### Low Cache Hit Rate
**Symptom**: Cache hit rate metrics show low values.

**Solutions**:
```bash
# Decrease block size for finer-grained matching
bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -b 32

# Reduce GPU memory to allocate more blocks
bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -g 0.88 -b 32

# Verify block size consistency
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep "block_size"
kubectl get inferencepool -n ${NAMESPACE} -o yaml | grep "lruCapacityPerServer"
```

#### SHM Errors
**Symptom**: Errors related to shared memory allocation, especially with tensor parallelism > 2.

**Solutions**:
```bash
# Increase shared memory size
bash skills/llmd-cache-config/scripts/update-cache-config.sh -n ${NAMESPACE} -s 40Gi

# Verify SHM allocation
kubectl exec <pod> -n ${NAMESPACE} -- df -h /dev/shm

# For TP=4, recommended SHM: 30-40Gi
# For TP=8, recommended SHM: 50-60Gi
```

#### Pods Not Restarting After Configuration Change
**Symptom**: Configuration changes applied but pods still running with old settings.

**Solutions**:
```bash
# Force rolling restart
kubectl rollout restart deployment/<deployment-name> -n ${NAMESPACE}

# Monitor rollout status
kubectl rollout status deployment/<deployment-name> -n ${NAMESPACE}

# Verify new configuration in logs
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep -E "gpu_memory_utilization|block_size"
```

## Pre-Deployment Checklist

See SKILL.md for complete checklist. Key points:
- Check for old deployments (ask user before cleanup)
- Verify cluster resources
- Review current config
- Preview with `--dry-run`

## Rollback Procedure

If configuration changes cause issues:

```bash
# Navigate to backup directory
cd deployments/<deployment-name>/backups/

# List available backups
ls -lt

# Restore from most recent backup (adjust paths based on your deployment structure)
cp backup-DDMMYYYY-HHMMSS/<modelservice-values-file> ../<modelservice-values-file>
cp backup-DDMMYYYY-HHMMSS/<inferencepool-values-file> ../<inferencepool-values-file>

# Reapply configuration
cd ..
helmfile apply -n ${NAMESPACE}

# Verify rollback
kubectl rollout status deployment/<deployment-name> -n ${NAMESPACE}
kubectl logs -l llm-d.ai/role=decode -n ${NAMESPACE} | grep -E "gpu_memory_utilization|block_size"
```

## Getting Help

**Debug commands**:
- Pod events: `kubectl describe pod <pod-name> -n ${NAMESPACE}`
- Pod logs: `kubectl logs <pod-name> -n ${NAMESPACE}`
- InferencePool logs: `kubectl logs -l inferencepool=<pool-name> -n ${NAMESPACE}`
- Helm status: `helm status <release-name> -n ${NAMESPACE}`

**When filing issues**, include: deployment structure, config changes, error logs, and resource availability.
