---
name: deploy-llm-d
description: Configure and deploy an llm-d stack on an existing Kubernetes or OpenShift cluster by driving the machine-readable guide.yaml of a Well-Lit Path guide (llm-d v1.0 and later). Use this skill when users want to deploy, verify, or customize llm-d from a guide they have already chosen.
---

# Deploy llm-d Stack

## Command Execution Notice

Before executing any command, the agent will:

1. Explain what the command does and the expected outcome.
2. Show the exact command that will be executed.
3. Explain why the command is needed at this point of the workflow.

## Rules

1. **Notify the user before creating anything.** Before creating any resource (namespace, Secret, PVC, Helm release, Gateway, HTTPRoute, file, or any other Kubernetes object), state what will be created and why.
2. **Do not change cluster-level definitions.** All changes are made inside the target namespace. Never modify ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or any resource outside the target namespace. Scope every `kubectl apply`, `helm install`, and `kubectl delete` command with `-n ${NAMESPACE}`.
   The only exception is a guide's own cluster-scoped prerequisite step (`prerequisites.gaie`, `prerequisites.crds`, `prerequisites.lws`, `prerequisites.keda`, `prerequisites.kueue`, `prerequisites.compute_domain`). These install CRDs or controllers that the guide cannot run without. Check whether they are already present (Step 3). If they are missing, show the exact upstream command, state that it is cluster-scoped, and run it only after the user explicitly confirms. Otherwise hand the command to the cluster administrator and stop.
3. **Do not modify any existing code you did not create.** Never edit files committed in the llm-d checkout (`guide.yaml`, `README.md`, values files, kustomize overlays). Customizations live in new files under `deployments/` (Step 4.4).
4. **Do not send inference requests without approval.** Readiness checks use Kubernetes state only. Requests populate the KV cache and change benchmark baselines; the connectivity test is opt-in (Step 5).

## Overview

Since llm-d v1.0 every foundation and model guide under `${LLMD_PATH}/guides/` is a pair of files:

- `guide.yaml`: the machine-readable source of truth. It declares `env.static` variables (`NAMESPACE`, `ACCELERATOR_TYPE`, `MODEL_SERVER`, `INFRA_PROVIDER`, `MODEL`, ...), a `support` matrix, and step lists under `prerequisites`, `deploy`, `verify`, optionally `benchmark`, and `cleanup`. Steps carry `when:` filters (selected by variable values) and `skip_in:` tags.
- `README.md`: human-readable prose whose bash blocks are rendered from `guide.yaml`.

`${LLMD_PATH}/scripts/guide.py emit <guide-dir> env <section...> --var NAME=VALUE` assembles an executable bash script from selected sections, resolving `when:` filters against the variables. This skill drives deployments through `emit`, so the commands executed are exactly the guide's commands for the chosen variables.

Deployment shape common to the guides:

| Element | Value |
|---|---|
| Shared variables | `source ${REPO_ROOT}/guides/env.sh` (chart URLs, `ROUTER_CHART_VERSION`, `GAIE_URL`, `LWS_VERSION`) |
| Router install | `helm install ${GUIDE_NAME} ${ROUTER_STANDALONE_CHART}` or `${ROUTER_GATEWAY_CHART}` with `recipes/router/base.values.yaml` plus the guide's values file |
| Helm release name | `${GUIDE_NAME}` (one release per guide per namespace) |
| Model servers | `kubectl apply -k guides/<guide>/modelserver/<ACCELERATOR_TYPE>/<MODEL_SERVER>/<INFRA_PROVIDER>/` |
| Modes | `standalone` (default; EPP pod with an Envoy sidecar, service `${GUIDE_NAME}-epp` on port 80) or `gateway` (Kubernetes Gateway named `llm-d-inference-gateway` plus an HTTPRoute) |
| Workload kinds | `Deployment` for aggregated serving; `DisaggregatedSet` (LeaderWorkerSet controller, API group `disaggregatedset.x-k8s.io`) for prefill/decode and wide expert parallelism on NVIDIA GPU |
| Pod labels | `llm-d.ai/guide=<guide>`, `llm-d.ai/role=prefill|decode`, `llm-d.ai/engine-type`, `llm-d.ai/model` |
| Containers | `modelserver` (engine), `routing-proxy` (sidecar on decode pods) |

