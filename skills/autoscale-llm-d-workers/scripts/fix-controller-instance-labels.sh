#!/bin/bash
# fix-controller-instance-labels.sh
# Fix missing controller-instance labels on VariantAutoscaling resources

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get target namespace from environment or argument
TARGET_NAMESPACE="${NAMESPACE:-${1}}"

if [ -z "$TARGET_NAMESPACE" ]; then
    echo -e "${RED}Error: No namespace specified${NC}"
    echo "Usage: NAMESPACE=<target-namespace> $0"
    echo "   or: $0 <target-namespace>"
    exit 1
fi

echo -e "${BLUE}=== Fixing Controller Instance Labels ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Get controller instance from deployment
echo -e "${YELLOW}Step 1: Detecting controller instance...${NC}"
CONTROLLER_INSTANCE=$(kubectl get deployment -n "$TARGET_NAMESPACE" \
  workload-variant-autoscaler-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CONTROLLER_INSTANCE")].value}' 2>/dev/null || echo "")

if [ -z "$CONTROLLER_INSTANCE" ]; then
    echo -e "${RED}Error: WVA controller not found or CONTROLLER_INSTANCE not set${NC}"
    echo "Deploy the controller first with: bash skills/llmd-scale-workers/scripts/deploy-wva-controller.sh ${TARGET_NAMESPACE}"
    exit 1
fi

echo -e "${GREEN}Controller instance: ${CONTROLLER_INSTANCE}${NC}"
echo ""

# Find all VariantAutoscaling resources
echo -e "${YELLOW}Step 2: Finding VariantAutoscaling resources...${NC}"
VAS=$(kubectl get variantautoscaling -n "$TARGET_NAMESPACE" -o name 2>/dev/null || echo "")

if [ -z "$VAS" ]; then
    echo -e "${YELLOW}No VariantAutoscaling resources found in namespace${NC}"
    exit 0
fi

echo "Found VariantAutoscaling resources:"
echo "$VAS"
echo ""

# Add/update labels on each resource
echo -e "${YELLOW}Step 3: Adding controller-instance labels...${NC}"
for va in $VAS; do
    VA_NAME=$(echo "$va" | cut -d'/' -f2)
    
    # Check current label
    CURRENT_LABEL=$(kubectl get "$va" -n "$TARGET_NAMESPACE" \
      -o jsonpath='{.metadata.labels.wva\.llmd\.ai/controller-instance}' 2>/dev/null || echo "")
    
    if [ "$CURRENT_LABEL" = "$CONTROLLER_INSTANCE" ]; then
        echo -e "  ${GREEN}✓ ${VA_NAME} already has correct label${NC}"
    else
        echo -e "  ${YELLOW}Updating ${VA_NAME}...${NC}"
        kubectl label "$va" -n "$TARGET_NAMESPACE" \
          wva.llmd.ai/controller-instance="${CONTROLLER_INSTANCE}" --overwrite
        echo -e "  ${GREEN}✓ ${VA_NAME} updated${NC}"
    fi
done

echo ""
echo -e "${GREEN}=== Labels Updated Successfully ===${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Verify controller picks up the resources:"
echo "   kubectl logs -n ${TARGET_NAMESPACE} deployment/workload-variant-autoscaler-controller-manager -f"
echo ""
echo "2. Check VariantAutoscaling status:"
echo "   kubectl get variantautoscaling -n ${TARGET_NAMESPACE}"
echo ""
echo "3. If controller still doesn't pick up resources, restart it:"
echo "   kubectl rollout restart deployment/workload-variant-autoscaler-controller-manager -n ${TARGET_NAMESPACE}"

