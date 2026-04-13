---
name: autoscale-llm-d-workers
description: Set up automatic scaling for llm-d prefill/decode workers on Kubernetes/OpenShift. Supports WVA (Workload Variant Autoscaling) for multi-variant deployments and HPA with IGW metrics for single-model deployments. Use for production workloads with variable traffic patterns.
---

# Autoscale llm-d Workers

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

Set up automatic scaling for prefill and decode workers in existing llm-d deployments:
- **WVA Autoscaling** - Continuous saturation-based autoscaling for multi-variant deployments
- **HPA + IGW Metrics** - Native Kubernetes HPA with Inference Gateway metrics for single-model deployments
- **Cost optimization** - Intelligent capacity allocation across variants
- **Dynamic scaling** - Responds to actual workload patterns

Works with P/D disaggregation, standard inference, and LeaderWorkerSet deployments.

## Architecture

**WVA:** Controller watches VariantAutoscaling CRDs → queries vLLM saturation metrics → scales deployments based on thresholds

**HPA:** IGW exposes queue metrics → Prometheus scrapes → Prometheus Adapter exposes to K8s → HPA scales based on thresholds

## Autoscaling Methods

| Method | Best For | Scaling Signal | Cost Optimization | Setup |
|--------|----------|----------------|-------------------|-------|
| **WVA** | Multi-variant on heterogeneous hardware | KV cache, queue depth, budgets | Yes (variant-aware) | Controller required |
| **HPA + IGW** | Single model on homogeneous hardware | Queue depth, running requests | No | Native K8s HPA |

**Choose WVA if:** Multiple variants (e.g., same model on A100s/H100s/L4s), need cost optimization
**Choose HPA if:** Single model, simpler setup, native Kubernetes

## Prerequisites

- Existing llm-d deployment in Kubernetes/OpenShift
- kubectl or oc CLI with appropriate permissions
- Sufficient cluster resources (GPUs, RDMA, memory)
- **For WVA**: Cluster admin access to deploy controller
- **For HPA**: Prometheus and metrics adapter installed

## Workflow

**CRITICAL RULES:**
1. **ALWAYS use existing scripts** from `skills/autoscale-llm-d-workers/scripts/`
2. **NEVER create README.md files** - provide summaries in conversation only
3. **Script modifications** - If existing scripts need updates, copy them to your deployment directory and modify the copy. Never edit scripts in `scripts/` directly.
4. **Scripts run non-interactively by default** - designed for automation (use `-i` flag for interactive mode)

### Step 1: Detect Deployment and Analyze

```bash
bash skills/autoscale-llm-d-workers/scripts/detect-deployment.sh ${NAMESPACE}
```

**I will automatically detect and present:**
- Deployment type (P/D disaggregation, standard inference, LeaderWorkerSet)
- Number of model variants/deployments in namespace
- Hardware types (if detectable from node labels/taints)
- Current replica counts
- Existing autoscaling resources (HPA, VariantAutoscaling)

**Example output I'll provide:**
```
Detected deployment in namespace 'default':
- Type: Prefill/Decode disaggregation
- Variants: 1 (single model deployment)
- Hardware: Homogeneous (all pods on same node type)
- Current replicas: prefill=2, decode=3
- Existing autoscaling: None

Recommendation: HPA + IGW Metrics
Reason: Single model on homogeneous hardware - simpler setup
```

### Step 2: Recommend and Confirm Method

**Based on auto-detection, I will:**
1. **Recommend** the best autoscaling method (WVA or HPA)
2. **Explain why** based on detected characteristics
3. **Ask for confirmation** or if you prefer the alternative method

**Decision logic:**
- **Multiple variants detected** → Recommend WVA
- **Single model, homogeneous hardware** → Recommend HPA + IGW Metrics
- **Uncertain/mixed signals** → Present both options and ask preference

### Step 3: Apply Selected Method

#### Option A: WVA Autoscaling

```bash
# Deploy WVA controller (v0.5.1)
NAMESPACE=${NAMESPACE} bash skills/autoscale-llm-d-workers/scripts/deploy-wva-controller.sh

# Create VariantAutoscaling resource (requires scaleTargetRef in v0.5.1)
bash skills/autoscale-llm-d-workers/scripts/create-variantautoscaling.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME}-autoscaler ${TARGET_DEPLOYMENT}

# If auto-detection fails (unhealthy pods), use manual creation:
bash skills/autoscale-llm-d-workers/scripts/create-variantautoscaling-manual.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME}-autoscaler ${TARGET_DEPLOYMENT} "model/id"

# Fix RBAC if controller shows permission errors
bash skills/autoscale-llm-d-workers/scripts/fix-wva-rbac.sh ${NAMESPACE}

# If controller doesn't detect resources, fix labels
bash skills/autoscale-llm-d-workers/scripts/fix-controller-instance-labels.sh ${NAMESPACE}
```

