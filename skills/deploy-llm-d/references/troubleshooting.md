# Troubleshooting Guidance

Applies to llm-d v1.0 and later deployments driven by `guide.yaml` (see the main workflow). Container names used below: `modelserver` (the engine container in every model server pod) and `routing-proxy` (the sidecar on decode pods of disaggregated guides).

## Tooling and Repository Issues

**`scripts/guide.py` or `docs/well-lit-paths/guides.yaml` not found:**
- **Cause**: the checkout predates llm-d v1.0 (before 2026-08) or is not an llm-d clone.
- **Action**: `git -C ${LLMD_PATH} fetch && git -C ${LLMD_PATH} checkout release-1.0`, or ask the user for the right path.

**`emit` fails with `--var names not declared in env.static` or `not in declared values`:**
- **Cause**: a variable name or value outside the guide's vocabulary (for example `ACCELERATOR_TYPE=h100`).
- **Action**: re-run `scripts/list-guide-steps.py ${GUIDE_DIR}` and use the listed names and values. The overlay tree is laid out by accelerator family, not by GPU model: all NVIDIA GPUs use `gpu`.

**`error: <guide> does not support MODEL_SERVER=... on ACCELERATOR_TYPE=...` while sourcing `guides/env.sh`:**
- **Cause**: no overlay exists at `modelserver/<ACCELERATOR_TYPE>/<MODEL_SERVER>/`. The guard in `env.sh` lists the engines available for the accelerator.
- **Action**: choose a pairing from the support matrix.

**Kustomize overlay path not found:**
- **Cause**: the leaf `INFRA_PROVIDER` level is missing or wrong. The layout is `modelserver/<ACCELERATOR_TYPE>/<MODEL_SERVER>/<INFRA_PROVIDER>/` (`base` on plain Kubernetes, `gke` on GKE, further values per guide).
- **Action**: `ls ${GUIDE_DIR}/modelserver/${ACCELERATOR_TYPE}/${MODEL_SERVER}/` and pick an existing leaf; verify with `kubectl kustomize <dir> | head`.

**`emit` prints `# (no steps after skip_in/when filtering)` for a section:**
- **Cause**: every step of the section is gated by a `when:` filter that the current variables do not satisfy (for example `deploy.monitoring_values` with `MONITORING=false`).
- **Action**: expected for optional sections. For a mandatory section, compare the variables with the `when:` filters shown by `list-guide-steps.py`.

**Helm OCI chart pull fails (`docker-credential-*` or `unauthorized`):**
- **Action**: `helm registry logout ghcr.io` (the charts are public); on Debian or Ubuntu install `libsecret-1-0` if the credential helper is missing; or `helm pull ${ROUTER_STANDALONE_CHART} --version ${ROUTER_CHART_VERSION}` and install from the local archive.

## Prerequisite Issues

**`no matches for kind "InferencePool" in version "inference.networking.k8s.io/v1"`:**
- **Cause**: the Gateway API Inference Extension CRDs are not installed.
- **Action**: cluster-scoped prerequisite (Rule 2). Command: `${GUIDE_PY} emit ${GUIDE_DIR} env prerequisites.gaie`. On GKE `1.34.0-gke.1626000` or later with the Gateway API enabled, GKE manages these CRDs; check `kubectl api-resources --api-group=inference.networking.k8s.io` before applying.

**`no matches for kind "DisaggregatedSet"` or the set is created but no pods appear:**
- **Cause**: the LeaderWorkerSet controller is missing, older than the version pinned in `guides/env.sh` (`LWS_VERSION`), or installed without `enableDisaggregatedSet=true`.
- **Diagnosis**: `kubectl get crd disaggregatedsets.disaggregatedset.x-k8s.io`; `kubectl get pods -n lws-system`; `helm list -n lws-system`.
- **Action**: cluster-scoped prerequisite (Rule 2). Command: `${GUIDE_PY} emit ${GUIDE_DIR} env prerequisites.lws`. For an existing older install, apply the new chart's CRDs first; `helm upgrade` does not update CRDs (see `docs/infrastructure/model-server-orchestration.md`).

**DRA overlays (`ResourceClaimTemplate`) rejected with `no matches for kind` or `unknown field`:**
- **Cause**: the overlay uses `resource.k8s.io/v1`, which needs Kubernetes 1.34 or newer and the accelerator's DRA driver.
- **Action**: `kubectl version`; `kubectl get deviceclasses.resource.k8s.io`. Upgrade the cluster or use a device-plugin based overlay.

**`HF_TOKEN: unbound variable` while running `prerequisites.secrets`:**
- **Cause**: the emitted script runs with `set -u` and the token is not exported.
- **Action**: `export HF_TOKEN=...` in the shell that runs the script. Never write the token into the script.

