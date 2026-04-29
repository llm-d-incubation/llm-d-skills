---
name: custom-deploy-llm-d
description: Generate custom llm-d deployment configurations for Kubernetes and OpenShift with flexible model, hardware, and gateway settings. Creates scheduler values, model server kustomizations, and deployment documentation based on user requirements. Use this skill when users want to deploy llm-d with specific customizations, need to adapt existing guides to their infrastructure, want to deploy custom models or configurations, or need a tailored deployment that doesn't match standard Well-Lit Path guides exactly. Triggers on requests like "deploy llm-d with custom settings", "create llm-d deployment for my cluster", "I need to deploy model X on hardware Y", or "customize llm-d deployment".
---

# llm-d Custom Deployment Skill


 ## 🔔 ALWAYS NOTIFY THE USER BEFORE CREATING ANYTHING
>
> **RULE**: Before creating ANY resource — including files, namespaces, PVCs, Helm releases, HTTPRoutes, or any Kubernetes object — you MUST first tell the user what you are about to create and why.
>
> **Format to use before every creation action**:
> > "I am about to create `<resource-type>` named `<name>` because `<reason>`. Proceeding now."
>
> **Never silently create resources.** If you are unsure whether a resource already exists, check first, then notify before acting.

This skill enables AI agents to generate custom llm-d deployment configurations for Kubernetes clusters with general configurations that are not part of the Well-Lit Paths. The agent will create deployment files (scheduler values, model server kustomizations, HTTPRoute if needed) and a README documenting the configuration.

## What Not To Do
Critical rules to follow when deploying and managing llm-d:

1. **Do NOT change cluster-level definitions** — All changes must be made exclusively inside the designated project namespace. Never modify cluster-wide resources (e.g., ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or any resource outside the target namespace). Scope every `kubectl apply` and `helm install` command to the target namespace using `-n ${NAMESPACE}`.

2. **Do NOT modify any existing code you did not create** — Only create new files and modify them as needed. Never edit pre-existing files in the repository (e.g., existing `values.yaml`, `helmfile.yaml`, `httproute.yaml`, `README.md`, or any other committed file). If customization is required, create a new file (e.g., `values-custom.yaml`, `httproute-custom.yaml`) and reference it instead.



## Core Execution Principle

**EXECUTE, DON'T JUST DOCUMENT**: This skill must actually run deployment commands and validate results. The workflow is:
1. Generate configuration files (scheduler values, model server kustomizations)
2. **Execute deployment commands** (helm install for scheduler, kustomize + kubectl apply for model server)
3. **Validate deployment** (check pods, resources, connectivity)
4. **Then generate reusable script** based on what was actually executed

Do not stop after creating files - always execute the deployment and validate it works.

## Workflow Overview

### Step 1: Project Setup

**Check for llm-d repository:**
- Use `LLMD_PATH` environment variable if set
- If not set, check if current directory is llm-d repository
- If not found, offer options:
  - User provides path to existing clone
  - Clone from GitHub: `git clone https://github.com/llm-d/llm-d.git`
  
**After locating the repository, always set LLMD_PATH:**
```bash
export LLMD_PATH=/path/to/llm-d
```
  
**Set up workspace:**
- Naming convention: `{model-short-name}-{namespace}-{DDMMYYYY}` (e.g., `qwen25-llmd-25032026`)
- Create deployment workspace: `deployments/deploy-{namespace}-{model}-{timestamp}/`
- This is where all custom files will be created
- Original repository files are never modified

### Step 2: Requirements Gathering

**CRITICAL: Automatically detect ALL possible information before asking the user.**

**Step 2.1: Automatic Infrastructure Detection**

Execute detection commands automatically:

1. **Detect cluster type:** Check for GKE, OpenShift, EKS, or generic Kubernetes
2. **Detect namespace:** Check NAMESPACE env var, oc project, or kubectl context
3. **Detect hardware:** Query nodes for GPUs, TPUs, accelerators with capacity and labels
4. **Detect gateway providers:** Check for Istio, Gateway API CRDs, gateway pods
5. **Detect storage classes:** List available storage classes and identify default
7. **Detect RDMA/network resources:** Check if RDMA/InfiniBand is available: `kubectl get nodes -o json | jq '.items[].status.allocatable | select(."rdma/ib" != null)'`
6. **Detect existing resources:** Check for llm-d deployments, HF token secret, PVCs

**Step 2.2: Present Detected Configuration**

