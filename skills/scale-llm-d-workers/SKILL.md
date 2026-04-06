---
name: scale-llm-d-workers
description: Execute scaling actions for llm-d prefill/decode workers on Kubernetes/OpenShift. Supports manual scaling (immediate adjustments), automatic WVA autoscaling (continuous saturation-based), HPA with IGW metrics, and suspend/resume operations. Use for handling load changes, optimizing worker ratios, cost savings, or setting up autoscaling.
---

# llm-d Worker Scaling Skill

> **Version Compatibility**: This skill supports **WVA v0.5.1**. Ensure all version references match this version for compatibility.

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

Scale prefill and decode workers in existing llm-d deployments without full redeployment:
- **Manual scaling** - Immediate adjustments via scripts or kubectl
- **Automatic scaling (WVA)** - Continuous saturation-based autoscaling for multi-variant deployments
- **HPA + IGW Metrics** - Native Kubernetes HPA with Inference Gateway metrics for single-model deployments
- **Suspend/Resume** - Scale to zero for cost savings, restore to previous state

Works with P/D disaggregation, standard inference, and LeaderWorkerSet deployments.

## When to Use

| Method | Use Cases |
|--------|-----------|
| **Manual Scaling** | Quick adjustments for known workload changes<br>Development/testing environments<br>P/D disaggregation or Wide-EP deployments<br>Immediate, predictable control needed |
| **Automatic Scaling (WVA)** | Multi-variant deployments on heterogeneous hardware<br>Cost-aware capacity allocation across variants<br>Intelligent Inference Scheduling deployments only<br>Requires WVA controller and VariantAutoscaling CRD |
| **HPA + IGW Metrics** | Single-model deployments on homogeneous hardware<br>Native Kubernetes HPA with queue depth/running requests<br>Simpler setup than WVA (no additional controllers)<br>Supports scale-to-zero with HPA alpha features or KEDA |
| **Suspend/Resume** | Off-hours cost savings<br>Maintenance windows or planned downtime<br>Free up cluster resources without deletion |

## Prerequisites

- Existing llm-d deployment in Kubernetes/OpenShift
- kubectl or oc CLI with appropriate permissions
- Sufficient cluster resources (GPUs, RDMA, memory)

## Workflow

**CRITICAL RULES:**
1. **ALWAYS use existing scripts** from `skills/scale-llm-d-workers/scripts/`
2. **NEVER create README.md files** - provide summaries in conversation only
3. **Script modifications** - If existing scripts need updates, copy them to your deployment directory and modify the copy. Never edit scripts in `scripts/` directly.
4. **Scripts run non-interactively by default** - designed for automation (use `-i` flag for interactive mode)

### Step 1: Detect Deployment

```bash
bash skills/scale-llm-d-workers/scripts/detect-deployment.sh ${NAMESPACE}
```

### Step 2: Execute Scaling Action

**Choose Your Autoscaling Approach:**

#### Option A: WVA Autoscaling (Multi-Variant Deployments)

Best for: Multiple models/variants on shared GPU hardware with cost optimization

```bash
# Deploy WVA controller (v0.5.1)
NAMESPACE=${NAMESPACE} bash skills/scale-llm-d-workers/scripts/deploy-wva-controller.sh

# Create VariantAutoscaling resource (requires scaleTargetRef in v0.5.1)
bash skills/scale-llm-d-workers/scripts/create-variantautoscaling.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME}-autoscaler ${TARGET_DEPLOYMENT}

# If auto-detection fails (unhealthy pods), use manual creation:
bash skills/scale-llm-d-workers/scripts/create-variantautoscaling-manual.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME}-autoscaler ${TARGET_DEPLOYMENT} "model/id"

# Fix RBAC if controller shows permission errors
bash skills/scale-llm-d-workers/scripts/fix-wva-rbac.sh ${NAMESPACE}

# If controller doesn't detect resources, fix labels
bash skills/scale-llm-d-workers/scripts/fix-controller-instance-labels.sh ${NAMESPACE}
```

