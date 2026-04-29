---
name: teardown-llm-d-stack
description: Tears down, removes, cleans up, or undeploys a deployed llm-d stack on Kubernetes. Use this skill whenever the user wants to remove or destroy an llm-d deployment, clean up a namespace after inference workloads, uninstall helm releases for llm-d, or free up cluster resources used by llm-d — even if they don't say "teardown" explicitly. Also handles partial cleanup (e.g., remove only the model service, keep the gateway). Supports both Helm-based and Kustomize-based deployments.
---

# Teardown llm-d Stack

## Purpose

Cleanly remove a deployed llm-d stack from a Kubernetes namespace. Works with both Helm-based deployments (using `helmfile` or `helm`) and Kustomize-based deployments (using `kubectl apply -k`). No local repo is needed for Helm-only teardown, but Kustomize-based resources require access to the kustomization directory. Always confirms with the user before deleting anything.

---

## Step 1: Locate the Stack and Set NAMESPACE

Use the same detection logic as the deploy and benchmark skills:

1. If the `NAMESPACE` environment variable is set, use it.
2. Otherwise check for an active `oc project`:
   ```bash
   oc project -q 2>/dev/null
   ```
3. If neither, ask the user for the namespace.

Verify the stack is present:
```bash
kubectl get pods -n $NAMESPACE
helm list -n $NAMESPACE
```

If no llm-d resources are found, tell the user and stop.

---

## Step 2: Inspect What Is Deployed

Gather a full picture before proposing any changes:

```bash
# All Helm releases in the namespace
helm list -n $NAMESPACE

# HTTPRoutes and Gateways
kubectl get httproute,gateway -n $NAMESPACE 2>/dev/null

# All deployments (including those created by Kustomize)
kubectl get deployments -n $NAMESPACE

# All services
kubectl get services -n $NAMESPACE

# All pods
kubectl get pods -n $NAMESPACE

# Check for llm-d labels to identify Kustomize-deployed resources
kubectl get deployments,services,serviceaccounts,podmonitors -n $NAMESPACE -l llm-d.ai/guide 2>/dev/null
```

**Identify deployment method:**
- If Helm releases exist: Helm-based deployment
- If resources with `llm-d.ai/guide` labels exist but no Helm releases: Kustomize-based deployment
- If both exist: Hybrid deployment (common pattern)

---

## Step 3: Present Teardown Plan and Confirm

Before touching anything, show the user exactly what will be removed and ask for confirmation:

```
Teardown plan for namespace: <NAMESPACE>

Deployment Method: <Helm-based | Kustomize-based | Hybrid>

Helm releases to uninstall:
  - <release-1>
  - <release-2>
  - <release-3>

Kustomize-deployed resources (if applicable):
  - Deployments: <list>
  - Services: <list>
  - ServiceAccounts: <list>
  - PodMonitors: <list>

Not removed unless you choose below:
  HTTPRoutes: <list or "none found">
  Gateways: <list or "none found">

Shall I proceed with the teardown?
```

**Do not proceed until the user confirms.**

---

## Step 4: Remove Deployed Resources

### Step 4a: Uninstall Helm Releases (if present)

Uninstall all releases identified in Step 2, scoped to the namespace. This approach works regardless of which guide was used to deploy the stack — no helmfile or local repo required.

```bash
helm uninstall <release-1> <release-2> <release-3> -n $NAMESPACE --ignore-not-found
```

After running, verify the releases are gone:
```bash
helm list -n $NAMESPACE
```

If any releases remain or errors occurred, diagnose and resolve before continuing.

### Step 4b: Remove Kustomize-Deployed Resources (if present)

**Two approaches for removing Kustomize resources:**

#### Approach 1: Using Kustomize Directory (Preferred)

If the user has access to the llm-d repository or deployment directory with kustomization files:

**First, verify or set LLMD_PATH:**
- Check if `LLMD_PATH` environment variable is set
- If not set, ask the user for the path to their llm-d repository
- Once obtained, set it: `export LLMD_PATH=/path/to/llm-d`

```bash
# Verify LLMD_PATH is set
echo $LLMD_PATH
# If empty, ask user for the llm-d repository path and set it:
# export LLMD_PATH=/path/to/llm-d

# For optimized-baseline guide with GPU/vLLM (example)
kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/gpu/vllm/ -n $NAMESPACE

# For other accelerators, adjust the path accordingly:
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/amd/vllm/ -n $NAMESPACE
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/cpu/vllm/ -n $NAMESPACE
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/xpu/vllm/ -n $NAMESPACE
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/hpu/vllm/ -n $NAMESPACE
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/tpu-v6/vllm/ -n $NAMESPACE
# kubectl delete -k ${LLMD_PATH}/guides/optimized-baseline/modelserver/tpu-v7/vllm/ -n $NAMESPACE
```

#### Approach 2: Using Label Selectors (Fallback)

If kustomization files are not available, delete resources by their llm-d labels:

