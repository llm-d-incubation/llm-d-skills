---
name: deploy-llm-d
description: Configure and deploy an llm-d stack on an existing Kubernetes and OpenShift cluster using Well-Lit Path guides. Use this skill when users want to deploy, verify, or customize llm-d.
---

# Deploy llm-d Stack
## 📋 Command Execution Notice

**Before executing any command, I will:**
1. **Explain what the command does** - A clear description of the command's purpose and expected outcome
2. **Show the actual command** - The exact command that will be executed
3. **Explain why it's needed** - How this command fits into the overall deployment workflow

This ensures you understand each step before it happens and can verify the actions align with your intentions.


> ## 🔔 ALWAYS NOTIFY THE USER BEFORE CREATING ANYTHING
>
> **RULE**: Before creating ANY resource — including namespaces, PVCs, files, Helm releases, HTTPRoutes, or any Kubernetes object — you MUST first tell the user what you are about to create and why.
 Critical rules to follow when deploying and managing llm-d:

1. **Do NOT change cluster-level definitions** 
All changes must be made exclusively inside the designated project namespace. Never modify cluster-wide resources (e.g., ClusterRoles, ClusterRoleBindings, StorageClasses, Nodes, or any resource outside the target namespace). Scope every `kubectl apply`, `helm install`, and `helmfile apply` command to the target namespace using `-n ${NAMESPACE}`.

2. **Do NOT modify any existing code you did not create** 
 Only create new files and modify them as needed. Never edit pre-existing files in the repository (e.g., existing `values.yaml`, `helmfile.yaml`, `httproute.yaml`, `README.md`, or any other committed file). If customization is required, create a new file (e.g., `values-custom.yaml`, `httproute-custom.yaml`) and reference it instead.

## Overview

llm-d provides Well-Lit Path deployment guides in the `guides/` directory of `${LLMD_PATH}`. The guide index at `${LLMD_PATH}/guides/README.md` is the main reference for available deployment paths and supporting guides.

**To discover available Well-Lit Paths**, the agent will:
1. Read `${LLMD_PATH}/guides/README.md`
2. Extract the currently listed guides and descriptions
3. Read the selected guide's README for guide-specific requirements
4. Present the available guides to the user with their descriptions

## When to Use This Skill

Activate this skill when users need to:
- Deploy LLM inference on Kubernetes or OpenShift
- Set up production-ready model serving infrastructure
- Choose between different deployment strategies
- Configure hardware-specific deployments (NVIDIA, AMD, Intel, TPU, CPU)
- Modify existing deployments (change models, adjust features, update configurations)

## Prerequisites

Each Well-Lit Path guide contains its own prerequisites section. Common prerequisites include:

1. **LLMD_PATH environment variable** - Point to the local llm-d repository clone
2. **Client Tools** - `kubectl` or `oc`, `helm`, `kustomize`, `git`
3. **HuggingFace Token** - Secret `llm-d-hf-token` with key `HF_TOKEN` in target namespace when the selected model requires it
4. **Gateway Provider** - only when the user selects Gateway API proxy mode; see `${LLMD_PATH}/guides/prereq/gateway-provider/README.md`
5. **Infrastructure** - sufficient cluster resources for the selected guide
6. **Benchmark tooling** (optional) - use the local `llm-d-benchmark` repository README and CLI docs for benchmarking workflows

**Refer to the specific guide's README for detailed prerequisites.**

## Deployment Workflow

When a user requests llm-d deployment, follow this workflow:

### Step 0: Verify LLMD_PATH or Get Repository Location

**Check for llm-d repository:**
- Use `LLMD_PATH` if set
- If not set, detect a nearby local clone; once a valid path is known, set/export `LLMD_PATH` before continuing
- If not found, offer options:
  - user provides path to an existing clone, then set/export `LLMD_PATH`
  - clone from GitHub from https://github.com/llm-d/llm-d on `main` or a specific branch, then set/export `LLMD_PATH`
  - use a release tag if requested, then set/export `LLMD_PATH`
  
### Step 1: Discover and Select Well-lit Path Guide

1. Automatically discover available Well-lit Path guides:

2. Extract guide information:
   - guide name from `${LLMD_PATH}/guides/README.md`
   - guide directory name
   - brief description from the guide index and selected guide README

3. Present discovered guides to user:

**Default suggestion**: If the user has no strong preference, suggest `optimized-baseline` as the default starting point.

**For deployment modifications** (changing model, features, or configuration):
- Select the Well-lit Path guide closest to the user's requirements
- Copy the guide directory to `deployments/` with naming convention: `{model-short-name}-{namespace}-{DDMMYYYY}` (e.g., `qwen25-llmd-25032026`)
- Modify the copied configuration files as needed
- Use the modified copy for deployment

### Step 2: Auto-Detect Current Project/Namespace

