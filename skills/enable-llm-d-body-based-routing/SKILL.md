---
name: enable-llm-d-body-based-routing
description: Enable Body-Based Routing (BBR) on an existing llm-d deployment for multi-model serving. Configures BBR component and adds a second model with LoRAs. Assumes llm-d stack is already deployed.
---

# Enable Body-Based Routing (BBR) on Existing llm-d Deployment

## Overview

This skill enables **Body-Based Routing (BBR)** on an existing llm-d deployment to support multi-model serving. It assumes you already have a working llm-d stack deployed and adds:
- Body-Based Router component
- Configuration for existing model to work with BBR
- A second model (DeepSeek-r1) with LoRA adapters

**Prerequisites:** An existing llm-d deployment with at least one model already running.

**Based on:** `guides/multi-model-serving` Well-lit Path guide

## When to Use This Skill

Use this skill when you:
- Have an existing llm-d deployment with one model
- Want to add multi-model serving capability
- Need to route requests based on model names in request payloads
- Want to add LoRA adapter support

## What This Skill Does

1. Detects your existing llm-d deployment and gateway
2. Auto-detects Gateway API Inference Extension version from Helm metadata
3. Deploys Body-Based Router (BBR) component using detected version
4. Upgrades existing InferencePool to enable BBR routing
5. Adds a second model (DeepSeek-r1) with 2 LoRAs
6. Configures intelligent request routing based on model names

## Prerequisites

- Existing llm-d deployment in a namespace
- Gateway deployed and programmed
- At least one InferencePool and model server running
- kubectl/oc access to the cluster
- helm and helmfile installed

## Step-by-Step Workflow

### Step 1: Identify Namespace and Verify Existing Deployment

**Auto-detect or set the namespace:**

1. check if a NAMESPACE environment variable is specified. 
2. check if an oc project exists.
3. If none of the above holds, ask the user for the NAMESPACE where it is deployed.
4. Make sure the NAMESPACE environment variable is set.

**Identify existing llm-d stack deployment components in the namespace:**
Verify that the stack is indeed deployed in the detected or provided namespace using kubectl commands. If you cannot locate the stack, ask the user to deploy one and refer to the llm-d-deployment skill.

```bash
# Identify your gateway name
export GATEWAY_NAME=$(kubectl get gateway -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
echo ""
echo "✓ Detected gateway: $GATEWAY_NAME"

# Identify your InferencePool
export EXISTING_INFERENCEPOOL=$(kubectl get inferencepool -n $NAMESPACE -o jsonpath='{.items[0].metadata.name}')
echo "✓ Detected InferencePool: $EXISTING_INFERENCEPOOL"

# Detect gateway provider from gateway name
if [[ $GATEWAY_NAME == *"istio"* ]]; then
    export GATEWAY_PROVIDER=istio
elif [[ $GATEWAY_NAME == *"kgateway"* ]] || [[ $GATEWAY_NAME == *"agentgateway"* ]]; then
    export GATEWAY_PROVIDER=kgateway
elif [[ $GATEWAY_NAME == *"gke"* ]]; then
    export GATEWAY_PROVIDER=gke
else
    echo "⚠️  Could not detect gateway provider from gateway name."
    echo "Please set manually:"
    echo "export GATEWAY_PROVIDER=istio  # or kgateway, gke, agentgateway"
    exit 1
fi
echo "✓ Gateway provider: $GATEWAY_PROVIDER"
```

### Step 2: Navigate to Multi-Model Serving Guide directory

### Step 3: Auto-Detect Gateway API Inference Extension Version

**Detect the IGW version from existing Helm deployment:**

The existing llm-d deployment uses a specific version of the Gateway API Inference Extension. We detect this from Helm metadata to ensure compatibility.

```bash
# Detect version from Helm release metadata
export IGW_CHART_VERSION=$(helm get metadata $EXISTING_INFERENCEPOOL -n $NAMESPACE -o json 2>/dev/null | \
  jq -r '.version // empty')

echo "Detected IGW version from Helm metadata: $IGW_CHART_VERSION"
```
If gateway component is installed, but Gateway API Inference Extension version could not be detected, ask the user which version to use (suggest to fallback to latest stable version)

### Step 4: Deploy Body-Based Router (BBR)

