#!/bin/bash
# deploy-wva-helm.sh
# Deploy WVA controller using Helm with auto-detection of cluster resources
# This script is cluster-agnostic and detects Prometheus automatically

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get target namespace from environment or argument
TARGET_NAMESPACE="${NAMESPACE:-${1}}"
MODEL_ID="${MODEL_ID:-}"
LLMD_DEPLOYMENT_NAME="${LLMD_DEPLOYMENT_NAME:-}"

if [ -z "$TARGET_NAMESPACE" ]; then
    echo -e "${RED}Error: No namespace specified${NC}"
    echo "Usage: NAMESPACE=<target-namespace> [MODEL_ID=<model-id>] [LLMD_DEPLOYMENT_NAME=<deployment-name>] $0"
    echo "   or: $0 <target-namespace>"
    echo ""
    echo "Optional environment variables:"
    echo "  MODEL_ID: Model identifier (e.g., 'Qwen/Qwen3-32B')"
    echo "  LLMD_DEPLOYMENT_NAME: Name of the llm-d modelservice deployment"
    echo "  PROMETHEUS_URL: Override Prometheus URL (auto-detected if not set)"
    echo "  PROMETHEUS_NAMESPACE: Override Prometheus namespace (auto-detected if not set)"
    exit 1
fi

echo -e "${BLUE}=== WVA Controller Deployment (Helm) ===${NC}"
echo -e "Target namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Step 1: Auto-detect Prometheus
echo -e "${YELLOW}Step 1: Detecting Prometheus service...${NC}"

if [ -n "$PROMETHEUS_URL" ]; then
    echo -e "  Using provided Prometheus URL: ${GREEN}${PROMETHEUS_URL}${NC}"
    PROM_URL="$PROMETHEUS_URL"
    PROM_NAMESPACE="${PROMETHEUS_NAMESPACE:-unknown}"
else
    # Try to find Prometheus service
    echo "  Searching for Prometheus services..."
    
    # Common Prometheus service patterns
    PROM_SERVICES=$(kubectl get svc -A -o json | jq -r '.items[] | select(.metadata.name | test("prometheus")) | "\(.metadata.namespace)/\(.metadata.name):\(.spec.ports[0].port)"' 2>/dev/null || echo "")
    
    if [ -z "$PROM_SERVICES" ]; then
        echo -e "${RED}✗ No Prometheus service found${NC}"
        echo ""
        echo "Please set PROMETHEUS_URL environment variable:"
        echo "  export PROMETHEUS_URL='http://prometheus.monitoring.svc.cluster.local:9090'"
        echo "  or"
        echo "  export PROMETHEUS_URL='https://prometheus.monitoring.svc.cluster.local:9090'"
        exit 1
    fi
    
    echo -e "${GREEN}  Found Prometheus services:${NC}"
    echo "$PROM_SERVICES" | nl
    echo ""
    
    # Use the first one found
    FIRST_PROM=$(echo "$PROM_SERVICES" | head -1)
    PROM_NAMESPACE=$(echo "$FIRST_PROM" | cut -d'/' -f1)
    PROM_SERVICE=$(echo "$FIRST_PROM" | cut -d'/' -f2 | cut -d':' -f1)
    PROM_PORT=$(echo "$FIRST_PROM" | cut -d':' -f2)
    
    # Check if service supports HTTPS (WVA v0.5.1 requirement)
    # For now, try HTTP first, then HTTPS
    PROM_URL="http://${PROM_SERVICE}.${PROM_NAMESPACE}.svc.cluster.local:${PROM_PORT}"
    
    echo -e "  Selected: ${GREEN}${PROM_URL}${NC}"
    echo -e "  ${YELLOW}Note: WVA v0.5.1 requires HTTPS. If this fails, configure Prometheus with TLS.${NC}"
fi

echo -e "${GREEN}✓ Prometheus detected${NC}"
echo ""

# Step 2: Auto-detect llm-d deployment
echo -e "${YELLOW}Step 2: Detecting llm-d deployment...${NC}"

