# Troubleshooting Guidance

## Deployment Issues

### Repository and Guide Issues

**llm-d repository structure changed:**
- **Problem**: Guides moved from `examples/` to `guides/` directory
- **Solution**: Check guide index at `${LLMD_PATH}/guides/README.md` or `${LLMD_PATH}/README.md` for current structure
- **Note**: Old deployment scripts referencing `examples/` will fail

**Guide not found or path incorrect:**
- **Problem**: Guide directory structure or naming changed between versions
- **Solution**: List available guides: `ls ${LLMD_PATH}/guides/`
- **Solution**: Read guide index: `cat ${LLMD_PATH}/guides/README.md`
- **Solution**: Find guide index: `cat ${LLMD_PATH}/README.md`

**Helm chart registry authentication issues:**
- **Problem**: `docker-credential-secretservice: error while loading shared libraries: libsecret-1.so.0`
- **Solution**: Install missing library: `sudo apt-get install libsecret-1-0` (Ubuntu/Debian)
- **Alternative**: Use `helm pull` to download chart locally first

### Configuration Issues

**Helmfile template error (missing config files):**
- Copy gateway config to workspace: `values/istio-config.yaml`
- Update helmfile to reference local copy

**Helmfile syntax error ("Add the .gotmpl file extension"):**
- Rename: `mv helmfile.yaml helmfile.yaml.gotmpl`

**Wrong chart version or incompatible versions:**
- **Problem**: Chart version mismatch with guide requirements
- **Solution**: Check guide's README for required chart versions
- **Solution**: Use exact version from guide: `--version X.Y.Z`

**Missing or incorrect values files:**
- **Problem**: Guide references values files that don't exist or have moved
- **Solution**: Check guide directory structure: `ls -R ${LLMD_PATH}/guides/<guide-name>/`
- **Solution**: Verify values file paths in helmfile or helm commands
- **Solution**: Use layered values approach: base values + guide-specific overrides

**CRD conflict:**
- Delete and retry: `kubectl delete crd variantautoscalings.llmd.ai`

**HPA minReplicas validation error:**
- Set `minReplicas: 1` (Kubernetes requires ≥1)
- Use WVA's `scaleToZero: true` for scale-to-zero

**Missing llm-d-monitoring namespace:**
- Create: `kubectl create namespace llm-d-monitoring`

### Deployment Command Issues

**kubectl/oc command syntax errors:**
- **Problem**: Using `--all` flag with label selectors
- **Error**: `error: setting 'all' parameter but found a non empty selector`
- **Solution**: Remove `--all` flag when using `-l` selector
- **Correct**: `kubectl delete pods -l llm-d.ai/role=decode -n ${NAMESPACE}`
- **Incorrect**: `kubectl delete pods -l llm-d.ai/role=decode --all -n ${NAMESPACE}`

**Kustomize build failures:**
- **Problem**: Kustomize overlay path incorrect or missing
- **Solution**: Verify overlay exists: `ls ${LLMD_PATH}/guides/<guide>/modelserver/<accelerator>/<server>/`
- **Solution**: Check kustomization.yaml exists in overlay directory
- **Solution**: Use full path: `kustomize build ${LLMD_PATH}/guides/<guide>/modelserver/<accelerator>/<server>/`

**Namespace not set or incorrect:**
- **Problem**: Commands fail because namespace not specified
- **Solution**: Always export NAMESPACE: `export NAMESPACE=your-namespace`
- **Solution**: Add `-n ${NAMESPACE}` to all kubectl/oc commands
- **Solution**: Verify current namespace: `kubectl config view --minify | grep namespace`

## Runtime Issues

### Pod Scheduling and Startup Issues

**Catastrophic pod explosion - hundreds of pods created:**
- **Problem**: Deployment creates 100+ pods instead of requested replica count (e.g., 130+ pods when only 3-4 replicas requested)
- **Root Cause**: Missing or incorrect `replicas` field in kustomization.yaml when using kustomize-based deployments
- **Symptoms**:
  - Massive number of pods created rapidly
  - Cluster resources exhausted
  - Most pods stuck in Pending, ContainerCreating, or CrashLoopBackOff
  - Pods fail to get GPU resources because cluster runs out
  - Kubernetes keeps creating new pods trying to meet replica requirements
- **Diagnosis**:
  ```bash
  # Check actual pod count vs expected
  kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode --no-headers | wc -l
  
  # Check deployment replica setting
  kubectl get deployment <deployment-name> -n ${NAMESPACE} -o jsonpath='{.spec.replicas}'
  
  # Check kustomization.yaml for replicas field
  cat kustomization.yaml | grep -A 3 "replicas:"
  ```
- **Solution**: Add explicit replica count in kustomization.yaml:
  ```yaml
  replicas:
    - name: decode  # or your deployment name
      count: 3      # your desired replica count
  ```
- **Emergency cleanup** if already deployed:
  ```bash
  # Delete the deployment to stop pod creation
  kubectl delete deployment <deployment-name> -n ${NAMESPACE}
  
  # Force delete stuck pods (if needed)
  kubectl delete pods -l llm-d.ai/role=decode -n ${NAMESPACE} --force --grace-period=0
  
  # Fix kustomization.yaml, then redeploy
  kubectl apply -k <path-to-kustomization>
  ```