Show detected configuration clearly:
- Cluster type and version
- Namespace (current or detected)
- Hardware: GPU/TPU/CPU types and counts per node
- Gateway provider: Istio/K-Gateway/Agent Gateway/GKE Gateway
- Storage: Available storage classes and default
- RDMA availability: Present/Absent (impacts P/D disaggregation networking)
- Existing resources: Any llm-d components already deployed

**Step 2.3: Ask ONLY for Missing Information**

Only ask user for:
- Model requirements (which model to deploy)
- Traffic patterns if not obvious from model choice
- Override values if detected configuration is insufficient

### Step 3: Guide Recommendation

**Recommend base guide based on requirements:**

| Use Case | Recommended Guide | Why |
|----------|------------------|-----|
| General production | `optimized-baseline` | Intelligent request routing with prefix-cache and load-aware balancing (default) |
| Enhanced prefix routing | `precise-prefix-cache-aware` | Adds precise global KV cache indexing to optimized-baseline |
| High throughput (large models) | `pd-disaggregation` | Separates prefill/decode for improved throughput and QoS stability |
| Large MoE models | `wide-ep-lws` | Expert parallelism for models like DeepSeek-R1 across multiple nodes |
| Extended cache capacity | `tiered-prefix-cache` | Offloads KV cache to CPU/disk for multi-turn workloads |
| Auto-scaling | `workload-autoscaling` | SLO-aware autoscaling based on queue depth and KV cache pressure |

**Explain the choice** - Help user understand why this guide fits their needs

### Step 4: Configuration Customization

**Copy guide to workspace:**
```
deployments/deploy-{namespace}-{timestamp}/
├── scheduler/             # Scheduler configuration
│   ├── base.values.yaml
│   ├── features/
│   └── {guide}.values.yaml
├── modelserver/           # Model server kustomization
│   └── kustomization.yaml
├── httproute.yaml         # HTTPRoute (if using Gateway API proxy mode)
├── README.md              # Deployment documentation
└── deploy.sh              # Deployment script
```

**Customize based on requirements:**

