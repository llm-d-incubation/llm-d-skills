# llm-d Cache Configuration Scripts

Helper scripts for modifying cache settings in llm-d deployments.

## Scripts

### show-current-config.sh

Display current cache configuration for a deployment.

**Usage:**
```bash
bash .claude/skills/llmd-cache-config/scripts/show-current-config.sh <namespace>
```

**Example:**
```bash
bash .claude/skills/llmd-cache-config/scripts/show-current-config.sh llmd-ns
```

**Output:**
- GPU memory utilization
- Block size
- Max model length
- Shared memory (SHM) size
- Tensor parallelism
- InferencePool configuration
- Resource usage

### update-cache-config.sh

Update cache configuration and apply changes with rolling update.

**Usage:**
```bash
bash .claude/skills/llmd-cache-config/scripts/update-cache-config.sh -n <namespace> [options]
```

**Options:**
- `-n <namespace>` - Target namespace (required)
- `-g <value>` - GPU memory utilization (0.0-1.0)
- `-b <value>` - Block size in tokens
- `-m <value>` - Max model length in tokens
- `-s <value>` - Shared memory size (e.g., 20Gi, 30Gi)
- `-d <dir>` - Deployment directory (auto-detected)
- `-r <name>` - Helm release name (auto-detected)
- `--dry-run` - Preview changes without applying

**Examples:**

Increase cache capacity:
```bash
bash .claude/skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n llmd-ns -g 0.90 -b 32
```

Support longer contexts:
```bash
bash .claude/skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n llmd-ns -m 16384 -g 0.85 -s 30Gi
```

Preview changes:
```bash
bash .claude/skills/llmd-cache-config/scripts/update-cache-config.sh \
  -n llmd-ns -g 0.90 --dry-run
```

**Features:**
- Auto-detects deployment directory
- Backs up configuration files
- Updates both ms-values.yaml and gaie-values.yaml (if needed)
- Applies changes with helmfile
- Verifies rollout completion
- Provides rollback instructions

## Quick Reference

### Cache Parameters

| Parameter | Location | Default | Range | Purpose |
|-----------|----------|---------|-------|---------|
| GPU Memory Utilization | `--gpu-memory-utilization` | 0.95 | 0.0-1.0 | Controls KV cache capacity |
| Block Size | `--block-size` | 64 | 16-128 | Cache granularity for prefix matching |
| Max Model Length | `--max-model-len` | Model-specific | Up to model max | Maximum context window |
| Shared Memory | `sizeLimit` | 20Gi | 10Gi-50Gi | IPC for multi-GPU setups |

### Common Scenarios

**Increase cache hit rate:**
```bash
-g 0.90 -b 32
```

**Support longer contexts:**
```bash
-m 16384 -g 0.85 -s 30Gi
```

**Maximize throughput:**
```bash
-g 0.95 -b 64
```

**High tensor parallelism (TP=8):**
```bash
-s 40Gi
```

## Workflow

1. **Check current config:**
   ```bash
   bash show-current-config.sh <namespace>
   ```

2. **Preview changes:**
   ```bash
   bash update-cache-config.sh -n <namespace> -g 0.90 --dry-run
   ```

3. **Apply changes:**
   ```bash
   bash update-cache-config.sh -n <namespace> -g 0.90
   ```

4. **Verify:**
   ```bash
   kubectl get pods -n <namespace>
   kubectl logs <pod> -n <namespace> | grep gpu_memory_utilization
   ```

## Troubleshooting

**Script can't find deployment directory:**
- Specify with `-d` option: `-d deployments/deploy-<name>`

**Changes not applied:**
- Check Helm release: `helm list -n <namespace>`
- Force restart: `kubectl rollout restart deployment/<name> -n <namespace>`

**Block size mismatch warning:**
- Script automatically updates both ms-values.yaml and gaie-values.yaml
- Verify: `bash show-current-config.sh <namespace>`

## Safety

- All changes create timestamped backups in `deployments/<name>/backups/`
- Rolling updates maintain availability (zero downtime)
- Use `--dry-run` to preview changes first
- Rollback instructions provided after each update