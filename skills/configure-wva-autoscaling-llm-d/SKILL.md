---
name: configure-wva-autoscaling-llm-d
description: Configure and optimize Workload Variant Autoscaler (WVA) for llm-d inference deployments. Use when users want to set up autoscaling based on KV cache saturation, configure multi-variant cost optimization, tune saturation thresholds, enable scale-to-zero, or troubleshoot WVA behavior. Helps translate user requirements like "I want aggressive scaling" or "optimize for cost across H100 and A100 variants" into proper WVA configuration.
---

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

1. **Do NOT modify existing repository code** - Cloning a missing repository is allowed and required for this skill, but never edit code you did not create. If existing code must be adjusted, copy it to a new location, modify the copied file there, and reference the new file instead of changing the original.

2. **ALWAYS use existing skill scripts first** - Use scripts in [`scripts/`](./scripts/SCRIPTS.md). Only perform manual edits if scripts fail due to non-standard deployment structure.

3. **Verify cluster resources** - Check available GPU/RDMA resources before applying changes.

## Prerequisites: Repository Setup

**Required Repositories**: llm-d, llm-d-workload-variant-autoscaler, llm-d-benchmark

**Setup Process**:
1. Check for repositories in common locations
2. Ask user for paths if not found
3. Clone missing repositories with user approval
4. Set environment variables: `LLMD_REPO_PATH`, `WVA_REPO_PATH`, `BENCHMARK_REPO_PATH`

## Overview
This skill helps you configure Workload Variant Autoscaler (WVA) for llm-d inference deployments based on your specific requirements. WVA provides intelligent autoscaling using KV cache saturation and queue depth metrics, with support for multi-variant cost optimization.

## When to Use This Skill

Use this skill when you need to:
- Configure WVA autoscaling for existing llm-d deployments
- Tune saturation thresholds based on workload characteristics
- Set up multi-variant deployments with cost optimization
- Enable or configure scale-to-zero behavior
- Troubleshoot WVA scaling decisions
- Align WVA thresholds with Inference Scheduler (EPP) settings

## What is WVA?

**Workload Variant Autoscaler (WVA)** is a Kubernetes controller that provides intelligent autoscaling for LLM inference workloads. Unlike traditional CPU/GPU-based autoscaling, WVA uses:

- **KV Cache Saturation**: Proactive scaling based on memory pressure in the inference server
- **Queue Depth**: Request backlog monitoring to prevent latency spikes
- **Cost Optimization**: Preferentially scales cheaper variants when multiple hardware options are available
- **Spare Capacity Model**: Scales before saturation occurs, not after

**Key Concept - Variants**: A variant is a way of serving a model with a specific combination of hardware, runtime, and serving approach. For example:
- Same model on H100 vs A100 vs L4 GPUs (different cost/performance)
- Same model with different parallelism strategies
- Same model with different LoRA adapters


### Skill Structure

```
skills/configure-wva-autoscaling-llm-d/
├── SKILL.md              # This file - main skill with configuration guidance
├── Troubleshooting.md    # Quick troubleshooting reference
├── scripts/              # Configuration templates and utility scripts
│   ├── SCRIPTS.md       # Detailed scripts usage guide
│   ├── configs/         # YAML configuration templates
│   ├── verify-wva.sh    # Verification script
│   ├── troubleshoot-metrics.sh
│   ├── troubleshoot-scaling.sh
│   └── apply-wva-config.sh
└── evals/               # Skill evaluation tests
```
## Core Workflow

When a user asks for WVA configuration help, follow this workflow:

### 1. Choose Namespace Isolation Strategy

**FIRST**, determine the WVA deployment scope based on the user's environment and requirements:

#### Option 1: Namespace-Scoped Controller (Recommended for Multi-Tenant/Testing)
**Use when**: Testing, development, or multi-tenant clusters where teams need isolation.

**Configuration**:
```bash
# Deploy WVA to watch only your specific namespace
helm upgrade -i wva ./charts/workload-variant-autoscaler \
  --namespace wva-system \
  --set controller.watchNamespace=my-namespace
```

Or set via environment variable in the deployment:
```yaml
env:
- name: WATCH_NAMESPACE
  value: "my-namespace"
```

**Behavior**:
- ✅ Only manages VariantAutoscaling resources in your namespace
- ✅ Ignores all other namespaces completely
- ✅ Perfect for multi-tenant clusters where each team has their own controller
- ✅ No interference with other teams' deployments

