# Troubleshooting Guidance

## Deployment Issues

**Helmfile template error (missing config files):**
- Copy gateway config to workspace: `values/istio-config.yaml`
- Update helmfile to reference local copy

**Helmfile syntax error ("Add the .gotmpl file extension"):**
- Rename: `mv helmfile.yaml helmfile.yaml.gotmpl`

**CRD conflict:**
- Delete and retry: `kubectl delete crd variantautoscalings.llmd.ai`

**HPA minReplicas validation error:**
- Set `minReplicas: 1` (Kubernetes requires ≥1)
- Use WVA's `scaleToZero: true` for scale-to-zero

**Missing llm-d-monitoring namespace:**
- Create: `kubectl create namespace llm-d-monitoring`

**Workload autoscaler CrashLoopBackOff:**
- Known issue: `-watch-namespace` flag removed in newer versions
- Core inference unaffected - model serving works normally
- Workaround: Use HPA only or manual scaling

## Runtime Issues

**Excessive pod creation:**
- **Symptom:** Deployment creates far more pods than requested replicas, often due to insufficient GPU resources
- **Root cause:** When pods fail to obtain required GPUs, Kubernetes keeps creating new pods while old ones remain in Pending/CrashLoopBackOff state. Multiple ReplicaSets from failed deployments can accumulate.
- **Fix:**
  1. Check current pod status: `kubectl get pods -n <namespace> -l llm-d.ai/model=<model-name>`
  2. Identify old ReplicaSets: `kubectl get replicasets -n <namespace> -l llm-d.ai/model=<model-name>`
  3. Delete old ReplicaSets: `kubectl delete replicaset <old-replicaset-name> -n <namespace>`
  4. Delete non-working pods: `kubectl delete pod <pod-name> -n <namespace>`
  5. Verify GPU availability matches requirements: `kubectl describe nodes | grep nvidia.com/gpu`
  6. Scale deployment if needed: Update `replicas` in modelservice-values.yaml and reapply with helmfile
- **Prevention:** Always verify cluster has sufficient GPU resources before deployment

**Pods pending:**
- Check GPU availability: `kubectl describe nodes | grep nvidia.com/gpu`

**Pods crash:**
- Check logs: `kubectl logs <pod> -c vllm`
- Verify HF token and model name

**Model loading slow:**
- Normal for large models (5-10 min for 100B+)
- Monitor: `kubectl logs <pod> -c vllm -f`

**Routing not working:**
- Verify gateway programmed: `kubectl get gateway`
- Check HTTPRoute accepted: `kubectl describe httproute`