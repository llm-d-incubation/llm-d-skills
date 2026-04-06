#!/bin/bash
# Check available cluster resources for scaling

set -e

NAMESPACE="${1:-${NAMESPACE}}"

echo "=== Cluster Resource Availability ==="
echo ""

# Check GPU resources
echo "GPU Resources:"
kubectl describe nodes | grep -A 5 "nvidia.com/gpu" | grep -E "Allocatable|Allocated" || echo "  No GPU resources found"
echo ""

# Check RDMA resources
echo "RDMA Resources:"
kubectl describe nodes | grep -A 5 "rdma/" | grep -E "Allocatable|Allocated" || echo "  No RDMA resources found"
echo ""

# Check memory
echo "Memory Resources:"
kubectl top nodes 2>/dev/null || echo "  Metrics server not available"
echo ""

# Show current pod resource usage in namespace
if [ -n "$NAMESPACE" ]; then
    echo "Current Pod Resources in $NAMESPACE:"
    kubectl get pods -n "$NAMESPACE" -l llm-d.ai/inference-serving=true \
        -o custom-columns=NAME:.metadata.name,GPU:.spec.containers[*].resources.requests.'nvidia\.com/gpu',MEMORY:.spec.containers[*].resources.requests.memory 2>/dev/null || echo "  No pods found"
fi