**Deploy BBR Helm chart using detected version:**
```bash
helm install body-based-router \
  --set provider.name=$GATEWAY_PROVIDER \
  --set inferenceGateway.name=$GATEWAY_NAME \
  --set bbr.plugins=null \
  --version $IGW_CHART_VERSION \
  -n $NAMESPACE \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/body-based-routing
```

**Note:** K-Gateway users don't need this chart as BBR is built-in.

**Verify BBR deployment:**
Verify body based router deployment is up and running

### Step 5: Configure Existing Model for BBR

**Identify the base model name from your existing deployment:**
Detect the model name in the existing inferencepool spec.selector.matchlabel. For example, if the spec.selector.matchlabel is llm-d.ai/model-name=Qwen/Qwen3-32B, then the model name is "Qwen/Qwen3-32B".
```bash
export EXISTING_BASE_MODEL=`{detected-model-name}`
```

**Create ConfigMap for the existing model:**
```bash
# Apply the ConfigMap for Qwen3-32B
kubectl apply -f vllm-qwen3-32b-adapters-allowlist -n $NAMESPACE
```

**Upgrade existing InferencePool to enable experimental HTTPRoute:**
```bash
helm upgrade $EXISTING_INFERENCEPOOL \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool \
  --version $IGW_CHART_VERSION \
  --reuse-values \
  --set experimentalHttpRoute.enabled=true \
  --set experimentalHttpRoute.baseModel=$EXISTING_BASE_MODEL \
  --set experimentalHttpRoute.inferenceGatewayName=$GATEWAY_NAME \
  -n $NAMESPACE
```

**Verify the upgrade:**
```bash
# Check InferencePool status
kubectl get inferencepool $EXISTING_INFERENCEPOOL -n $NAMESPACE -o yaml | grep -A 10 conditions

# Check HTTPRoute was created
kubectl get httproute $EXISTING_INFERENCEPOOL -n $NAMESPACE

# Verify HTTPRoute references correct gateway
kubectl get httproute $EXISTING_INFERENCEPOOL -n $NAMESPACE -o yaml | grep -A 5 parentRefs
```

### Step 6: Deploy Second Model (DeepSeek-r1 with LoRAs)

**Deploy the second model server and its ConfigMap:**
```bash
# This creates:
# - Deployment: vllm-deepseek-r1 (model server)
# - ConfigMap: deepseek-adapters-allowlist (with ski-resorts and movie-critique LoRAs)
kubectl apply -f mdeepseek.yaml -n $NAMESPACE
```

**Wait for model server pod to be ready:**
```bash
kubectl wait --for=condition=ready pod -l app=vllm-deepseek-r1 -n $NAMESPACE --timeout=300s
```

**Create InferencePool and HTTPRoute for the second model:**
```bash
helm install vllm-deepseek-r1 \
  oci://us-central1-docker.pkg.dev/k8s-staging-images/gateway-api-inference-extension/charts/inferencepool \
  --version $IGW_CHART_VERSION \
  --dependency-update \
  --set inferencePool.modelServers.matchLabels.app=vllm-deepseek-r1 \
  --set provider.name=$GATEWAY_PROVIDER \
  --set experimentalHttpRoute.enabled=true \
  --set experimentalHttpRoute.baseModel=deepseek/DeepSeek-r1 \
  --set experimentalHttpRoute.inferenceGatewayName=$GATEWAY_NAME \
  -n $NAMESPACE
```

**Verify second model deployment:**
```bash
# Check InferencePool
kubectl get inferencepool vllm-deepseek-r1 -n $NAMESPACE

# Check HTTPRoute
kubectl get httproute vllm-deepseek-r1 -n $NAMESPACE

# Check all pods
kubectl get pods -n $NAMESPACE
```

### Step 7: Validate BBR Configuration

**Check all resources:**
```bash
echo "=== Helm Releases ==="
helm list -n $NAMESPACE

echo ""
echo "=== InferencePools ==="
kubectl get inferencepools -n $NAMESPACE

echo ""
echo "=== HTTPRoutes ==="
kubectl get httproutes -n $NAMESPACE

echo ""
echo "=== ConfigMaps (BBR-managed) ==="
kubectl get configmaps -l inference.networking.k8s.io/bbr-managed=true -n $NAMESPACE

echo ""
echo "=== Pods ==="
kubectl get pods -n $NAMESPACE
```

