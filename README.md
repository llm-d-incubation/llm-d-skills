# llm-d Skills

A collection of skills for deploying and benchmarking llm-d. This project follows the [anthropics/skills](https://github.com/anthropics/skills) template format.

## Overview

This repository provides modular, reusable agent skills required to operate and deploy llm-d, following the Anthropics `SKILL.md` specification. Each skill is a directory implementing automation, scripts, and metadata for a specific operational task, reusing llm-d guides and scripts as much as possible.

All skills adhere to the Anthropics skills template and can be copied into a code assistant skills directory for use. The code assistant will read the skills when pointed to the skills directory. Note that the code assistant reads the name and description of the skill, and will load the entire skill only when prompted to perform a task associated with that skill.

In the case of Claude code, skills residing in `.claude/skills/` at the project root will be automatically available for the code assistant. 


## Installation

### Claude Code plugin marketplace (recommended)

This repository is a Claude Code plugin marketplace. Each skill is published as its own plugin, so you install only the ones you need:

```
/plugin marketplace add llm-d-incubation/llm-d-skills
```

Then install any subset:

```
/plugin install deploy-llm-d@llm-d
/plugin install run-llm-d-benchmark@llm-d
/plugin install teardown-llm-d@llm-d
```

Or install all of them at once:

```
/plugin install llm-d-all@llm-d
```

You can also browse and pick them interactively with `/plugin`.

Every skill in the [Skills Index](#skills-index) below is a plugin of the same name, plus `llm-d-autoconfig` from [`autoconfig/`](autoconfig/). `compare-llm-d-configurations` drives the deploy, benchmark, and teardown skills, so installing it pulls in `deploy-llm-d`, `run-llm-d-benchmark`, and `teardown-llm-d` automatically.

New and updated skills reach users as soon as they land on `main`, with no release step.

### Manual install

Alternatively, copy any skill directory from [`skills/`](skills/) into `.claude/skills/` in your project (or `~/.claude/skills/` for all projects).

## Skills Index

| Skill | Description |
|-------|-------------|
| [create-gke-infra-llm-d](skills/create-gke-infra-llm-d/) | Create or prepare GKE infrastructure (cluster, GPU node pools, RDMA/RoCE networking, DRA/DRANET drivers, Gateway API prerequisites) so llm-d can be deployed on it. |
| [deploy-llm-d](skills/deploy-llm-d/) | Configure and deploy llm-d on existing Kubernetes and OpenShift clusters. |
| [teardown-llm-d](skills/teardown-llm-d/) | Tear down, remove, clean up, or undeploy a deployed llm-d stack, using the guide's own `cleanup` steps where available (llm-d v1.0 and later). |
| [run-llm-d-benchmark](skills/run-llm-d-benchmark/) | Run a benchmark workload against an already deployed llm-d stack using llm-d-benchmark tooling. |
| [run-fma-benchmark](skills/run-fma-benchmark/) | Run the Fast Model Actuation (FMA) actuation-timing benchmark (nop harness, standup → run → teardown) measuring hot/warm/cold actuation latency. |
| [compare-llm-d-configurations](skills/compare-llm-d-configurations/) | Compare the benchmark performance of two llm-d stack configurations end-to-end. |
| [configure-wva-autoscaling-llm-d](skills/configure-wva-autoscaling-llm-d/) | Configure and optimize Workload Variant Autoscaler (WVA) for llm-d inference deployments. |
| [clear-kv-cache-tiers-in-llm-d-deployment](skills/clear-kv-cache-tiers-in-llm-d-deployment/) | Clear all KV / prefix cache tiers (GPU, CPU, and FS offload) on every vLLM pod for a clean benchmarking state. |

## Autoconfig

[`autoconfig/`](autoconfig/) is a larger, self-contained sub-project (kept outside `skills/` because it carries its own tested Python renderer, fixtures, and design docs). It configures an llm-d EPP `EndpointPickerConfig` from workload + SLA inputs and renders a complete deployable YAML set. The agent skill lives at [`autoconfig/skill/llm-d-autoconfig/`](autoconfig/skill/llm-d-autoconfig/); see [`autoconfig/README.md`](autoconfig/README.md) for how to install and run it.

## Choosing between autoconfig and the single-purpose skills

The single-purpose skills above each do **one** operation you already know you want. Autoconfig is a **guided, end-to-end workflow** for the case where you *don't* yet know the right configuration: you describe a workload + SLA and it recommends an EPP config (doc-anchored), renders a deployable bundle, and can drive the deploy and a benchmark.

| You want to… | Use |
|---|---|
| Create or prepare the GKE cluster itself (GPU node pools, RDMA/RoCE, DRA/DRANET) | [`create-gke-infra-llm-d`](skills/create-gke-infra-llm-d/) |
| Decide *what* llm-d config fits a workload + SLA, then stand it up from scratch | **autoconfig** |
| Deploy/verify/customize a config you already know | [`deploy-llm-d`](skills/deploy-llm-d/) |
| Benchmark an already-deployed stack | [`run-llm-d-benchmark`](skills/run-llm-d-benchmark/) |
| Measure Fast Model Actuation (FMA) actuation latency (hot/warm/cold) | [`run-fma-benchmark`](skills/run-fma-benchmark/) |
| Compare two stack configurations end-to-end | [`compare-llm-d-configurations`](skills/compare-llm-d-configurations/) |
| Configure WVA autoscaling | [`configure-wva-autoscaling-llm-d`](skills/configure-wva-autoscaling-llm-d/) |
| Tear down a deployed stack | [`teardown-llm-d`](skills/teardown-llm-d/) |

**How they relate.** Autoconfig owns config *generation* and its own deterministic, clone-free deploy/benchmark path (built around the bundle it renders). The single-purpose skills are the tools for a standalone operation on a config you already have — they follow the guide-driven (`LLMD_PATH` clone) workflow and can be used independently of autoconfig. To avoid duplication, autoconfig defers generic Kubernetes/deploy troubleshooting to [`deploy-llm-d`'s troubleshooting guide](skills/deploy-llm-d/references/troubleshooting.md) and keeps only EPP/PD/bundle-specific pitfalls of its own.

**For code assistants:** activate autoconfig when the user is asking *what config to use* / *how to set up llm-d for a workload* / *tune the EPP scheduler*. Activate a single-purpose skill when the user names a single, well-scoped operation (deploy this, benchmark that, tear this down) on a stack or config that's already decided.
