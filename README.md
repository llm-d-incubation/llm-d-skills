# llm-d Skills

A collection of skills for deploying and benchmarking llm-d. This project follows the [anthropics/skills](https://github.com/anthropics/skills) template format.

## Overview

This repository provides modular, reusable agent skills required to operate and invoke vLLM, following the Anthropics `SKILL.md` specification. Each skill is a directory implementing automation, scripts, and metadata for a specific operational task, reusing llm-d guides and scripts as much as possible.

All skills adhere to the Anthropics skills template and can be copied into a code assistant skills directory for use. The code assistant will read the skills when pointed to the skills directory. Note that the code assistant reads the name and description of the skill, and will load the entire skill only when prompted to perform a task associated with that skill.

In the case of Claude code, skills residing in `.claude/skills/` at the project root will be automatically available for the code assistant. 


## Skills Index

| Skill | Description |
|-------|-------------|
| [deploy-llm-d](skills/deployment/) | Configure and deploy llm-d on existing Kubernetes and OpenShift clusters. |
| [teardown-llm-d](skills/teardown-llm-d/) | Tear down, remove, clean up, or undeploy a deployed llm-d stack. |
| [run-llm-d-benchmark](skills/run-llm-d-benchmark/) | Run a benchmark workload against an already deployed llm-d stack using llm-d-benchmark tooling. |
| [compare-llm-d-configurations](skills/compare-llm-d-configurations/) | Compare the benchmark performance of two llm-d stack configurations end-to-end. |