- **Prevention**: Always verify kustomization.yaml includes explicit replica count before deploying
- **Note**: This is specific to kustomize-based deployments. Helm-based deployments specify replicas in values.yaml

**Pods in CrashLoopBackOff:**
- **Problem**: Pods repeatedly crashing and restarting
- **Diagnosis**: Check logs: `kubectl logs <pod> -n ${NAMESPACE} --previous`
- **Common causes**:
  - vLLM configuration errors (wrong model path, invalid parameters)
  - Insufficient GPU memory for model
  - Missing or invalid HuggingFace token
  - Network connectivity issues to model registry
  - Container image pull failures
  - GPU allocation failures (see pod explosion issue above)
- **Solution**: Review pod logs for specific error messages
- **Solution**: Verify resource requests match available resources
- **Solution**: Check HF token secret exists and is valid
- **Solution**: If many pods in CrashLoopBackOff, check for pod explosion issue (missing replicas in kustomization.yaml)

**Pods pending:**
- Check GPU availability: `kubectl describe nodes | grep nvidia.com/gpu`
- **Additional checks**:
  - Node selectors: `kubectl get pod <pod> -n ${NAMESPACE} -o yaml | grep -A 5 nodeSelector`
  - Taints and tolerations: `kubectl describe nodes | grep -A 5 Taints`
  - PVC binding: `kubectl get pvc -n ${NAMESPACE}`
  - Resource quotas: `kubectl describe resourcequota -n ${NAMESPACE}`

**Pods in UnexpectedAdmissionError:**
- **Problem**: Admission webhook or policy blocking pod creation
- **Solution**: Check admission webhook logs
- **Solution**: Verify pod security policies/standards
- **Solution**: Check for resource quota violations

**Excessive pod creation / GPU hardware failures:**
- **Problem**: Deployment creates hundreds of pods (e.g., 450+) instead of requested replicas, with pods failing due to GPU hardware errors
- **Symptoms**:
  - Massive pod creation (100s of pods when only 1-3 replicas requested)
  - Pods stuck in `ContainerStatusUnknown`, `Pending`, or `UnexpectedAdmissionError`
  - GPU NVLink errors in pod events: `error getting NVLink for devices: failed to get nvlink state: GPU is lost`
  - Continuous pod creation/failure loop exhausting cluster resources
- **Root Cause**: GPU hardware failure on specific cluster nodes (e.g., NVLink failures, GPU device errors)
- **Immediate Fix** (stop the pod creation loop):
  ```bash
  # 1. Delete the deployment to stop creating new pods
  kubectl delete deployment <deployment-name> -n ${NAMESPACE}
  
  # 2. Force delete all failing pods
  kubectl delete pods -n ${NAMESPACE} -l llm-d.ai/model=<model-name> --grace-period=0 --force
  
  # 3. Scale deployment to minimal replicas before redeploying
  # Edit your deployment configuration to set replicas: 1
  ```
- **Diagnosis**:
  ```bash
  # Check pod events for GPU errors
  kubectl describe pod <pod-name> -n ${NAMESPACE} | grep -A 10 Events
  
  # Identify problematic nodes
  kubectl get pods -n ${NAMESPACE} -o wide | grep <failing-pod-prefix>
  
  # Check node GPU status
  kubectl describe node <node-name> | grep -A 10 "nvidia.com/gpu"
  ```
- **Long-term Solution** (avoid problematic nodes):
  Add node anti-affinity to your deployment configuration to avoid scheduling on nodes with GPU hardware issues:
  ```yaml
  # Add to your patch file or deployment spec under spec.template.spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: kubernetes.io/hostname
            operator: NotIn
            values:
            - <problematic-node-name>  # e.g., pokprod-b93r38s3
  ```
- **Prevention**:
  - Monitor pod events during initial deployment
  - Report GPU hardware failures to cluster administrators
  - Maintain a list of known problematic nodes in your deployment documentation
- **Note**: This requires cluster administrator intervention to repair or replace faulty GPU hardware

**Pods crash:**
- Check logs: `kubectl logs <pod> -c vllm -n ${NAMESPACE}`
- Check previous logs: `kubectl logs <pod> -c vllm -n ${NAMESPACE} --previous`
- Verify HF token and model name
- **Additional diagnostics**:
  - Check events: `kubectl describe pod <pod> -n ${NAMESPACE}`
  - Verify container image: `kubectl get pod <pod> -n ${NAMESPACE} -o jsonpath='{.spec.containers[*].image}'`
  - Check resource limits: `kubectl get pod <pod> -n ${NAMESPACE} -o yaml | grep -A 10 resources`

**Model loading slow:**
- Normal for large models (5-10 min for 100B+)
- Monitor: `kubectl logs <pod> -c vllm -f -n ${NAMESPACE}`
- **Expected behavior**: Model download and loading takes time
- **When to worry**: If stuck for >15 minutes with no progress
- **Check**: Network bandwidth to HuggingFace, disk I/O performance

