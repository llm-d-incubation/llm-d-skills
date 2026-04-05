#!/bin/bash
# Show current cache configuration for llm-d deployment

set -e

NAMESPACE=${1:-${NAMESPACE}}

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace>"
    echo "Or set NAMESPACE environment variable"
    exit 1
fi

echo "=== Current Cache Configuration in namespace: $NAMESPACE ==="
echo ""

# Find model service deployments
DEPLOYMENTS=$(kubectl get deployment -n "$NAMESPACE" -l llm-d.ai/role=decode -o name 2>/dev/null || true)

if [ -z "$DEPLOYMENTS" ]; then
    echo "No decode deployments found in namespace $NAMESPACE"
    exit 1
fi

for DEPLOY in $DEPLOYMENTS; do
    DEPLOY_NAME=$(echo "$DEPLOY" | cut -d'/' -f2)
    echo "Deployment: $DEPLOY_NAME"
    echo "---"
    
    # Get pod to inspect
    POD=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode --field-selector=status.phase=Running -o name 2>/dev/null | head -1)
    
    if [ -n "$POD" ]; then
        POD_NAME=$(echo "$POD" | cut -d'/' -f2)
        
        # Extract cache settings from pod spec
        echo "GPU Memory Utilization:"
        kubectl get "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].args}' | \
            grep -o 'gpu-memory-utilization=[0-9.]*' || echo "  Not set (using default)"
        
        echo ""
        echo "Block Size:"
        kubectl get "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].args}' | \
            grep -o 'block-size=[0-9]*' || echo "  Not set (using default)"
        
        echo ""
        echo "Max Model Length:"
        kubectl get "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].args}' | \
            grep -o 'max-model-len=[0-9]*' || echo "  Not set (using default)"
        
        echo ""
        echo "Shared Memory (SHM):"
        kubectl get "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.volumes[?(@.name=="shm")].emptyDir.sizeLimit}' || echo "  Not configured"
        
        echo ""
        echo "Tensor Parallelism:"
        kubectl get "$POD" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].args}' | \
            grep -o 'tensor-parallel-size=[0-9]*' || echo "  Not set (TP=1)"
        
        echo ""
        echo "---"
        echo ""
    else
        echo "  No running pods found"
        echo ""
    fi
done

# Check for InferencePool configuration
echo "=== InferencePool Configuration ==="
POOLS=$(kubectl get inferencepool -n "$NAMESPACE" -o name 2>/dev/null || true)
if [ -n "$POOLS" ]; then
    for POOL in $POOLS; do
        POOL_NAME=$(echo "$POOL" | cut -d'/' -f2)
        echo "Pool: $POOL_NAME"
        kubectl get inferencepool "$POOL_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.modelServerType}' 2>/dev/null || echo "  Type: unknown"
        echo ""
    done
else
    echo "No InferencePools found"
fi

echo ""
echo "=== Resource Usage ==="
kubectl top pods -n "$NAMESPACE" -l llm-d.ai/role=decode 2>/dev/null || echo "Metrics not available (metrics-server may not be installed)"