Guides that have no `guide.yaml` (README-only operations guides such as `rollouts`, `multi-model-routing`, `batch-serving`) are followed manually from their README under the same rules.

## When to Use This Skill

Activate this skill when users need to:

- Deploy LLM inference on Kubernetes or OpenShift from a named llm-d guide
- Choose between deployment strategies (aggregated, prefill/decode, wide-EP, tiered prefix cache, ...)
- Deploy on a specific accelerator and model server (NVIDIA, AMD, Intel XPU, Google TPU, CPU, and the community accelerators listed in the guide's support matrix; vLLM, SGLang, TensorRT-LLM, Atom)
- Modify an existing deployment (change model, replicas, engine flags, router values)

Do not use it to decide which configuration fits a workload; that is `llm-d-autoconfig`. Do not use it for benchmarking (`run-llm-d-benchmark`) or removal (`teardown-llm-d`).

## Prerequisites

Client side:

- `LLMD_PATH` pointing to a local llm-d checkout (Step 0)
- `kubectl` (or `oc`), `helm` 3.x, `git`, `jq`
- `python3` with PyYAML, or `uv` (both run `scripts/guide.py`)
- `HF_TOKEN` exported in the shell when the guide creates the `llm-d-hf-token` Secret

Cluster side (checked in Step 3):

- Kubernetes 1.29 or newer; 1.34 or newer for DRA-based overlays (`resource.k8s.io/v1`)
- Gateway API Inference Extension CRDs (`inferencepools.inference.networking.k8s.io`)
- LeaderWorkerSet controller with `enableDisaggregatedSet=true` for guides whose overlays render a `DisaggregatedSet`
- A Gateway provider (Istio, GKE Gateway, Agentgateway, Envoy AI Gateway, NGINX Gateway Fabric) only in `gateway` mode; see `${LLMD_PATH}/docs/infrastructure/gateway/README.md`
- Sufficient accelerators for the selected overlay (see the guide's support table)

## Workflow

### Step 0: Locate the llm-d Checkout

1. Use `LLMD_PATH` if set. Otherwise look for a nearby clone (`./llm-d`, `../llm-d`). If none exists, offer to clone:
   ```bash
   # release-1.0 is the branch the v1.0.0 guides are published from; main tracks development
   git clone --branch release-1.0 https://github.com/llm-d/llm-d.git && export LLMD_PATH="$(pwd)/llm-d"
   ```
   Use `main` or another branch or tag only when the user asks for it.
2. Record the checkout identity for the deployment script: `git -C ${LLMD_PATH} describe --tags --always` and `git -C ${LLMD_PATH} branch --show-current`.
3. Confirm the machine-readable tooling exists and runs:
   ```bash
   test -f ${LLMD_PATH}/scripts/guide.py && test -f ${LLMD_PATH}/docs/well-lit-paths/guides.yaml
   python3 -c 'import yaml' 2>/dev/null && GUIDE_PY="python3 ${LLMD_PATH}/scripts/guide.py" || GUIDE_PY="uv run ${LLMD_PATH}/scripts/guide.py"
   ${GUIDE_PY} --help >/dev/null
   ```
   If `scripts/guide.py` is absent, the checkout predates llm-d v1.0 (before 2026-08). Ask the user to update it; do not improvise commands from an old README.

### Step 1: Discover and Select a Guide

1. Read `${LLMD_PATH}/docs/well-lit-paths/guides.yaml`. Its `sections` (`foundations`, `models`, `operations`, `operations-startup`, `operations-traffic`) list every published guide with `dir`, `slug`, and `title`. Read `${LLMD_PATH}/guides/README.md` for the one-line descriptions.
2. For each candidate, note whether `<dir>/guide.yaml` exists. Only those are driven by `emit`.
3. Present the guides grouped by section with their descriptions. If the user has no preference, suggest `optimized-baseline`.
4. Set `GUIDE_DIR=${LLMD_PATH}/<dir>` (for example `${LLMD_PATH}/guides/optimized-baseline` or `${LLMD_PATH}/guides/models/glm-5-2`) and read `${GUIDE_DIR}/README.md` for the guide-specific prerequisites and the meaning of its variants.

### Step 2: Resolve the Namespace and Existing Releases

1. Use `NAMESPACE` if set; otherwise the current `oc project`; otherwise ask. Export `NAMESPACE`.
2. Check for an existing deployment of the same guide:
   ```bash
   helm list -n ${NAMESPACE}
   kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide -L llm-d.ai/guide,llm-d.ai/role
   ```
   The router release is named after the guide, so a release called `<guide>` already present means the guide is deployed in this namespace. Ask whether to modify it (Step 4.4), use another namespace, or stop. Do not install a second copy under the same name.

### Step 3: Summarize the Guide and Detect the Target

1. Summarize the guide's variables, support matrix, modes, and step paths:
   ```bash
   python3 skills/deploy-llm-d/scripts/list-guide-steps.py ${GUIDE_DIR}
   ```
   The output classifies every step path as `stage` (run in order), `mode=<name>` (run exactly one mode), `option(by-variables)` (selected by `when:` filters), `option(manual)` (alternatives that need a choice; the README explains them), or `test` (sends traffic; Step 5 only). Add `--json` for structured output.
2. Detect the accelerator and map it to the guide's `ACCELERATOR_TYPE` values:
   ```bash
   kubectl get nodes -o json | jq -r '.items[].status.allocatable | keys[]' \
     | grep -E '^(nvidia\.com/gpu|amd\.com/gpu|google\.com/tpu|iluvatar\.com/gpu|metax-tech\.com/gpu|birentech\.com/gpu|mthreads\.com/gpu)$' | sort | uniq -c
   kubectl get deviceclasses.resource.k8s.io -o name 2>/dev/null   # DRA: gpu.nvidia.com, gpu.intel.com, npu.rebellions.ai, mrdma.google.com
   kubectl get nodes -L cloud.google.com/gke-accelerator,cloud.google.com/gke-tpu-accelerator,cloud.google.com/gke-nodepool --no-headers 2>/dev/null | head
   ```

   | Signal | `ACCELERATOR_TYPE` |
   |---|---|
   | `nvidia.com/gpu` allocatable, or DeviceClass `gpu.nvidia.com` | `gpu` |
   | `amd.com/gpu` | `amd` |
   | DeviceClass `gpu.intel.com` | `xpu` |
   | `google.com/tpu` with node label `gke-tpu-accelerator=tpu-v6e-slice` / `tpu7x` | `tpu/v6` / `tpu/v7` (confirm against the support table) |
   | DeviceClass `npu.rebellions.ai` | `npu` |
   | `iluvatar.com/gpu`, `metax-tech.com/gpu`, `birentech.com/gpu`, `mthreads.com/gpu` | `iluvatar`, `metax`, `biren`, `mthreads` |
   | none of the above | `cpu`, only if the guide offers it; confirm with the user |

3. Set the remaining variables from the summary:
   - `MODEL_SERVER`: the guide default (`vllm`) unless the user asks for another engine the support matrix marks as `validated` or `community` for that accelerator.
   - `INFRA_PROVIDER`: `gke` when nodes carry `cloud.google.com/gke-nodepool` and the support matrix lists `gke` for the accelerator; otherwise `base`. Other values (`coreweave`, `aws`, `cks-mooncake`, `nixl/*`, `moriio/*`, `rdma`, `gke/a4x`) only on request.
   - `MODEL`: the served model the support matrix lists for the accelerator. Changing it is a customization (Step 4.4).
   - `MODE`: `standalone` unless the user asks for Gateway mode or a Gateway named `llm-d-inference-gateway` already exists in the namespace. In gateway mode map the GatewayClass to the chart's `provider.name`: `gke-l7-*` to `gke`, `istio` to `istio`, `agentgateway` to `agentgateway`, anything else to `none`.
   - `MONITORING`: `false` unless the user wants Prometheus monitoring and the stack exists.
4. Check prerequisites programmatically:
   ```bash
   kubectl get secret llm-d-hf-token -n ${NAMESPACE} >/dev/null 2>&1 && echo "HF secret: present" || echo "HF secret: missing (prerequisites.secrets will create it; HF_TOKEN must be exported)"
   kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1 && echo "GAIE CRDs: present" || echo "GAIE CRDs: missing (cluster-scoped; prerequisites.gaie)"
   kubectl get crd disaggregatedsets.disaggregatedset.x-k8s.io >/dev/null 2>&1 && echo "DisaggregatedSet CRD: present" || echo "DisaggregatedSet CRD: missing (needed only if the overlay renders a DisaggregatedSet)"
   kubectl kustomize ${GUIDE_DIR}/modelserver/${ACCELERATOR_TYPE}/${MODEL_SERVER}/${INFRA_PROVIDER} 2>/dev/null | grep -E '^kind: (Deployment|DisaggregatedSet|LeaderWorkerSet|PersistentVolumeClaim|ResourceClaimTemplate)$' | sort | uniq -c
   kubectl get gatewayclass 2>/dev/null                      # gateway mode only
   kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} 2>/dev/null   # gateway mode only
   kubectl get storageclass 2>/dev/null                      # only if the overlay renders a PersistentVolumeClaim
   ```
   Cluster-scoped prerequisites that are missing fall under Rule 2: show the guide's command (`${GUIDE_PY} emit ${GUIDE_DIR} env prerequisites.gaie` or `prerequisites.lws`), state that it is cluster-scoped, and run it only on explicit confirmation.
5. Present the detected configuration and ask only for gaps or overrides:
   ```
   Detected configuration:
   - Guide: <guide> (<GUIDE_DIR>), llm-d <describe output>
   - Namespace: <NAMESPACE>
   - Accelerator: <ACCELERATOR_TYPE> (<count> nodes, <signal>), model server: <MODEL_SERVER>, provider: <INFRA_PROVIDER>
   - Model: <MODEL>
   - Mode: <MODE> (<provider.name> in gateway mode)
   - Prerequisites: HF secret <state>, GAIE CRDs <state>, DisaggregatedSet CRD <state or n/a>
   - Existing releases in the namespace: <list or none>
   ```

### Step 4: Plan and Execute

#### 4.1 Compose the section list

From the Step 3 summary, in `guide.yaml` order:

- `prerequisites.*` except `prerequisites.clone` (the checkout exists) and except `prerequisites.secrets` when the Secret already exists. Cluster-scoped prerequisites only per Rule 2.
- `deploy.*` stages in order, including only the selected mode (`deploy.standalone` or `deploy.gateway`), every `option(by-variables)` member (the filters select the right one), and the chosen member of each `option(manual)` group. Confirm `option(manual)` choices with the user, quoting the README text that explains them.
- `verify.endpoint.<MODE>` (it only exports `IP`). No `verify.tests.*` yet.

Variables are passed with `--var`; `emit` rejects names not declared in `env.static` and values outside the declared `values:`. Always pass `--var REPO_ROOT=${LLMD_PATH}` so the script does not depend on the working directory.

#### 4.2 Render the plan and the deployment script

```bash
mkdir -p deployments
DATE=$(date +%Y%m%d)
EMIT_VARS=(--var REPO_ROOT=${LLMD_PATH} --var NAMESPACE=${NAMESPACE} --var ACCELERATOR_TYPE=${ACCELERATOR_TYPE} --var MODEL_SERVER=${MODEL_SERVER} --var INFRA_PROVIDER=${INFRA_PROVIDER} --var MODEL=${MODEL})
# add --var MONITORING=true and other guide variables as selected
{
  echo '#!/usr/bin/env bash'
  echo "# Deployment script generated by deploy-llm-d on $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "# llm-d: $(git -C ${LLMD_PATH} describe --tags --always) ($(git -C ${LLMD_PATH} branch --show-current))  guide: ${GUIDE_DIR#${LLMD_PATH}/}  namespace: ${NAMESPACE}  mode: ${MODE}"
  echo "# HF_TOKEN must be exported in the shell before running."
  ${GUIDE_PY} emit ${GUIDE_DIR} env <section...> "${EMIT_VARS[@]}" | sed '1{/^#!/d;}'   # emit's shebang would otherwise land below the header
} > deployments/deploy-${DATE}.sh
chmod +x deployments/deploy-${DATE}.sh
```

Show the full script to the user and obtain confirmation before executing anything. The script is the record of what runs; generating it is mandatory, also when the user later declines execution.

#### 4.3 Execute section by section

Run each section in its own invocation so a failure is attributed to one section. Every invocation starts with `env`, which also sources `guides/env.sh` and validates the accelerator and engine pairing:

```bash
${GUIDE_PY} emit ${GUIDE_DIR} env <section> "${EMIT_VARS[@]}" | bash
```

Order: prerequisites, then router (`deploy.router_values`, `deploy.monitoring_values`, `deploy.accelerator_values`, `deploy.<MODE>`), then model servers (`deploy.modelserver...`), then `deploy.monitoring`. Note that `deploy.router_values` only exports variables, so it must be emitted together with `deploy.<MODE>` in the same invocation. Inspect each output; on failure, consult [troubleshooting.md](references/troubleshooting.md), fix, and re-run the failed section only.

After the model server section, wait for readiness without sending requests:

```bash
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} -w
kubectl wait --for=condition=Ready pod -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --field-selector=status.phase!=Failed --timeout=1800s
```

The field selector matters: evicted pods stay behind as `Failed` objects with the same labels and would make the wait time out after the live pods are Ready. Model download and engine startup take 5 to 30 minutes depending on model size and image pull; TPU engines add a compilation phase of a similar length. A `DisaggregatedSet` creates one LeaderWorkerSet per role; watch `kubectl get disaggregatedset,leaderworkerset -n ${NAMESPACE}`.

#### 4.4 Customizations

Never edit the checkout. Two supported customization points:

- **Model servers**: create `deployments/<name>/kustomization.yaml` that uses the upstream overlay as its base and adds patches, then apply it instead of the emitted `deploy.modelserver` step:
  ```yaml
  apiVersion: kustomize.config.k8s.io/v1beta1
  kind: Kustomization
  resources:
    - ../../llm-d/guides/<guide>/modelserver/<ACCELERATOR_TYPE>/<MODEL_SERVER>/<INFRA_PROVIDER>   # relative to deployments/<name>/; kustomize rejects absolute paths
  patches:
    - path: patch-modelserver.yaml   # for example: replicas, --max-model-len, model name, resources
  ```
  ```bash
  python3 -c 'import os.path, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
    ${LLMD_PATH}/guides/<guide>/modelserver/<ACCELERATOR_TYPE>/<MODEL_SERVER>/<INFRA_PROVIDER> deployments/<name>   # the resources: entry
  kubectl kustomize deployments/<name> | less   # inspect the render before applying
  kubectl apply -n ${NAMESPACE} -k deployments/<name>
  ```
  Patch rules that matter in practice: a strategic-merge patch replaces `args` wholesale but merges `env`, `volumes`, and `volumeMounts` by name, so remove entries with `- name: <entry>` plus `$patch: delete` and replace a whole list with a leading `- $patch: replace` element. Replacing a volume's source (for example the hostPath HF cache with an ephemeral PVC) takes two patches, one that deletes the entry and one that re-adds it under the same name. Overlays that render a `DisaggregatedSet` need `guides/recipes/modelserver/components/disaggregatedset-schema` under `components:` so those merge keys apply inside the roles.
  Changing `MODEL` also changes the served model name the router and clients use; keep the `llm-d.ai/*` labels intact so the router's `modelServers.matchLabels` still selects the pods (the `llm-d.ai/model` label may be corrected in both `spec.selector.matchLabels` and the pod template).
- **Router**: copy the emitted `helm install` command into the deployment script and append `-f deployments/<name>/router.values.yaml` after the guide's values file. Plugin changes belong to `llm-d-autoconfig`; this skill only layers values the user supplies.

Record every customization in the deployment script (replace the emitted command with the one actually run and keep a comment pointing at the custom file).

### Step 5: Validate

1. Kubernetes state (no traffic):
   ```bash
   helm status ${GUIDE_NAME} -n ${NAMESPACE}
   kubectl get pods -n ${NAMESPACE} -o wide -L llm-d.ai/role
   kubectl get inferencepool -n ${NAMESPACE}
   kubectl get svc ${GUIDE_NAME}-epp -n ${NAMESPACE}                       # standalone mode
   kubectl get gateway,httproute -n ${NAMESPACE}                           # gateway mode: PROGRAMMED=True, ACCEPTED=True
   kubectl get disaggregatedset,leaderworkerset -n ${NAMESPACE} 2>/dev/null
   kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -20
   ```
   Success criteria: every pod `Running` with all containers ready and no restarts, the Helm release `deployed`, an `InferencePool` present, and in gateway mode the Gateway programmed and the HTTPRoute accepted.
2. Connectivity test (opt-in). Ask the user whether to run the guide's request test; it sends one completion request through the router and therefore populates the KV cache. On agreement follow [connectivity-verification.md](references/connectivity-verification.md), which emits `verify.endpoint.<MODE>` and `verify.tests.request` from the same `guide.yaml`.
3. Report: pods per role, endpoint (`${GUIDE_NAME}-epp` ClusterIP or the Gateway address), model name, the deployment script path, and any customization files.

### Step 6: Deliverables

- `deployments/deploy-YYYYMMDD.sh` (Step 4.2), updated with any customizations actually applied and with the validation commands of Step 5 appended.
- Custom overlays or values under `deployments/<name>/`, if any.
- A short summary of what was deployed and how to remove it: the guide's `cleanup` section (`${GUIDE_PY} emit ${GUIDE_DIR} env cleanup "${EMIT_VARS[@]}"`) or the `teardown-llm-d` skill.

## Common Issues

| Symptom | Cause and action |
|---|---|
| `error: <guide> does not support MODEL_SERVER=... on ACCELERATOR_TYPE=...` when sourcing `env.sh` | The pairing has no overlay. Pick a pairing from the support matrix. |
| `--var X=... not in declared values` from `emit` | Value outside `env.static` vocabulary. Use a listed value. |
| `no matches for kind "InferencePool"` | GAIE CRDs missing. Cluster-scoped prerequisite (`prerequisites.gaie`), Rule 2. |
| `no matches for kind "DisaggregatedSet"` | LeaderWorkerSet controller missing or installed without `enableDisaggregatedSet=true`. Cluster-scoped prerequisite (`prerequisites.lws`), Rule 2. |
| `cannot re-use a name that is still in use` from `helm install` | A release named `${GUIDE_NAME}` exists in the namespace (Step 2). |
| Requests return 503 in gateway mode on GKE | `provider.name=none` renders no `HealthCheckPolicy`. Re-install with `--set provider.name=gke`. |
| Pods `Pending` | Accelerator count, node selectors, taints, or quota. See troubleshooting. |
| Model servers stall at `unauthenticated requests to HF Hub` | `llm-d-hf-token` Secret missing or empty. Create it, then delete the pods. |
| Hundreds of pods created, GPU errors in events | Faulty node. Remove the workload (`kubectl delete -k <overlay> -n ${NAMESPACE}`), add node anti-affinity through a custom overlay, redeploy. See troubleshooting. |

For detailed guidance see [troubleshooting.md](references/troubleshooting.md).

## Additional Resources

- Guide index: `${LLMD_PATH}/guides/README.md` and `${LLMD_PATH}/docs/well-lit-paths/guides.yaml`
- Guide authoring reference (schema of `guide.yaml`): `${LLMD_PATH}/guides/templates/README.md`
- Quickstart: `${LLMD_PATH}/docs/getting-started/quickstart.md`
- Gateway providers: `${LLMD_PATH}/docs/infrastructure/gateway/README.md`
- LeaderWorkerSet and DisaggregatedSet: `${LLMD_PATH}/docs/infrastructure/model-server-orchestration.md`, `${LLMD_PATH}/docs/operations/disaggregation/disaggregatedset.md`
- Smoke test script: `${LLMD_PATH}/docs/operations/validation/smoke-test/healthcheck.sh`
- Benchmarking: `${LLMD_PATH}/docs/operations/validation/benchmark.md` and the `run-llm-d-benchmark` skill

## Security Considerations

- Run deployments in isolated namespaces
- Never modify cluster-wide resources except the guide's own prerequisites, and only with explicit confirmation
- Keep the HuggingFace token in the `llm-d-hf-token` Secret; never print it or write it into the deployment script
- Use RBAC for access control, network policies for pod-to-pod traffic, and TLS at the Gateway in gateway mode
- Audit all deployments and changes through the dated deployment scripts