**Breaking Change in v0.5.1**: The `scaleTargetRef` field is now **required** in VariantAutoscaling CRD. See [guides/workload-autoscaling/README.wva.md](../../guides/workload-autoscaling/README.wva.md#upgrading) for migration steps.

**Common Issues:**
- **RBAC errors**: Controller needs pods list/watch permissions → use `fix-wva-rbac.sh`
- **Unhealthy deployments**: Auto-detection fails → use `create-variantautoscaling-manual.sh` with model ID from prefill pods
- **Model ID detection**: Query from prefill if decode is down: `kubectl exec deployment/prefill-name -- curl -s localhost:8000/v1/models`

**Controller Deployment Reference**: See [WVA_CONTROLLER_DEPLOYMENT.md](WVA_CONTROLLER_DEPLOYMENT.md) for full WVA controller deployment details, ConfigMaps, RBAC requirements, verification steps, and advanced failure-mode guidance.

#### Option B: HPA + IGW Metrics

**Step 1: Enable flow control in gaie-values.yaml**

Add flow control configuration to your `gaie-values.yaml`. See template: [templates/gaie-values-flowcontrol.yaml](./templates/gaie-values-flowcontrol.yaml)

```yaml
inferenceExtension:
  featureGates:
    - flowControl
```

After updating, apply with helmfile:
```bash
cd deployments/<your-deployment>
helmfile apply
```

**Important:** Restart the endpoint picker pod to pick up the new configuration:
```bash
kubectl delete pod -l inferencepool=<inferencepool-name>-epp -n ${NAMESPACE}
kubectl wait --for=condition=ready pod -l inferencepool=<inferencepool-name>-epp -n ${NAMESPACE} --timeout=60s
```

**Step 2: Verify metrics are available**

Use the verification script to check all prerequisites:
```bash
bash skills/autoscale-llm-d-workers/scripts/verify-hpa-metrics.sh ${NAMESPACE} ${INFERENCEPOOL_NAME}
```

This script checks:
- Custom metrics API availability
- Inference pool metrics exposure
- EPP service and pod status
- Current queue size metric value

**Step 3: Create HPA resource**

Use the HPA creation script:
```bash
bash skills/autoscale-llm-d-workers/scripts/create-hpa.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME} ${INFERENCEPOOL_NAME} \
  [min-replicas] [max-replicas] [target-queue-size]
```

Example:
```bash
bash skills/autoscale-llm-d-workers/scripts/create-hpa.sh \
  default ms-gpt-oss-20b-llm-d-modelservice-decode gaie-gpt-oss-20b 1 5 10
```

**Step 4: Monitor HPA**

```bash
# Check HPA status
kubectl get hpa -n ${NAMESPACE}

# View detailed status and events
kubectl describe hpa <hpa-name> -n ${NAMESPACE}

# Watch HPA continuously
watch kubectl get hpa -n ${NAMESPACE}
```

**Common Issues:**

1. **Metrics show `<unknown>`**:
   - Run `verify-hpa-metrics.sh` to diagnose
   - Ensure flow control is enabled and EPP pod restarted
   - Check custom metrics API is healthy

2. **HPA can't find metrics on InferencePool**:
   - Metrics are exposed on Service object (`<inferencepool-name>-epp`), not InferencePool
   - The `create-hpa.sh` script handles this correctly

3. **Queue size always 0**:
   - Normal if model processes requests faster than they arrive
   - Autoscaling triggers when sustained load exceeds single pod capacity

**Step 5 (Optional): Test Autoscaling**

> **⚠️ CRITICAL: MUST ASK USER BEFORE TESTING**
>
> **ALWAYS ask the user:** "Would you like me to test the autoscaling by sending load to the deployment?"
>
> **WAIT for explicit user confirmation.** Do NOT proceed with testing without user response.
>
> **If no response:** Skip this step entirely and complete the task.

After receiving user confirmation, verify autoscaling works by sending load:

```bash
bash skills/autoscale-llm-d-workers/scripts/test-hpa-scaling.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME} ${GATEWAY_URL} ${MODEL_NAME} \
  [num-requests] [max-tokens]
```

Example:
```bash
bash skills/autoscale-llm-d-workers/scripts/test-hpa-scaling.sh \
  default ms-gpt-oss-20b-llm-d-modelservice-decode \
  http://infra-gpt-oss-20b-inference-gateway-istio.default.svc.cluster.local:80 \
  EleutherAI/gpt-neox-20b 50 300
```

The script will show initial state, send concurrent requests, monitor for 2 minutes, and report scaling results.

**Scripts Reference:**
- [create-hpa.sh](./scripts/create-hpa.sh) - Create HPA resource
- [verify-hpa-metrics.sh](./scripts/verify-hpa-metrics.sh) - Verify metrics setup
- [test-hpa-scaling.sh](./scripts/test-hpa-scaling.sh) - Test autoscaling with load
- [templates/gaie-values-flowcontrol.yaml](./templates/gaie-values-flowcontrol.yaml) - Flow control template

See [guides/workload-autoscaling/README.hpa-igw.md](../../guides/workload-autoscaling/README.hpa-igw.md) for detailed HPA setup.

### Output Format

**Correct:** Execute scripts, provide brief summary (3-5 sentences)

**WRONG:**
- ❌ Create README.md, monitoring-guide.md, or any documentation files


## Monitoring Autoscaling

**WVA Monitoring:**
```bash
# Check controller logs
kubectl logs -n ${NAMESPACE} -l app=wva-controller

# View VariantAutoscaling status
kubectl get variantautoscaling -n ${NAMESPACE} -o yaml

# Monitor pod saturation metrics
kubectl exec -n ${NAMESPACE} deployment/prefill-name -- curl -s localhost:8000/metrics | grep saturation
```

**HPA Monitoring:**
```bash
# Check HPA status
kubectl get hpa -n ${NAMESPACE}

# View HPA events
kubectl describe hpa <hpa-name> -n ${NAMESPACE}

# Check custom metrics
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq .
```

## Troubleshooting

For common autoscaling issues and solutions, see [Troubleshooting.md](./Troubleshooting.md).
