---
name: run-llm-d-benchmark
description: Runs a benchmark workload against an already deployed llm-d stack (high-performance distributed LLM inference) using llm-d-benchmark tooling. Use this skill whenever the user wants to benchmark, load test, measure performance, run inference-perf/guidellm/vllm-benchmark, evaluate throughput or latency, or compare llm-d configuration strategies — even if they don't say "benchmark" explicitly.
---

# Run llm-d Benchmark

## Purpose

Run a specific benchmark harness and workload against an already deployed llm-d stack (high-performance distributed LLM inference). Useful for evaluating the performance of the llm-d stack. When benchmark terminates, store benchmarking results in a local storage. Optionally create scripts on top of the raw results to analyze them.

## Workflow

### Step 1: Locate the llm-d stack and set environment variables

Locate the llm-d stack according to the following logic:

1. If a NAMESPACE environment variable is specified, the llm-d stack is assumed to be deployed there
2. If an oc project exists, the stack is assumed to be deployed in the current oc project.
3. If none of the above holds, ask the user for the NAMESPACE where it is deployed.
4. Make sure the NAMESPACE environment variable is set.

Verify that the stack is indeed deployed in the detected or provided namespace using kubectl commands. If you cannot locate the stack, ask the user to deploy one and refer to the llm-d-kubernetes deployment skill.

Also determine and set the `GATEWAY_SVC` environment variable — this is the name of the gateway service that exposes the inference endpoint. You can find it by running:
```bash
kubectl get svc -n $NAMESPACE
```
Look for the gateway or ingress service (typically named something like `llm-d-gateway` or `inference-gateway`). Ask the user to confirm if ambiguous.

### Step 2: Verify or create the benchmark PVC

Check whether a PVC already exists for storing benchmark results:
```bash
kubectl get pvc -n $NAMESPACE
```

If a suitable PVC exists, set `BENCHMARK_PVC` to its name and confirm with the user.

If no PVC exists, ask the user for a name and create one with **ReadWriteMany (RWX)** access mode and at least **200Gi** of storage:
```bash
BENCHMARK_PVC="<name>"
cat <<YAML | kubectl -n ${NAMESPACE} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${BENCHMARK_PVC}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 200Gi
YAML
```

Make sure the `BENCHMARK_PVC` environment variable is set.

### Step 3: Determine the template configuration file for benchmarking and instantiate it

List the available benchmarking template YAML files from the local `guides/*/benchmark-templates` directories. Show the user full paths so they know which guide each template originates from.

Display them to the user and ask them to select one. If the local directory is not available, fall back to browsing https://github.com/llm-d/llm-d/tree/main/guides/ and look for the content of `benchmark-templates` sub-directories.

Instantiate the selected template by substituting environment variables:
```bash
envsubst < guides/<selected-guide>/benchmark-templates/<selected-template>.yaml > config.yaml
```

### Step 4: Select benchmark harness 

Ask the user to either confirm the harness appearing in the selected configuration file, or select a new one. The available harnesses are:
- `inference-perf` 
- `guidellm`
- `inferencemax`
- `vllm-benchmark`

If a non-default harness is used, update the instantiated configuration file with the selected harness.

### Step 5: Select or generate workload to use

Ask the user to select one of the following options:

1. Confirm the existing workload specified in the config file (default)
2. Provide a link or a path to another workload
3. Provide a path to a trace to replay
4. provide a workload description. In this case, you should automatically generate a workload based on it.

If a non-default workload is used, update the instantiated configuration file with the selected or generated workload.

### Step 6: Verify the model to use

Display the model name specified in the configuration file to the user for verification.

Only if the user wants to change to a different model, check which models are available in the stack deployment. Ask the user select one of them, and update the instantiated configuration file with the selected model name.

### Step 7: Verify the final configuration

Display the instantiated configuration file to the user for verification. If the user wants to change any of the configuration parameters, update the instantiated configuration file based on user feedback.

**Common customizations include**:

 **Model name**: Which model to benchmark 
- **Workload type**: Type of synthetic data 
- **Load stages**: Request rates and durations
- **Input/Output distribution**: Prompt and response length parameters
  - `input_distribution`: min, max, mean, std, total_count
  - `output_distribution`: min, max, mean, std, total_count
