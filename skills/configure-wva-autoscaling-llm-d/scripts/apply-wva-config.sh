#!/bin/bash
set -e

# Improved WVA Configuration Script
# Applies VariantAutoscaling and HPA with proper validation

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "WVA Configuration Script"
echo "========================================="
echo ""

# Check required parameters
if [ $# -lt 3 ]; then
    echo "Usage: $0 <namespace> <deployment-name> <model-id> [variant-name] [accelerator]"
    echo ""
    echo "Example:"
    echo "  $0 my-namespace ms-my-model-decode EleutherAI/gpt-j-6b my-autoscaler nvidia"
    exit 1
fi

NAMESPACE=$1
DEPLOYMENT=$2
MODEL_ID=$3
VARIANT_NAME=${4:-"${DEPLOYMENT}-autoscaler"}
ACCELERATOR=${5:-"nvidia"}

echo "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Deployment: ${DEPLOYMENT}"
echo "  Model ID: ${MODEL_ID}"
echo "  Variant Name: ${VARIANT_NAME}"
echo "  Accelerator: ${ACCELERATOR}"
echo ""

# Step 1: Verify deployment exists
echo "Step 1: Verifying deployment exists..."
if ! oc get deployment ${DEPLOYMENT} -n ${NAMESPACE} &>/dev/null; then
    echo -e "${RED}✗ Deployment ${DEPLOYMENT} not found in namespace ${NAMESPACE}${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Deployment found${NC}"
echo ""

# Step 2: Check for existing WVA controller
echo "Step 2: Checking for WVA controller..."
WVA_CONTROLLER_NS=$(oc get deployment --all-namespaces -l app.kubernetes.io/name=workload-variant-autoscaler -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")

if [ -z "$WVA_CONTROLLER_NS" ]; then
    echo -e "${YELLOW}⚠ No WVA controller found. You need to install WVA first.${NC}"
    echo "See: https://github.com/llm-d/llm-d-workload-variant-autoscaler"
    exit 1
fi
echo -e "${GREEN}✓ WVA controller found in namespace: ${WVA_CONTROLLER_NS}${NC}"
echo ""

# Step 3: Create VariantAutoscaling
echo "Step 3: Creating VariantAutoscaling..."
cat <<EOF | oc apply -f -
apiVersion: llmd.ai/v1alpha1
kind: VariantAutoscaling
metadata:
  name: ${VARIANT_NAME}
  namespace: ${NAMESPACE}
  labels:
    inference.optimization/acceleratorName: ${ACCELERATOR}
spec:
  scaleTargetRef:
    kind: Deployment
    name: ${DEPLOYMENT}
  modelID: "${MODEL_ID}"
  variantCost: "10.0"
EOF

echo -e "${GREEN}✓ VariantAutoscaling created/updated${NC}"
echo ""

# Step 4: Wait for metrics to be ready
echo "Step 4: Waiting for metrics to be ready..."
for i in {1..30}; do
    METRICS_READY=$(oc get variantautoscaling ${VARIANT_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="MetricsAvailable")].status}' 2>/dev/null || echo "")
    if [ "$METRICS_READY" = "True" ]; then
        echo -e "${GREEN}✓ Metrics are ready${NC}"
        break
    fi
    echo -n "."
    sleep 2
done
echo ""

if [ "$METRICS_READY" != "True" ]; then
    echo -e "${YELLOW}⚠ Metrics not ready yet. Check VariantAutoscaling status:${NC}"
    echo "  oc get variantautoscaling ${VARIANT_NAME} -n ${NAMESPACE} -o yaml"
fi
echo ""

# Step 5: Verify metrics are available
echo "Step 5: Verifying WVA metrics are available..."
METRICS=$(oc get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/wva_desired_replicas" 2>/dev/null | jq -r ".items[] | select(.metricLabels.variant_name==\"${VARIANT_NAME}\" and .metricLabels.exported_namespace==\"${NAMESPACE}\") | .value" 2>/dev/null || echo "")

if [ -n "$METRICS" ]; then
    echo -e "${GREEN}✓ WVA metrics available. Current desired replicas: ${METRICS}${NC}"
else
    echo -e "${YELLOW}⚠ WVA metrics not found yet. This may take 30-60 seconds.${NC}"
    echo "  Check with: oc get --raw \"/apis/external.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/wva_desired_replicas\" | jq"
fi
echo ""

# Step 6: Create HPA
echo "Step 6: Creating HPA with aggressive scaling..."
cat <<EOF | oc apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${VARIANT_NAME}-hpa
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${DEPLOYMENT}
  minReplicas: 1
  maxReplicas: 10
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      selectPolicy: Max
      policies:
      - type: Pods
        value: 3
        periodSeconds: 15
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300
      selectPolicy: Min
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
  metrics:
  - type: External
    external:
      metric:
        name: wva_desired_replicas
        selector:
          matchLabels:
            variant_name: ${VARIANT_NAME}
            exported_namespace: ${NAMESPACE}
      target:
        type: AverageValue
        averageValue: "1"
EOF

echo -e "${GREEN}✓ HPA created/updated${NC}"
echo ""

# Step 7: Verify HPA can read metrics
echo "Step 7: Verifying HPA configuration..."
sleep 5
HPA_STATUS=$(oc get hpa ${VARIANT_NAME}-hpa -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null || echo "")

if [ "$HPA_STATUS" = "True" ]; then
    echo -e "${GREEN}✓ HPA is active and reading metrics${NC}"
elif [ "$HPA_STATUS" = "False" ]; then
    HPA_REASON=$(oc get hpa ${VARIANT_NAME}-hpa -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].reason}' 2>/dev/null || echo "")
    if [ "$HPA_REASON" = "ScalingDisabled" ]; then
        echo -e "${YELLOW}⚠ HPA scaling is disabled (deployment has 0 replicas)${NC}"
        echo "  Scale deployment to at least 1 replica:"
        echo "  oc scale deployment ${DEPLOYMENT} --replicas=1 -n ${NAMESPACE}"
    else
        echo -e "${YELLOW}⚠ HPA not active yet. Reason: ${HPA_REASON}${NC}"
    fi
else
    echo -e "${YELLOW}⚠ HPA status unknown. Check with:${NC}"
    echo "  oc describe hpa ${VARIANT_NAME}-hpa -n ${NAMESPACE}"
fi
echo ""

# Step 8: Display status
echo "========================================="
echo "Configuration Complete!"
echo "========================================="
echo ""
echo "VariantAutoscaling Status:"
oc get variantautoscaling ${VARIANT_NAME} -n ${NAMESPACE} -o wide
echo ""
echo "HPA Status:"
oc get hpa ${VARIANT_NAME}-hpa -n ${NAMESPACE}
echo ""
echo "Deployment Status:"
oc get deployment ${DEPLOYMENT} -n ${NAMESPACE}
echo ""

echo "Next steps:"
echo "1. Monitor autoscaling:"
echo "   oc get hpa ${VARIANT_NAME}-hpa -n ${NAMESPACE} -w"
echo ""
echo "2. Check VariantAutoscaling status:"
echo "   oc get variantautoscaling ${VARIANT_NAME} -n ${NAMESPACE} -o yaml"
echo ""
echo "3. View WVA controller logs:"
echo "   oc logs -f -n ${WVA_CONTROLLER_NS} -l app.kubernetes.io/name=workload-variant-autoscaler"
echo ""

# Made with Bob
