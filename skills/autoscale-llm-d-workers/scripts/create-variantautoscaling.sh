#!/bin/bash
# create-variantautoscaling.sh
# Create VariantAutoscaling resource for WVA controller

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get parameters
TARGET_NAMESPACE="${NAMESPACE:-${1}}"
DEPLOYMENT_NAME="${2}"
TARGET_DEPLOYMENT="${3}"

if [ -z "$TARGET_NAMESPACE" ] || [ -z "$DEPLOYMENT_NAME" ] || [ -z "$TARGET_DEPLOYMENT" ]; then
    echo -e "${RED}Error: Missing required parameters${NC}"
    echo "Usage: NAMESPACE=<namespace> $0 <deployment-name> <target-deployment>"
    echo "   or: $0 <namespace> <deployment-name> <target-deployment>"
    echo ""
    echo "Example:"
    echo "  $0 my-namespace my-autoscaler ms-my-deployment-llm-d-modelservice-decode"
    exit 1
fi

echo -e "${BLUE}=== Creating VariantAutoscaling Resource ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Detect controller instance from WVA controller deployment
echo -e "${YELLOW}Detecting controller instance...${NC}"
CONTROLLER_INSTANCE=$(kubectl get deployment -n "$TARGET_NAMESPACE" \
  workload-variant-autoscaler-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTROLLER_INSTANCE")].value}' 2>/dev/null || echo "")

if [ -z "$CONTROLLER_INSTANCE" ]; then
    # Fallback: use namespace as controller instance
    CONTROLLER_INSTANCE="$TARGET_NAMESPACE"
    echo -e "${YELLOW}No CONTROLLER_INSTANCE env found, using namespace: ${CONTROLLER_INSTANCE}${NC}"
else
    echo -e "${GREEN}Detected controller instance: ${CONTROLLER_INSTANCE}${NC}"
fi
echo ""

# Find a decode deployment to query model ID
echo -e "${YELLOW}Detecting model ID from vLLM...${NC}"
DECODE_DEPLOYMENT=$(kubectl get deployments -n "$TARGET_NAMESPACE" -l component=decode -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$DECODE_DEPLOYMENT" ]; then
    echo -e "${RED}Error: No decode deployment found in namespace${NC}"
    echo "Please specify the model ID manually or ensure a decode deployment exists"
    exit 1
fi

# Get model ID from vLLM
MODEL_ID=$(kubectl exec -n "$TARGET_NAMESPACE" deployment/"$DECODE_DEPLOYMENT" -- \
  curl -s localhost:8000/v1/models 2>/dev/null | jq -r '.data[0].id' 2>/dev/null || echo "")

if [ -z "$MODEL_ID" ] || [ "$MODEL_ID" = "null" ]; then
    echo -e "${RED}Error: Could not detect model ID from vLLM${NC}"
    echo "Please ensure the decode deployment is running and accessible"
    exit 1
fi

echo -e "${GREEN}Detected model ID: ${MODEL_ID}${NC}"
echo ""

# Create VariantAutoscaling resource
echo -e "${YELLOW}Creating VariantAutoscaling resource with controller-instance label...${NC}"
echo -e "${BLUE}Note: v0.5.1 requires scaleTargetRef field (breaking change from v0.4.1)${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: llmd.ai/v1alpha1
kind: VariantAutoscaling
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${TARGET_NAMESPACE}
  labels:
    wva.llmd.ai/controller-instance: ${CONTROLLER_INSTANCE}
spec:
  modelID: ${MODEL_ID}
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${TARGET_DEPLOYMENT}
  variantCost: "10.0"
EOF

echo -e "${GREEN}✓ VariantAutoscaling resource created${NC}"
echo ""

# Verify the resource
echo -e "${YELLOW}Verifying VariantAutoscaling...${NC}"
sleep 3
kubectl get variantautoscaling -n "$TARGET_NAMESPACE" "$DEPLOYMENT_NAME"

echo ""
echo -e "${BLUE}=== Next Steps ===${NC}"
echo "Monitor the VariantAutoscaling status:"
echo "  kubectl get variantautoscaling -n ${TARGET_NAMESPACE} ${DEPLOYMENT_NAME} -w"
echo ""
echo "Check controller logs:"
echo "  kubectl logs -n ${TARGET_NAMESPACE} deployment/workload-variant-autoscaler-controller-manager -f"
