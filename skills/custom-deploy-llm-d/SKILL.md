---
name: custom-deploy-llm-d
description: Generate custom llm-d deployment configurations for Kubernetes and OpenShift with flexible model, hardware, and gateway settings. Creates helmfile.yaml, httproute.yaml, and deployment README based on user requirements. Use this skill when users want to deploy llm-d with specific customizations, need to adapt existing guides to their infrastructure, want to deploy custom models or configurations, or need a tailored deployment that doesn't match standard Well-lit Path guides exactly. Triggers on requests like "deploy llm-d with custom settings", "create llm-d deployment for my cluster", "I need to deploy model X on hardware Y", or "customize llm-d deployment".
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

This skill enables AI agents to generate custom llm-d deployment configurations for Kubernetes clusters with general configurations that are not part of the well-lit paths. The agent will create deployment files (helmfile.yaml, httproute.yaml) and a README documenting the configuration.

## What Not To Do
Critical rules to follow when deploying and managing llm-d:

1. **Do NOT change cluster-level definitions** — All changes must be made exclusively inside the designated project namespace. Never modify cluster-wide resources (e.g., ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or any resource outside the target namespace). Scope every `kubectl apply`, `helm install`, and `helmfile apply` command to the target namespace using `-n ${NAMESPACE}`.

2. **Do NOT modify any existing code you did not create** — Only create new files and modify them as needed. Never edit pre-existing files in the repository (e.g., existing `values.yaml`, `helmfile.yaml`, `httproute.yaml`, `README.md`, or any other committed file). If customization is required, create a new file (e.g., `values-custom.yaml`, `httproute-custom.yaml`) and reference it instead.



## Core Execution Principle

**EXECUTE, DON'T JUST DOCUMENT**: This skill must actually run deployment commands and validate results. The workflow is:
1. Generate configuration files
2. **Execute deployment commands** (helmfile apply, kubectl apply)
3. **Validate deployment** (check pods, resources, connectivity)
4. **Then generate reusable script** based on what was actually executed

Do not stop after creating files - always execute the deployment and validate it works.

## Workflow Overview

### Step 1: Project Setup

**Check for llm-d repository:**
- Use `LLMD_PATH` environment variable if set;
- If not set check if current directory is llm-d repository 
- If not found, offer options:
  - User provides path to existing clone
  - Clone from GitHub form https://github.com/llm-d/llm-d,
  - Work with files from internet (fetch specific files as needed) form https://github.com/llm-d/llm-d,
  
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
| General production | `inference-scheduling` | Intelligent request routing, good default |
| High throughput | `pd-disaggregation` | Separates prefill/decode for efficiency |
| Long context | `precise-prefix-cache-aware` | Optimizes prefix caching |
| Multi-model | `wide-ep-lws` | Wide expert parallelism |
| Auto-scaling | `workload-autoscaling` | Dynamic scaling based on load |

**Explain the choice** - Help user understand why this guide fits their needs

### Step 4: Configuration Customization

**Copy guide to workspace:**
```
deployments/deploy-{namespace}-{timestamp}/
├── helmfile.yaml          # Copied and customized
├── httproute.yaml         # Copied and customized  
├── values/                # Custom values files
│   ├── infra-values.yaml
│   └── modelservice-values.yaml
├── README.md              # Deployment documentation
└── deploy.sh              # Deployment script
```

**Customize based on requirements:**

1. **Helmfile modifications:**
   - Update namespace references
   - Adjust environment configurations
   - Modify chart versions if needed
   - Add custom values files
***Placeholder Replacement**: Before writing any files, replace ALL placeholders with actual values:

2. **HTTPRoute customization:**
   - Configure gateway references
   - Set up routing rules
   - Add custom headers or filters
   - Configure TLS if needed
   - See detailed HTTPRoute examples and guidance below

3. **DestinationRule for EPP service (Istio only):**
   - Configure connection pooling and timeouts for the EPP (Endpoint Picker) service
   - Required for high-throughput scenarios to prevent connection bottlenecks
   - Created by the `llm-d-infra` chart when using Istio gateway provider
   - See [Gateway Customization docs](../docs/customizing-your-gateway.md) for details

4. **Values files:**
   - Model configuration (name, revision, quantization)
   - Resource requests/limits
   - Hardware-specific settings
   - Scaling parameters
   - **CRITICAL**: Remove `rdma/ib` resource requests if RDMA not detected in cluster
   - **CRITICAL**: For models >30B, increase startup probe: `failureThreshold: 120, periodSeconds: 30`
   - Storage configuration

**Example customizations:**