**Expected state:**
- 2 InferencePools (existing + vllm-deepseek-r1)
- 2 HTTPRoutes (existing + vllm-deepseek-r1)
- 2 ConfigMaps with BBR label
- BBR pod running
- All model server pods running

### Step 8: Test Multi-Model Routing

**Get gateway address or create port-forward:**
```bash
# Get gateway service
GATEWAY_SERVICE=$(kubectl get svc -n $NAMESPACE -l gateway.networking.k8s.io/gateway-name=$GATEWAY_NAME -o jsonpath='{.items[0].metadata.name}')

# Create port-forward
kubectl port-forward -n $NAMESPACE svc/$GATEWAY_SERVICE 8080:80 &
```

**Test routing to first model (Qwen3-32B):**
```bash
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "prompt": "Hello, how are you?",
    "max_tokens": 50
  }'
```

**Test routing to second model (DeepSeek-r1 base):**
```bash
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek/DeepSeek-r1",
    "prompt": "What is the best ski resort?",
    "max_tokens": 50
  }'
```

**Test routing to DeepSeek-r1 LoRA (ski-resorts):**
```bash
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ski-resorts",
    "prompt": "Tell me about ski deals in Austria",
    "max_tokens": 50
  }'
```

**Test routing to DeepSeek-r1 LoRA (movie-critique):**
```bash
curl -X POST http://localhost:8080/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "movie-critique",
    "prompt": "What are the best movies of 2025?",
    "max_tokens": 100
  }'
```

**Verify routing in BBR logs:**
```bash
kubectl logs -l app.kubernetes.io/name=body-based-router -n $NAMESPACE --tail=50 | grep "X-Gateway-Base-Model-Name"
```

## Troubleshooting

### BBR Not Routing Correctly

**Check BBR pod status:**
```bash
kubectl get pods -l app.kubernetes.io/name=body-based-router -n $NAMESPACE
kubectl logs -l app.kubernetes.io/name=body-based-router -n $NAMESPACE
```

**Verify ConfigMaps have correct labels:**
```bash
kubectl get configmaps -l inference.networking.k8s.io/bbr-managed=true -n $NAMESPACE -o yaml
```

### HTTPRoute Not Matching Requests

**Check HTTPRoute status:**
```bash
kubectl describe httproute $EXISTING_INFERENCEPOOL -n $NAMESPACE
kubectl describe httproute vllm-deepseek-r1 -n $NAMESPACE
```

**Verify HTTPRoute references correct gateway:**
```bash
kubectl get httproute -n $NAMESPACE -o yaml | grep -A 5 parentRefs
```

**Check if gateway name matches:**
```bash
echo "Gateway name: $GATEWAY_NAME"
kubectl get httproute -n $NAMESPACE -o yaml | grep "name: $GATEWAY_NAME"
```

### LoRA Routing Failures

**Verify LoRA names in ConfigMap:**
```bash
kubectl get configmap deepseek-adapters-allowlist -n $NAMESPACE -o yaml
```

**Check BBR extracted correct base model:**
```bash
kubectl logs -l app.kubernetes.io/name=body-based-router -n $NAMESPACE | grep -i "ski-resorts\|movie-critique"
```

### Model Server Not Discovered

**Check pod labels match InferencePool selector:**
```bash
kubectl get pods -n $NAMESPACE --show-labels
kubectl get inferencepool vllm-deepseek-r1 -n $NAMESPACE -o yaml | grep -A 5 matchLabels
```


## Key Points

1. **Assumes Existing Deployment**: This skill works with an already-deployed llm-d stack
2. **Dynamic Gateway Detection**: Automatically detects and uses the correct gateway name
3. **Non-Destructive**: Upgrades existing InferencePool without disrupting service
4. **Two Models**: Configures existing model + adds DeepSeek-r1 with 2 LoRAs
5. **Intelligent Routing**: Routes based on model name in request body

## Configuration Summary

After completion, you will have:
- **Models**: 2 base models (Qwen3-32B, DeepSeek-r1)
- **LoRAs**: 2 LoRAs on DeepSeek-r1 (ski-resorts, movie-critique)
- **Routing**: Body-based routing via BBR component
- **Endpoint**: Single unified gateway endpoint for all models

## References

- **Guide**: `guides/multi-model-serving/README.md`
- **BBR Chart**: https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/config/charts/body-based-routing
- **Gateway API Inference Extension**: https://github.com/kubernetes-sigs/gateway-api-inference-extension