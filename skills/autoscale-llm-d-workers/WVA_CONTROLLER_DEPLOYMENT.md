---
name: WVA Controller Deployment Guide
description: Complete guide for deploying WVA controllers including all ConfigMaps, RBAC requirements, and troubleshooting steps. Use this when WVA setup fails or when deploying to new namespaces.
type: guide
---

# WVA Controller Deployment Guide

## Overview

This guide helps you deploy Workload Variant Autoscaler (WVA) controllers when automated setup fails. It covers the architecture, deployment methods, verification steps, and troubleshooting.

## How WVA Works

**Architecture:**
1. **CRD is cluster-scoped** - Installed once per cluster via CRD manifest
2. **Controller is namespace-scoped** - Must be deployed to EACH namespace where autoscaling is needed
3. **Controller watches only its own namespace** by default
4. **Requires Prometheus access** - Controller queries Prometheus for vLLM metrics
5. **Uses controller-instance labels** - Controller filters resources by matching `wva.llmd.ai/controller-instance` label

**Why namespace-scoped?** Each namespace with llm-d deployments needs its own WVA controller to manage autoscaling independently.

**Controller Instance Filtering:**
The WVA controller uses the `CONTROLLER_INSTANCE` environment variable to filter which resources it manages. Only VariantAutoscaling resources with a matching `wva.llmd.ai/controller-instance` label will be processed. The scripts automatically set this to the namespace name for simplicity.

## Deployment Methods

**Before you begin**, determine which method to use:

