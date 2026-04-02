---
name: teardown-llm-d-stack
description: Tears down, removes, cleans up, or undeploys a deployed llm-d stack on Kubernetes. Use this skill whenever the user wants to remove or destroy an llm-d deployment, clean up a namespace after inference workloads, uninstall helm releases for llm-d, or free up cluster resources used by llm-d — even if they don't say "teardown" explicitly. Also handles partial cleanup (e.g., remove only the model service, keep the gateway).
---

# Teardown llm-d Stack

## Purpose

Cleanly remove a deployed llm-d stack from a Kubernetes namespace. Works regardless of which Well-lit Path guide was used to deploy the stack — no local repo is needed. Always confirms with the user before deleting anything.

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

# All remaining pods
kubectl get pods -n $NAMESPACE
```

---

## Step 3: Present Teardown Plan and Confirm

Before touching anything, show the user exactly what will be removed and ask for confirmation:

```
Teardown plan for namespace: <NAMESPACE>

Helm releases to uninstall:
  - <release-1>
  - <release-2>
  - <release-3>

Not removed unless you choose below:
  HTTPRoutes: <list or "none found">

Shall I proceed to uninstall the helm releases listed above?
```

**Do not proceed until the user confirms.**

---

## Step 4: Uninstall Helm Releases

Uninstall all releases identified in Step 2, scoped to the namespace. This approach works regardless of which guide was used to deploy the stack — no helmfile or local repo required.

```bash
helm uninstall <release-1> <release-2> <release-3> -n $NAMESPACE --ignore-not-found
```

After running, verify the releases are gone:
```bash
helm list -n $NAMESPACE
```

If any releases remain or errors occurred, diagnose and resolve before continuing.

---

## Step 5: Optionally Remove HTTPRoutes

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
helm list -n $NAMESPACE
kubectl get pods -n $NAMESPACE
kubectl get httproute,gateway -n $NAMESPACE 2>/dev/null
```

Report what remains and whether it is expected (e.g., unrelated workloads the user intentionally kept).

---

## Execution Rules

1. **Confirm before any deletion** — never silently delete resources.
2. **Scope all operations to `$NAMESPACE`** — no cluster-level changes.
3. **HTTPRoutes deletion is always opt-in** — ask separately; never assume.
4. **Handle errors** — if a command fails, diagnose and resolve before continuing.

## What Not To Do

1. **Do NOT change cluster-level definitions** — Never modify ClusterRoles, ClusterRoleBindings, StorageClasses, CRDs, Nodes, or any resource outside the target namespace.
2. **Do NOT delete resources outside the target namespace** — All `kubectl delete` and `helm uninstall` commands must use `-n $NAMESPACE`.
3. **Do NOT skip the confirmation step** — Even if the user says "just tear it down", show the specific list of resources first.

## When to Use This Skill

- Removing a deployed llm-d stack after benchmarking or experimentation
- Freeing up GPU/CPU resources in a namespace
- Resetting a namespace before a fresh deployment
- Partial cleanup (e.g., remove model service only, keep the gateway)

## Security Considerations

- Run teardown operations in isolated namespaces
- Use RBAC for access control
- Audit all deletions
- Never delete cluster-wide resources
