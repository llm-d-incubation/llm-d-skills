# llm-d Worker Scaling Scripts

Helper scripts for scaling prefill and decode workers in llm-d deployments.

## Scripts

### detect-deployment.sh
Detects and displays current llm-d deployment state.

**Usage:**
```bash
bash detect-deployment.sh [NAMESPACE]
```

**Output:**
- Helm releases
- Deployments and LeaderWorkerSets
- Current worker pods (decode/prefill)
- Replica counts

### scale-workers.sh
Scales decode or prefill workers to a target replica count.

**Usage:**
```bash
bash scale-workers.sh -n NAMESPACE -t TYPE -r REPLICAS [-d DEPLOYMENT_NAME] [-m METHOD]
```

**Options:**
- `-n` Namespace (required)
- `-t` Worker type: decode|prefill (required)
- `-r` New replica count (required)
- `-d` Deployment name (auto-detected if not provided)
- `-m` Method: kubectl|helm (default: kubectl)

**Examples:**
```bash
# Scale decode workers to 3
bash scale-workers.sh -n llmd-ns -t decode -r 3

# Scale prefill workers to 8
bash scale-workers.sh -n llmd-ns -t prefill -r 8
```

### check-resources.sh
Checks available cluster resources for scaling validation.

**Usage:**
```bash
bash check-resources.sh [NAMESPACE]
```

**Output:**
- GPU availability
- RDMA availability
- Memory usage
- Current pod resource usage

## Prerequisites

All scripts require:
- kubectl or oc CLI configured
- Access to target namespace
- Appropriate RBAC permissions

## Notes

- Scripts use `set -e` for fail-fast behavior
- Auto-detection features require proper llm-d labels
- Interactive prompts can be bypassed with `-y` flag (where applicable)