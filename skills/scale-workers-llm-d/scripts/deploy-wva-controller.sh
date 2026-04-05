#!/bin/bash
# deploy-wva-controller.sh
# Deploy WVA controller to a namespace with embedded default ConfigMaps
# No longer requires copying from existing deployments

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

echo -e "${BLUE}=== WVA Controller Deployment ===${NC}"
echo -e "Target namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo ""

# Create namespace if it doesn't exist
echo -e "${YELLOW}Step 1: Creating namespace...${NC}"
kubectl create namespace "$TARGET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo -e "${GREEN}✓ Namespace ready${NC}"
echo ""

# Create default ConfigMaps
echo -e "${YELLOW}Step 2: Creating default ConfigMaps...${NC}"

# ConfigMap 1: Main WVA Configuration
echo "  Creating workload-variant-autoscaler-variantautoscaling-config..."
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: workload-variant-autoscaler-variantautoscaling-config
  namespace: ${TARGET_NAMESPACE}
data:
  config.yaml: |
    # Prometheus Configuration (REQUIRED)
    PROMETHEUS_BASE_URL: "https://llmd-kube-prometheus-stack-prometheus.llm-d-monitoring.svc.cluster.local:9090"
    PROMETHEUS_CA_CERT_PATH: "/etc/ssl/certs/prometheus-ca.crt"
    PROMETHEUS_TLS_INSECURE_SKIP_VERIFY: "true"

    # Optimization
    GLOBAL_OPT_INTERVAL: "60s"

    # Feature Flags
    WVA_SCALE_TO_ZERO: "false"

    # Prometheus Metrics Cache
    PROMETHEUS_METRICS_CACHE_TTL: "30s"
    PROMETHEUS_METRICS_CACHE_CLEANUP_INTERVAL: "1m"
    PROMETHEUS_METRICS_CACHE_FETCH_INTERVAL: "30s"
    PROMETHEUS_METRICS_CACHE_FRESH_THRESHOLD: "1m"
    PROMETHEUS_METRICS_CACHE_STALE_THRESHOLD: "2m"
    PROMETHEUS_METRICS_CACHE_UNAVAILABLE_THRESHOLD: "5m"
EOF
sed -i.bak "s/\${TARGET_NAMESPACE}/$TARGET_NAMESPACE/g" /dev/stdin <<< "$(kubectl get configmap workload-variant-autoscaler-variantautoscaling-config -n "$TARGET_NAMESPACE" -o yaml)" | kubectl apply -f - 2>/dev/null || true
echo -e "  ${GREEN}✓ Main config created${NC}"

# ConfigMap 2: Saturation Scaling Configuration
echo "  Creating workload-variant-autoscaler-wva-saturation-scaling-config..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: workload-variant-autoscaler-wva-saturation-scaling-config
  namespace: ${TARGET_NAMESPACE}
data:
  default: |
    kvCacheThreshold: 0.80
    queueLengthThreshold: 5
    kvSpareTrigger: 0.1
    queueSpareTrigger: 3
    enableLimiter: false
EOF
echo -e "  ${GREEN}✓ Saturation scaling config created${NC}"

# ConfigMap 3: Service Classes Configuration
echo "  Creating workload-variant-autoscaler-service-classes-config..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: workload-variant-autoscaler-service-classes-config
  namespace: ${TARGET_NAMESPACE}
data:
  premium.yaml: |
    name: Premium
    priority: 1
    data:
      - model: default/default
        slo-tpot: 24
        slo-ttft: 500
      - model: meta/llama0-70b
        slo-tpot: 80
        slo-ttft: 500
  freemium.yaml: |
    name: Freemium
    priority: 10
    data:
      - model: ibm/granite-13b
        slo-tpot: 200
        slo-ttft: 2000
      - model: meta/llama0-7b
        slo-tpot: 150
        slo-ttft: 1500
EOF
echo -e "  ${GREEN}✓ Service classes config created${NC}"

echo -e "${YELLOW}Note: Prometheus CA ConfigMap (optional) not created - using insecureSkipVerify${NC}"
echo ""

# Create ServiceAccount
echo -e "${YELLOW}Step 3: Creating ServiceAccount...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workload-variant-autoscaler-controller-manager
  namespace: ${TARGET_NAMESPACE}
EOF
echo -e "${GREEN}✓ ServiceAccount created${NC}"
echo ""

