#!/bin/bash
# create-variantautoscaling-manual.sh
# Manually create VariantAutoscaling when auto-detection fails

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TARGET_NAMESPACE="${1}"
AUTOSCALER_NAME="${2}"
TARGET_DEPLOYMENT="${3}"
MODEL_ID="${4}"

if [ -z "$TARGET_NAMESPACE" ] || [ -z "$AUTOSCALER_NAME" ] || [ -z "$TARGET_DEPLOYMENT" ] || [ -z "$MODEL_ID" ]; then
    echo -e "${RED}Error: Missing required parameters${NC}"
    echo "Usage: $0 <namespace> <autoscaler-name> <target-deployment> <model-id>"
    echo ""
    echo "Example:"
    echo "  $0 dolev-llmd ms-qwen35b-autoscaler ms-qwen35b-llm-d-modelservice-decode 'Qwen/Qwen2.5-32B-Instruct'"
    exit 1
fi

echo -e "${BLUE}=== Creating VariantAutoscaling (Manual) ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo -e "Name: ${GREEN}${AUTOSCALER_NAME}${NC}"
echo -e "Target: ${GREEN}${TARGET_DEPLOYMENT}${NC}"
echo -e "Model: ${GREEN}${MODEL_ID}${NC}"
echo ""

# Detect controller instance
CONTROLLER_INSTANCE=$(kubectl get deployment -n "$TARGET_NAMESPACE" \
  workload-variant-autoscaler-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTROLLER_INSTANCE")].value}' 2>/dev/null || echo "")

if [ -z "$CONTROLLER_INSTANCE" ]; then
    CONTROLLER_INSTANCE="llm-d-inference-scheduler"
    echo -e "${YELLOW}Using default controller instance: ${CONTROLLER_INSTANCE}${NC}"
else
    echo -e "${GREEN}Detected controller instance: ${CONTROLLER_INSTANCE}${NC}"
fi

# Create VariantAutoscaling
cat <<EOF | kubectl apply -f -
apiVersion: llmd.ai/v1alpha1
kind: VariantAutoscaling
metadata:
  name: ${AUTOSCALER_NAME}
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

echo ""
echo -e "${GREEN}✓ VariantAutoscaling created${NC}"
echo ""
echo -e "${BLUE}Verify:${NC}"
echo "  kubectl get variantautoscaling -n ${TARGET_NAMESPACE} ${AUTOSCALER_NAME}"

