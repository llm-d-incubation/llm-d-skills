# WVA Autoscale llm-d Workers Skill

## Overview

This skill helps configure and optimize Workload Variant Autoscaler (WVA) for llm-d inference deployments. Unlike traditional autoscaling approaches, this skill focuses on **configuration guidance** rather than installation automation.

## Key Focus: Configuration, Not Installation

This skill is designed to help users:
- **Configure WVA** based on specific requirements (aggressive scaling, cost optimization, etc.)
- **Tune saturation thresholds** for optimal performance
- **Set up multi-variant deployments** with cost-aware scaling
- **Troubleshoot WVA behavior** and scaling decisions
- **Align WVA with Inference Scheduler (EPP)** for optimal cluster performance

## What This Skill Does NOT Do

- ❌ Create new automation scripts (uses existing ones from llm-d repos)
- ❌ Duplicate installation documentation (links to official guides)
- ❌ Provide generic configurations (asks questions to understand requirements)

## Repository Requirements

This skill requires access to three repositories:

1. **llm-d**: Main repository with installation guides
   - GitHub: https://github.com/llm-d/llm-d
   - Contains: `guides/workload-autoscaling/` with helmfiles and templates

2. **llm-d-workload-variant-autoscaler**: WVA controller repository
   - GitHub: https://github.com/llm-d/llm-d-workload-variant-autoscaler
   - Contains: Documentation, configuration samples, CRDs

3. **llm-d-benchmark**: Testing and benchmarking tools
   - GitHub: https://github.com/llm-d/llm-d-benchmark
   - Contains: Testing scripts, workload profiles

### Repository Setup

When you first use this skill, it will:
1. Check for repositories in common locations
2. Ask you to specify custom locations if not found
3. Offer to clone missing repositories to a location of your choice

The skill uses environment variables to reference repository paths:
- `LLMD_REPO_PATH`: Path to llm-d repository
- `WVA_REPO_PATH`: Path to llm-d-workload-variant-autoscaler repository
- `BENCHMARK_REPO_PATH`: Path to llm-d-benchmark repository

## Skill Structure

```
skills/wva-autoscale-llm-d-workers/
├── SKILL.md              # Main skill with configuration guidance
├── Troubleshooting.md    # Quick troubleshooting reference
└── README.md            # This file
```

## Configuration Patterns

The skill provides guidance for common configuration patterns:

### 1. Aggressive Scaling (Low Latency)
- Lower saturation thresholds (kvCacheThreshold: 0.70)
- Higher spare triggers (kvSpareTrigger: 0.15)
- Faster HPA stabilization (60s scale-up)

### 2. Cost-Optimized Multi-Variant
- Multiple VariantAutoscaling resources with different costs
- WVA preferentially scales cheaper variants
- Example: H100 (variantCost: "80.0") vs A100 (variantCost: "40.0")

### 3. Conservative Scaling (Stability)
- Higher saturation thresholds (kvCacheThreshold: 0.85)
- Lower spare triggers (kvSpareTrigger: 0.05)
- Longer HPA stabilization (300s scale-up, 600s scale-down)

### 4. Scale-to-Zero (Development)
- Enable in WVA values: `scaleToZero: true`
- Configure retention period in ConfigMap
- Set HPA minReplicas: 0

## Key Concepts

### What is WVA?

WVA (Workload Variant Autoscaler) provides intelligent autoscaling for LLM inference using:
- **KV Cache Saturation**: Memory pressure in inference server
- **Queue Depth**: Request backlog monitoring
- **Cost Optimization**: Preferential scaling of cheaper variants
- **Spare Capacity Model**: Proactive scaling before saturation

### What is a Variant?

A variant is a way of serving a model with a specific combination of:
- Hardware (H100, A100, L4 GPUs)
- Runtime configuration
- Serving approach (parallelism, LoRA adapters)

Multiple variants of the same model enable cost-aware scaling decisions.

### Critical: Threshold Alignment

WVA and Inference Scheduler (End Point Picker) must use the same saturation thresholds for optimal performance. Misalignment causes:
- EPP marks replica saturated → stops routing → WVA sees capacity → doesn't scale
- Or: WVA scales up → EPP still routing to old replicas → new capacity unused

## Usage Examples

### Example 1: Basic Configuration Request
**User**: "Set up autoscaling for Qwen/Qwen3-32B on H100s"

**Skill Response**:
1. Asks clarifying questions (scaling goals, platform, etc.)
2. Provides VariantAutoscaling YAML
3. Provides HPA configuration
4. Explains monitoring commands
5. Links to relevant documentation

### Example 2: Multi-Variant Setup
**User**: "I have Llama-70B on H100 and A100, optimize for cost"

**Skill Response**:
1. Creates two VariantAutoscaling resources with different costs
2. Explains how WVA will prefer A100 (cheaper)
3. Provides HPA configurations for both
4. Shows monitoring commands to verify behavior

### Example 3: Troubleshooting
**User**: "WVA isn't scaling, replicas stay at 1"

**Skill Response**:
1. Checks current saturation levels
2. Reviews WVA controller logs
3. Verifies HPA metrics
4. Suggests threshold adjustments if needed

## Testing

Use llm-d-benchmark to test WVA configurations:

```bash
# Deploy with WVA
cd ${BENCHMARK_REPO_PATH}
./setup/standup.sh -p <namespace> -m <model-id> -c inference-scheduling --wva

# Run workload
./run.sh -l guidellm -w chatbot_synthetic -p <namespace> -m <model-id> -c inference-scheduling

# Teardown
./setup/teardown.sh -p <namespace> -d -c inference-scheduling
```

## Best Practices

1. **Start with defaults**: Use default thresholds, tune based on observed behavior
2. **Align thresholds**: Keep WVA and EPP synchronized
3. **Monitor first**: Observe saturation patterns before aggressive tuning
4. **Stabilization windows**: Use longer windows to prevent flapping
5. **Test with load**: Validate with llm-d-benchmark under realistic load
6. **Cost accuracy**: Set variantCost to reflect actual infrastructure costs
7. **Scale-to-zero**: Only enable in dev/test, not production

## Changes from Previous Version

### What Changed

1. **Focus shifted from installation to configuration**
   - Removed custom installation scripts
   - Links to official installation guides instead
   - Emphasizes configuration patterns and tuning

2. **Portable repository references**
   - Uses environment variables instead of hardcoded paths
   - Detects and clones repositories as needed
   - Works across different users and machines

3. **Configuration-centric approach**
   - Provides configuration patterns for common use cases
   - Explains the "why" behind configuration choices
   - Helps translate user requirements into WVA config

4. **Simplified structure**
   - Removed scripts/ and templates/ directories
   - Uses existing scripts from llm-d repositories
   - Focuses on guidance, not automation

### What Stayed the Same

- Troubleshooting guidance (updated with dynamic paths)
- Focus on WVA for llm-d deployments
- Support for multi-variant cost optimization
- Emphasis on threshold alignment with EPP

## Contributing

When improving this skill:
1. Keep focus on configuration guidance, not installation
2. Use existing scripts from llm-d repositories
3. Provide specific examples based on user requirements
4. Explain the reasoning behind configuration choices
5. Link to official documentation for detailed information

## References

- **WVA GitHub**: https://github.com/llm-d/llm-d-workload-variant-autoscaler
- **llm-d GitHub**: https://github.com/llm-d/llm-d
- **llm-d-benchmark GitHub**: https://github.com/llm-d/llm-d-benchmark