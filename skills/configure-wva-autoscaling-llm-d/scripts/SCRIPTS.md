# WVA Configuration Scripts Guide

This directory contains scripts and configuration examples for setting up Workload Variant Autoscaler (WVA) with llm-d deployments.

## Overview

**Important**: For deployment and installation, use the official scripts from the WVA repository (`${WVA_REPO_PATH}`). The scripts in this directory focus on:
- Runtime verification and monitoring
- Troubleshooting specific issues
- Configuration examples and templates

## Quick Start

### 1. Deploy WVA (Use WVA Repository Scripts)

**For full deployment**, use the WVA repository's installation scripts:

```bash
# Deploy WVA with llm-d infrastructure
cd ${WVA_REPO_PATH}

# Using Makefile (recommended)
make deploy-e2e-infra \
  ENVIRONMENT=kubernetes \
  IMG=ghcr.io/llm-d/llm-d-workload-variant-autoscaler:latest

# Or using install script directly
ENVIRONMENT=kubernetes \
DEPLOY_LLM_D=true \
SCALER_BACKEND=prometheus-adapter \
./deploy/install.sh
```

**For manual configuration**, use the configuration templates in `configs/` directory and apply with kubectl:

```bash
# 1. Customize the template
cp configs/variantautoscaling-basic.yaml my-va.yaml
# Edit my-va.yaml with your values

# 2. Apply configuration
kubectl apply -f my-va.yaml
kubectl apply -f configs/hpa-basic.yaml
```

### 2. Verify WVA Setup

Check that everything is working:

```bash
./verify-wva.sh <namespace>
```

### 3. Troubleshoot Issues

If autoscaling isn't working:

```bash
# Check metrics availability
./troubleshoot-metrics.sh <namespace> <pod-name>

# Check scaling behavior
./troubleshoot-scaling.sh <namespace>
```

## Available Scripts

### Runtime Verification Scripts

**`verify-wva.sh`** - Comprehensive runtime verification
```bash
./verify-wva.sh <namespace>
```
Checks:
- VariantAutoscaling status (METRICSREADY, CURRENTREPLICAS, DESIREDREPLICAS, SATURATION)
- HPA status and metrics
- WVA controller logs
- External metrics API availability

**`troubleshoot-metrics.sh`** - Diagnose metrics issues
```bash
./troubleshoot-metrics.sh <namespace> <pod-name>
```
Checks:
- Pod metrics endpoint
- PodMonitor configuration
- Provides test request examples

**`troubleshoot-scaling.sh`** - Diagnose scaling issues
```bash
./troubleshoot-scaling.sh <namespace>
```
Checks:
- WVA scaling decisions in logs
- Current saturation levels
- HPA metric visibility
- Recent HPA events

### Deprecated Scripts

**`apply-wva-config.sh`** - DEPRECATED (see [DEPRECATED.md](./DEPRECATED.md))
- Use WVA repository's installation scripts instead
- Or use Helm charts with proper values
- Or apply configuration templates manually

## Configuration Examples

The `configs/` directory contains example configurations:

### Basic Templates
- **`variantautoscaling-basic.yaml`** - Minimal VariantAutoscaling configuration
- **`hpa-basic.yaml`** - Basic HPA configuration

### Complete Examples
- **`example1-single-variant.yaml`** - Single variant with moderate scaling
- **`example2-multi-variant.yaml`** - Multiple variants with cost optimization
- **`example3-aggressive-scaling.yaml`** - Low-latency aggressive scaling
- **`example4-scale-to-zero.yaml`** - Scale-to-zero configuration

## Critical Configuration Requirements

### 1. VariantAutoscaling Must Have Accelerator Label

```yaml
apiVersion: llmd.ai/v1alpha1
kind: VariantAutoscaling
metadata:
  name: my-autoscaler
  namespace: my-namespace
  labels:
    # REQUIRED: Without this label, WVA will not process the resource
    inference.optimization/acceleratorName: nvidia
spec:
  scaleTargetRef:
    kind: Deployment
    name: my-deployment
  modelID: "vendor/model-name"
  variantCost: "10.0"
```

**Why it's required:**
- WVA controller filters resources by accelerator type
- Without this label, the VariantAutoscaling will show `METRICSREADY: False`
- Controller logs will show: "Skipping status update for VA without accelerator info"

### 2. HPA Must Match Both Labels

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-hpa
  namespace: my-namespace
spec:
  metrics:
  - type: External
    external:
      metric:
        name: wva_desired_replicas
        selector:
          matchLabels:
            # REQUIRED: Must match VariantAutoscaling name
            variant_name: my-autoscaler
            # REQUIRED: Must match namespace
            exported_namespace: my-namespace
      target:
        type: AverageValue
        averageValue: "1"
```

**Why both labels are required:**
- WVA exports metrics with both `variant_name` and `exported_namespace` labels
- HPA needs both labels to uniquely identify the correct metric
- Without both labels, HPA will show `<unknown>` for metrics

## Common Issues and Solutions

### Issue 1: VariantAutoscaling shows METRICSREADY: False

**Symptom:**
```bash
$ oc get variantautoscaling
NAME              METRICSREADY   REPLICAS   DESIRED
my-autoscaler     False          1          0
```

**Solution:**
Add the accelerator label to VariantAutoscaling metadata:
```yaml
metadata:
  labels:
    inference.optimization/acceleratorName: nvidia
