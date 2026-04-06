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

## When to Use

| Method | Use Cases |
|--------|-----------|
| **WVA Autoscaling** | Multi-variant deployments on heterogeneous hardware<br>Cost-aware capacity allocation across variants<br>Intelligent Inference Scheduling deployments only<br>Requires WVA controller and VariantAutoscaling CRD |
| **HPA + IGW Metrics** | Single-model deployments on homogeneous hardware<br>Native Kubernetes HPA with queue depth/running requests<br>Simpler setup than WVA (no additional controllers)<br>Supports scale-to-zero with HPA alpha features or KEDA |

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

### Step 1: Detect Deployment

```bash
bash skills/autoscale-llm-d-workers/scripts/detect-deployment.sh ${NAMESPACE}
```

### Step 2: Choose Autoscaling Method

#### Option A: WVA Autoscaling (Multi-Variant Deployments)

Best for: Multiple models/variants on shared GPU hardware with cost optimization

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

### Output Format

**Correct:** Execute scripts, provide brief summary (3-5 sentences)

**WRONG:**
- ❌ Create README.md, monitoring-guide.md, or any documentation files

## WVA Architecture

**Components:**
- **WVA Controller**: Monitors pod saturation metrics and adjusts replica counts
- **VariantAutoscaling CRD**: Defines autoscaling policies per deployment
- **Metrics**: Uses vLLM saturation metrics from model pods

**How It Works:**
1. Controller watches VariantAutoscaling resources
2. Queries saturation metrics from target pods
3. Calculates optimal replica count based on saturation thresholds
4. Scales deployments up/down to maintain target saturation
5. Respects min/max replica bounds and cooldown periods

## HPA Architecture

**Components:**
- **Prometheus**: Collects IGW metrics (queue depth, running requests)
- **Prometheus Adapter**: Exposes metrics to Kubernetes metrics API
- **HPA**: Native Kubernetes autoscaler using custom metrics

**How It Works:**
1. IGW exposes queue depth and running request metrics
2. Prometheus scrapes and stores these metrics
3. Prometheus Adapter makes them available to HPA
4. HPA scales based on configured thresholds
5. Supports multiple metrics and scale-to-zero (with alpha features)

## Best Practices

1. **Start with conservative thresholds** - Avoid aggressive scaling that causes thrashing
2. **Monitor autoscaling behavior** - Watch metrics and adjust policies as needed
3. **Set appropriate min/max replicas** - Prevent over-provisioning or under-provisioning
4. **Use cooldown periods** - Prevent rapid scale up/down cycles
5. **Test in non-production first** - Validate autoscaling behavior before production
6. **Document autoscaling policies** - Track threshold changes and rationale
7. **Combine with manual scaling** - Use manual scaling for known events (maintenance, demos)

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

## Related Skills

For manual scaling operations, see:
- [`scale-llm-d-workers-manually`](../scale-llm-d-workers-manually/SKILL.md) - Manual scaling and suspend/resume