#!/bin/bash
# fix-wva-rbac.sh
# Fix RBAC permissions for WVA controller to access pods

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

TARGET_NAMESPACE="${1}"

if [ -z "$TARGET_NAMESPACE" ]; then
    echo -e "${RED}Error: Missing namespace parameter${NC}"
    echo "Usage: $0 <namespace>"
    exit 1
fi

echo -e "${BLUE}=== Fixing WVA Controller RBAC ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Check if role exists
if ! kubectl get role workload-variant-autoscaler-manager-role -n "$TARGET_NAMESPACE" &>/dev/null; then
    echo -e "${RED}Error: WVA manager role not found${NC}"
    exit 1
fi

# Check if pods permission exists
HAS_PODS=$(kubectl get role workload-variant-autoscaler-manager-role -n "$TARGET_NAMESPACE" -o jsonpath='{.rules[*].resources}' | grep -o "pods" || echo "")

if [ -n "$HAS_PODS" ]; then
    echo -e "${GREEN}✓ Role already has pods permissions${NC}"
    exit 0
fi

echo -e "${YELLOW}Adding pods permissions to WVA role...${NC}"

# Add pods permission
kubectl patch role workload-variant-autoscaler-manager-role -n "$TARGET_NAMESPACE" --type=json -p='[
  {
    "op": "add",
    "path": "/rules/-",
    "value": {
      "apiGroups": [""],
      "resources": ["pods"],
      "verbs": ["get", "list", "watch"]
    }
  }
]'

echo -e "${GREEN}✓ Pods permissions added${NC}"
echo ""
echo -e "${YELLOW}Restarting WVA controller...${NC}"
kubectl rollout restart deployment/workload-variant-autoscaler-controller-manager -n "$TARGET_NAMESPACE"

echo -e "${GREEN}✓ RBAC fixed and controller restarted${NC}"


