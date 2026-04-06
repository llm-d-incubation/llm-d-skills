# Troubleshooting Manual Worker Scaling

## Issue: scale-workers.sh Script Fails

**Symptoms:**
- Script exits with error when trying to scale workers
- Error: "Could not auto-detect deployment" or "no objects passed to scale"

**Root Cause:**
- Deployments may not have the expected `llm-d.ai/role` labels
- Script relies on label selectors that may not exist in all deployments

**Solution:**
Use direct kubectl commands instead:
```bash
# 1. List all deployments to find worker names
kubectl get deployments -n ${NAMESPACE}

# 2. Scale using exact deployment names
kubectl scale deployment <exact-deployment-name> --replicas=${COUNT} -n ${NAMESPACE}
```

## Issue: Lost Replica Counts After Suspension

**Symptoms:**
- Cannot remember how many workers were running before suspension
- Annotation-based tracking doesn't work

**Root Cause:**
- Deployments without `llm-d.ai/role` labels can't use annotation tracking
- Manual scaling operations may not preserve annotations

**Solution:**
Always save replica counts to a file before suspending:
```bash
# Save current state
kubectl get deployments -n ${NAMESPACE} -o json | \
  jq -r '.items[] | select(.metadata.name | contains("decode") or contains("prefill")) | 
  "\(.metadata.name) \(.spec.replicas)"' > worker-replicas-backup.txt

# Add resume commands to the file for easy reference
```

## Issue: Deployments Don't Have Expected Labels

**Symptoms:**
- Label selectors return no results
- Cannot use `-l llm-d.ai/role=decode` filters

**Root Cause:**
- Different deployment methods may use different labeling schemes
- Helm charts may not apply standard llm-d labels

**Solution:**
Use deployment name patterns instead:
```bash
# Find deployments by name pattern
kubectl get deployments -n ${NAMESPACE} | grep -E "(decode|prefill)"

# Or use JSON filtering
kubectl get deployments -n ${NAMESPACE} -o json | \
  jq -r '.items[] | select(.metadata.name | contains("decode") or contains("prefill")) | .metadata.name'