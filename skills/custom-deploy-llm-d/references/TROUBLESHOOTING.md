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