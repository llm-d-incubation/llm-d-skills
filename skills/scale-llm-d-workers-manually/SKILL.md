---
name: scale-llm-d-workers-manually
description: Manually scale llm-d prefill/decode workers on Kubernetes/OpenShift. Supports immediate replica adjustments and suspend/resume operations for cost savings. Use for quick scaling changes, development/testing, or planned downtime.
---

# Scale llm-d Workers Manually

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

1. **Do NOT change cluster-level definitions** - All changes must be within the designated namespace. Never modify cluster-wide resources (ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes). Always scope commands with `-n ${NAMESPACE}`.

2. **Do NOT modify existing repository code** - Only create new files. Never edit pre-existing repository files. For customization, create new files and reference them.

3. **ALWAYS use existing skill scripts first** - Use scripts in [scripts](./scripts). Only perform manual edits if scripts fail due to non-standard deployment structure.

4. **Verify cluster resources** - Check available GPU/RDMA resources before applying changes.

## Overview

Manually scale prefill and decode workers in existing llm-d deployments:
- **Manual scaling** - Immediate replica adjustments via scripts or kubectl
- **Suspend/Resume** - Scale to zero for cost savings, restore to previous state
- **Direct control** - Predictable, immediate changes without autoscaling complexity

Works with P/D disaggregation, standard inference, and LeaderWorkerSet deployments.

## When to Use

| Operation | Use Cases |
|-----------|-----------|
| **Manual Scaling** | Quick adjustments for known workload changes. |
| **Suspend/Resume** | Off-hours cost savings.Free up cluster resources without deletion |

## Prerequisites

- Existing llm-d deployment in Kubernetes/OpenShift
- kubectl or oc CLI with appropriate permissions
- Sufficient cluster resources (GPUs, RDMA, memory) for scaling up

## Workflow

**CRITICAL RULES:**
1. **ALWAYS use existing scripts** from `skills/scale-llm-d-workers-manually/scripts/`
2. **NEVER create README.md files** - provide summaries in conversation only
3. **Script modifications** - If existing scripts need updates, copy them to your deployment directory and modify the copy. Never edit scripts in `scripts/` directly.
4. **Scripts run non-interactively by default** - designed for automation (use `-i` flag for interactive mode)

### Step 1: Detect Deployment

```bash
bash skills/scale-llm-d-workers-manually/scripts/detect-deployment.sh ${NAMESPACE}
```

### Step 2: Execute Scaling Operation

#### Option A: Manual Scaling

```bash
# Scale decode workers
bash skills/scale-llm-d-workers-manually/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}

# Scale prefill workers
bash skills/scale-llm-d-workers-manually/scripts/scale-workers.sh -n ${NAMESPACE} -t prefill -r ${COUNT}
```

#### Option B: Suspend/Resume Operations

> **⚠️ Known Issue**: The `scale-workers.sh` script may fail when deployments don't have the `llm-d.ai/role` label. Use direct kubectl commands as shown below.

**Suspend Workers (Scale to 0):**

```bash
# Step 1: Get deployment names and current replica counts
kubectl get deployments -n ${NAMESPACE} -o json | \
  jq -r '.items[] | select(.metadata.name | contains("decode") or contains("prefill")) | "\(.metadata.name) \(.spec.replicas)"'

# Step 2: Save replica counts to file (CRITICAL for resumption)
cat > worker-replicas-backup.txt <<EOF
# Worker Replica Counts - Saved on $(date -u +"%Y-%m-%d")
# Namespace: ${NAMESPACE}

DECODE_DEPLOYMENT=<decode-deployment-name>
DECODE_REPLICAS=<current-decode-count>

PREFILL_DEPLOYMENT=<prefill-deployment-name>
PREFILL_REPLICAS=<current-prefill-count>

# To resume, run:
# kubectl scale deployment \$DECODE_DEPLOYMENT --replicas=\$DECODE_REPLICAS -n ${NAMESPACE}
# kubectl scale deployment \$PREFILL_DEPLOYMENT --replicas=\$PREFILL_REPLICAS -n ${NAMESPACE}
EOF

# Step 3: Suspend workers (scale to 0)
kubectl scale deployment <decode-deployment-name> --replicas=0 -n ${NAMESPACE}
kubectl scale deployment <prefill-deployment-name> --replicas=0 -n ${NAMESPACE}

# Step 4: Verify suspension
kubectl get deployments -n ${NAMESPACE} <decode-deployment-name> <prefill-deployment-name>
```

