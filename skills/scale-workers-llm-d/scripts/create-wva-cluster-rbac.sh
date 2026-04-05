#!/bin/bash
# create-wva-cluster-rbac.sh
# Create cluster-level RBAC for WVA controller to access Prometheus
# Requires cluster-admin privileges

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

echo -e "${BLUE}=== Creating Cluster-Level RBAC for WVA ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Create ClusterRole for WVA manager
echo -e "${YELLOW}Creating ClusterRole for WVA manager...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workload-variant-autoscaler-${TARGET_NAMESPACE}-manager-role
rules:
- apiGroups: [""]
  resources: ["configmaps", "namespaces", "pods", "services", "nodes"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["llmd.ai"]
  resources: ["variantautoscalings"]
  verbs: ["*"]
EOF
echo -e "${GREEN}✓ ClusterRole created${NC}"
echo ""

# Create ClusterRole for metrics
echo -e "${YELLOW}Creating ClusterRole for metrics...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: workload-variant-autoscaler-${TARGET_NAMESPACE}-metrics-reader
rules:
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]
EOF
echo -e "${GREEN}✓ Metrics ClusterRole created${NC}"
echo ""

# Create ClusterRoleBinding
echo -e "${YELLOW}Creating ClusterRoleBinding...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: workload-variant-autoscaler-${TARGET_NAMESPACE}-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: workload-variant-autoscaler-${TARGET_NAMESPACE}-manager-role
subjects:
- kind: ServiceAccount
  name: workload-variant-autoscaler-controller-manager
  namespace: ${TARGET_NAMESPACE}
EOF
echo -e "${GREEN}✓ ClusterRoleBinding created${NC}"
echo ""

echo -e "${GREEN}=== Cluster RBAC Setup Complete ===${NC}"
echo ""
echo "The WVA controller in namespace '${TARGET_NAMESPACE}' now has cluster-level permissions."
echo "Restart the controller to apply the new permissions:"
echo "  kubectl rollout restart deployment/workload-variant-autoscaler-controller-manager -n ${TARGET_NAMESPACE}"