```yaml
# values/modelservice-values.yaml
modelService:
  model:
    name: "meta-llama/Llama-3.1-70B-Instruct"
    revision: "main"
  
  resources:
    requests:
      nvidia.com/gpu: 4
      memory: "64Gi"
    limits:
      nvidia.com/gpu: 4
      memory: "64Gi"
  
  vllm:
    extraArgs:
      - "--max-model-len=8192"
      - "--tensor-parallel-size=4"
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

4. **Gateway provider ready:**
   - Verify gateway pods are running
   - Check CRDs are installed
   - Confirm gateway configuration

### Step 6: Execute Deployment

**CRITICAL: Actually execute the deployment commands, don't just create scripts.**

**Pre-deployment checks:**
- Ensure helmfile uses `.gotmpl` extension if using Go templates
- Copy gateway config files to workspace (don't reference external paths)
- Create required namespaces (target + llm-d-monitoring if using autoscaler)
- Create Prometheus CA placeholder: `echo "# placeholder" > /tmp/prometheus-ca.crt`

1. **Navigate to workspace:**
   ```bash
   cd deployments/deploy-{namespace}-{timestamp}
   ```

2. **Execute helmfile deployment:**
   ```bash
   helmfile apply -n {namespace} [environment-flags]
   ```
   
   Add environment flags based on detected configuration:
   - Hardware: `-e cuda`, `-e tpu`, `-e xpu`, `-e hpu`
   - Gateway: `-e istio`, `-e kgateway`, `-e agentgateway`
   
   **If CRD conflict occurs:** Delete CRD and retry: `kubectl delete crd variantautoscalings.llmd.ai`

3. **Monitor deployment progress:**
   - Watch pods starting: `kubectl get pods -n {namespace} -w`
   - Wait for all pods to reach Running state
   - Check for any errors or issues
   - **Note**: Large models (>30B) may take 5-10 minutes to load. CrashLoopBackOff during initial load is expected.
   - Clean up old pending pods: `kubectl delete pod -n {namespace} --field-selector status.phase=Pending`
   - Note: Autoscaler pods may crash (known issue) - core inference unaffected

4. **Apply HTTPRoute:**
   Once helmfile deployment completes and pods are running:
   ```bash
   kubectl apply -f httproute.yaml -n {namespace}
   ```

5. **Verify HTTPRoute is accepted:**
   ```bash
   kubectl get httproute -n {namespace}
   ```

### Step 7: Validate Deployment

**Execute validation checks to confirm successful deployment:**

1. **Pod health:**
   - All pods should reach Running state
   - Check pod logs for errors
   - Check for CrashLoopBackOff or ImagePullBackOff
   - Review logs if issues: `kubectl logs {pod} -n {namespace}`

2. **Resource status:**
   - InferencePool shows Ready
   - Gateway shows Programmed
   - HTTPRoute shows Accepted
   - Check PVCs (if applicable)

3. **Connectivity test:**
   - Get gateway address: `kubectl get gateway -n {namespace}`
   - Test endpoint: `curl http://{gateway-address}/v1/models`
   - Send test request: `curl http://{gateway-address}/v1/chat/completions -d {...}`
   Model loading can take several minutes depending on model size


4. **Performance check:**
   - Monitor resource usage: `kubectl top pods -n {namespace}`
   - Check GPU utilization (if applicable)
   - Verify response times meet requirements

**Success Criteria:**
- All pods in Running state with N/N ready
- InferencePool shows Ready status
- Gateway shows Programmed status
- HTTPRoute shows Accepted status
- Inference endpoint responds to requests

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

# Deploy
echo "Deploying llm-d..."
cd $(dirname $0)
helmfile apply -n $NAMESPACE

# Apply routing
kubectl apply -f httproute.yaml -n $NAMESPACE

# Validate
echo "Validating deployment..."
kubectl wait --for=condition=Ready inferencepool --all -n $NAMESPACE --timeout=300s
kubectl get pods,inferencepool,gateway,httproute -n $NAMESPACE

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

### Documentation
- [llm-d Project](https://github.com/llm-d/llm-d)
- [Project Overview](https://github.com/llm-d/llm-d/blob/main/PROJECT.md)
- [Well-lit Paths](https://github.com/llm-d/llm-d/blob/main/guides/README.md)
- [Quickstart Guide](https://github.com/llm-d/llm-d/blob/main/guides/QUICKSTART.md)
- [Gateway Customization](https://github.com/llm-d/llm-d/blob/main/docs/customizing-your-gateway.md)

### External Resources
- [Gateway API Inference Extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension)
- [vLLM Documentation](https://docs.vllm.ai)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io)

### Helm Chart Repositories
- **llm-d-infra**: `https://llm-d-incubation.github.io/llm-d-infra/` - Infrastructure components
- **llm-d-modelservice**: `https://llm-d-incubation.github.io/llm-d-modelservice/` - Model server
- **inferencepool**: `oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool` - Inference scheduler