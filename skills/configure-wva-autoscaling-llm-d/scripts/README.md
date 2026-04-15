# WVA Configuration Scripts and Templates

This directory contains configuration templates and utility scripts for setting up and troubleshooting Workload Variant Autoscaler (WVA) for llm-d deployments.

## Directory Structure

```
scripts/
├── configs/                          # YAML configuration templates
│   ├── variantautoscaling-basic.yaml # Basic VariantAutoscaling resource template
│   ├── hpa-basic.yaml                # Basic HPA configuration template
│   ├── example1-single-variant.yaml  # Single variant moderate scaling example
│   ├── example2-multi-variant.yaml   # Multi-variant cost optimization example
│   ├── example3-aggressive-scaling.yaml # Aggressive scaling for low latency
│   ├── example4-scale-to-zero.yaml   # Scale-to-zero configuration
│   └── configmap-aggressive-saturation.yaml # Aggressive saturation thresholds
├── verify-wva.sh                     # Verify WVA configuration and status
├── troubleshoot-metrics.sh           # Troubleshoot metrics issues
└── troubleshoot-scaling.sh           # Troubleshoot scaling issues
```

## Configuration Templates

### Basic Templates

- **[`variantautoscaling-basic.yaml`](configs/variantautoscaling-basic.yaml)**: Core VariantAutoscaling resource template
- **[`hpa-basic.yaml`](configs/hpa-basic.yaml)**: Basic HPA configuration for WVA

### Example Configurations

1. **[`example1-single-variant.yaml`](configs/example1-single-variant.yaml)**: Single variant with moderate scaling
   - Use case: Standard deployment with balanced scaling behavior
   - Default saturation thresholds

2. **[`example2-multi-variant.yaml`](configs/example2-multi-variant.yaml)**: Multi-variant cost optimization
   - Use case: Multiple GPU types (H100/A100) with cost-based scaling preference
   - Demonstrates variant cost configuration

3. **[`example3-aggressive-scaling.yaml`](configs/example3-aggressive-scaling.yaml)**: Aggressive scaling for low latency
   - Use case: Low-latency requirements with fast scale-up
   - Requires [`configmap-aggressive-saturation.yaml`](configs/configmap-aggressive-saturation.yaml)

4. **[`example4-scale-to-zero.yaml`](configs/example4-scale-to-zero.yaml)**: Scale-to-zero for development
   - Use case: Development/testing environments to save costs
   - Requires HPAScaleToZero feature gate

## Utility Scripts

### verify-wva.sh

Comprehensive verification of WVA configuration and status.

**Usage:**
```bash
./verify-wva.sh <namespace>
```

**Checks:**
- VariantAutoscaling resource status
- HPA status and metrics
- WVA controller logs
- External metrics availability

### troubleshoot-metrics.sh

Diagnose issues with metrics collection and exposure.

**Usage:**
```bash
./troubleshoot-metrics.sh <namespace> <pod-name>
```

**Checks:**
- Pod metrics endpoint
- PodMonitor configuration
- Provides test request examples

### troubleshoot-scaling.sh

Diagnose scaling behavior issues.

**Usage:**
```bash
./troubleshoot-scaling.sh <namespace>
```

**Checks:**
- WVA scaling decisions in logs
- Current saturation levels
- HPA metric visibility
- Recent scaling events

## Quick Start

1. **Choose a configuration template** based on your use case
2. **Customize the template** with your deployment details
3. **Apply the configuration**:
   ```bash
   kubectl apply -f configs/example1-single-variant.yaml
   ```
4. **Verify the setup**:
   ```bash
   ./verify-wva.sh <namespace>
   ```
5. **Monitor and troubleshoot** as needed using the utility scripts

## Configuration Parameters

### Key Saturation Thresholds

- `kvCacheThreshold`: KV cache utilization threshold (0.0-1.0, default: 0.80)
- `queueLengthThreshold`: Queue depth threshold (default: 5)
- `kvSpareTrigger`: Scale-up when average spare KV capacity < trigger (default: 0.10)
- `queueSpareTrigger`: Scale-up when average spare queue capacity < trigger (default: 3)

### HPA Behavior

- `stabilizationWindowSeconds`: Time to wait before scaling (prevents flapping)
  - Scale-up: 60-120s (faster response)
  - Scale-down: 300-600s (avoid premature scale-down)

## Best Practices

1. **Start with defaults**: Use default thresholds initially, tune based on observed behavior
2. **Align thresholds**: Keep WVA and EPP (Inference Scheduler) thresholds synchronized
3. **Monitor first**: Observe saturation patterns before aggressive tuning
4. **Test with load**: Use llm-d-benchmark to validate scaling behavior
5. **Cost optimization**: For multi-variant setups, set variantCost accurately

## Related Documentation

- Main skill documentation: [`../SKILL.md`](../SKILL.md)
- Troubleshooting guide: [`../Troubleshooting.md`](../Troubleshooting.md)