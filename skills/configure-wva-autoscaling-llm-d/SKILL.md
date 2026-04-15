---
name: configure-wva-autoscaling-llm-d
description: Configure and optimize Workload Variant Autoscaler (WVA) for llm-d inference deployments. Use when users want to set up autoscaling based on KV cache saturation, configure multi-variant cost optimization, tune saturation thresholds, enable scale-to-zero, or troubleshoot WVA behavior. Helps translate user requirements like "I want aggressive scaling" or "optimize for cost across H100 and A100 variants" into proper WVA configuration.
---

# WVA Configuration for llm-d Autoscaling

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

2. **Do NOT modify existing repository code** - Cloning a missing repository is allowed and required for this skill, but never edit code you did not create. If existing code must be adjusted, copy it to a new location, modify the copied file there, and reference the new file instead of changing the original.

3. **ALWAYS use existing skill scripts first** - Use scripts in [scripts](./scripts). Only perform manual edits if scripts fail due to non-standard deployment structure.

4. **Verify cluster resources** - Check available GPU/RDMA resources before applying changes.

## Prerequisites: Repository Setup

Before using this skill, ensure you have the required repositories. The skill must check for them first, ask the user for a directory path if any repository is missing, and clone only the missing repositories into that user-approved location.

**Required Repositories**:
1. **llm-d**: Main llm-d repository with guides and helmfiles
   - GitHub: https://github.com/llm-d/llm-d
   - Contains: `guides/workload-autoscaling/` with installation templates

2. **llm-d-workload-variant-autoscaler**: WVA controller repository
   - GitHub: https://github.com/llm-d/llm-d-workload-variant-autoscaler
   - Contains: Documentation, configuration samples, and CRDs

3. **llm-d-benchmark**: Benchmarking and testing tools
   - GitHub: https://github.com/llm-d/llm-d-benchmark
   - Contains: Testing scripts and workload profiles

**Set repository environment variables**:
1. Ask the user for the existing repository paths, or ask for a directory path where missing repositories should be cloned
2. If a required repository is missing, ask for approval before cloning it into the user-provided directory
3. Set `LLMD_REPO_PATH`, `WVA_REPO_PATH`, and `BENCHMARK_REPO_PATH` after paths are confirmed or cloning completes
4. Use these variables for all repository references in this skill

**Repository Detection**: When you start using this skill, I will:
1. Check if repositories exist in common locations
2. Ask you to specify custom locations if not found
3. Ask for a directory path where missing repositories should be cloned
4. Offer to clone only the missing repositories to that location


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

## Core Workflow

When a user asks for WVA configuration help, follow this workflow:

### 1. Understand Requirements

Ask clarifying questions to understand:
- **Scaling goals**: Aggressive scaling, cost optimization, or balanced?
- **Variants**: Single accelerator type or multi-variant (H100/A100/L4)?
- **Scale-to-zero**: Should replicas scale to zero during idle periods?
- **Platform**: OpenShift, GKE, Kind, or other Kubernetes?

### 2. Configuration Strategy

Based on requirements, help configure:

#### A. VariantAutoscaling Resource
The core WVA resource that defines autoscaling for a deployment.

**Template**: [`scripts/configs/variantautoscaling-basic.yaml`](scripts/configs/variantautoscaling-basic.yaml)

#### B. Saturation Thresholds
Configure when WVA considers a replica saturated and triggers scaling:

**Key Parameters**:
- `kvCacheThreshold`: KV cache utilization threshold (0.0-1.0, default: 0.80)
- `queueLengthThreshold`: Queue depth threshold (default: 5)
- `kvSpareTrigger`: Scale-up when average spare KV capacity < trigger (default: 0.10)
- `queueSpareTrigger`: Scale-up when average spare queue capacity < trigger (default: 3)

#### C. HPA Configuration
WVA works with Kubernetes HPA to perform actual scaling.

**Template**: [`scripts/configs/hpa-basic.yaml`](scripts/configs/hpa-basic.yaml)

### 3. Common Configuration Patterns

#### Pattern 1: Single Variant with Moderate Scaling
**For example when user says**: "Set up autoscaling for Qwen/Qwen3-32B on H100s, moderate scaling behavior"

**Configuration**:
- Balanced saturation thresholds (kvCacheThreshold: 0.80)
- Standard spare triggers (kvSpareTrigger: 0.10)
- Moderate HPA stabilization (120s scale-up, 300s scale-down)

**Example Configuration**: [`scripts/configs/example1-single-variant.yaml`](scripts/configs/example1-single-variant.yaml)

#### Pattern 2: Cost-Optimized Multi-Variant
**For example when user says**: "I have H100 and A100 GPUs, optimize for cost" or "I have Llama-70B on both H100 and A100, optimize for cost"

**Configuration**:
- Create VariantAutoscaling for each variant with different costs
- H100: variantCost: "80.0" (premium)
- A100: variantCost: "40.0" (standard)
- WVA will prefer scaling A100 first, H100 only when needed

**Example Configuration**: [`scripts/configs/example2-multi-variant.yaml`](scripts/configs/example2-multi-variant.yaml)

**Behavior**: WVA will preferentially scale the A100 variant (lower cost) and only scale H100 when A100 capacity is exhausted.

#### Pattern 3: Aggressive Scaling (Low Latency Priority)
**For example when user says**: "I need fast response times, scale aggressively" or "I need sub-second latency, scale aggressively"

**Configuration**:
- Lower saturation thresholds (kvCacheThreshold: 0.70)
- Higher spare triggers (kvSpareTrigger: 0.15)
- Faster HPA stabilization (60s scale-up window)

**Example Configuration**:
- HPA: [`scripts/configs/example3-aggressive-scaling.yaml`](scripts/configs/example3-aggressive-scaling.yaml)
- Saturation Config: [`scripts/configs/configmap-aggressive-saturation.yaml`](scripts/configs/configmap-aggressive-saturation.yaml)

#### Pattern 4: Conservative Scaling (Stability Priority)
**For example when user says**: "Avoid frequent scaling, prefer stability"

**Configuration**:
- Higher saturation thresholds (kvCacheThreshold: 0.85)
- Lower spare triggers (kvSpareTrigger: 0.05)
- Longer HPA stabilization (300s scale-up, 600s scale-down)

#### Pattern 5: Scale-to-Zero (Development/Testing)
**For example when user says**: "Scale to zero when idle to save costs" or "Development environment, scale to zero when idle"

**Configuration**:
- Enable in WVA values: `scaleToZero: true`
- Configure retention period in ConfigMap
- Set HPA minReplicas: 0 (requires alpha feature gate)

**Example Configuration**: [`scripts/configs/example4-scale-to-zero.yaml`](scripts/configs/example4-scale-to-zero.yaml)

**Note**: Enable in WVA Helm values with `wva.scaleToZero: true`

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

## Troubleshooting

For detailed troubleshooting guidance, see [`Troubleshooting.md`](./Troubleshooting.md).

**Quick troubleshooting scripts**:
```bash
# Check metrics availability
./scripts/troubleshoot-metrics.sh <namespace> <pod-name>

# Check scaling behavior
./scripts/troubleshoot-scaling.sh <namespace>

# Verify WVA setup
./scripts/verify-wva.sh <namespace>
```

**Common issues covered in Troubleshooting.md**:
- METRICSREADY: False
- WVA Not Scaling
- Frequent Scaling (Flapping)
- Wrong Deployment Target
- Prometheus Connection Issues
- Scale-to-Zero Not Working
- Multi-Variant Cost Optimization Issues
- Threshold Tuning Guide
- EPP/WVA Threshold Alignment

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