- **API settings**: Streaming mode, completion type
- **Parallelism**: Number of parallel workload launcher pods

### Step 8: Obtain the benchmarking script

First check if `run_only.sh` is already available locally (it ships with the repo at `guides/benchmark/run_only.sh`). If so, use it directly — no download needed:
```bash
cp guides/benchmark/run_only.sh . && chmod u+x run_only.sh
```

If not available locally, download it:
```bash
curl -L -O https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/existing_stack/run_only.sh
chmod u+x run_only.sh
```

### Step 9: Run benchmarking

Use the command `./run_only.sh -c config.yaml`, monitor its progress and wait for its completion.

Note that the benchmark harness pod may still be running also after the benchmarking run is completed.

### Step 10: Locate and save results

Ask the user for a path to store the results. Save the benchmarking results by copying them from the BENCHMARK_PVC to a local `results` directory inside the path specified by the user.  This step requires locating the results of the current benchmarkr run in the BENCHMARK_PVC. This can be performed using the command ` kubectl exec -n $NAMESPACE llmdbench-harness-launcher -- ls -ltr /requests/`.

### Step 11: Run analyses and save them

Ask the user whether an analysis of raw results is requested. For example, create specific graphs or tables from the raw metric reporting. The user can also tell you what analysis is needed. If the user requests for an analysis, create corresponding analysis scripts, run them, and store them along with their results in the `analysis` directory inside the `results` directory.


#### Execution Rules

1. **Run every command** from Steps 1–11 in order using `execute_command`.
2. **After each command**, inspect the output:
   - If the command **succeeds** → proceed to the next command.
   - If the command **fails** → diagnose the error, apply a fix, and re-run before continuing.
3. **Never skip a step** — each step depends on the previous one succeeding.

**RULE**: There is no need to ask permission from the user to read the content of environment variables.

> ## 🔔 ALWAYS NOTIFY THE USER BEFORE CREATING ANYTHING
>
> **RULE**: Before creating ANY resource — including PVCs, files, or any Kubernetes object — you MUST first tell the user what you are about to create and why.
>
> **RULE**: Before deleting or overriding ANY resources — including PVCs, files, or any Kubernetes object — you MUST first get confirmation from the user.
>
>
> **Never silently create resources.** If you are unsure whether a resource already exists, check first, then notify before acting.

## What Not To Do

Critical rules to follow when configuring and running benchmarking on llm-d:

1. **Do NOT change cluster-level definitions** — All changes must be made exclusively inside the designated project namespace. Never modify cluster-wide resources (e.g., ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or any resource outside the target namespace). Scope every `kubectl apply`, `helm install`, and `helmfile apply` command to the target namespace using `-n ${NAMESPACE}`.

2. **Do NOT modify any existing code you did not create** — Only create new files and modify them as needed. Never edit pre-existing files in the repository (e.g., existing `values.yaml`, `helmfile.yaml`, `httproute.yaml`, `README.md`, or any other committed file). If customization is required, create a new file (e.g., `values-custom.yaml`, `httproute-custom.yaml`) and reference it instead.


## When to Use This Skill

Activate this skill when users need to:
- Run benchmarking against a deployed llm-d stack on Kubernetes
- Analyze llm-d specific-configuration serving performance 
- Optimize llm-d serving performance
- Choose between different configuration strategies

## Prerequisites

### Client Setup
**Guide**: `https://github.com/llm-d/llm-d/tree/main/guides/prereq/client-setup/README.md`

Required tools:
- kubectl
- helm
- helmfile
- git
- yq (YAML processor, version ≥ 4) — required by `run_only.sh`
- `timeout` utility — on macOS, install with `brew install coreutils` if missing


## Security Considerations

- Run benchmarking in isolated namespaces
- Use RBAC for access control
- Secure HuggingFace tokens as Kubernetes secrets
- Enable network policies for pod-to-pod communication
- Use TLS for gateway ingress
- Audit all deployments and changes


## Additional Resources

- **Basic Benchmarking Documentation**: `https://github.com/llm-d/llm-d/blob/main/guides/benchmark/README.md`
- **Advanced Benchmarking Documentation**: `https://github.com/llm-d/llm-d-benchmark/blob/main/README.md`