1. **Scheduler values customization:**
   - Layer values files: base.values.yaml + features/*.values.yaml + {guide}.values.yaml
   - Set provider name (gke, istio, none)
   - Configure monitoring and features
   - Adjust scheduler-specific settings

2. **Model server kustomization:**
   - Select appropriate accelerator overlay (cuda, tpu, xpu, hpu, cpu)
   - Select server type (vllm, sglang)
   - Customize model configuration (name, revision, quantization)
   - Adjust resource requests/limits
   - Configure parallelism strategy (TP, DP, EP, PP)
   - **CRITICAL**: Remove `rdma/ib` resource requests if RDMA not detected in cluster
   - **CRITICAL**: For models >30B, increase startup probe: `failureThreshold: 120, periodSeconds: 30`

3. **HTTPRoute customization (Gateway API proxy mode only):**
   - Configure gateway references
   - Set up routing rules
   - Add custom headers or filters
   - Configure TLS if needed
   - See detailed HTTPRoute examples and guidance below

4. **DestinationRule for scheduler service (Istio only):**
   - Configure connection pooling and timeouts for the scheduler service
   - Required for high-throughput scenarios to prevent connection bottlenecks
   - Typically created automatically by gateway recipes
   - See `${LLMD_PATH}/guides/recipes/gateway/README.md` for details

**Example customizations:**

```yaml
# scheduler/{guide}.values.yaml
provider:
  name: istio  # or gke, none

# modelserver/kustomization.yaml
resources:
  - ../../recipes/modelserver/base
patches:
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/env
        value:
          - name: MODEL_NAME
            value: "meta-llama/Llama-3.1-70B-Instruct"
          - name: TENSOR_PARALLEL_SIZE
            value: "4"
          - name: MAX_MODEL_LEN
            value: "8192"
  - patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/resources
        value:
          requests:
            nvidia.com/gpu: 4
            memory: "64Gi"
          limits:
            nvidia.com/gpu: 4
            memory: "64Gi"
```

### Step 5: Prerequisites Verification

**Before deploying, verify all prerequisites are met:**

1. **Namespace exists or create it:**
   - Check: `kubectl get namespace {namespace}`
   - Create if needed: `kubectl create namespace {namespace}`

2. **HuggingFace token secret:**
   - Required for model downloads
   - Check: `kubectl get secret llm-d-hf-token -n {namespace}`
   - Create: `kubectl create secret generic llm-d-hf-token --from-literal=HF_TOKEN={token} -n {namespace}`

3. **Storage provisioning (if needed):**
   - Check for PVC requirements in guide
   - Verify storage class availability
   - Create PVC if required

4. **Gateway provider ready (if using Gateway API proxy mode):**
   - Verify gateway pods are running
   - Check Gateway API CRDs are installed: `kubectl get crd gateways.gateway.networking.k8s.io`
   - Confirm gateway resource exists: `kubectl get gateway -n {namespace}`

### Step 6: Execute Deployment

**CRITICAL: Actually execute the deployment commands, don't just create scripts.**

**Pre-deployment checks:**
- Verify LLMD_PATH is set and points to llm-d repository
- Create required namespaces: `kubectl create namespace {namespace}`
- Ensure HuggingFace token secret exists if required by model
- For Gateway API proxy mode: ensure gateway provider is installed and gateway resource exists

1. **Navigate to workspace:**
   ```bash
   cd deployments/deploy-{namespace}-{timestamp}
   ```

2. **Install the Scheduler:**
   
   Follow the current install flow documented in `${LLMD_PATH}/guides/01_installing_a_guide.md`:
   
   **Choose deployment mode:**
   - **Standalone mode (default)** - Simplest path, no external proxy needed. Scheduler includes Envoy sidecar.
   - **Gateway API proxy mode** - For production with full gateway provider (Istio, Agentgateway, GKE Gateway)
   
   **Standalone mode:**
   ```bash
   cd ${LLMD_PATH}
   helm install <guide>-scheduler \
     oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
     -f guides/recipes/scheduler/base.values.yaml \
     -f guides/recipes/scheduler/features/monitoring.values.yaml \
     -f guides/<guide>/scheduler/<guide>.values.yaml \
     --set provider.name=<gke|istio|none> \
     -n ${NAMESPACE} --version v1.4.0
   ```
   
   **Gateway API proxy mode:**
   ```bash
   cd ${LLMD_PATH}
   # First deploy gateway (see ${LLMD_PATH}/guides/recipes/gateway/README.md)
   kubectl apply -k guides/recipes/gateway/<provider> -n ${NAMESPACE}
   
   # Then install scheduler
   helm install <guide>-scheduler \
     oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
     -f guides/recipes/scheduler/base.values.yaml \
     -f guides/recipes/scheduler/features/monitoring.values.yaml \
     -f guides/<guide>/scheduler/<guide>.values.yaml \
     --set provider.name=<gke|istio|none> \
     -n ${NAMESPACE} --version v1.4.0
   ```

3. **Deploy the Model Server:**
   
   Deploy the model server using the guide's `kustomize` overlay:
   ```bash
   cd ${LLMD_PATH}
   kustomize build guides/<guide>/modelserver/<accelerator>/<server>/ | kubectl apply -n {namespace} -f -
   ```

4. **Monitor deployment progress:**
   - Watch pods starting: `kubectl get pods -n {namespace} -w`
   - Wait for all pods to reach Running state
   - Check for any errors or issues
   - **Note**: Large models (>30B) may take 5-10 minutes to load. CrashLoopBackOff during initial load is expected.
   - Clean up old pending pods: `kubectl delete pod -n {namespace} --field-selector status.phase=Pending`

### Step 7: Validate Deployment

**Execute validation checks to confirm successful deployment:**

1. **Pod health:**
   - All pods should reach Running state
   - Check pod logs for errors
   - Check for CrashLoopBackOff or ImagePullBackOff
   - Review logs if issues: `kubectl logs {pod} -n {namespace}`

2. **Resource status:**
   - Scheduler pods are Running and Ready
   - Model server pods are Running and Ready
   - For Gateway API proxy mode: Gateway shows Programmed, HTTPRoute shows Accepted
   - Check PVCs (if applicable)

3. **Connectivity test:**
   - Expose the endpoint using the current verification guide: port-forward, external IP, ingress, or route as described in `${LLMD_PATH}/guides/02_verifying_a_guide.md`
   - Test endpoint: `curl ${ENDPOINT}/v1/models`
   - Send test request: `curl ${ENDPOINT}/v1/completions -d {...}`
   - Query `/v1/models` first and use the actual returned model name in completion requests
   Model loading can take several minutes depending on model size


4. **Performance check:**
   - Monitor resource usage: `kubectl top pods -n {namespace}`
   - Check GPU utilization (if applicable)
   - Verify response times meet requirements

**Success Criteria:**
- All required pods are Running state with N/N ready
- Scheduler resources are ready
- Gateway resources are healthy when gateway mode is used
- `/v1/models` responds successfully
- `/v1/completions` responds successfully

### Step 8: Generate Reusable Artifacts

**CRITICAL: After successful deployment and validation, You MUST ALWAYS generate reusable artifacts:**

1. After successful validation, **you MUST generate a reusable deployment script** with a date-stamped filename.
**Script Naming Convention:**
- **REQUIRED FORMAT**: `deploy-DDMMYYYY.sh` (e.g., `deploy-15032026.sh`)

**Script Location:**
- Save the script in the `deployments/` directory
- Full path example: `deployments/deploy-15032026.sh`

**Script Content Requirements:**
The deployment script MUST contain ALL commands that were actually executed during deployment:
- Include exact commands used (with actual values, not placeholders)
- Add prerequisite checks at the beginning
- Include all deployment steps in order
- Include validation steps at the end
- Add error handling and exit on failures
- Add comments explaining each major step
- Set executable permissions: `chmod +x deployments/deploy-DDMMYYYY.sh`

**Example Script (based on actual executed commands):**
```bash
#!/bin/bash
# Deployment script generated on DD-MM-YYYY
# Guide: [guide-name]
# Namespace: [namespace]
set -e

# Configuration
export NAMESPACE="your-namespace"
export LLMD_PATH="/path/to/llm-d"

# Prerequisites check
echo "Checking prerequisites..."
kubectl get namespace $NAMESPACE || kubectl create namespace $NAMESPACE
kubectl get secret llm-d-hf-token -n $NAMESPACE || {
  echo "ERROR: HuggingFace token secret not found"
  exit 1
}

# Deploy scheduler
echo "Installing scheduler..."
cd $(dirname $0)
# Add actual helm install commands based on mode

# Deploy model server
echo "Deploying model server..."
kustomize build guides/<guide>/modelserver/<accelerator>/<server>/ | kubectl apply -n $NAMESPACE -f -

# Validate
echo "Validating deployment..."
kubectl get pods -n $NAMESPACE
kubectl get all -n $NAMESPACE

echo "Deployment complete!"
```
**REMINDER: Generating this script is NOT optional - it MUST be created every time a deployment is completed.**


2. **README.md** - **CONCISE** deployment summary:
   - Configuration summary (namespace, model, hardware)
   - Prerequisites checklist (bullet points only)
   - Deployment command (single command to run)
   - Validation steps (3-4 key checks)
   - Common issues (2-3 most likely problems)
   
   **Keep it SHORT - users want quick reference, not documentation.**
   **REMINDER: Generating this deployment summary is NOT optional - it MUST be created every time a deployment is completed.**


## Common Customization Patterns

### Custom Model Configuration

**When user wants specific model:**
- Update model name and revision in values
- Adjust resource requests based on model size
- Configure tensor parallelism for large models
- Set appropriate context length

### Hardware-Specific Tuning

**NVIDIA GPUs:**
- Set `nvidia.com/gpu` resource requests
- Configure tensor parallel size
- Enable CUDA optimizations

**AMD GPUs:**
- Use `amd.com/gpu` resource requests
- Configure ROCm settings
- Adjust memory allocation

**TPUs (GKE):**
- Set `google.com/tpu` resource requests
- Configure TPU topology
- Use TPU-optimized images

**CPU-only:**
- Remove GPU resource requests
- Increase CPU and memory allocations
- Disable GPU-specific optimizations

### Gateway Customization

**Istio:**
- Configure VirtualService for advanced routing
- Set up mTLS if needed
- Add custom headers or filters

**K-Gateway:**
- Use Gateway API resources
- Configure HTTPRoute with filters
- Set up TLS certificates

**GKE Gateway:**
- Use GKE-managed gateway
- Configure Cloud Armor if needed
- Set up Cloud CDN for caching

### HTTPRoute Configuration

HTTPRoute connects your Gateway to the InferencePool for routing inference requests.

**Example:** See [`examples/httproute-example.yaml`](examples/httproute-example.yaml) for a complete annotated example with inline comments explaining each field.

**Key customization points:**
- `metadata.name`: Your HTTPRoute name (e.g., `llm-d-{model}`)
- `parentRefs[].name`: Gateway name from llm-d-infra chart (e.g., `infra-{release}-inference-gateway`)
- `backendRefs[].group`: Use `inference.networking.k8s.io` for InferencePool backends
- `backendRefs[].name`: InferencePool name from inferencepool chart (e.g., `gaie-{release}`)

### DestinationRule Configuration (Istio)

DestinationRule optimizes connection handling to the EPP service for high-throughput scenarios. Used with Istio gateway provider. Typically created by the `llm-d-infra` chart.

**Example:** See [`examples/destinationrule-example.yaml`](examples/destinationrule-example.yaml) for a complete annotated example with inline comments explaining each field.

**Key customization points:**
- `metadata.name`: Match your EPP service name
- `spec.host`: Full service FQDN (e.g., `gaie-{release}.{namespace}.svc.cluster.local`)
- `connectionPool.http.http2MaxRequests`: Adjust for expected concurrent requests
- `connectionPool.tcp.maxConnections`: Adjust for throughput requirements
- Timeout values: Adjust based on inference duration

## Troubleshooting Guidance

For detailed troubleshooting guidance, see [TROUBLESHOOTING.md](./references/TROUBLESHOOTING.md).


## When to Use This Skill

**Use llm-d-custom-deploy when:**
- User needs specific model or configuration not in standard guides
- Infrastructure requires customization (special hardware, networking)
- Production deployment needs tailoring
- User wants to understand and control the deployment process

**Use llm-d-deployment when:**
- User wants to quickly try a standard Well-lit Path guide
- Minimal customization needed
- Following tested recipes exactly
- Learning llm-d capabilities

## Success Criteria

A successful deployment should have:
- ✅ All pods running and ready
- ✅ InferencePool, Gateway, HTTPRoute in healthy state
- ✅ Inference endpoint responding to requests
- ✅ Reusable deployment script created
- ✅ Documentation explaining configuration choices
- ✅ User understands what was deployed and why

## Critical Rules

1. **NEVER modify original repository files** - Only create new files in a workspace directory
2. **Copy, then customize** - Copy guide files to workspace, then modify the copies
3. **Preserve originals** - All llm-d repository files remain untouched
4. **Create deployment artifacts** - Generate reusable deployment scripts and documentation

## Additional Resources

### Documentation (Local Repository)
All documentation should be accessed from your local llm-d repository at `${LLMD_PATH}`:
- **Well-Lit Path Guides**: `${LLMD_PATH}/guides/README.md`
- **Installing a Guide**: `${LLMD_PATH}/guides/01_installing_a_guide.md`
- **Verifying a Guide**: `${LLMD_PATH}/guides/02_verifying_a_guide.md`
- **Benchmarking a Guide**: `${LLMD_PATH}/guides/03_benchmarking_a_guide.md`
- **Customizing a Guide**: `${LLMD_PATH}/guides/04_customizing_a_guide.md`
- **Scheduler Recipes**: `${LLMD_PATH}/guides/recipes/scheduler/README.md`
- **Gateway Recipes**: `${LLMD_PATH}/guides/recipes/gateway/README.md`
- **Model Server Recipes**: `${LLMD_PATH}/guides/recipes/modelserver/README.md`

### External Resources
- [llm-d Project on GitHub](https://github.com/llm-d/llm-d)
- [llm-d-benchmark CLI](https://github.com/llm-d/llm-d-benchmark)

### External Resources
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [vLLM Documentation](https://docs.vllm.ai)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io)

### Helm Chart Repositories
- **standalone**: `oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone` - Scheduler with Envoy sidecar (v1.4.0)
- **inferencepool**: `oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool` - Scheduler for Gateway API mode (v1.4.0)

### Available Well-Lit Path Guides
Current guides in llm-d repository:
1. **optimized-baseline** - Default production path with prefix-cache and load-aware routing
2. **precise-prefix-cache-aware** - Enhanced with precise global KV cache indexing
3. **pd-disaggregation** - Prefill/decode separation for medium/large models
4. **wide-ep-lws** - Expert parallelism for large MoE models (DeepSeek-R1)
5. **tiered-prefix-cache** - KV cache offloading to CPU/disk/shared storage
6. **workload-autoscaling** - SLO-aware autoscaling (experimental)
7. **predicted-latency-based-scheduling** - XGBoost-based latency prediction (experimental)
8. **asynchronous-processing** - Queue-based async inference (experimental)