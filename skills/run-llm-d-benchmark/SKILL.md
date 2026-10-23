---
name: run-llm-d-benchmark
description: Benchmark an already-deployed llm-d stack (llm-d v1.0 and later) with the llmdbenchmark CLI from llm-d-benchmark. Use this skill when the user wants to run a benchmark workload against a deployed llm-d stack, either following a named guide (for example optimized-baseline, pd-disaggregation) or with a custom workload profile against any OpenAI-compatible endpoint. Activate for requests to measure performance (TTFT, TPOT, ITL, throughput), validate a deployment under load, or run inference-perf, guidellm, vllm-benchmark, aiperf, inferencemax, or lm-eval, even if the word "benchmark" is not used.
---

# Run llm-d Benchmark

## Purpose

Run a benchmark workload against an already-deployed llm-d stack with the `llmdbenchmark` CLI (the run-only path of llm-d-benchmark). The CLI deploys a harness launcher pod into the namespace, renders a workload profile into it, runs the chosen harness against the endpoint, copies the results to a local workspace, and runs the analysis that produces the harness-agnostic benchmark reports. Two modes:

- **Guide mode**: the stack was deployed from a named llm-d guide. `--spec guides/<name>` selects the matching benchmark scenario and the `guide_<name>_<n>.yaml` profiles reproduce the published load ladders.
- **Custom endpoint mode**: the user supplies an endpoint URL and a workload profile. A scenario is still required (`--spec`), so the closest guide is used.

The upstream reference for this skill is `${LLMD_PATH}/docs/operations/validation/benchmark.md` in the llm-d repository (the former `helpers/benchmark.md`). Flags and profiles below were checked against llm-d-benchmark v1.0.0.

## Rules

1. **Do not change cluster-level resources.** Scope every `kubectl` command to `-n ${NAMESPACE}`. The CLI itself creates only namespaced objects (harness pod, ConfigMaps, the workload PVC, the data-access pod, llm-d-prism).
2. **Do not modify committed files** in the llm-d or llm-d-benchmark checkouts. New profiles are new files under `workload/profiles/<harness>/` or are passed with `--workload-file-path`.
3. **Notify the user before creating Kubernetes resources** and **confirm before deleting any**.
4. Reading environment variables needs no permission.

## Prerequisites

Client side: `kubectl` (or `oc`), `helm`, `git`, `curl`, `jq`, and either `uv` or a system Python 3.14 or newer for the CLI's virtualenv (llm-d-benchmark v1.0.0 requires Python 3.14; `uv` downloads it). The installer installs missing `helm`, `helmfile`, `kubectl`, and `oc` through the system package manager, which may require `sudo` on Linux; install them beforehand to avoid prompts.

Cluster side:

- A deployed stack whose endpoint is reachable from inside the cluster (`deploy-llm-d`).
- The Secret `llm-d-hf-token` in the harness namespace. The harness pod uses it to download the tokenizer; gated models fail without it.
- CPU headroom for the harness launcher pod: 16 CPUs and 32 GiB memory by default. Smaller requests are set with `--set harness.resources.cpu=<n> --set harness.resources.memory=<size>` (Step 7).
- A `ReadWriteMany` StorageClass for the workload PVC, or `--no-pvc` (Step 7).

---

## Workflow

### Step 1: Verify or Install the `llmdbenchmark` CLI

```bash
command -v llmdbenchmark && llmdbenchmark --version
```

If it is not installed, clone the repository and run the installer with `--uv`, which skips the interactive prompt and lets `uv` provide Python 3.14 (it creates `./llm-d-benchmark/.venv`):

```bash
git clone https://github.com/llm-d/llm-d-benchmark.git
cd llm-d-benchmark && ./install.sh --uv
```

`./install.sh --no-uv -y` uses the system interpreter instead and fails with `Python 3.14+ required` on older systems; do not combine `-y` with `--uv`, since `-y` forces the system interpreter. The one-line form `curl -sSL https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/install.sh | bash` is equivalent but prompts for the virtualenv tool. Activate the virtualenv and stay inside the repository for every later command: the virtualenv provides the `llmdbenchmark` executable and the repository provides `workload/profiles/` and `config/specification/`.

```bash
cd llm-d-benchmark
source .venv/bin/activate
llmdbenchmark --version
```

