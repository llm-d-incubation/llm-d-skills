#!/bin/bash

# Script to test HPA autoscaling by sending load and monitoring pod scaling
# Usage: ./test-hpa-scaling.sh <namespace> <deployment-name> <gateway-url> <model-name> [num-requests] [max-tokens]

set -e

NAMESPACE=${1:-}
DEPLOYMENT_NAME=${2:-}
GATEWAY_URL=${3:-}
MODEL_NAME=${4:-}
NUM_REQUESTS=${5:-50}
MAX_TOKENS=${6:-300}

if [ -z "$NAMESPACE" ] || [ -z "$DEPLOYMENT_NAME" ] || [ -z "$GATEWAY_URL" ] || [ -z "$MODEL_NAME" ]; then
  echo "Usage: $0 <namespace> <deployment-name> <gateway-url> <model-name> [num-requests] [max-tokens]"
  echo ""
  echo "Example:"
  echo "  $0 default ms-gpt-oss-20b-llm-d-modelservice-decode \\"
  echo "    http://infra-gpt-oss-20b-inference-gateway-istio.default.svc.cluster.local:80 \\"
  echo "    EleutherAI/gpt-neox-20b 50 300"
  echo ""
  echo "Parameters:"
  echo "  namespace        - Kubernetes namespace"
  echo "  deployment-name  - Name of the deployment being scaled"
  echo "  gateway-url      - Full URL to the inference gateway"
  echo "  model-name       - Model name for requests"
  echo "  num-requests     - Number of concurrent requests (default: 50)"
  echo "  max-tokens       - Tokens per request (default: 300)"
  exit 1
fi

# Auto-detect HPA name - try common patterns
HPA_NAME=""
if kubectl get hpa "${DEPLOYMENT_NAME}-hpa" -n "$NAMESPACE" &>/dev/null; then
  HPA_NAME="${DEPLOYMENT_NAME}-hpa"
else
  # Try to find HPA by deployment reference
  HPA_NAME=$(kubectl get hpa -n "$NAMESPACE" -o json | jq -r ".items[] | select(.spec.scaleTargetRef.name==\"$DEPLOYMENT_NAME\") | .metadata.name" 2>/dev/null | head -1)
fi

if [ -z "$HPA_NAME" ]; then
  echo "⚠ No HPA found for deployment: $DEPLOYMENT_NAME"
  echo "Available HPAs in namespace:"
  kubectl get hpa -n "$NAMESPACE" 2>/dev/null || echo "  None found"
  echo ""
  echo "Create HPA first using:"
  echo "  bash skills/autoscale-llm-d-workers/scripts/create-hpa.sh $NAMESPACE $DEPLOYMENT_NAME <inferencepool-name>"
  exit 1
fi

echo "========================================="
echo "HPA Autoscaling Load Test"
echo "========================================="
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT_NAME"
echo "HPA: $HPA_NAME (auto-detected)"
echo "Gateway: $GATEWAY_URL"
echo "Model: $MODEL_NAME"
echo "Concurrent Requests: $NUM_REQUESTS"
echo "Tokens per request: $MAX_TOKENS"
echo ""

# Check initial state
echo "Initial State:"
echo "-------------"
INITIAL_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
echo "Current replicas: $INITIAL_REPLICAS"
kubectl get hpa "$HPA_NAME" -n "$NAMESPACE"
echo ""

# Start load test in background
echo "Starting load test..."
echo "Launching $NUM_REQUESTS concurrent requests in a test pod..."

kubectl run hpa-load-test --rm -i --restart=Never --image=curlimages/curl:latest -n "$NAMESPACE" -- sh -c "
echo 'Sending $NUM_REQUESTS concurrent requests...'

for i in \$(seq 1 $NUM_REQUESTS); do
  (
    curl -s -X POST '$GATEWAY_URL/v1/completions' \
      -H 'Content-Type: application/json' \
      -d '{\"model\": \"$MODEL_NAME\", \"prompt\": \"Write a very long and detailed story about artificial intelligence and machine learning\", \"max_tokens\": $MAX_TOKENS, \"temperature\": 0.7}' > /dev/null 2>&1 &
  ) &
done

echo 'All $NUM_REQUESTS requests launched'
echo 'Waiting for requests to complete...'
sleep 10
echo 'Load test pod exiting'
" &

LOAD_TEST_PID=$!

echo "Load test started (PID: $LOAD_TEST_PID)"
echo ""
echo "Monitoring HPA and deployment for 2 minutes..."
echo "Press Ctrl+C to stop monitoring early"
echo ""

# Monitor for 2 minutes (12 checks, 10 seconds apart)
for i in {1..12}; do
  echo "Check #$i ($(date '+%H:%M:%S')):"
  echo "-------------------"
  
  # Get current replicas
  CURRENT_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  DESIRED_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  READY_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  
  echo "Replicas: $READY_REPLICAS ready / $CURRENT_REPLICAS current / $DESIRED_REPLICAS desired"
  
  # Get HPA status
  HPA_STATUS=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].object.current.value}' 2>/dev/null || echo "N/A")
  HPA_TARGET=$(kubectl get hpa "$HPA_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentMetrics[0].object.target.value}' 2>/dev/null || echo "N/A")
  echo "Queue size: $HPA_STATUS / $HPA_TARGET"
  
  # Check if scaling occurred
  if [ "$CURRENT_REPLICAS" -gt "$INITIAL_REPLICAS" ]; then
    echo "✓ SCALING DETECTED! Replicas increased from $INITIAL_REPLICAS to $CURRENT_REPLICAS"
  fi
  
  echo ""
  
  if [ $i -lt 12 ]; then
    sleep 10
  fi
done

# Wait for load test to complete
wait $LOAD_TEST_PID 2>/dev/null || true

echo "========================================="
echo "Load Test Complete"
echo "========================================="
echo ""

# Final state
FINAL_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
echo "Final State:"
echo "  Initial replicas: $INITIAL_REPLICAS"
echo "  Final replicas: $FINAL_REPLICAS"
echo ""

if [ "$FINAL_REPLICAS" -gt "$INITIAL_REPLICAS" ]; then
  echo "✓ SUCCESS: Autoscaling triggered! Deployment scaled from $INITIAL_REPLICAS to $FINAL_REPLICAS replicas"
  echo ""
  echo "HPA Events:"
  kubectl describe hpa "$HPA_NAME" -n "$NAMESPACE" | grep -A 10 "Events:"
else
  echo "⚠ No scaling detected. Possible reasons:"
  echo "  - Model processes requests too quickly (queue never builds up)"
  echo "  - Target queue size is too high"
  echo "  - Not enough concurrent requests"
  echo ""
  echo "Try:"
  echo "  - Increase number of requests: $0 $NAMESPACE $DEPLOYMENT_NAME $GATEWAY_URL $MODEL_NAME 100 500"
  echo "  - Lower HPA target queue size"
  echo "  - Check HPA events: kubectl describe hpa $HPA_NAME -n $NAMESPACE"
fi
echo ""

echo "To continue monitoring:"
echo "  watch kubectl get hpa $HPA_NAME -n $NAMESPACE"
echo "  watch kubectl get deployment $DEPLOYMENT_NAME -n $NAMESPACE"

# Made with Bob
