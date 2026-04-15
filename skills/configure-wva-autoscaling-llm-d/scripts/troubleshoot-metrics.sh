#!/bin/bash
# Troubleshoot WVA Metrics Issues
# Usage: ./troubleshoot-metrics.sh <namespace> <pod-name>

set -e

NAMESPACE=${1:-llm-inference}
POD_NAME=${2}

if [ -z "$POD_NAME" ]; then
  echo "Usage: $0 <namespace> <pod-name>"
  echo "Example: $0 llm-inference ms-inference-scheduling-llm-d-modelservice-abc123"
  exit 1
fi

echo "=== Checking if pod exposes metrics ==="
kubectl exec -n "$NAMESPACE" "$POD_NAME" -- curl -s localhost:8000/metrics | grep vllm || echo "No vllm metrics found"
echo ""

echo "=== Sending test request to trigger metrics ==="
echo "Note: You may need to port-forward the gateway service first"
echo "Run: kubectl port-forward -n $NAMESPACE svc/<gateway-service> 8080:80"
echo ""
echo "Then run this curl command:"
echo 'curl -X POST http://localhost:8080/v1/chat/completions \'
echo '  -H "Content-Type: application/json" \'
echo '  -d '"'"'{"model": "<model-id>", "messages": [{"role": "user", "content": "test"}]}'"'"
echo ""

echo "=== Checking PodMonitor configuration ==="
kubectl get podmonitor -n "$NAMESPACE" -o yaml

# Made with Bob