```

### Issue 2: HPA shows `<unknown>` for metrics

**Symptom:**
```bash
$ oc get hpa
NAME        REFERENCE              TARGETS         MINPODS   MAXPODS
my-hpa      Deployment/my-deploy   <unknown>/1     1         10
```

**Solution:**
Update HPA metric selector to include both labels:
```yaml
selector:
  matchLabels:
    variant_name: my-autoscaler
    exported_namespace: my-namespace
```

### Issue 3: Multiple WVA controllers reporting same metric

**Symptom:**
Multiple metric values for the same variant in Prometheus adapter.

**Solution:**
This is normal behavior. HPA automatically averages the values from multiple controllers. Ensure your HPA selector includes both `variant_name` and `exported_namespace` labels to filter correctly.

### Issue 4: Deployment not scaling

**Symptom:**
HPA shows correct metrics but deployment doesn't scale.

**Troubleshooting steps:**
1. Check HPA status: `oc describe hpa <hpa-name> -n <namespace>`
2. Verify deployment has at least 1 replica
3. Check WVA controller logs for errors
4. Verify saturation thresholds are appropriate for your workload
## WVA Repository Scripts Reference

For deployment and installation, use scripts from `${WVA_REPO_PATH}/deploy/`:

### Main Installation Script
**`${WVA_REPO_PATH}/deploy/install.sh`**
- Handles complete WVA deployment
- Supports Kind, Kubernetes, and OpenShift
- Deploys monitoring stack (Prometheus, Grafana)
- Installs scaler backend (Prometheus Adapter or KEDA)
- Optionally deploys llm-d infrastructure

### Multi-Model Deployment
**`${WVA_REPO_PATH}/deploy/install-multi-model.sh`**
- Deploy multiple model services simultaneously
- Each model gets its own VariantAutoscaling and HPA
- Supports namespace-scoped or cluster-wide deployment

### Kind Cluster Management
**`${WVA_REPO_PATH}/deploy/kind-emulator/setup.sh`**
- Create Kind cluster with GPU emulation
- Configure node labels and capacities

**`${WVA_REPO_PATH}/deploy/kind-emulator/teardown.sh`**
- Clean up Kind cluster

### Library Scripts
**`${WVA_REPO_PATH}/deploy/lib/`** contains modular functions:
- `verify.sh` - Deployment verification
- `infra_wva.sh` - WVA controller deployment
- `infra_llmd.sh` - llm-d infrastructure
- `infra_monitoring.sh` - Monitoring stack
- `infra_scaler_backend.sh` - Scaler backend setup

See the main [SKILL.md](../SKILL.md) for detailed Makefile targets and usage examples.


## Saturation Configuration

Adjust saturation thresholds in the WVA controller namespace:

```bash
# View current configuration
oc get configmap wva-saturation-config -n <wva-controller-namespace> -o yaml

# Update for aggressive scaling (low latency)
oc apply -f configs/configmap-aggressive-saturation.yaml
```

**Default thresholds:**
- `kvCacheThreshold: 0.80` (80% KV cache full)
- `queueLengthThreshold: 5` (5 requests queued)
- `kvSpareTrigger: 0.10` (10% spare capacity)
- `queueSpareTrigger: 3` (3 requests spare capacity)

**Aggressive thresholds:**
- `kvCacheThreshold: 0.70` (70% KV cache full)
- `queueLengthThreshold: 3` (3 requests queued)
- `kvSpareTrigger: 0.15` (15% spare capacity)
- `queueSpareTrigger: 5` (5 requests spare capacity)

## Monitoring

### Watch HPA scaling decisions
```bash
oc get hpa <hpa-name> -n <namespace> -w
```

### View WVA controller logs
```bash
# Find WVA controller namespace
WVA_NS=$(oc get deployment --all-namespaces -l app.kubernetes.io/name=workload-variant-autoscaler -o jsonpath='{.items[0].metadata.namespace}')

# Tail logs
oc logs -f -n $WVA_NS -l app.kubernetes.io/name=workload-variant-autoscaler
```

### Check VariantAutoscaling status
```bash
oc get variantautoscaling <name> -n <namespace> -o yaml
```

### Verify metrics are available
```bash
oc get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/<namespace>/wva_desired_replicas" | jq
```

## Best Practices

1. **Start with default thresholds** - Only adjust after observing behavior
2. **Use appropriate stabilization windows** - Prevent flapping
3. **Set realistic maxReplicas** - Consider cluster capacity
4. **Monitor for 24-48 hours** - Ensure stable behavior under various loads
5. **Use cost-based optimization** - For multi-variant deployments
6. **Test scale-down behavior** - Ensure graceful handling of reduced load

## Additional Resources

- [Main Skill Documentation](../SKILL.md)
- [Troubleshooting Guide](../Troubleshooting.md)