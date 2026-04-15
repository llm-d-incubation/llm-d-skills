#!/bin/bash
# Troubleshoot WVA Scaling Issues
# Usage: ./troubleshoot-scaling.sh <namespace>

set -e

NAMESPACE=${1:-llm-inference}

echo "=== Checking WVA Decision Logs ==="
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler \
  --tail=50 | grep "desired replicas" || echo "No scaling decisions found in recent logs"
echo ""

echo "=== Checking Current Saturation ==="
kubectl get variantautoscaling -n "$NAMESPACE" -o yaml | grep -A 5 "saturation" || echo "No saturation data found"
echo ""

echo "=== Verifying HPA Sees Metrics ==="
kubectl describe hpa -n "$NAMESPACE"
echo ""

echo "=== Checking HPA Events ==="
kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | grep -i hpa | tail -20
echo ""

echo "=== Current Replica Status ==="
kubectl get variantautoscaling -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,CURRENT:.status.currentReplicas,DESIRED:.status.desiredReplicas,SATURATION:.status.saturation

# Made with Bob