#### Option 2: Cluster-Wide with Namespace Exclusions
**Use when**: You want cluster-wide monitoring but need to exclude specific namespaces.

**Configuration**:
```bash
# Exclude specific namespaces from WVA monitoring
kubectl annotate namespace other-team-namespace wva.llmd.ai/exclude=true
kubectl annotate namespace kube-system wva.llmd.ai/exclude=true
```

**Behavior**:
- ✅ WVA watches all namespaces by default
- ✅ Explicitly excluded namespaces are ignored
- ✅ Good for shared clusters with some protected namespaces

#### Option 3: Multi-Controller Isolation (Advanced)
**Use when**: Complete isolation between teams/projects is required.

**Configuration**:
```bash
# Your team's controller (only manages your namespace)
helm upgrade -i wva-my-team ./charts/workload-variant-autoscaler \
  --namespace wva-system \
  --set wva.controllerInstance=my-team \
  --set controller.watchNamespace=my-namespace

# Other team's controller (manages their namespace)
helm upgrade -i wva-other-team ./charts/workload-variant-autoscaler \
  --namespace wva-system \
  --set wva.controllerInstance=other-team \
  --set controller.watchNamespace=other-namespace
```

**Behavior**:
- ✅ Complete isolation between teams
- ✅ Each controller has its own metrics with `controller_instance` label
- ✅ No interference between different teams' autoscaling
- ✅ Separate monitoring and troubleshooting per team

**Choose one of the above options based on your requirements.**

### 2. Understand Requirements

Ask clarifying questions to understand:
- **Scaling goals**: Aggressive scaling, cost optimization, or balanced?
- **Variants**: Single accelerator type or multi-variant (H100/A100/L4)?
- **Scale-to-zero**: Should replicas scale to zero during idle periods?
- **Platform**: OpenShift, GKE, Kind, or other Kubernetes?

### 2. Configuration Strategy

Configure three components:
- **VariantAutoscaling**: Core WVA resource ([template](scripts/configs/variantautoscaling-basic.yaml))
- **Saturation Thresholds**: kvCacheThreshold (0.80), queueLengthThreshold (5), kvSpareTrigger (0.10), queueSpareTrigger (3)
- **HPA**: Kubernetes HPA for actual scaling ([template](scripts/configs/hpa-basic.yaml))

### 3. Common Configuration Patterns

Choose based on user requirements:

1. **Single Variant** ([example](scripts/configs/example1-single-variant.yaml)) - Balanced thresholds, moderate scaling
2. **Multi-Variant Cost Optimization** ([example](scripts/configs/example2-multi-variant.yaml)) - Different variantCost values, WVA scales cheaper first
3. **Aggressive Scaling** ([example](scripts/configs/example3-aggressive-scaling.yaml)) - Lower thresholds (0.70), faster scale-up (60s)
4. **Conservative Scaling** - Higher thresholds (0.85), longer stabilization (300s+)
5. **Scale-to-Zero** ([example](scripts/configs/example4-scale-to-zero.yaml)) - For dev/test only, requires alpha feature gate

**Key**: Always include `inference.optimization/acceleratorName` label and ensure HPA selector matches `variant_name` + `exported_namespace`.

See [`scripts/SCRIPTS.md`](./scripts/SCRIPTS.md) for detailed configuration examples.

### 4. Threshold Alignment with Inference Scheduler

**Critical**: WVA and Inference Scheduler (End Point Picker) should use the same thresholds for optimal performance.

**Why**: EPP routes requests away from saturated replicas. If WVA and EPP use different thresholds, you get:
- EPP marks replica saturated → stops routing → WVA still sees capacity → doesn't scale
- Or: WVA scales up → EPP still routing to old replicas → new capacity unused

**How to align**:
1. Check EPP configuration in GAIE values
2. Match WVA saturation thresholds to EPP thresholds
3. Update both together when tuning

## Installation and Testing Scripts

**Do not create new automation scripts**. Use existing scripts from the llm-d repositories:

### Installation Scripts
- **Full WVA Setup**: `${LLMD_REPO_PATH}/guides/workload-autoscaling/`
  - Use `helmfile apply` for complete installation
  - See `${LLMD_REPO_PATH}/guides/workload-autoscaling/README.wva.md` for detailed steps

### Testing Scripts
- **llm-d-benchmark WVA Testing**: `${BENCHMARK_REPO_PATH}/`
  - Use `./setup/standup.sh --wva` to deploy with WVA
  - Use `./run.sh` to run workloads and test autoscaling
  - See `${BENCHMARK_REPO_PATH}/docs/workload-variant-autoscaler.md` for testing guide