1. check if a NAMESPACE environment variable is specified. 
2. check if an oc project exists.
3. If none of the above holds, ask the user for the NAMESPACE where it is deployed.
4. Make sure the NAMESPACE environment variable is set.

**Auto-detect release name postfix:**
- Check for existing releases in the namespace to detect if postfix is needed
- Only ask if concurrent installations are detected or if detection fails

### Step 3: Auto-Detect Configuration and Resources

**Extract requirements from the guide:**
- Parse the guide's README.md to identify required components e.g., Gateway API, Kueue, monitoring tools
- Identify hardware requirements (GPU types, memory, storage)
- Note any prerequisite configurations or dependencies
- Extract recommended values and configuration parameters

**Automatically detect existing resources and configuration:**

1. Detect Hardware/Accelerators

2. Detect Gateway Provider
   
3. Detect Storage Class
   
4. Check existing resources in namespace:
   
**Present detected configuration:**

"Detected configuration:
- Namespace: `{detected-namespace}`
- Hardware: `{detected-hardware}` ({count} nodes with {accelerator-type})
- Gateway Provider: `{detected-gateway}`
- Storage Class: `{detected-storage-class}`
- Existing resources: {list if any found}"

**Only ask user for input if:**
1. Auto-detection failed for any component
2. Detected resource doesn't exist or is invalid
3. User wants to override detected values

If user wants changes, ask specifically for the values they want to override. Otherwise, proceed with detected configuration.

### Step 4: Execute Deployment Plan

**Navigate to the guide directory:**

**Key principle**: Only provide input when changing defaults. Use auto-detected values unless user explicitly overrides.

#### Deployment Actions

Execute these actions in sequence, adapting based on the specific guide's requirements:

1. Verify namespace exists:

2. Check for existing PVC:

**If PVC is required by the guide:**
- **PVC exists and is Bound**: Use existing PVC. Inform user: "Found existing PVC `{pvc-name}` in namespace `{namespace}`. Using it for deployment."
- **No PVC exists**:
  - Read PVC configuration from guide (typically in `manifests/pvc.yaml`)
  - Use auto-detected storage class from Step 3
  - Inform user: "Creating PVC `{pvc-name}` with storage class `{storage-class}` and size `{size}`."
  - Apply PVC manifest
  - Wait for PVC to be Bound


#### 4.3 Prerequisites Verification

**Verify all prerequisites are met:**
- Client tools installed (`kubectl` or `oc`, `helm`, `kustomize`)
- HuggingFace token secret created if required by the selected model
- Gateway provider deployed if the user selected Gateway API proxy mode
- Infrastructure requirements met (nodes, accelerators)
- PVC is Bound if required by the guide

**Check each prerequisite programmatically where possible:**
```bash
# Example: Check for HuggingFace secret
kubectl get secret llm-d-hf-token -n ${NAMESPACE} 2>/dev/null || echo "Warning: HuggingFace token secret not found"

# Example: Check for Gateway API CRDs when gateway mode is selected
kubectl get crd gateways.gateway.networking.k8s.io 2>/dev/null || echo "Warning: Gateway API CRDs not installed"
```

#### 4.4 Install the Scheduler

Follow the current install flow in `${LLMD_PATH}/guides/01_installing_a_guide.md`:

- **Standalone mode** is the default and simplest path
- **Gateway API proxy mode** is used when the user needs a full gateway provider

Install the scheduler using the guide's layered Helm values and the appropriate chart for the chosen mode.

#### 4.5 Deploy the Model Server

Deploy the model server using the guide's `kustomize` overlay:

```bash
kustomize build guides/<guide>/modelserver/<accelerator>/<server>/ | kubectl apply -n ${NAMESPACE} -f -
```

#### 4.6 Deployment Validation

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
   
   **Note:** By default, the connectivity test is NOT performed. Only run this test if explicitly needed for verification purposes.
   
   <ask_followup_question>
   <question>Would you like to run the connectivity test?</question>
   <follow_up>
   <suggest>No - Skip connectivity test (recommended default)</suggest>
   <suggest>Yes - Run connectivity test</suggest>
   </follow_up>
   </ask_followup_question>
   
   If yes:
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
### 4.7 Generate Deployment Script

**CRITICAL: You MUST ALWAYS generate a deployment script after successful validation.**

After successful validation, **you MUST generate a reusable deployment script** with a date-stamped filename.

**Script Naming Convention:**
- **REQUIRED FORMAT**: `deploy-YYYYMMDD.sh` (e.g., `deploy-20260315.sh`)
- Use the current date in the format: YYYYMMDD
- Example: For March 15, 2026, the script should be named `deploy-20260315.sh`

**Script Location:**
- Save the script in the `deployments/` directory
- Full path example: `deployments/deploy-20260315.sh`

