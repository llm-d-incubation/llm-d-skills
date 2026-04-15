#!/bin/bash
# Verify WVA Configuration and Status
# Usage: ./verify-wva.sh <namespace>

set -e

NAMESPACE=${1:-llm-inference}

echo "=== Checking VariantAutoscaling Status ==="
kubectl get variantautoscaling -n "$NAMESPACE"
echo ""

echo "=== Checking HPA Status ==="
kubectl get hpa -n "$NAMESPACE"
echo ""

echo "=== Checking WVA Controller Logs (last 20 lines) ==="
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler \
  --tail=20
echo ""

echo "=== Checking WVA Metrics ==="
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/$NAMESPACE/wva_desired_replicas" | jq '.' || echo "Metrics not available or jq not installed"
echo ""

echo "=== VariantAutoscaling Details ==="
kubectl get variantautoscaling -n "$NAMESPACE" -o yaml

# Made with Bob
