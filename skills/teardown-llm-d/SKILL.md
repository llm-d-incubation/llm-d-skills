---
name: teardown-llm-d
description: Tears down, removes, cleans up, or undeploys a deployed llm-d stack (llm-d v1.0 and later) on Kubernetes or OpenShift. Use this skill whenever the user wants to remove or destroy an llm-d deployment, clean up a namespace after inference workloads, uninstall the llm-d router Helm release, or free up accelerator resources used by llm-d, even if they do not say "teardown" explicitly. Handles partial cleanup (for example remove only the model servers, keep the router) and prefers the guide's own cleanup steps from guide.yaml.
---

# Teardown llm-d Stack

## Purpose

Cleanly remove a deployed llm-d stack from a Kubernetes namespace. An llm-d v1.0 stack consists of:

| Part | Created by | Removed by |
|---|---|---|
| Router: EPP Deployment, Services `<guide>-epp` and `<guide>-epp-model-servers`, ConfigMaps, Roles, the chart's ClusterRole and ClusterRoleBinding, `InferencePool <guide>`, and in gateway mode the `HTTPRoute <guide>` with provider policies | `helm install <guide> llm-d-router-standalone|gateway` | `helm uninstall <guide> -n <ns>` |
| Model servers: `Deployment` (aggregated) or `DisaggregatedSet` (prefill/decode, wide-EP), ServiceAccount, ConfigMaps, PVCs or `ResourceClaimTemplate`s in some overlays | `kubectl apply -k guides/<guide>/modelserver/<accelerator>/<engine>/<provider>` | the guide's `cleanup.modelserver` step, which is `kubectl delete -k` of the same overlay |
| Monitoring objects (`PodMonitor`, `PodMonitoring`) | `kubectl apply -k guides/recipes/modelserver/components/monitoring[-pd]` | `kubectl delete -k` of the same component |
| Guide-specific extras (objectives, render pods, Mooncake store, model-cache PVC, metrics-reader ClusterRoleBindings) | guide-specific deploy steps | the guide's other `cleanup.*` steps |
| `Gateway llm-d-inference-gateway` (gateway mode) | `kubectl apply -k guides/recipes/gateway/<provider>` | user decision (opt-in) |
| Secret `llm-d-hf-token`, PVCs, the namespace | prerequisites | kept unless the user asks |

Workload pods carry the labels `llm-d.ai/guide=<guide>` and `llm-d.ai/role=prefill|decode`. Chart-created objects carry no `llm-d.ai/guide` label; they are found through `helm list`. The helper [scripts/inventory.sh](scripts/inventory.sh) prints all of the above for a namespace.

Always confirms with the user before deleting anything.

---

## Step 1: Locate the Stack and Set NAMESPACE

1. If the `NAMESPACE` environment variable is set, use it.
2. Otherwise check for an active `oc project`:
   ```bash
   oc project -q 2>/dev/null
   ```
3. If neither, ask the user for the namespace.

Verify the stack is present:
```bash
helm list -n $NAMESPACE
kubectl get pods -n $NAMESPACE -L llm-d.ai/guide,llm-d.ai/role
```

If no llm-d resources are found, tell the user and stop.

---

## Step 2: Recover How the Stack Was Deployed

The removal commands are the guide's own `cleanup` steps when the guide and its variables are known. Recover them, in this order:

1. **Deployment record.** The `deploy-llm-d` skill writes `deployments/deploy-YYYYMMDD.sh` with a header naming the guide and namespace and an `env` block with the variables:
   ```bash
   REC=$(grep -l "namespace: ${NAMESPACE}" deployments/deploy-*.sh 2>/dev/null | sort | tail -1)
   [ -n "$REC" ] && grep -E '^# llm-d:|^# sections:|^export (REPO_ROOT|GUIDE_NAME|NAMESPACE|ACCELERATOR_TYPE|MODEL_SERVER|INFRA_PROVIDER|MODEL|TOPOLOGY|VARIANT|CONNECTOR|HOST_TYPE|TASK)=' "$REC"
   ```
   From it set `LLMD_PATH` (the `REPO_ROOT` export), `GUIDE_DIR` (`REPO_ROOT` joined with the `guide:` path of the header), and the `--var` values that were used. The `# sections:` line names the deploy sections that ran (for example `deploy.modelserver.standard`); the matching `cleanup.modelserver.standard` is the removal step. Also note the custom overlays or values files the record references (Step 4.4 of `deploy-llm-d`); those replace the corresponding guide steps.
