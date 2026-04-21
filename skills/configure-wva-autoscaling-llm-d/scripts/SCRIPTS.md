# WVA Configuration Scripts Guide

This directory contains scripts and configuration examples for setting up Workload Variant Autoscaler (WVA) with llm-d deployments.

## Quick Start

### 1. Apply WVA Configuration (Recommended)

Use the automated script to configure WVA for your deployment:

```bash
./apply-wva-config.sh <namespace> <deployment-name> <model-id> [variant-name] [accelerator]
```

**Example:**
```bash
./apply-wva-config.sh dolev-llmd ms-gpt-oss-6b-decode "EleutherAI/gpt-j-6b" gpt-j-autoscaler nvidia
```

**What it does:**
- ✅ Verifies deployment exists
- ✅ Checks for existing WVA controller
- ✅ Creates VariantAutoscaling with correct labels
- ✅ Creates HPA with proper metric selectors
- ✅ Validates metrics are available
- ✅ Provides troubleshooting guidance

### 2. Verify WVA Setup

Check that everything is working:

```bash
./verify-wva.sh <namespace> <variant-name>
```

### 3. Troubleshoot Issues

If autoscaling isn't working:

```bash
# Check metrics availability
./troubleshoot-metrics.sh <namespace> <variant-name>

# Check scaling behavior
./troubleshoot-scaling.sh <namespace> <deployment-name>
```

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