# Create Role (namespace-scoped)
echo -e "${YELLOW}Step 4: Creating Role...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: workload-variant-autoscaler-manager-role
  namespace: ${TARGET_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["configmaps", "pods", "services"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["apps"]
  resources: ["deployments", "deployments/scale"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: ["llmd.ai"]
  resources: ["variantautoscalings", "variantautoscalings/status"]
  verbs: ["*"]
- apiGroups: ["inference.networking.k8s.io"]
  resources: ["inferencepools"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["inference.networking.x-k8s.io"]
  resources: ["inferencepools"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["monitoring.coreos.com"]
  resources: ["servicemonitors"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
EOF
echo -e "${GREEN}✓ Role created${NC}"
echo ""

# Create RoleBinding
echo -e "${YELLOW}Step 5: Creating RoleBinding...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: workload-variant-autoscaler-manager-rolebinding
  namespace: ${TARGET_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: workload-variant-autoscaler-manager-role
subjects:
- kind: ServiceAccount
  name: workload-variant-autoscaler-controller-manager
  namespace: ${TARGET_NAMESPACE}
EOF
echo -e "${GREEN}✓ RoleBinding created${NC}"
echo ""

# Create Deployment
echo -e "${YELLOW}Step 6: Creating Deployment...${NC}"
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: workload-variant-autoscaler-controller-manager
  namespace: ${TARGET_NAMESPACE}
  labels:
    app.kubernetes.io/name: workload-variant-autoscaler
    app.kubernetes.io/component: controller
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: workload-variant-autoscaler
      app.kubernetes.io/component: controller
  template:
    metadata:
      labels:
        app.kubernetes.io/name: workload-variant-autoscaler
        app.kubernetes.io/component: controller
    spec:
      serviceAccountName: workload-variant-autoscaler-controller-manager
      containers:
      - name: manager
        image: quay.io/llm-d-incubation/workload-variant-autoscaler:v0.5.1
        command:
        - /manager
        args:
        - --leader-elect=false
        - --namespace=${TARGET_NAMESPACE}
        env:
        - name: WATCH_NAMESPACE
          value: ${TARGET_NAMESPACE}
        - name: CONTROLLER_INSTANCE
          value: ${TARGET_NAMESPACE}
        volumeMounts:
        - name: config
          mountPath: /etc/wva
        - name: saturation-config
          mountPath: /etc/wva/saturation
        - name: service-classes-config
          mountPath: /etc/wva/service-classes
        - name: prometheus-ca
          mountPath: /etc/ssl/certs/prometheus-ca.crt
          subPath: ca.crt
          readOnly: true
        resources:
          limits:
            cpu: 500m
            memory: 512Mi
          requests:
            cpu: 100m
            memory: 128Mi
      volumes:
      - name: config
        configMap:
          name: workload-variant-autoscaler-variantautoscaling-config
      - name: saturation-config
        configMap:
          name: workload-variant-autoscaler-wva-saturation-scaling-config
      - name: service-classes-config
        configMap:
          name: workload-variant-autoscaler-service-classes-config
      - name: prometheus-ca
        configMap:
          name: workload-variant-autoscaler-prometheus-ca
          optional: true
EOF
echo -e "${GREEN}✓ Deployment created${NC}"
echo ""

# Wait for deployment to be ready
echo -e "${YELLOW}Step 7: Waiting for controller to be ready...${NC}"
kubectl wait --for=condition=available deployment/workload-variant-autoscaler-controller-manager \
    -n "$TARGET_NAMESPACE" --timeout=120s || true
echo ""

# Verify deployment
echo -e "${YELLOW}Step 8: Verifying deployment...${NC}"
echo ""
echo "Pod status:"
kubectl get pods -n "$TARGET_NAMESPACE" -l app.kubernetes.io/name=workload-variant-autoscaler
echo ""

# Check logs for errors
echo "Checking controller logs for errors..."
sleep 5
LOGS=$(kubectl logs -n "$TARGET_NAMESPACE" deployment/workload-variant-autoscaler-controller-manager --tail=20 2>/dev/null || echo "")

if echo "$LOGS" | grep -q "failed to load config"; then
    echo -e "${RED}✗ Controller failed to load configuration${NC}"
    echo "Check logs with: kubectl logs -n $TARGET_NAMESPACE deployment/workload-variant-autoscaler-controller-manager"
elif echo "$LOGS" | grep -q "Prometheus API validation failed"; then
    echo -e "${YELLOW}⚠ Controller cannot access Prometheus (403 Forbidden)${NC}"
    echo "This requires cluster-level RBAC. See WVA_CONTROLLER_DEPLOYMENT.md for details."
elif echo "$LOGS" | grep -q "Configuration loaded successfully"; then
    echo -e "${GREEN}✓ Controller is running successfully${NC}"
else
    echo -e "${YELLOW}⚠ Controller status unclear - check logs manually${NC}"
fi

echo ""
echo -e "${BLUE}=== Deployment Summary ===${NC}"
echo -e "Namespace: ${GREEN}${TARGET_NAMESPACE}${NC}"
echo -e "ConfigMaps: ${GREEN}Created with default values${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Verify controller is running:"
echo "   kubectl get pods -n ${TARGET_NAMESPACE} -l app.kubernetes.io/name=workload-variant-autoscaler"
echo ""
echo "2. Check controller logs:"
echo "   kubectl logs -n ${TARGET_NAMESPACE} deployment/workload-variant-autoscaler-controller-manager"
echo ""
echo "3. Customize ConfigMaps if needed:"
echo "   kubectl edit configmap workload-variant-autoscaler-variantautoscaling-config -n ${TARGET_NAMESPACE}"
echo "   kubectl edit configmap workload-variant-autoscaler-wva-saturation-scaling-config -n ${TARGET_NAMESPACE}"
echo "   kubectl edit configmap workload-variant-autoscaler-service-classes-config -n ${TARGET_NAMESPACE}"
echo ""
echo "4. If Prometheus access fails (403), you need cluster-admin to create ClusterRole/ClusterRoleBinding"
echo "   See: skills/llmd-scale-workers/WVA_CONTROLLER_DEPLOYMENT.md"
echo ""
echo "5. Once controller is healthy, create VariantAutoscaling resource:"
echo "   kubectl apply -f your-variantautoscaling.yaml"
echo ""