**Script Content Requirements:**
The deployment script MUST contain ALL commands that were actually executed during deployment:
- Include exact commands used (with actual values, not placeholders)
- Add prerequisite checks at the beginning
- Include all deployment steps in order
- Include validation steps at the end
- Add error handling and exit on failures
- Add comments explaining each major step
- Set executable permissions: `chmod +x deployments/deploy-YYYYMMDD.sh`

**Example Script Structure:**
```bash
#!/bin/bash
# Deployment script generated on YYYY-MM-DD
# Guide: [guide-name]
# Namespace: [namespace]

set -e  # Exit on error

# Prerequisites check
echo "Checking prerequisites..."
[prerequisite commands]

# Deployment
echo "Starting deployment..."
[actual deployment commands]

# Validation
echo "Validating deployment..."
[validation commands]

echo "Deployment complete!"
```

**REMINDER: Generating this script is NOT optional - it MUST be created every time a deployment is completed.**
#### Common Issues and Solutions

##### Long Namespace Names

**Issue**: Generated pod hostnames become too long (>64 characters)

**Solution**: Use shorter namespace names (e.g., `llm-d`) and set `RELEASE_NAME_POSTFIX` environment variable if needed

##### RDMA Connectivity Failures (Wide-EP)

**Issue**: All-to-All RDMA connectivity not working

**Solution**: Ensure every NIC can communicate with every NIC on all hosts (not just rail-only connectivity). Verify RDMA device plugin is running.

##### Pod Scheduling Failures

**Issue**: Pods not scheduling despite available resources

**Solution**: 
- Check node selectors: `$CLI_CMD get pod <pod> -n ${NAMESPACE} -o yaml | grep -A 5 nodeSelector`
- Check taints and tolerations: `$CLI_CMD describe nodes | grep -A 5 Taints`
- Verify hardware requirements match available nodes

##### Excessive Pod Creation / GPU Hardware Failures

**Issue**: Deployment creates hundreds of pods, all failing with GPU errors like "GPU is lost" or NVLink failures

**Solution**:
1. **Stop the pod creation loop immediately:**
   ```bash
   kubectl delete deployment <deployment-name> -n ${NAMESPACE}
   kubectl delete pods -n ${NAMESPACE} -l llm-d.ai/model=<model-name> --grace-period=0 --force
   ```

2. **Identify problematic nodes:**
   ```bash
   kubectl describe pod <failing-pod> -n ${NAMESPACE} | grep -A 10 "Events:"
   ```
   Look for node names in "Successfully assigned" messages and GPU errors

3. **Add node anti-affinity to avoid bad nodes:**
   Add this to your deployment patch YAML:
   ```yaml
   spec:
     template:
       spec:
         affinity:
           nodeAffinity:
             requiredDuringSchedulingIgnoredDuringExecution:
               nodeSelectorTerms:
               - matchExpressions:
                 - key: kubernetes.io/hostname
                   operator: NotIn
                   values:
                   - <problematic-node-name>
   ```

4. **Redeploy with the updated configuration**

See [troubleshooting.md](./references/troubleshooting.md) for detailed steps and additional solutions.


##### Gateway Routing Not Working

**Issue**: HTTPRoute not routing traffic to services

**Solution**:
- Verify gateway provider is correctly deployed
- Check HTTPRoute backend references match service names
- Verify services have endpoints: `$CLI_CMD get endpoints -n ${NAMESPACE}`
- Check gateway logs for routing errors

##### HuggingFace Token Issues

**Issue**: Models fail to download or authentication errors

**Solution**:
- Verify secret exists: `$CLI_CMD get secret llm-d-hf-token -n ${NAMESPACE}`
- Check secret has correct key: `$CLI_CMD get secret llm-d-hf-token -n ${NAMESPACE} -o yaml`
- Verify token is valid: Test token at https://huggingface.co/settings/tokens
- Ensure pods have access to secret (check volume mounts)

---


## Troubleshooting Guidance

For detailed troubleshooting guidance, see [troubleshooting.md](./references/troubleshooting.md).

### Additional Resources

- **Guide Index**: `${LLMD_PATH}/guides/README.md`
- **Installing a Guide**: `${LLMD_PATH}/guides/01_installing_a_guide.md`
- **Verifying a Guide**: `${LLMD_PATH}/guides/02_verifying_a_guide.md`
- **Benchmarking a Guide**: `${LLMD_PATH}/guides/03_benchmarking_a_guide.md`
- **llm-d-benchmark CLI**: use the local `llm-d-benchmark` repository README when benchmark automation is needed

## Security Considerations

- Run deployments in isolated namespaces
- Never modify cluster-wide resources
- Use RBAC for access control
- Secure HuggingFace tokens as Kubernetes secrets
- Enable network policies for pod-to-pod communication
- Use TLS for gateway ingress
- Audit all deployments and changes