```bash
# Delete all resources with llm-d.ai/guide label
kubectl delete deployments,services,serviceaccounts,podmonitors \
  -n $NAMESPACE \
  -l llm-d.ai/guide

# Verify specific guide resources if known (e.g., optimized-baseline)
kubectl delete deployments,services,serviceaccounts,podmonitors \
  -n $NAMESPACE \
  -l llm-d.ai/guide=optimized-baseline
```

**Verify resources are removed:**
```bash
kubectl get deployments,services,serviceaccounts,podmonitors -n $NAMESPACE -l llm-d.ai/guide
kubectl get pods -n $NAMESPACE
```

If resources remain, check for finalizers or other blocking conditions.

---

## Step 5: Optionally Remove HTTPRoutes and Gateways

Ask the user:

> "The following HTTPRoute/Gateway resources exist in `<NAMESPACE>`. Do you want to delete them?"
> `<list of httproutes and gateways>`

Only proceed if the user confirms. Delete all HTTPRoutes and Gateways scoped to the namespace:

```bash
kubectl delete httproute --all -n $NAMESPACE
kubectl delete gateway --all -n $NAMESPACE
```

If no HTTPRoutes or Gateways exist, skip this step.

---

## Step 6: Verify Cleanup

Confirm the resources have been removed:

```bash
# Check Helm releases
helm list -n $NAMESPACE

# Check Kustomize-deployed resources
kubectl get deployments,services,serviceaccounts,podmonitors -n $NAMESPACE -l llm-d.ai/guide

# Check all pods
kubectl get pods -n $NAMESPACE

# Check HTTPRoutes and Gateways
kubectl get httproute,gateway -n $NAMESPACE 2>/dev/null

# Check for any remaining llm-d resources
kubectl get all -n $NAMESPACE -l llm-d.ai/guide
```

Report what remains and whether it is expected (e.g., unrelated workloads the user intentionally kept).

---

## Execution Rules

1. **Confirm before any deletion** — never silently delete resources.
2. **Scope all operations to `$NAMESPACE`** — no cluster-level changes.
3. **HTTPRoutes and Gateways deletion is always opt-in** — ask separately; never assume.
4. **Handle errors** — if a command fails, diagnose and resolve before continuing.
5. **Detect deployment method** — identify whether resources were deployed via Helm, Kustomize, or both.
6. **Prefer kustomization directory** — when available, use `kubectl delete -k` for cleaner removal.
7. **Use label selectors as fallback** — when kustomization files are unavailable, delete by labels.

## What Not To Do

1. **Do NOT change cluster-level definitions** — Never modify ClusterRoles, ClusterRoleBindings, StorageClasses, CRDs, Nodes, or any resource outside the target namespace.
2. **Do NOT delete resources outside the target namespace** — All `kubectl delete` and `helm uninstall` commands must use `-n $NAMESPACE`.
3. **Do NOT skip the confirmation step** — Even if the user says "just tear it down", show the specific list of resources first.

## When to Use This Skill

- Removing a deployed llm-d stack after benchmarking or experimentation
- Freeing up GPU/CPU resources in a namespace
- Resetting a namespace before a fresh deployment
- Partial cleanup (e.g., remove model service only, keep the gateway)
- Cleaning up after Helm-based deployments (helmfile or helm install)
- Cleaning up after Kustomize-based deployments (kubectl apply -k)
- Cleaning up hybrid deployments (both Helm and Kustomize)

## Common Deployment Patterns
Understanding how different guides deploy resources helps determine the correct teardown approach:
### Optimized Baseline Guide
- **Scheduler**: Deployed via Helm (`helm install` in standalone or gateway mode)
- **Model Server**: Deployed via Kustomize (`kubectl apply -k guides/optimized-baseline/modelserver/<accelerator>/<server>/`)
- **HTTPRoute**: Applied separately (`kubectl apply -f`)

**Teardown sequence:**
1. Delete model server: `kubectl delete -k guides/optimized-baseline/modelserver/<accelerator>/<server>/ -n $NAMESPACE`
2. Uninstall scheduler: `helm uninstall <release-name> -n $NAMESPACE`
3. Optionally delete HTTPRoute: `kubectl delete httproute --all -n $NAMESPACE`

### PD Disaggregation Guide
- **All components**: Deployed via helmfile (`helmfile apply`)
- **HTTPRoute**: Applied separately (`kubectl apply -f`)

**Teardown sequence:**
1. Uninstall all releases: `helm uninstall infra-pd gaie-pd ms-pd -n $NAMESPACE`
2. Optionally delete HTTPRoute: `kubectl delete -f httproute.yaml -n $NAMESPACE`

### Workload Autoscaling Guide
- **All components**: Deployed via helmfile (`helmfile apply`)
- **HTTPRoute**: Applied separately (`kubectl apply -f`)

**Teardown sequence:**
1. Uninstall all releases: `helm uninstall infra-<postfix> gaie-<postfix> ms-<postfix> workload-variant-autoscaler -n $NAMESPACE`
2. Optionally delete HTTPRoute and autoscaling resources

## Security Considerations

- Run teardown operations in isolated namespaces
- Use RBAC for access control
- Audit all deletions
- Never delete cluster-wide resources