if [ -z "$LLMD_DEPLOYMENT_NAME" ]; then
    # Try to find llm-d modelservice deployment
    LLMD_DEPLOYMENTS=$(kubectl get deployment -n "$TARGET_NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name | test("modelservice")) | .metadata.name' 2>/dev/null || echo "")
    
    if [ -z "$LLMD_DEPLOYMENTS" ]; then
        echo -e "${YELLOW}⚠ No llm-d modelservice deployment found in namespace${NC}"
        echo "  Will use default naming convention"
        LLMD_DEPLOYMENT_NAME="ms-inference-scheduling-llm-d-modelservice"
    else
        LLMD_DEPLOYMENT_NAME=$(echo "$LLMD_DEPLOYMENTS" | head -1)
        echo -e "  Detected: ${GREEN}${LLMD_DEPLOYMENT_NAME}${NC}"
    fi
else
    echo -e "  Using provided: ${GREEN}${LLMD_DEPLOYMENT_NAME}${NC}"
fi

echo -e "${GREEN}✓ Deployment name set${NC}"
echo ""

# Step 3: Auto-detect model ID
echo -e "${YELLOW}Step 3: Detecting model ID...${NC}"

if [ -z "$MODEL_ID" ]; then
    # Try to get model ID from running pods
    MODEL_POD=$(kubectl get pods -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=llm-d-modelservice -o name 2>/dev/null | head -1 || echo "")
    
    if [ -n "$MODEL_POD" ]; then
        echo "  Querying model from pod..."
        MODEL_ID=$(kubectl exec -n "$TARGET_NAMESPACE" "$MODEL_POD" -- curl -s localhost:8000/v1/models 2>/dev/null | jq -r '.data[0].id' 2>/dev/null || echo "")
    fi
    
    if [ -z "$MODEL_ID" ]; then
        echo -e "${YELLOW}⚠ Could not auto-detect model ID${NC}"
        echo "  Using default: Qwen/Qwen3-32B"
        MODEL_ID="Qwen/Qwen3-32B"
    else
        echo -e "  Detected: ${GREEN}${MODEL_ID}${NC}"
    fi
else
    echo -e "  Using provided: ${GREEN}${MODEL_ID}${NC}"
fi

echo -e "${GREEN}✓ Model ID set${NC}"
echo ""

# Step 4: Install WVA using Helm
echo -e "${YELLOW}Step 4: Installing WVA via Helm...${NC}"

# Check if already installed
if helm list -n "$TARGET_NAMESPACE" | grep -q "workload-variant-autoscaler"; then
    echo "  WVA already installed, upgrading..."
    HELM_CMD="upgrade"
else
    echo "  Installing WVA..."
    HELM_CMD="install"
fi

# Determine if we should use HTTP or HTTPS
if [[ "$PROM_URL" == https://* ]]; then
    TLS_SKIP_VERIFY="true"
    CA_CERT_PATH=""
else
    # HTTP - but WVA v0.5.1 requires HTTPS
    echo -e "${YELLOW}  Warning: Prometheus URL is HTTP but WVA v0.5.1 requires HTTPS${NC}"
    echo -e "${YELLOW}  This installation may fail. Consider setting up Prometheus with TLS.${NC}"
    TLS_SKIP_VERIFY="true"
    CA_CERT_PATH=""
fi

helm $HELM_CMD workload-variant-autoscaler oci://ghcr.io/llm-d/workload-variant-autoscaler \
  --version 0.5.1 \
  --namespace "$TARGET_NAMESPACE" \
  --skip-crds \
  --set wva.prometheus.baseURL="$PROM_URL" \
  --set wva.prometheus.tls.insecureSkipVerify="$TLS_SKIP_VERIFY" \
  --set wva.prometheus.tls.caCertPath="$CA_CERT_PATH" \
  --set wva.prometheus.monitoringNamespace="$PROM_NAMESPACE" \
  --set llmd.namespace="$TARGET_NAMESPACE" \
  --set llmd.modelName="$LLMD_DEPLOYMENT_NAME" \
  --set llmd.modelID="$MODEL_ID" \
  --set va.enabled=true \
  --set hpa.enabled=false

echo -e "${GREEN}✓ Helm installation complete${NC}"
echo ""

# Step 5: Wait for controller to be ready
echo -e "${YELLOW}Step 5: Waiting for controller pods...${NC}"
echo "  This may take up to 2 minutes..."

if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=workload-variant-autoscaler -n "$TARGET_NAMESPACE" --timeout=120s 2>/dev/null; then
    echo -e "${GREEN}✓ Controller pods are ready${NC}"
else
    echo -e "${YELLOW}⚠ Controller pods not ready yet${NC}"
    echo "  Checking pod status..."
    kubectl get pods -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=workload-variant-autoscaler
    echo ""
    echo "  Checking logs for errors..."
    kubectl logs -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=workload-variant-autoscaler --tail=20 2>/dev/null || echo "  (No logs available yet)"
fi

echo ""
echo -e "${BLUE}=== Deployment Summary ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo -e "Prometheus: ${GREEN}${PROM_URL}${NC}"
echo -e "Model Service: ${GREEN}${LLMD_DEPLOYMENT_NAME}${NC}"
echo -e "Model ID: ${GREEN}${MODEL_ID}${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Verify controller is running:"
echo "   kubectl get pods -n ${TARGET_NAMESPACE} -l app.kubernetes.io/name=workload-variant-autoscaler"
echo ""
echo "2. Check controller logs:"
echo "   kubectl logs -n ${TARGET_NAMESPACE} -l app.kubernetes.io/name=workload-variant-autoscaler"
echo ""
echo "3. Create VariantAutoscaling resource:"
echo "   bash .claude/skills/autoscale-llm-d-workers/scripts/create-variantautoscaling.sh ${TARGET_NAMESPACE} <name> <deployment>"
echo ""
echo -e "${YELLOW}Troubleshooting:${NC}"
echo "If controller fails with Prometheus errors, see:"
echo "  .claude/skills/autoscale-llm-d-workers/Troubleshooting.md"

# Made with Bob