An existing clone is reused by the installer but not updated. If a flag below is reported as `unrecognized arguments`, run `git -C llm-d-benchmark pull` and re-run the installer.

---

### Step 2: Locate the Stack and the Guide

1. `NAMESPACE`: the environment variable, else the active `oc project`, else ask. Export it.
2. Confirm a stack is deployed and identify the guide:
   ```bash
   helm list -n ${NAMESPACE}                                   # router release: chart llm-d-router-*, release name = guide name
   kubectl get pods -n ${NAMESPACE} -L llm-d.ai/guide,llm-d.ai/role
   ```
   The `deploy-llm-d` record `deployments/deploy-*.sh` (header line `guide: ... namespace: ... mode: ...`) gives the same information when present. Set `GUIDE_NAME` (for example `optimized-baseline`, `pd-disaggregation`). If no pods are running, tell the user the stack is not deployed and point to `deploy-llm-d`.
3. Map the guide to a benchmark scenario:
   ```bash
   ls config/specification/guides/        # available --spec values, without the .yaml.j2 suffix
   ```
   Use `--spec guides/${GUIDE_NAME}` when a file of that name exists. Guides without a scenario (model guides under `guides/models/`, `omni-serving`, `agentic-api`, `modelexpress-p2p`, `pod-snapshot`, `rollouts`) use the scenario of the closest topology: `guides/optimized-baseline` for aggregated serving, `guides/pd-disaggregation` for prefill/decode, `guides/wide-ep` for wide expert parallelism. Say so to the user; the scenario only shapes the plan the CLI renders around the harness pod.

In custom endpoint mode skip the guide detection, set `SPEC=guides/optimized-baseline` unless the user names another, and take `ENDPOINT_URL` from the user in Step 3.

---

### Step 3: Resolve the Endpoint and Gateway Class

Standalone Mode (the default of every guide; the router is an EPP pod with an Envoy sidecar):

```bash
export ENDPOINT_URL="http://$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')"
export GATEWAY_CLASS=standalone      # epponly is accepted as a synonym
```

Gateway Mode (a Kubernetes Gateway in front of the InferencePool):

```bash
export ENDPOINT_URL="http://$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')"
export GATEWAY_CLASS=<istio|agentgateway|gke>   # the provider used when the Gateway was deployed
```

`--gateway-class` must be passed even in run-only mode; without it the rendered plan may not match the topology. `llmdbenchmark --spec ${SPEC} run --list-endpoints --namespace ${NAMESPACE}` prints the endpoints the CLI can detect, with ready-to-run invocations.

If `kubectl get svc -n ${NAMESPACE}` shows neither service, list the services and ask the user which one fronts the model servers.

---

### Step 4: Confirm the Served Model Name

`--model` must equal the ID the endpoint reports. Query it from inside the cluster:

```bash
kubectl run curl-probe -n ${NAMESPACE} --rm -i --restart=Never --image=cfmanteiga/alpine-bash-curl-jq \
  -- sh -c "curl -s ${ENDPOINT_URL}/v1/models | jq -r '.data[].id'"
```

Set `MODEL` to the returned string (for example `Qwen/Qwen3-32B`). With several models, ask the user which one to benchmark. The error `did not return expected model 'X'. Available models: ['Y']` always means this step was skipped or wrong.

---

### Step 5: Select the Harness

| Harness | Tool | Use |
|---|---|---|
| `inference-perf` (default) | kubernetes-sigs/inference-perf | Load ladders, shared-prefix and multi-turn workloads, trace replay; richest profile catalog, all `guide_*` profiles |
| `guidellm` | guidellm | Rate sweeps and concurrency patterns |
| `vllm-benchmark` | `vllm bench serve` | vLLM-native latency percentiles; `guide_wide-ep_1` |
| `aiperf` | NVIDIA AIPerf | Synthetic or trace datasets (for example mooncake traces) |
| `inferencemax` | custom script | Warmup and seeded random workloads |
| `lm-eval` | lm-evaluation-harness | Accuracy on standard tasks; no latency or throughput report |
| `nop` | no-op | Pipeline check without load (harness pod, PVC, collection) |

Set `HARNESS`. All harnesses except `lm-eval` write the harness-agnostic `benchmark_report,_stage_*.yaml` files used in Step 14.