## Monitoring and Verification

After configuration, verify WVA is working using the verification script:

```bash
./scripts/verify-wva.sh <namespace>
```

This script checks:
- VariantAutoscaling status (METRICSREADY, CURRENTREPLICAS, DESIREDREPLICAS, SATURATION)
- HPA status
- WVA controller logs
- External metrics availability

## Critical Configuration Requirements

**Two critical requirements for WVA to work**:

1. **VariantAutoscaling MUST have accelerator label**: `inference.optimization/acceleratorName: nvidia`
2. **HPA selector MUST match both labels**: `variant_name` and `exported_namespace`

See [`scripts/SCRIPTS.md`](./scripts/SCRIPTS.md) for detailed examples and [`Troubleshooting.md`](./Troubleshooting.md) for common issues.

**Using existing WVA controller**: If a WVA controller exists in another namespace, just create your VariantAutoscaling - it will be automatically discovered. Update saturation config in the controller's namespace if needed.

## Troubleshooting

For detailed troubleshooting guidance, see [`Troubleshooting.md`](./Troubleshooting.md) and [`scripts/SCRIPTS.md`](./scripts/SCRIPTS.md).

**Quick diagnostics**:
```bash
./scripts/verify-wva.sh <namespace>              # Comprehensive verification
./scripts/troubleshoot-metrics.sh <namespace>    # Check metrics issues
./scripts/troubleshoot-scaling.sh <namespace>    # Check scaling behavior
```

**Most common issues**: Missing accelerator label, wrong HPA label selector, or metrics not yet scraped. See Troubleshooting.md for solutions.

## Best Practices

1. **Start with defaults**: Use default thresholds initially, tune based on observed behavior
2. **Align thresholds**: Keep WVA and EPP thresholds synchronized
3. **Monitor first**: Observe saturation patterns before aggressive tuning
4. **Stabilization windows**: Use longer windows (120s+ scale-up, 300s+ scale-down) to prevent flapping
5. **Test with load**: Use llm-d-benchmark to validate scaling behavior under realistic load
6. **Cost optimization**: For multi-variant setups, set variantCost accurately to reflect actual costs
7. **Scale-to-zero**: Only enable in dev/test environments, not production (cold start latency)

## Output Format

When helping users configure WVA:

1. **Ask clarifying questions** about their requirements
2. **Provide specific YAML configurations** based on their needs
3. **Explain the reasoning** behind configuration choices
4. **Include monitoring commands** to verify the setup
5. **Link to relevant documentation** for deeper understanding

**Do not**:
- Create new automation scripts (use existing ones)
- Provide generic configurations without understanding requirements
- Skip threshold alignment with EPP
- Forget to explain the "why" behind configurations

## Reference Documentation

For detailed information, refer to these files in the repositories:

**WVA Repository** (`${WVA_REPO_PATH}`):
- **Configuration Guide**: `docs/user-guide/configuration.md`
- **Saturation Scaling**: `docs/saturation-scaling-config.md`
- **CRD Reference**: `docs/user-guide/crd-reference.md`
- **Troubleshooting**: `docs/user-guide/troubleshooting.md`
- **HPA Integration**: `docs/user-guide/hpa-integration.md`
- **KEDA Integration**: `docs/user-guide/keda-integration.md`
- **Configuration Samples**: `config/samples/`

**llm-d Repository** (`${LLMD_REPO_PATH}`):
- **Installation Guide**: `guides/workload-autoscaling/README.wva.md`
- **HPA+IGW Guide**: `guides/workload-autoscaling/README.hpa-igw.md`
- **Helmfile Templates**: `guides/workload-autoscaling/helmfile.yaml.gotmpl`
- **Values Configuration**: `guides/workload-autoscaling/workload-autoscaling/values.yaml`

**llm-d-benchmark Repository** (`${BENCHMARK_REPO_PATH}`):
- **WVA Testing Guide**: `docs/workload-variant-autoscaler.md`
- **Setup Scripts**: `setup/standup.sh`, `setup/teardown.sh`
- **Run Scripts**: `run.sh`
- **Workload Profiles**: `workload/profiles/guidellm/`

**Online Resources**:
- **WVA GitHub**: https://github.com/llm-d/llm-d-workload-variant-autoscaler
- **llm-d GitHub**: https://github.com/llm-d/llm-d
- **llm-d-benchmark GitHub**: https://github.com/llm-d/llm-d-benchmark