### Networking and Routing Issues

**Routing not working:**
- Verify gateway programmed: `kubectl get gateway -n ${NAMESPACE}`
- Check HTTPRoute accepted: `kubectl describe httproute -n ${NAMESPACE}`
- **Additional checks**:
  - Gateway status: `kubectl get gateway <gateway-name> -n ${NAMESPACE} -o yaml`
  - HTTPRoute backend references: `kubectl get httproute <route-name> -n ${NAMESPACE} -o yaml`
  - Service endpoints: `kubectl get endpoints -n ${NAMESPACE}`
  - Gateway provider logs (Istio/Envoy/etc.)

**Cluster API server unreachable:**
- **Problem**: `couldn't get current server API group list: Get "https://api...": connection refused`
- **Cause**: Cluster connectivity issues, API server down, or network problems
- **Solution**: Verify cluster access: `kubectl cluster-info`
- **Solution**: Check kubeconfig: `kubectl config view`
- **Solution**: Test API server: `curl -k https://<api-server>:6443/healthz`
- **Note**: This is a cluster infrastructure issue, not an llm-d deployment issue

**Service not accessible:**
- **Problem**: Cannot reach service via port-forward or ingress
- **Solution**: Verify service exists: `kubectl get svc -n ${NAMESPACE}`
- **Solution**: Check service endpoints: `kubectl get endpoints <service> -n ${NAMESPACE}`
- **Solution**: Verify pods are ready: `kubectl get pods -n ${NAMESPACE}`
- **Solution**: Test with port-forward: `kubectl port-forward svc/<service> 8080:80 -n ${NAMESPACE}`

### Resource and Performance Issues

**Workload autoscaler CrashLoopBackOff:**
- Known issue: `-watch-namespace` flag removed in newer versions
- Core inference unaffected - model serving works normally
- Workaround: Use HPA only or manual scaling

**Insufficient resources:**
- **Problem**: Pods pending due to insufficient CPU/GPU/memory
- **Solution**: Check node resources: `kubectl describe nodes`
- **Solution**: Check resource requests: `kubectl get pod <pod> -n ${NAMESPACE} -o yaml | grep -A 10 resources`
- **Solution**: Scale down replicas or adjust resource requests
- **Solution**: Add more nodes to cluster

**GPU not detected or allocated:**
- **Problem**: vLLM cannot find GPU devices
- **Solution**: Verify GPU resources on nodes: `kubectl describe nodes | grep -A 5 "nvidia.com/gpu"`
- **Solution**: Check GPU device plugin: `kubectl get pods -n kube-system | grep nvidia`
- **Solution**: Verify pod GPU requests: `kubectl get pod <pod> -n ${NAMESPACE} -o yaml | grep nvidia.com/gpu`

## Best Practices to Avoid Issues

### Pre-Deployment Checklist

1. **Verify llm-d repository version**:
   - Check current branch: `cd ${LLMD_PATH} && git branch --show-current`
   - Verify guide exists: `ls ${LLMD_PATH}/guides/<guide-name>/`
   - Read guide README: `cat ${LLMD_PATH}/guides/<guide-name>/README.md`

2. **Set required environment variables**:
   ```bash
   export LLMD_PATH=/path/to/llm-d
   export NAMESPACE=your-namespace
   ```

3. **Verify prerequisites**:
   - Namespace exists: `kubectl get namespace ${NAMESPACE}`
   - HF token secret (if needed): `kubectl get secret llm-d-hf-token -n ${NAMESPACE}`
   - Gateway provider (if using Gateway API mode): `kubectl get crd gateways.gateway.networking.k8s.io`
   - Sufficient cluster resources: `kubectl describe nodes`

4. **Clean up previous deployments**:
   - Check existing resources: `kubectl get all -n ${NAMESPACE}`
   - Remove old deployments if needed: `helm list -n ${NAMESPACE}`
   - Delete conflicting resources before redeploying

### During Deployment

1. **Follow guide structure exactly**:
   - Use paths from guide README
   - Don't modify guide files directly
   - Create custom overlays if customization needed

2. **Verify each step**:
   - Check command output for errors
   - Verify resources created: `kubectl get <resource> -n ${NAMESPACE}`
   - Monitor pod status: `kubectl get pods -n ${NAMESPACE} -w`

3. **Save deployment commands**:
   - Create deployment script with actual commands used
   - Include environment variables and prerequisites
   - Add validation steps at the end

### Post-Deployment

1. **Validate deployment**:
   - All pods running: `kubectl get pods -n ${NAMESPACE}`
   - Services have endpoints: `kubectl get endpoints -n ${NAMESPACE}`
   - Gateway/HTTPRoute ready (if applicable)
   - Test inference endpoint: `curl http://<endpoint>/v1/models`

2. **Monitor for issues**:
   - Watch pod logs: `kubectl logs -f <pod> -n ${NAMESPACE}`
   - Check resource usage: `kubectl top pods -n ${NAMESPACE}`
   - Monitor events: `kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'`

3. **Document configuration**:
   - Save deployment script
   - Note any customizations made
   - Record resource requirements and performance metrics