#!/bin/bash
# Detect llm-d deployment type and current state

set -e

NAMESPACE="${1:-${NAMESPACE}}"

if [ -z "$NAMESPACE" ]; then
    # Try to detect namespace
    if command -v oc &> /dev/null; then
        NAMESPACE=$(oc project -q 2>/dev/null || echo "")
    fi
    if [ -z "$NAMESPACE" ]; then
        NAMESPACE=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo "default")
    fi
fi

echo "=== Deployment Detection for namespace: $NAMESPACE ==="
echo ""

# Check for Helm releases
echo "Helm Releases:"
helm list -n "$NAMESPACE" 2>/dev/null || echo "  None found"
echo ""

# Check for deployments
echo "Deployments:"
kubectl get deployments -n "$NAMESPACE" -l llm-d.ai/inference-serving=true 2>/dev/null || echo "  None found"
echo ""

# Check for LeaderWorkerSets
echo "LeaderWorkerSets:"
kubectl get leaderworkerset -n "$NAMESPACE" -l llm-d.ai/inference-serving=true 2>/dev/null || echo "  None found"
echo ""

# Check decode workers
echo "Decode Workers:"
kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode 2>/dev/null || echo "  None found"
echo ""

# Check prefill workers
echo "Prefill Workers:"
kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=prefill 2>/dev/null || echo "  None found"
echo ""

# Get replica counts
echo "Current Replica Counts:"
for deploy in $(kubectl get deployments -n "$NAMESPACE" -l llm-d.ai/inference-serving=true -o name 2>/dev/null); do
    name=$(echo "$deploy" | cut -d'/' -f2)
    replicas=$(kubectl get "$deploy" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
    role=$(kubectl get "$deploy" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.llm-d\.ai/role}')
    echo "  $name ($role): $replicas replicas"
done


