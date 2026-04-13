#!/bin/bash

# Script to create HPA for llm-d deployment using inference pool metrics
# Usage: ./create-hpa.sh <namespace> <deployment-name> <inferencepool-name> [min-replicas] [max-replicas] [target-queue-size]

set -e

NAMESPACE=${1:-}
DEPLOYMENT_NAME=${2:-}
INFERENCEPOOL_NAME=${3:-}
MIN_REPLICAS=${4:-1}
MAX_REPLICAS=${5:-5}
TARGET_QUEUE_SIZE=${6:-10}

if [ -z "$NAMESPACE" ] || [ -z "$DEPLOYMENT_NAME" ] || [ -z "$INFERENCEPOOL_NAME" ]; then
  echo "Usage: $0 <namespace> <deployment-name> <inferencepool-name> [min-replicas] [max-replicas] [target-queue-size]"
  echo ""
  echo "Example:"
  echo "  $0 default ms-gpt-oss-20b-llm-d-modelservice-decode gaie-gpt-oss-20b 1 5 10"
  echo ""
  echo "Parameters:"
  echo "  namespace           - Kubernetes namespace"
  echo "  deployment-name     - Name of the deployment to scale"
  echo "  inferencepool-name  - Name of the InferencePool (without -epp suffix)"
  echo "  min-replicas        - Minimum number of replicas (default: 1)"
  echo "  max-replicas        - Maximum number of replicas (default: 5)"
  echo "  target-queue-size   - Target queue size to trigger scaling (default: 10)"
  exit 1
fi

HPA_NAME="${DEPLOYMENT_NAME}-hpa"
EPP_SERVICE="${INFERENCEPOOL_NAME}-epp"

echo "Creating HPA for deployment: $DEPLOYMENT_NAME"
echo "Namespace: $NAMESPACE"
echo "InferencePool EPP Service: $EPP_SERVICE"
echo "Replica range: $MIN_REPLICAS-$MAX_REPLICAS"
echo "Target queue size: $TARGET_QUEUE_SIZE"
echo ""

# Create HPA YAML
cat <<EOF | kubectl apply -f -
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${HPA_NAME}
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${DEPLOYMENT_NAME}
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
  metrics:
  - type: Object
    object:
      metric:
        name: inference_pool_average_queue_size
      describedObject:
        apiVersion: v1
        kind: Service
        name: ${EPP_SERVICE}
      target:
        type: Value
        value: "${TARGET_QUEUE_SIZE}"
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
      - type: Percent
        value: 100
        periodSeconds: 30
      - type: Pods
        value: 2
        periodSeconds: 30
      selectPolicy: Max
EOF

echo ""
echo "HPA created successfully!"
echo ""
echo "Check HPA status:"
echo "  kubectl get hpa ${HPA_NAME} -n ${NAMESPACE}"
echo ""
echo "View detailed status:"
echo "  kubectl describe hpa ${HPA_NAME} -n ${NAMESPACE}"
echo ""
echo "Monitor queue size:"
echo "  kubectl get --raw \"/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/services/${EPP_SERVICE}/inference_pool_average_queue_size\" | jq -r '.items[0].value'"

# Made with Bob