---

### Step 6: Select a Workload Profile

Profiles live in `workload/profiles/${HARNESS}/` as `.yaml.in` templates (a few as `.yaml`); always pass the `.yaml` form to `--workload`.

```bash
ls workload/profiles/${HARNESS}/
ls workload/profiles/${HARNESS}/ | grep -E "^guide_${GUIDE_NAME}_"     # guide mode
```

Recommendations for `inference-perf`:

| Goal | Profile |
|---|---|
| Smoke test (1 req/s for 30 s) | `sanity_random.yaml` |
| Reproduce the guide's published load ladder | `guide_${GUIDE_NAME}_1.yaml` (and `_2`, when present) |
| Prefix-cache aware routing under a ladder | `shared_prefix_synthetic.yaml`, `approx_prefix_cache_ladder.yaml` |
| Multi-turn chat | `shared_prefix_multi_turn_chat.yaml`, `interactive-chat.yaml` |
| Code completion, summarization, chatbot | `code_completion_synthetic.yaml`, `summarization_synthetic.yaml`, `chatbot_synthetic.yaml` |
| Prefill-heavy or decode-heavy steady load | `random_prefill_heavy.yaml`, `random_decode_heavy.yaml`, `random_symmetrical.yaml` |
| Agentic trace replay | `agentic_code_generation.yaml`, `agent_llm_traces_v2.yaml` |

The catalog with load pattern and data type of every profile is `workload/README.md` ("Available Profiles by Harness"). Guide profiles are sized for the guide's reference hardware; a smaller deployment should start with `sanity_random.yaml` or an `--overrides` reduced ladder (Step 9).

Custom profiles: copy a `.yaml.in` template to a new name in the same directory and pass its `.yaml` name, or pass any local file with `--workload-file-path <path>` (then `--workload` is not resolved). `REPLACE_ENV_*` tokens (`REPLACE_ENV_LLMDBENCH_DEPLOY_CURRENT_MODEL`, `REPLACE_ENV_LLMDBENCH_HARNESS_STACK_ENDPOINT_URL`) are substituted at run time. Set `WORKLOAD_PROFILE`.

---

### Step 7: Size the Harness Pod and Choose the Storage Mode

1. **CPU and memory.** The launcher pod requests 16 CPUs and 32 GiB by default and stays `Pending` on smaller nodes. Check headroom and lower the request when needed; load generation is CPU-bound, so a smaller request limits the achievable request rate:
   ```bash
   kubectl describe nodes | grep -A4 'Allocated resources' | grep -E 'cpu|memory'
   SET_ARGS=(--set harness.resources.cpu=4 --set harness.resources.memory=8Gi)   # example for small CPU nodes
   ```
   `--set` is a `run` flag (after `run`) and overrides the scenario; `harness.nodeSelector` is settable the same way. The scenario's `harness.resources.memoryLimit` (128Gi) is a limit and does not block scheduling.
2. **Workload PVC.** The harness, the data-access pod, and llm-d-prism share a `ReadWriteMany` PVC named `workload-pvc`:
   ```bash
   kubectl get storageclass
   kubectl get pvc workload-pvc -n ${NAMESPACE} 2>/dev/null
   ```
   With no RWX-capable class (GKE without the Filestore CSI driver, most PD-only clusters), use `--no-pvc`: results are copied from the harness pod directly and llm-d-prism is not deployed. With an RWX class that is not the default, set `storage.workloadPvc.storageClassName` in the scenario or with `--set`, and raise `--pvc-bind-timeout`. A PVC's StorageClass is immutable and the CLI reuses an existing claim; delete a claim created with the wrong class before retrying.
3. **Permissions.** Add the top-level `--non-admin` when the user lacks cluster-wide read access; the CLI then skips its cluster-admin sanity checks.
4. **HuggingFace Secret.** `kubectl get secret llm-d-hf-token -n ${NAMESPACE}`; create it as in the guide's `prerequisites.secrets` step if missing (the CLI does not create it).

---

### Step 8: Set the Workspace

Results land on the local machine under `<workspace>/runner-<timestamp>/`. Without `--workspace` the CLI creates a timestamped directory and prints it in the run summary. When the user, or a calling skill such as `compare-llm-d-configurations`, supplies a workspace:

```bash
export WORKSPACE_DIR=<path>; mkdir -p "${WORKSPACE_DIR}"
```

---

### Step 9: Override Profile Parameters (optional)

`--overrides "key=value,..."` edits fields of the rendered profile; keys are dotted paths, numeric segments index lists, values are parsed as YAML. A key whose parent path does not exist is ignored with a warning in the run log. Example for `sanity_random.yaml` at 5 req/s for 120 s with 500 prompts:

```bash
OVERRIDES="load.stages.0.rate=5,load.stages.0.duration=120,data.input_distribution.total_count=500"
```

---

### Step 10: Timeouts (if needed)

| Flag | Default | Controls |
|---|---|---|
| `--wait-timeout` | 3600 s (or the scenario's `harness.waitTimeout`) | harness pod start and harness completion, each phase separately |
| `--pvc-bind-timeout` | 240 s | `workload-pvc` reaching `Bound` (no effect with `--no-pvc`) |
| `--data-access-timeout` | 120 s | data-access pod `Ready` (no effect with `--no-pvc`) |

First-time image pulls and slow shared storage need `--wait-timeout 7200 --pvc-bind-timeout 1200 --data-access-timeout 600`. `--wait-timeout 0` dispatches and returns without waiting; combine it with `--no-cleanup`.

---

### Step 11: Show and Run the Benchmark Command

Display the command, then run it from inside `llm-d-benchmark/` with the virtualenv active:

```bash
llmdbenchmark \
    --spec           ${SPEC:-guides/${GUIDE_NAME}} \
    ${WORKSPACE_DIR:+--workspace "${WORKSPACE_DIR}"} \
    run \
    ${SET_ARGS[@]+"${SET_ARGS[@]}"} \
    --endpoint-url   "${ENDPOINT_URL}" \
    --gateway-class  "${GATEWAY_CLASS}" \
    --model          "${MODEL}" \
    --namespace      "${NAMESPACE}" \
    --harness        "${HARNESS:-inference-perf}" \
    --workload       "${WORKLOAD_PROFILE}" \
    ${OVERRIDES:+--overrides "${OVERRIDES}"} \
    ${NO_PVC:+--no-pvc} \
    ${MONITORING:+--monitoring} \
    --wait-timeout   ${WAIT_TIMEOUT:-3600}
```

`--spec`, `--workspace`, and `--non-admin` are accepted before or after `run`; `--set` and the flags below only after `run`. Optional flags: `--monitoring` scrapes the model server and EPP `/metrics` during the run and embeds them in the report (off by default); `--no-prism` skips the llm-d-prism dashboard; `--no-cleanup` keeps the harness pod and its ConfigMaps for inspection (the next run removes them); `--parallelism <n>` starts several harness pods with the same profile; `--output gs://... | s3://...` mirrors the results to cloud storage (`--output` does not accept local paths; use `--workspace`). `--analyze` is deprecated and ignored: analysis always runs inside the harness pod.

Note the workspace path printed at the start of the run; `RUN_DIR=<workspace>/runner-<timestamp>` is used below.

---

### Step 12: Monitor the Run

```bash
kubectl get pods -n ${NAMESPACE} -l app=llmdbench-harness-launcher -w
kubectl logs -n ${NAMESPACE} -l app=llmdbench-harness-launcher -f --tail=100
kubectl get pods -n ${NAMESPACE} -l role=llm-d-benchmark-data-access     # PVC mode only
```

The run ends with a `BENCHMARK RUN SUMMARY` block listing the harness, workload, model, treatments, the local results path, and, in PVC mode, how to reach llm-d-prism (a Route URL on OpenShift, a `kubectl port-forward -n ${NAMESPACE} svc/llm-d-prism 8080:<port>` command elsewhere). A `Pending` harness pod with `Insufficient cpu` means Step 7 sizing; an `OOMKilled` harness needs a larger `harness.resources.memory`. A failed run is diagnosed with the Troubleshooting section before any re-run; re-running without clearing the model servers' prefix cache measures a warm cache (`clear-kv-cache-tiers-in-llm-d-deployment`).

---

### Step 13: Collect Model Server Logs

Save the model server logs next to the results before the pods are recycled. Pods carry `llm-d.ai/guide=${GUIDE_NAME}` and `llm-d.ai/role`; the engine container is `modelserver`, decode pods of disaggregated guides also run `routing-proxy`:

```bash
mkdir -p "${RUN_DIR}/results/vllm-logs"
for pod in $(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'); do
  kubectl logs -n ${NAMESPACE} ${pod} -c modelserver --timestamps > "${RUN_DIR}/results/vllm-logs/${pod}.modelserver.log" 2>&1
  kubectl logs -n ${NAMESPACE} ${pod} -c routing-proxy --timestamps > "${RUN_DIR}/results/vllm-logs/${pod}.routing-proxy.log" 2>/dev/null || rm -f "${RUN_DIR}/results/vllm-logs/${pod}.routing-proxy.log"
done
kubectl logs -n ${NAMESPACE} deploy/${GUIDE_NAME}-epp -c epp --timestamps > "${RUN_DIR}/results/vllm-logs/${GUIDE_NAME}-epp.log" 2>&1 || true
```

Without the guide label (custom stacks) use `kubectl get pods -n ${NAMESPACE} --show-labels` to pick the selector. With `--monitoring` the CLI also captures pod logs into the results.

---

### Step 14: Verify and Summarize the Results

```bash
ls "${RUN_DIR}/results/"
find "${RUN_DIR}/results" -name 'benchmark_report*' -o -name 'summary_lifecycle_metrics.json' | sort
```

Layout per harness pod: `results/<experiment-id>_<i>/` with `benchmark_report,_stage_<n>.yaml` (harness-agnostic, schema v0.2), the harness's native files (`stage_<n>_lifecycle_metrics.json`, `summary_lifecycle_metrics.json`, `per_request_lifecycle_metrics.json` for inference-perf), `config.yaml`, the rendered profile, `stdout.log`, `stderr.log`; `plan/` and `environment/` sit next to `results/`.

If `results/` is empty (for example the copy phase lost the connection), re-collect without re-running: `llmdbenchmark --spec ${SPEC} ${WORKSPACE_DIR:+--workspace "${WORKSPACE_DIR}"} run --skip --namespace ${NAMESPACE} ...` reads the existing results from the PVC; with `--no-pvc --no-cleanup` the kept harness pod still holds them (`kubectl cp`).

Print the per-stage table from the benchmark reports:

```bash
python3 skills/run-llm-d-benchmark/scripts/summarize-results.py "${RUN_DIR}"
```

It reports requests and failures, request rate, output and total token rate, TTFT p50/p90/p99, TPOT and ITL means, and end-to-end latency p50/p90/p99 per stage (`--json` for structured output). `lm-eval` produces accuracy tables in its native files instead.

---

### Step 15: Announce Completion and Offer Cleanup

Report the run directory, the summary table, and the log directory:

```
Benchmark complete. Run directory: <RUN_DIR>
  results/<experiment-id>_<i>/benchmark_report,_stage_*.yaml   harness-agnostic reports
  results/<experiment-id>_<i>/summary_lifecycle_metrics.json   inference-perf native summary
  results/vllm-logs/                                           model server and EPP logs
  plan/, environment/                                          rendered plan and cluster context
```

Benchmark leftovers stay in the namespace between runs: `workload-pvc` (billed shared storage), the data-access pod, `service/llm-d-benchmark-harness`, the llm-d-prism Deployment and Service, and two ConfigMaps. Offer to remove them when the user is done benchmarking in the namespace, and only after confirmation (`--no-pvc` runs leave nothing but the ConfigMaps):

```bash
kubectl delete deployment,service -n ${NAMESPACE} --ignore-not-found -l app.kubernetes.io/name=llm-d-prism   # first: it mounts the PVC
kubectl delete -n ${NAMESPACE} --ignore-not-found pod/access-to-harness-data-workload-pvc service/llm-d-benchmark-harness \
  pvc/workload-pvc configmap/llm-d-benchmark-preprocesses configmap/llm-d-benchmark-run-parameters
kubectl delete pod -n ${NAMESPACE} --ignore-not-found -l app=llmdbench-harness-launcher                      # only after --no-cleanup
```

On OpenShift add `route` to the first command. Removing the stack itself is the `teardown-llm-d` skill.

---

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| `did not return expected model 'X'. Available models: ['Y']` | `--model` differs from `/v1/models`. Use the exact ID (Step 4). |
| `Could not detect endpoint for <stack>` | `--endpoint-url` missing in run-only mode. Pass it with `--gateway-class` (Step 3). |
| `Unknown output destination: ./results` | `--output` accepts only `local`, `gs://`, `s3://`. Use `--workspace` for a local path. |
| Harness pod `Pending`, `Insufficient cpu` or `Insufficient memory` | Default request is 16 CPUs and 32 GiB. `--set harness.resources.cpu=... --set harness.resources.memory=...` (Step 7). |
| `Timed out after 240s waiting for workload PVC` | Slow StorageClass: `--pvc-bind-timeout 1200`; or no default class: `kubectl get sc`, `kubectl describe pvc workload-pvc`. |
| `ProvisioningFailed ... multi writer with mount access type` | Default class is RWO-only. Use an RWX class via `storage.workloadPvc.storageClassName` (GKE: enable the Filestore CSI driver, class `standard-rwx`) or run with `--no-pvc`. Delete the stale claim (and llm-d-prism first) before retrying. |
| Harness fails downloading the tokenizer of a gated model | `llm-d-hf-token` missing in the harness namespace; the pod mounts it as optional, so it starts anyway. Create the Secret and re-run. |
| Harness `ContainerCreating` or `ImagePullBackOff` for a long time | First pull of the harness image; `--wait-timeout 7200`. Check events for registry or pull-secret errors. |
| `unrecognized arguments: --<flag>` | Installed CLI predates the flag. `git -C llm-d-benchmark pull` and re-run the installer. |
| Installer stops with `Python 3.14+ required`, or the `uv`-managed interpreter is killed at startup | llm-d-benchmark needs Python 3.14. Run `./install.sh --uv` without `-y`; if the machine's security policy blocks binaries that `uv` downloads, install Python 3.14 from a trusted source and use `./install.sh --no-uv`. |
| `--analyze ... is ignored: results are always analyzed now` | Informational; drop the flag. |
| Harness `OOMKilled` | Raise `harness.resources.memory` (and `memoryLimit`, default 128Gi) with `--set`. |
| Run finished but `results/` is empty | Connection lost during the copy phase. Re-collect with `run --skip`; in `--no-pvc` mode only kept pods (`--no-cleanup`) still hold the data. |
| High error rate in the report | Inspect `stderr.log` of the experiment directory and the model server logs from Step 13; common causes are `--max-model-len` smaller than the profile's sequence lengths and request timeouts under overload. |

---

## Execution Rules

1. Run the steps in order; each depends on the previous one.
2. After each command inspect the output: success proceeds, failure is diagnosed, fixed, and re-run.
3. Never skip Step 4 (model name), Step 7 (sizing and storage mode), Step 13 (logs before pods are recycled), and Step 14 (results verified locally).
4. Reading environment variables needs no permission; creating Kubernetes resources is announced first; deleting anything is confirmed first.

## What Not To Do

1. Do not change cluster-level resources or anything outside `${NAMESPACE}`.
2. Do not edit committed files in the llm-d-benchmark or llm-d checkouts; new profiles are new files.
3. Do not pass `--output` with a local path, and do not pass `--analyze`.
4. Do not re-run a benchmark on a warm prefix cache when a clean baseline is wanted; clear the cache tiers first.

## Security Considerations

- Run benchmarking in isolated namespaces with RBAC-scoped access.
- The harness pod receives the HuggingFace token through the `llm-d-hf-token` Secret; never print it or write it into the workspace.
- `workload-pvc` and llm-d-prism persist in the namespace and bill shared storage until removed.
- Audit runs through the per-run `plan/` and `environment/` directories.

## Additional Resources

- Performance assessment (canonical run-only reference): `${LLMD_PATH}/docs/operations/validation/benchmark.md`
- llm-d-benchmark repository: https://github.com/llm-d/llm-d-benchmark (`workload/README.md` profile catalog, `docs/benchmark_report.md` schema, `docs/analysis.md`, `docs/resource_requirements.md`, `docs/metrics_collection.md`)
- llm-d-prism dashboard: https://github.com/llm-d/llm-d-prism
- Results store and submission policy: `llmdbenchmark/results_store/README.md` in llm-d-benchmark