**RBAC denied during apply:**
- **Diagnosis**: `kubectl auth can-i <verb> <resource> -n ${NAMESPACE}`.
- **Action**: ask the cluster administrator for the specific role; state the exact rule needed; do not attempt to escalate privileges.

## Router (Helm Release) Issues

**`cannot re-use a name that is still in use`:**
- **Cause**: a release named `${GUIDE_NAME}` already exists in the namespace (`helm list -n ${NAMESPACE}`).
- **Action**: modify that release (`helm upgrade` with the same values files plus overrides), use another namespace, or remove it with `teardown-llm-d`.

**EPP pod in `CrashLoopBackOff`:**
- **Diagnosis**: find the router pod with `kubectl get pods -n ${NAMESPACE} | grep -- -epp`, then `kubectl logs <pod> -n ${NAMESPACE} -c epp --previous` (list container names with `-o jsonpath='{.spec.containers[*].name}'` if `epp` does not match).
- **Common causes**: an invalid `EndpointPickerConfig` in custom values (plugin names must exist in the pinned router image; `apiVersion: llm-d.ai/v1`), or a `pluginsConfigFile` name that does not match a key under `pluginsCustomConfig`.
- **Action**: re-install with the guide's values only; introduce custom router values one at a time.

**Router runs but never picks a pod (`no endpoints`, 503 from the EPP service):**
- **Cause**: `router.modelServers.matchLabels` (`llm-d.ai/guide: <guide>` in the guide's values) does not match the model server pods, typically after a customization changed or dropped labels, or the pods are not `Ready`.
- **Diagnosis**: `kubectl get inferencepool -n ${NAMESPACE} -o yaml`; `kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME}`.

**Requests return 503 in gateway mode on GKE:**
- **Cause**: the router chart was installed with `provider.name=none`, so no `HealthCheckPolicy` exists and the load balancer marks the backends unhealthy.
- **Action**: re-install with `--set provider.name=gke`. On Istio the equivalent setting renders a `DestinationRule`.

**Gateway not programmed or HTTPRoute not accepted (gateway mode):**
- **Diagnosis**: `kubectl describe gateway llm-d-inference-gateway -n ${NAMESPACE}`; `kubectl describe httproute -n ${NAMESPACE}`; the gateway controller logs.
- **Common causes**: no Gateway provider installed, a GatewayClass name that does not match the provider, or the HTTPRoute `parentRefs` naming a Gateway in another namespace.

**Prefix-cache affinity does not spread load on a different model or accelerator:**
- **Cause**: `peakPrefillThroughput` of `prefix-cache-affinity-filter` is calibrated for the guide's reference setup (Qwen3-32B on H100, TP=2).
- **Action**: measure with `guides/recipes/router/calibration/` and set the value in a custom router values file (Step 4.4). A performance tuning concern, not a deployment failure.

## Model Server Issues

**Pods `Pending`:**
- **Diagnosis**: `kubectl describe pod <pod> -n ${NAMESPACE} | sed -n '/Events/,$p'`.
- **Checks**: accelerator capacity (`kubectl describe nodes | grep -A3 -E 'nvidia.com/gpu|amd.com/gpu|google.com/tpu'`), node selectors and affinities in the overlay (GKE overlays select machine families), taints and tolerations, `ResourceClaim` allocation for DRA overlays (`kubectl get resourceclaims -n ${NAMESPACE}`), resource quotas, PVC binding for overlays that mount one.

**`ImagePullBackOff`:**
- **Diagnosis**: `kubectl describe pod <pod> -n ${NAMESPACE}` shows `unauthorized`, `not found`, or `manifest unknown`.
- **Checks**: the image tag comes from `guides/recipes/modelserver/components/images/<engine>/<release|nightly>`; nightly tags move and may be absent from mirrors. For a private registry add `imagePullSecrets` through a custom overlay.

**Pods stall with `unauthenticated requests to HF Hub` as the last log line:**
- **Cause**: the `llm-d-hf-token` Secret is missing or holds an empty `HF_TOKEN`; HuggingFace rate-limits anonymous downloads so a 32B model can take hours.
- **Diagnosis**: `kubectl get secret llm-d-hf-token -n ${NAMESPACE} -o jsonpath='{.data.HF_TOKEN}' | wc -c` (must be greater than 0); `kubectl logs <pod> -n ${NAMESPACE} -c modelserver --tail=50`.
- **Action**: create the Secret (`prerequisites.secrets`), then delete the pods so the controller recreates them with the token mounted.

**`CrashLoopBackOff` of the `modelserver` container:**
- **Diagnosis**: `kubectl logs <pod> -n ${NAMESPACE} -c modelserver --previous`.
- **Common causes**: wrong model name for the accelerator overlay, insufficient accelerator memory for the model and `--max-model-len`, an invalid engine flag introduced by a customization, a driver and CUDA mismatch (the images ship CUDA 12.9.1; driver 575.x recommended, see `docs/getting-started/accelerators.md`).

**`ValueError: ... KV cache is needed, which is larger than the available KV cache memory` (TP=1 with large models):**
- **Action**: cap `--max-model-len` to the workload (for example `8192`) and keep `--gpu-memory-utilization` at or below `0.90` through a custom patch. Affects every TP=1 pod, including prefill in prefill/decode disaggregation.

**vLLM crashes on OpenShift with `KeyError` in `getpwuid`:**
- **Cause**: OpenShift assigns arbitrary UIDs absent from `/etc/passwd`.
- **Action**: set `USER=vllm`, `HOME=/.cache`, `TORCHINDUCTOR_CACHE_DIR=/.cache/torchinductor` on the `modelserver` container and mount an `emptyDir` at `/.cache` through a custom patch. The upstream `base` overlays already mount `/.cache` and `/.triton`.

**Pod `OOMKilled` during model loading:**
- **Diagnosis**: `kubectl describe pod <pod> -n ${NAMESPACE}` shows `Reason: OOMKilled`.
- **Action**: raise the `modelserver` container's `resources.limits.memory` in a custom patch (about 80Gi is typical for a 32B model).

**Model loading slow:**
- Normal: 5 to 10 minutes for 100B+ models with a warm registry; up to 30 minutes with first-time image pulls and compilation.
- Monitor: `kubectl logs <pod> -n ${NAMESPACE} -c modelserver -f`.
- Investigate when there is no log progress for more than 15 minutes: HF token (above), network egress, node disk pressure.

**Hundreds of pods created, events show `GPU is lost` or NVLink errors:**
- **Cause**: a node with failed accelerator hardware; the controller keeps replacing failed pods.
- **Immediate action**: remove the workload so the controller stops replacing pods: `kubectl delete -n ${NAMESPACE} -k ${GUIDE_DIR}/modelserver/${ACCELERATOR_TYPE}/${MODEL_SERVER}/${INFRA_PROVIDER}` (or the custom overlay that was applied), then `kubectl delete pods -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --grace-period=0 --force` for pods stuck in termination.
- **Diagnosis**: `kubectl get pods -n ${NAMESPACE} -o wide` to find the node; `kubectl describe node <node> | grep -A10 -E 'nvidia.com/gpu|Conditions'`.
- **Long-term action**: add a `nodeAffinity` with `kubernetes.io/hostname NotIn [<node>]` through a custom overlay (Step 4.4), redeploy, and report the node to the cluster administrator.

**`DisaggregatedSet` rollout stalls with new pods `Pending`:**
- **Cause**: the controller creates the new revision before draining the old one; on a fully allocated cluster the new pods cannot schedule.
- **Action**: keep at least one decode replica worth of free accelerators before a template change, or scale `slices` down by one first (see `docs/operations/disaggregation/disaggregatedset.md`).

**Decode pods `Running` but not `Ready` in prefill/decode guides:**
- **Diagnosis**: `kubectl logs <pod> -n ${NAMESPACE} -c routing-proxy` and `-c modelserver`.
- **Common causes**: the NIXL side channel or RDMA transport is not reachable (`UCX_TLS`, missing `rdma/*` resources or DRA claims); see `docs/infrastructure/rdma/README.md` for the verification steps.

## Networking Issues

**`/v1/models` works but completions time out in standalone mode:**
- **Diagnosis**: logs of the sidecar and EPP containers of the router pod (`kubectl get pods -n ${NAMESPACE} | grep -- -epp`); `kubectl get endpointslices -n ${NAMESPACE}`.
- **Common causes**: model server pods not `Ready`, or the EPP service port mapping changed by custom values (the guides expose port 80 to container port 8081).

**Cluster API server unreachable (`connection refused` from kubectl):**
- A cluster connectivity issue, not an llm-d issue. `kubectl cluster-info`; check the kubeconfig context.

## Checklists

Before deployment:

1. `git -C ${LLMD_PATH} describe --tags --always` and `${GUIDE_PY} check ${GUIDE_DIR}` succeed.
2. `NAMESPACE` exported; `HF_TOKEN` exported if the Secret is missing.
3. GAIE CRDs present; LWS present for `DisaggregatedSet` overlays; Gateway provider present for gateway mode.
4. `helm list -n ${NAMESPACE}` shows no release named after the guide.

During deployment:

1. Execute one section per `emit` invocation; inspect each output.
2. Do not edit files under `${LLMD_PATH}`; customizations live under `deployments/`.
3. Keep `deployments/deploy-YYYYMMDD.sh` equal to what was executed.

After deployment:

1. All pods `Running` and `Ready`, Helm release `deployed`, `InferencePool` present.
2. Connectivity test only with approval (`references/connectivity-verification.md`).
3. Record endpoint, model name, script path, and customizations in the summary.
