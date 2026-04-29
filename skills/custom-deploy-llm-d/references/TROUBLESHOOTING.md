# Troubleshooting Guidance

## Deployment Issues

### Scheduler Installation

**Helm chart not found:**
- Verify chart version: `helm search repo gateway-api-inference-extension`
- Check OCI registry access: `oci://registry.k8s.io/gateway-api-inference-extension/charts/`
- Ensure you're using the correct chart name: `standalone` or `inferencepool`

**Values file not found:**
- Verify guide path: `${LLMD_PATH}/guides/<guide>/scheduler/`
- Check recipe files exist: `${LLMD_PATH}/guides/recipes/scheduler/base.values.yaml`
- Ensure LLMD_PATH is set correctly

**Provider configuration error:**
- Valid providers: `gke`, `istio`, `none`
- For standalone mode: use `--set provider.name=none`
- For gateway mode: ensure gateway provider is installed first

### Model Server Deployment

**Kustomize build fails:**
- Verify guide path: `${LLMD_PATH}/guides/<guide>/modelserver/<accelerator>/<server>/`
- Check kustomization.yaml exists in the directory
- Ensure all referenced files are present

**Resource not found errors:**
- Verify namespace exists: `kubectl get namespace ${NAMESPACE}`
- Check if scheduler is installed: `kubectl get pods -n ${NAMESPACE}`
- Ensure HuggingFace token secret exists (if required): `kubectl get secret llm-d-hf-token -n ${NAMESPACE}`

### Gateway Configuration (Gateway API Proxy Mode Only)

**Gateway not programmed:**
- Check gateway provider is running: `kubectl get pods -n <gateway-namespace>`
- Verify Gateway API CRDs installed: `kubectl get crd gateways.gateway.networking.k8s.io`
- Check gateway status: `kubectl describe gateway -n ${NAMESPACE}`

**HTTPRoute not accepted:**
- Verify parentRefs match gateway name: `kubectl get gateway -n ${NAMESPACE}`
- Check backendRefs match scheduler name: `kubectl get svc -n ${NAMESPACE}`
- Review HTTPRoute status: `kubectl describe httproute -n ${NAMESPACE}`

## Runtime Issues

### Pod Issues

**Pods pending:**
- Check resource availability: `kubectl describe nodes | grep <resource-type>`
  - For GPUs: `nvidia.com/gpu`, `amd.com/gpu`, `google.com/tpu`
  - For RDMA: `rdma/ib`
- Verify node selectors and tolerations match cluster configuration
- Check resource requests don't exceed node capacity

**Pods crash (CrashLoopBackOff):**
- Check vllm container logs: `kubectl logs <pod> -n ${NAMESPACE} -c vllm`
- Common causes:
  - Invalid model name or HuggingFace token
  - Insufficient GPU memory for model
  - Incorrect tensor parallelism configuration
  - Missing or incorrect environment variables

**Model loading slow (>10 minutes):**
- Normal for very large models (100B+ parameters)
- Monitor progress: `kubectl logs <pod> -n ${NAMESPACE} -c vllm -f`
- Check for download issues (network, HF token)
- Verify sufficient storage for model cache

### Connectivity Issues

**Cannot reach inference endpoint:**
- Verify endpoint exposure method (see `${LLMD_PATH}/guides/02_verifying_a_guide.md`):
  - Port-forward: Check port-forward is running
  - LoadBalancer: Verify external IP assigned
  - Ingress: Check ingress controller and rules
- Test with `/v1/models` first (simpler endpoint)
- Check service exists: `kubectl get svc -n ${NAMESPACE}`

**Requests timeout:**
- For standalone mode: Check scheduler pod is running
- For gateway mode: Verify gateway and HTTPRoute are healthy
- Increase timeout values in HTTPRoute if needed
- Check model server logs for processing errors

**Wrong model name in requests:**
- Query `/v1/models` to get actual model name
- Use exact model name from response in completion requests
- Model name may differ from deployment configuration

### Performance Issues

**High latency:**
- Check GPU utilization: `kubectl exec <pod> -n ${NAMESPACE} -- nvidia-smi`
- Review scheduler metrics for routing decisions
- Consider adjusting parallelism strategy (TP/DP/EP)
- Check for resource contention on nodes

**Low throughput:**
- Verify sufficient replicas are running
- Check for bottlenecks in scheduler or gateway
- Review connection pool settings (DestinationRule for Istio)
- Consider scaling up model server instances

## Common Configuration Mistakes

**RDMA resources requested but not available:**
- Remove `rdma/ib` from resource requests if cluster doesn't support RDMA
- Check RDMA availability: `kubectl get nodes -o json | jq '.items[].status.allocatable | select(."rdma/ib" != null)'`

**Startup probes failing for large models:**
- Increase `failureThreshold` and `periodSeconds` for models >30B
- Example: `failureThreshold: 120, periodSeconds: 30` (60 minutes total)

**Incorrect namespace references:**
- Ensure all resources use the same namespace
- Check service FQDNs include correct namespace
- Verify RBAC permissions for the namespace

## Getting Help

For additional troubleshooting:
- Review guide-specific README: `${LLMD_PATH}/guides/<guide>/README.md`
- Check installation guide: `${LLMD_PATH}/guides/01_installing_a_guide.md`
- Check verification guide: `${LLMD_PATH}/guides/02_verifying_a_guide.md`
- Review llm-d documentation: https://llm-d.ai/docs
- Join llm-d Slack: https://llm-d.ai/slack