2. **Helm releases.** `helm list -n $NAMESPACE -o json | jq -r '.[] | "\(.name)\t\(.chart)"'`. A release whose chart starts with `llm-d-router-` is a router release; for a guide deployment its name is the guide name (`GUIDE_NAME`), hand-rolled stacks may use any name. Other llm-d charts (`llm-d-async`, `batch-gateway`, `ipp`, FMA) belong to README-only operations guides.
3. **Workload labels.** `kubectl get deployments,statefulsets,disaggregatedsets.disaggregatedset.x-k8s.io -n $NAMESPACE -L llm-d.ai/guide,llm-d.ai/role` gives the guide name when no record exists.
4. **Checkout.** If `LLMD_PATH` is still unknown, use the environment variable, a nearby clone, or ask. Without a checkout, the guide's `cleanup` steps cannot be emitted; fall back to Step 4b.

Set `GUIDE_PY="python3 ${LLMD_PATH}/scripts/guide.py"` (or `uv run ${LLMD_PATH}/scripts/guide.py`) when a checkout exists.

---

## Step 3: Inventory and Teardown Plan

Run the inventory and read it with the user:

```bash
bash skills/teardown-llm-d/scripts/inventory.sh $NAMESPACE ${GUIDE_NAME:-}
```

When a `guide.yaml` is available, read its cleanup steps and their `when:` and `skip_in:` filters:

```bash
sed -n '/^cleanup:/,$p' ${GUIDE_DIR}/guide.yaml
```