**Resume Workers (Restore from Backup):**

```bash
# Load saved replica counts and restore
source worker-replicas-backup.txt
kubectl scale deployment $DECODE_DEPLOYMENT --replicas=$DECODE_REPLICAS -n ${NAMESPACE}
kubectl scale deployment $PREFILL_DEPLOYMENT --replicas=$PREFILL_REPLICAS -n ${NAMESPACE}
```

**Why Save to File:**
- Deployments may not have `llm-d.ai/role` labels for annotation-based tracking
- File backup provides reliable, human-readable record of previous state
- Enables easy resumption even if annotations are lost or unavailable
- Serves as documentation for operational changes

### Output Format

**Correct:** Execute scripts, provide brief summary (3-5 sentences)

**WRONG:**
- ❌ Create README.md, monitoring-guide.md, or any documentation files

## Scaling Methods

**Deployment Type Detection:** Auto-detected in Step 1

| Deployment Type | Scaling Method |
|----------------|----------------|
| **Standard Deployment** | `scale-workers.sh` script or `kubectl scale deployment` |
| **LeaderWorkerSet** | `kubectl scale leaderworkerset` |

**Execution Examples:**
```bash
# Using script (recommended) - auto-detects deployment type
bash skills/scale-llm-d-workers-manually/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}

# Interactive mode (optional)
bash skills/scale-llm-d-workers-manually/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT} -i

# Direct kubectl (standard deployments)
kubectl scale deployment <name> --replicas=${COUNT} -n ${NAMESPACE}

# Direct kubectl (LeaderWorkerSet)
kubectl scale leaderworkerset <name> --replicas=${COUNT} -n ${NAMESPACE}
```

## Scaling Characteristics

**kubectl Scaling Benefits:**
- ✅ No pod restarts - existing pods keep in-memory vLLM cache intact
- ✅ Immediate effect - new pods added/removed without disruption
- ⚠️ **Helm-managed deployments:** kubectl scaling creates drift from values.yaml. Running `helmfile apply` later reverts to values.yaml replica count.

**Cache Implications:**
- **Existing pods:** Retain in-memory HBM prefix cache (no performance impact)
- **New pods:** Start with empty cache, require warmup period
- **Shared storage:** Tiered prefix cache with CephFS/Lustre persists across pods
- **Performance:** Expect temporary TTFT increase for new pods during warmup

**Best Practices:**
1. Use kubectl scaling for quick, non-disruptive adjustments
2. Document scaling changes for Helm-managed deployments to track drift
3. Use shared storage backends in production to minimize cache warmup impact
4. **Always save replica counts to a file before suspending** - enables reliable resumption
5. Always suspend both worker types together to avoid resource waste
6. Verify deployment names and counts before scaling operations
7. Test resume in non-production first

**Adjustment Recommendations:**
- If user requests mismatched ratios (e.g., 1 decode + 20 prefill for high-output), suggest reversing
- For equal workers with skewed workload, recommend adjusting based on ISL/OSL
- Always explain reasoning based on expected input/output sequence lengths

## Post-Scaling Verification

After scaling, verify the workers are running:
```bash
kubectl get pods -n ${NAMESPACE} | grep -E "(decode|prefill)"
kubectl get deployments -n ${NAMESPACE} | grep -E "(decode|prefill)"
```

If issues occur, check pod status with `kubectl describe pod <pod-name> -n ${NAMESPACE}`.

## Troubleshooting

For common issues and solutions, see [Troubleshooting.md](./Troubleshooting.md).

## Related Skills

For automatic scaling based on workload metrics, see:
- [`autoscale-llm-d-workers`](../autoscale-llm-d-workers/SKILL.md) - WVA and HPA-based autoscaling