**Breaking Change in v0.5.1**: The `scaleTargetRef` field is now **required** in VariantAutoscaling CRD. See [guides/workload-autoscaling/README.wva.md](../../guides/workload-autoscaling/README.wva.md#upgrading) for migration steps.

**Common Issues:**
- **RBAC errors**: Controller needs pods list/watch permissions → use `fix-wva-rbac.sh`
- **Unhealthy deployments**: Auto-detection fails → use `create-variantautoscaling-manual.sh` with model ID from prefill pods
- **Model ID detection**: Query from prefill if decode is down: `kubectl exec deployment/prefill-name -- curl -s localhost:8000/v1/models`

**Controller Deployment Reference**: See [WVA_CONTROLLER_DEPLOYMENT.md](WVA_CONTROLLER_DEPLOYMENT.md) for full WVA controller deployment details, ConfigMaps, RBAC requirements, verification steps, and advanced failure-mode guidance.

#### Option B: HPA + IGW Metrics (Single-Model Deployments)

Best for: Homogeneous hardware, simpler setup, native Kubernetes HPA

```bash
# 1. Enable flow control in EndpointPickerConfig
kubectl patch endpointpickerconfig <name> -n ${NAMESPACE} --type=merge -p '{"featureGates":["flowControl"]}'

# 2. Install Prometheus Adapter
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring --create-namespace \
  --set prometheus.url=http://prometheus-operated.monitoring.svc \
  --set prometheus.port=9090

# 3. Configure adapter rules (see guides/workload-autoscaling/README.hpa-igw.md)
# 4. Create HPA resource targeting igw_queue_depth and igw_running_requests metrics
```

See [guides/workload-autoscaling/README.hpa-igw.md](../../guides/workload-autoscaling/README.hpa-igw.md) for detailed HPA setup.

#### Manual Scaling (All Deployment Types)
```bash
bash skills/scale-llm-d-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}
```

**Suspend/Resume Operations:**

> **⚠️ Known Issue**: The `scale-workers.sh` script may fail when deployments don't have the `llm-d.ai/role` label. Use direct kubectl commands as shown below.

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

# Resume (restore from backup file)
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
bash skills/scale-llm-d-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}

# Interactive mode (optional)
bash skills/scale-llm-d-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT} -i

# Direct kubectl (standard deployments)
kubectl scale deployment <name> --replicas=${COUNT} -n ${NAMESPACE}

# Direct kubectl (LeaderWorkerSet)
kubectl scale leaderworkerset <name> --replicas=${COUNT} -n ${NAMESPACE}
```

### Scaling Characteristics

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
4. Prefer WVA autoscaling for production workloads with variable traffic
5. **Always save replica counts to a file before suspending** - enables reliable resumption
6. Always suspend both worker types together to avoid resource waste
7. Verify deployment names and counts before scaling operations
8. Test resume in non-production first


**Adjustment Recommendations:**
- If user requests mismatched ratios (e.g., 1 decode + 20 prefill for high-output), suggest reversing
- For equal workers with skewed workload, recommend adjusting based on ISL/OSL
- Always explain reasoning based on expected input/output sequence lengths


## Post-Scaling Verification

After scaling, verify the workers are running:
```bash
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode
kubectl wait --for=condition=ready pod -l llm-d.ai/role=decode -n ${NAMESPACE} --timeout=600s
```

If issues occur, check pod status with `kubectl describe pod <pod-name> -n ${NAMESPACE}`.

## Troubleshooting

### Issue: scale-workers.sh Script Fails

**Symptoms:**
- Script exits with error when trying to scale workers
- Error: "Could not auto-detect deployment" or "no objects passed to scale"

**Root Cause:**
- Deployments may not have the expected `llm-d.ai/role` labels
- Script relies on label selectors that may not exist in all deployments

**Solution:**
Use direct kubectl commands instead:
```bash
# 1. List all deployments to find worker names
kubectl get deployments -n ${NAMESPACE}

# 2. Scale using exact deployment names
kubectl scale deployment <exact-deployment-name> --replicas=${COUNT} -n ${NAMESPACE}
```

### Issue: Lost Replica Counts After Suspension

**Symptoms:**
- Cannot remember how many workers were running before suspension
- Annotation-based tracking doesn't work

**Root Cause:**
- Deployments without `llm-d.ai/role` labels can't use annotation tracking
- Manual scaling operations may not preserve annotations

**Solution:**
Always save replica counts to a file before suspending:
```bash
# Save current state
kubectl get deployments -n ${NAMESPACE} -o json | \
  jq -r '.items[] | select(.metadata.name | contains("decode") or contains("prefill")) |
  "\(.metadata.name) \(.spec.replicas)"' > worker-replicas-backup.txt

# Add resume commands to the file for easy reference
```

### Issue: Deployments Don't Have Expected Labels

**Symptoms:**
- Label selectors return no results
- Cannot use `-l llm-d.ai/role=decode` filters

**Root Cause:**
- Different deployment methods may use different labeling schemes
- Helm charts may not apply standard llm-d labels

**Solution:**
Use deployment name patterns instead:
```bash
# Find deployments by name pattern
kubectl get deployments -n ${NAMESPACE} | grep -E "(decode|prefill)"

# Or use JSON filtering
kubectl get deployments -n ${NAMESPACE} -o json | \
  jq -r '.items[] | select(.metadata.name | contains("decode") or contains("prefill")) | .metadata.name'
```