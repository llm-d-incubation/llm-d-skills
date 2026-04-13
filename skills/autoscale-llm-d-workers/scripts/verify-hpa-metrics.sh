#!/bin/bash

# Script to verify HPA metrics are available
# Usage: ./verify-hpa-metrics.sh <namespace> <inferencepool-name>

set -e

NAMESPACE=${1:-}
INFERENCEPOOL_NAME=${2:-}

if [ -z "$NAMESPACE" ] || [ -z "$INFERENCEPOOL_NAME" ]; then
  echo "Usage: $0 <namespace> <inferencepool-name>"
  echo ""
  echo "Example:"
  echo "  $0 default gaie-gpt-oss-20b"
  exit 1
fi

EPP_SERVICE="${INFERENCEPOOL_NAME}-epp"

echo "========================================="
echo "Verifying HPA Metrics Setup"
echo "========================================="
echo "Namespace: $NAMESPACE"
echo "InferencePool: $INFERENCEPOOL_NAME"
echo "EPP Service: $EPP_SERVICE"
echo ""

# Check if custom metrics API is available
echo "1. Checking custom metrics API..."
if kubectl get apiservice v1beta1.custom.metrics.k8s.io &>/dev/null; then
  echo "   ✓ Custom metrics API is available"
  kubectl get apiservice v1beta1.custom.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True" && echo "   ✓ Custom metrics API is healthy" || echo "   ✗ Custom metrics API is not healthy"
else
  echo "   ✗ Custom metrics API not found"
  echo "   Install Prometheus Adapter to enable custom metrics"
  exit 1
fi
echo ""

# Check if inference pool metrics are available
echo "2. Checking inference pool metrics..."
METRICS=$(kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 2>/dev/null | jq -r '.resources[].name' | grep inference_pool || true)
if [ -n "$METRICS" ]; then
  echo "   ✓ Inference pool metrics found:"
  echo "$METRICS" | sed 's/^/     - /'
else
  echo "   ✗ No inference pool metrics found"
  echo "   Ensure flow control is enabled in gaie-values.yaml"
  exit 1
fi
echo ""

# Check specific metric value
echo "3. Checking queue size metric for $EPP_SERVICE..."
METRIC_URL="/apis/custom.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/services/${EPP_SERVICE}/inference_pool_average_queue_size"
if METRIC_VALUE=$(kubectl get --raw "$METRIC_URL" 2>/dev/null); then
  QUEUE_SIZE=$(echo "$METRIC_VALUE" | jq -r '.items[0].value' 2>/dev/null || echo "N/A")
  echo "   ✓ Metric is available"
  echo "   Current queue size: $QUEUE_SIZE"
else
  echo "   ✗ Metric not available for service $EPP_SERVICE"
  echo "   Check that:"
  echo "     - Flow control is enabled in gaie-values.yaml"
  echo "     - Endpoint picker pod has been restarted after enabling flow control"
  echo "     - Service name is correct (should be ${EPP_SERVICE})"
  exit 1
fi
echo ""

# Check if EPP service exists
echo "4. Checking EPP service..."
if kubectl get service "$EPP_SERVICE" -n "$NAMESPACE" &>/dev/null; then
  echo "   ✓ EPP service exists: $EPP_SERVICE"
else
  echo "   ✗ EPP service not found: $EPP_SERVICE"
  exit 1
fi
echo ""

# Check EPP pod status
echo "5. Checking EPP pod status..."
EPP_POD=$(kubectl get pods -n "$NAMESPACE" -l "inferencepool=${EPP_SERVICE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$EPP_POD" ]; then
  POD_STATUS=$(kubectl get pod "$EPP_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
  echo "   ✓ EPP pod found: $EPP_POD"
  echo "   Status: $POD_STATUS"
  
  if [ "$POD_STATUS" != "Running" ]; then
    echo "   ⚠ Pod is not running. Check pod logs:"
    echo "     kubectl logs $EPP_POD -n $NAMESPACE"
  fi
else
  echo "   ✗ EPP pod not found"
  exit 1
fi
echo ""

echo "========================================="
echo "✓ All checks passed!"
echo "========================================="
echo ""
echo "You can now create an HPA using:"
echo "  bash skills/autoscale-llm-d-workers/scripts/create-hpa.sh \\"
echo "    $NAMESPACE <deployment-name> $INFERENCEPOOL_NAME"

# Made with Bob