1. **Do you have access to the llm-d repository?**
   - ✅ **Yes** → Use [Method 1: Full WVA Setup](#method-1-full-wva-setup-requires-guidesworkload-autoscaling)
     - If llm-d is not in the current directory, set the path:
       ```bash
       export LLMD_PATH=/path/to/llm-d
       ```
   - ❌ **No** → Use [Method 2: Standalone WVA Controller](#method-2-standalone-wva-controller) (recommended for most users)

2. **Need complete manual control?**
   - Use [Method 3: Manual Deployment](#method-3-manual-deployment-advanced) (advanced users only)

### Method 1: Full WVA Setup (requires guides/workload-autoscaling)

Use this when you have access to the guides/workload-autoscaling directory from the main llm-d repository:

```bash
# From llm-d repository root
bash skills/llmd-scale-workers/scripts/setup-wva-autoscaling.sh

# Or specify repository path
LLMD_PATH=/path/to/llm-d bash skills/llmd-scale-workers/scripts/setup-wva-autoscaling.sh

# Interactive mode (prompts for user input)
INTERACTIVE=true bash skills/llmd-scale-workers/scripts/setup-wva-autoscaling.sh
```

### Method 2: Standalone WVA Controller

Use the deploy-wva-controller.sh script which automatically:
- Creates embedded default ConfigMaps
- Creates all necessary RBAC resources
- Deploys the controller
- Verifies the deployment

```bash
# Deploy to target namespace
NAMESPACE=<target-namespace> bash skills/llmd-scale-workers/scripts/deploy-wva-controller.sh

# Or pass namespace as argument
bash skills/llmd-scale-workers/scripts/deploy-wva-controller.sh <target-namespace>
```

**What this script does:**
1. Creates namespace if it doesn't exist
2. Creates default ConfigMaps with standard WVA configuration
3. Creates ServiceAccount, Role, and RoleBinding
4. Deploys the WVA controller
5. Verifies deployment and checks logs

**Prerequisites:**
- ✅ Prometheus accessible in the cluster
- ⚠️ Cluster-admin access (for Prometheus RBAC) - optional but recommended

**ConfigMap Customization:**

The script creates ConfigMaps with default values. You can customize them after deployment:

```bash
# Edit main WVA configuration (Prometheus URL, intervals, etc.)
kubectl edit configmap workload-variant-autoscaler-variantautoscaling-config -n ${NAMESPACE}

# Edit saturation scaling thresholds
kubectl edit configmap workload-variant-autoscaler-wva-saturation-scaling-config -n ${NAMESPACE}

# Edit service classes and SLOs
kubectl edit configmap workload-variant-autoscaler-service-classes-config -n ${NAMESPACE}

# Restart controller to apply changes
kubectl rollout restart deployment/workload-variant-autoscaler-controller-manager -n ${NAMESPACE}
```

### Method 3: Manual Deployment (Advanced)

> **Note**: This method is rarely needed. Use Method 2 (deploy-wva-controller.sh) instead.

If you need complete manual control, extract the YAML from deploy-wva-controller.sh script:

```bash
# View all resource definitions in the script
cat skills/llmd-scale-workers/scripts/deploy-wva-controller.sh

# The script contains: ConfigMaps, ServiceAccount, Role, RoleBinding, and Deployment
```

## ConfigMap Contents

**Required ConfigMaps:**
- `workload-variant-autoscaler-variantautoscaling-config` - Main config with Prometheus URL and connection settings
- `workload-variant-autoscaler-wva-saturation-scaling-config` - Saturation thresholds for scaling decisions
- `workload-variant-autoscaler-service-classes-config` - Service class definitions for workload types
- `workload-variant-autoscaler-prometheus-ca` - Prometheus CA certificate (optional, needed for TLS)

## Cluster-Level RBAC for Prometheus Access

WVA controller needs cluster-level RBAC to query Prometheus metrics. Use the provided script:

```bash
# Create cluster-level RBAC (requires cluster-admin privileges)
bash skills/llmd-scale-workers/scripts/create-wva-cluster-rbac.sh ${NAMESPACE}
```

**Important:** This requires cluster-admin privileges. If you see "403 Forbidden" errors in controller logs, you need to run this script.

**Without cluster-admin access:**
1. Request cluster-admin to run the script for you
2. Use manual scaling instead: `bash skills/llmd-scale-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}`

## Verification Steps

After deploying the controller, verify it's healthy before creating VariantAutoscaling resources:

1. **Check controller pod is running:**
   ```bash
   kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=workload-variant-autoscaler
   # Should show READY 1/1, NOT CrashLoopBackOff
   ```

2. **Check controller logs for success:**
   ```bash
   kubectl logs -n ${NAMESPACE} deployment/workload-variant-autoscaler-controller-manager
   # Should show "Configuration loaded successfully"
   # Should show "Watching single namespace: ${NAMESPACE}"
   ```

3. **Common error patterns to watch for:**
   - ❌ "failed to load config: prometheus configuration is required" → Missing ConfigMaps
   - ❌ "open /etc/ssl/certs/prometheus-ca.crt: no such file" → Missing prometheus-ca ConfigMap
   - ❌ "Prometheus API validation failed, retrying - 403" → Need cluster-admin for RBAC

## Creating VariantAutoscaling Resource

Once the controller is healthy, create the VariantAutoscaling resource using the provided script:

```bash
# Create VariantAutoscaling resource (auto-detects model ID)
bash skills/llmd-scale-workers/scripts/create-variantautoscaling.sh \
  ${NAMESPACE} \
  ${DEPLOYMENT_NAME}-autoscaler \
  ${TARGET_DEPLOYMENT}

# Example:
bash skills/llmd-scale-workers/scripts/create-variantautoscaling.sh \
  my-namespace \
  my-autoscaler \
  ms-my-deployment-llm-d-modelservice-decode
```

The script automatically:
- Detects the model ID from vLLM
- Creates the VariantAutoscaling resource
- Verifies the resource was created successfully

## Common Failure Modes and Fixes

**Failure 1: "Inferencepool datastore is empty" - API Group Mismatch**
```
Controller logs: "Inferencepool datastore is empty - skipping processing inactive variant"
Controller startup shows: "Starting EventSource ... inference.networking.x-k8s.io ... *v1alpha2.InferencePool"
```
**Root Cause:** The WVA controller v0.5.1 is hardcoded to watch `inference.networking.x-k8s.io/v1alpha2` InferencePools, but your deployment uses `inference.networking.k8s.io/v1` InferencePools (the stable GA API).

**This is a controller version incompatibility issue.** The controller code needs to be updated to watch the correct API group.

**Workaround Options:**
1. **Use manual scaling instead** (recommended for production):
   ```bash
   bash skills/llmd-scale-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}
   ```

2. **Request controller upgrade** from the llm-d team to support `inference.networking.k8s.io/v1` API

3. **Check if newer WVA controller version exists** that supports the GA InferencePool API

**Failure 2: "No active VariantAutoscalings found" - Missing controller-instance Label**
```
Controller logs show no resources found despite VariantAutoscaling existing
```
**Root Cause:** Missing or mismatched `wva.llmd.ai/controller-instance` label on VariantAutoscaling resources

**Fix:** The controller filters resources by the `CONTROLLER_INSTANCE` environment variable. Ensure:
1. Controller has `CONTROLLER_INSTANCE` env set (automatically set to namespace by deploy script)
2. VariantAutoscaling has matching `wva.llmd.ai/controller-instance` label (automatically added by create script)

To fix existing resources:
```bash
# Get controller instance
CONTROLLER_INSTANCE=$(kubectl get deployment -n ${NAMESPACE} \
  workload-variant-autoscaler-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTROLLER_INSTANCE")].value}')

# Add label to existing VariantAutoscaling
kubectl label variantautoscaling -n ${NAMESPACE} <name> \
  wva.llmd.ai/controller-instance=${CONTROLLER_INSTANCE} --overwrite
```

**Failure 2: No ConfigMaps**
```
failed to load config: prometheus configuration is required
```
**Fix:** ConfigMaps are automatically created by deploy-wva-controller.sh script

**Failure 3: Missing Prometheus CA**
```
open /etc/ssl/certs/prometheus-ca.crt: no such file
```
**Fix:** The deployment uses `insecureSkipVerify: true` by default, so this warning can be ignored

**Failure 4: Prometheus 403 Forbidden**
```
Prometheus API validation failed, retrying - {"query: ": "up", "error": "client_error: client error: 403"}
```
**Fix:** Create cluster-level RBAC for Prometheus access (requires cluster-admin)
```bash
bash skills/llmd-scale-workers/scripts/create-wva-cluster-rbac.sh ${NAMESPACE}
```

**Failure 5: Immutable selector error**
```
field is immutable
```
**Fix:** Delete and recreate the deployment:
```bash
kubectl delete deployment -n ${NAMESPACE} workload-variant-autoscaler-controller-manager
bash skills/llmd-scale-workers/scripts/deploy-wva-controller.sh ${NAMESPACE}
```

## Quick Reference

### Complete WVA Setup Flow

```bash
# 1. Deploy WVA controller
bash skills/llmd-scale-workers/scripts/deploy-wva-controller.sh ${NAMESPACE}

# 2. Create cluster RBAC (if you see 403 errors)
bash skills/llmd-scale-workers/scripts/create-wva-cluster-rbac.sh ${NAMESPACE}

# 3. Create VariantAutoscaling resource
bash skills/llmd-scale-workers/scripts/create-variantautoscaling.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME}-autoscaler ${TARGET_DEPLOYMENT}

# 4. Monitor autoscaling
kubectl get variantautoscaling -n ${NAMESPACE} -w
```

### When to Use Manual Scaling Instead

Consider manual scaling if:
- You don't have cluster-admin access for Prometheus RBAC
- Prometheus is not available in your cluster
- You need immediate, predictable control over replica counts
- You're in a development/testing environment

```bash
bash skills/llmd-scale-workers/scripts/scale-workers.sh -n ${NAMESPACE} -t decode -r ${COUNT}
```

## Model Name Format

The `modelID` in VariantAutoscaling must match the model name served by vLLM (includes vendor prefix).

**Correct format:** `Qwen/Qwen3-30B-A3B-Thinking-2507`
**Incorrect format:** `Qwen3-30B-A3B-Thinking-2507` (missing vendor prefix)

The create-variantautoscaling.sh script automatically detects the correct format.