(The `deploy-llm-d` skill's `scripts/list-guide-steps.py`, when installed, prints the same information classified per step path.)

Present the plan before touching anything:

```
Teardown plan for namespace: <NAMESPACE>
Guide: <GUIDE_NAME> (<GUIDE_DIR> | unknown)   Source of commands: guide.yaml cleanup | kubectl delete -k | label selectors

1. Model servers (removed first, so pods drain before the router goes):
   - <Deployment|DisaggregatedSet names>  (<n> pods, roles: ...)
   - command: <cleanup.modelserver command | kubectl delete -k <overlay> | label-based delete>
2. Monitoring and guide extras:
   - <PodMonitors, objectives, render pods, ...> with their commands
3. Router Helm release(s):
   - helm uninstall <release> -n <NAMESPACE>   (removes EPP, InferencePool, chart RBAC, HTTPRoute in gateway mode)

Opt-in (ask separately, default keep):
   - HTTPRoutes not owned by the release: <list or none>
   - Gateway llm-d-inference-gateway: <present | none>
   - PVCs: <list or none>
   - Secret llm-d-hf-token: <present | none>
   - Namespace <NAMESPACE>
   - Cluster-scoped objects the guide created (ClusterRoleBindings named <guide>-metrics-reader, CRDs): <list or none>

Shall I proceed with items 1 to 3?
```

For a **partial teardown** (for example "remove only the model servers, keep the router"), keep only the requested items in the plan and say explicitly what stays.

Write the plan's commands to `deployments/teardown-YYYYMMDD.sh` (header with namespace, guide, and source of commands; opt-in commands commented out with an `# OPT-IN:` prefix). This file is the record of what ran.

**Do not proceed until the user confirms.**

---

## Step 4: Remove the Stack

### Step 4a: Guide-driven removal (preferred)

With `GUIDE_DIR` and the variables known, emit the guide's own cleanup steps into the teardown record. Select the sections first:

- A `cleanup` that is a flat list (`flow-control`, `pod-snapshot`, `fast-model-actuation`): the single section `cleanup`.
- A `cleanup` with sub-groups (`cleanup.modelserver`, `cleanup.rest`, and guide extras such as `cleanup.render`, `cleanup.storage`, `cleanup.mooncake`, `cleanup.router`): every sub-group, in the guide's order. Where a sub-group has members (`cleanup.modelserver.standard` and `cleanup.modelserver.dynamic_slice` in optimized-baseline), take only the member that matches the deployed variant, which is the `deploy.<group>.<member>` recorded in the `# sections:` line. Members gated by `when:` select themselves from the variables; members without `when:` are alternatives and emitting the whole group would run the wrong overlay deletion and abort the script.

The guide's order is already model servers first, router release and monitoring last:

```bash
EMIT_VARS=(--var REPO_ROOT=${LLMD_PATH} --var NAMESPACE=${NAMESPACE} --var ACCELERATOR_TYPE=... --var MODEL_SERVER=... --var INFRA_PROVIDER=... --var MODEL=...)
CLEANUP_SECTIONS=(cleanup.modelserver.standard cleanup.rest)   # per the selection above
mkdir -p deployments
{
  echo "# Teardown script generated by teardown-llm-d on $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "# llm-d: $(git -C ${LLMD_PATH} describe --tags --always)  guide: ${GUIDE_DIR#${LLMD_PATH}/}  namespace: ${NAMESPACE}"
  ${GUIDE_PY} emit ${GUIDE_DIR} env "${CLEANUP_SECTIONS[@]}" "${EMIT_VARS[@]}"
} > deployments/teardown-$(date +%Y%m%d).sh
grep -nE 'kubectl delete (namespace|crd|clusterrole|clusterrolebinding)|(pvc|persistentvolumeclaim|secret)' deployments/teardown-*.sh
```

Review the file. Every step that the `grep` flags (namespace, CRDs, ClusterRoles and ClusterRoleBindings, PVCs, Secrets) is opt-in: comment out all of its lines with an `# OPT-IN: ` prefix (steps can span several lines, so edit the step, not a single line). If the deployment used a custom overlay (`deployments/<name>/kustomization.yaml`), replace the guide's `kubectl delete -k .../modelserver/...` step with `kubectl delete -n ${NAMESPACE} -k deployments/<name>`. Show the resulting script to the user; after confirmation:

```bash
bash deployments/teardown-$(date +%Y%m%d).sh
kubectl wait --for=delete pod -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --timeout=300s
```

The script runs with `set -euo pipefail`, so it stops at the first failing step. A step that fails because the object is already gone (`not found`, `release: not found`) is not an error: run the remaining steps of the file by hand and continue.

### Step 4b: Fallback without a checkout

1. **Model servers**: delete by the guide label across the workload kinds, then the supporting objects that carry the label:
   ```bash
   kubectl delete deployments,statefulsets,disaggregatedsets.disaggregatedset.x-k8s.io -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --ignore-not-found
   kubectl wait --for=delete pod -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --timeout=300s
   kubectl delete services,serviceaccounts,configmaps,resourceclaimtemplates.resource.k8s.io -n ${NAMESPACE} -l llm-d.ai/guide=${GUIDE_NAME} --ignore-not-found
   ```
   Objects of the overlay that carry no label (the ServiceAccount of some DisaggregatedSet overlays, `PodMonitor`s, `ScaledObject`s) appear in the inventory by name; list them to the user and delete them by name after confirmation.
2. **Router**: `helm uninstall <release> -n ${NAMESPACE}` for every router release the user confirmed.
3. Verify with `helm list -n ${NAMESPACE}` and the inventory script.

### Step 4c: Router only, or model servers only

- Model servers only: run only the model server removal (4a first block, or 4b item 1). The router keeps running with an empty `InferencePool`.
- Router only: `helm uninstall <release> -n ${NAMESPACE}`. The model servers keep running without a router in front of them.

---

## Step 5: Opt-in Removals

Ask about each group separately and only act on an explicit yes. Never remove these as part of "tear down the stack".

| Item | Command | Notes |
|---|---|---|
| HTTPRoutes not owned by the release | `kubectl delete httproute <name> -n ${NAMESPACE}` | the chart's HTTPRoute is already gone with `helm uninstall` |
| Gateway | `kubectl delete gateway llm-d-inference-gateway -n ${NAMESPACE}` | shared by every guide deployed in gateway mode in this namespace |
| PVCs | `kubectl delete pvc <name> -n ${NAMESPACE}` | model caches, FS KV tiers, benchmark `workload-pvc`; data loss |
| Secret `llm-d-hf-token` | `kubectl delete secret llm-d-hf-token -n ${NAMESPACE}` | needed again by the next deployment |
| Namespace | `kubectl delete namespace ${NAMESPACE}` | removes everything above as well |
| Cluster-scoped objects the guide created | the guide's own `kubectl delete clusterrolebinding ...` or `kubectl delete crd ...` cleanup lines | confirm they were created for this deployment and are not shared; otherwise hand to the cluster administrator |

Never uninstall shared controllers (LeaderWorkerSet in `lws-system`, KEDA, Gateway providers, the Gateway API and Inference Extension CRDs). They are cluster infrastructure.

---

## Step 6: Verify Cleanup

```bash
bash skills/teardown-llm-d/scripts/inventory.sh $NAMESPACE ${GUIDE_NAME:-}
helm list -n $NAMESPACE
kubectl get pods -n $NAMESPACE
```

Report what remains and whether it is expected (kept PVCs, the Secret, the Gateway, unrelated workloads). Pods of a `DisaggregatedSet` can take a minute to terminate; `kubectl get leaderworkersets.leaderworkerset.x-k8s.io -n $NAMESPACE` must be empty once the set is gone.

---

## Invocation From Other Skills

`compare-llm-d-configurations` calls this skill between runs with fixed constraints: uninstall the Helm releases, remove the model servers, remove HTTPRoutes and the Gateway, keep PVCs, keep the Secret, keep the namespace, and do not ask about the optional steps. Apply exactly those constraints when the caller states them.

---

## Execution Rules

1. **Confirm before any deletion.** Show the specific list first, even when the user says "just tear it down".
2. **Scope every command to `$NAMESPACE`.** The only cluster-scoped deletions are the ones the guide's own cleanup lists, and they are opt-in (Step 5).
3. **Model servers before the router.** Pods drain first; the router release goes last.
4. **Prefer the guide's cleanup steps**, then `kubectl delete -k` of the recorded overlay, then label selectors.
5. **Opt-in items are asked separately**: HTTPRoutes, Gateway, PVCs, Secret, namespace, cluster-scoped leftovers.
6. **Handle errors.** Already-deleted objects are not failures; other errors are diagnosed before continuing.
7. **Record the commands** in `deployments/teardown-YYYYMMDD.sh`.

## What Not To Do

1. Do not modify or delete CRDs, ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or shared controllers except through the guide's own cleanup lines after explicit confirmation.
2. Do not delete resources outside the target namespace.
3. Do not delete the namespace, PVCs, or the HuggingFace Secret as part of a stack teardown.
4. Do not skip the confirmation step.

## When to Use This Skill

- Removing a deployed llm-d stack after benchmarking or experimentation
- Freeing accelerators in a namespace
- Resetting a namespace before a fresh deployment of the same or another guide
- Partial cleanup (model servers only, router only)
- Cleaning up stacks deployed from a `guide.yaml` guide, from a custom overlay under `deployments/`, or by hand with `helm` and `kubectl apply -k`

## Security Considerations

- Run teardown operations in isolated namespaces
- Use RBAC for access control
- Audit all deletions through the dated teardown script
- Never delete cluster-wide resources
