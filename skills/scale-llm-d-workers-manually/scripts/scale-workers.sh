#!/bin/bash
# Scale llm-d workers (prefill or decode)

set -e

# Non-interactive by default, can be overridden with INTERACTIVE=true
NON_INTERACTIVE="${NON_INTERACTIVE:-true}"
INTERACTIVE="${INTERACTIVE:-false}"

# If INTERACTIVE is explicitly set to true, disable non-interactive mode
if [ "$INTERACTIVE" = "true" ]; then
    NON_INTERACTIVE="false"
fi

# Usage
usage() {
    echo "Usage: $0 -n NAMESPACE -t TYPE -r REPLICAS [-d DEPLOYMENT_NAME] [-m METHOD] [-i]"
    echo ""
    echo "Options:"
    echo "  -n NAMESPACE        Target namespace"
    echo "  -t TYPE            Worker type: decode|prefill"
    echo "  -r REPLICAS        New replica count"
    echo "  -d DEPLOYMENT_NAME Deployment name (auto-detected if not provided)"
    echo "  -m METHOD          Scaling method: kubectl|helm (default: kubectl)"
    echo "  -i                 Interactive mode (prompt for confirmation)"
    echo ""
    echo "Environment Variables:"
    echo "  INTERACTIVE        Set to 'true' to enable confirmation prompts"
    echo "  NON_INTERACTIVE    Set to 'false' to enable confirmation prompts"
    echo ""
    echo "Examples:"
    echo "  $0 -n llmd-ns -t decode -r 3"
    echo "  $0 -n llmd-ns -t prefill -r 8 -m helm"
    echo "  $0 -n llmd-ns -t decode -r 3 -i  # Interactive mode"
    echo "  INTERACTIVE=true $0 -n llmd-ns -t decode -r 3"
    exit 1
}

# Parse arguments
while getopts "n:t:r:d:m:ih" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG" ;;
        t) TYPE="$OPTARG" ;;
        r) REPLICAS="$OPTARG" ;;
        d) DEPLOYMENT_NAME="$OPTARG" ;;
        m) METHOD="$OPTARG" ;;
        i) INTERACTIVE="true"; NON_INTERACTIVE="false" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate required arguments
if [ -z "$NAMESPACE" ] || [ -z "$TYPE" ] || [ -z "$REPLICAS" ]; then
    echo "Error: Missing required arguments"
    usage
fi

# Validate type
if [ "$TYPE" != "decode" ] && [ "$TYPE" != "prefill" ]; then
    echo "Error: TYPE must be 'decode' or 'prefill'"
    exit 1
fi

# Set default method
METHOD="${METHOD:-kubectl}"

# Auto-detect deployment name if not provided
if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME=$(kubectl get deployments -n "$NAMESPACE" \
        -l llm-d.ai/role="$TYPE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$DEPLOYMENT_NAME" ]; then
        echo "Error: Could not auto-detect $TYPE deployment in namespace $NAMESPACE"
        exit 1
    fi
    echo "Auto-detected deployment: $DEPLOYMENT_NAME"
fi

# Get current replicas
CURRENT_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

echo "=== Scaling $TYPE Workers ==="
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOYMENT_NAME"
echo "Current Replicas: $CURRENT_REPLICAS"
echo "Target Replicas: $REPLICAS"
echo "Method: $METHOD"
echo ""

# Confirm action (skip in non-interactive mode)
if [ "$NON_INTERACTIVE" = "true" ]; then
    echo "Non-interactive mode - proceeding with scaling..."
else
    read -p "Proceed with scaling? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Scaling cancelled"
        exit 0
    fi
fi

# Execute scaling based on method
if [ "$METHOD" = "kubectl" ]; then
    echo "Scaling via kubectl..."
    kubectl scale deployment "$DEPLOYMENT_NAME" --replicas="$REPLICAS" -n "$NAMESPACE"
    
elif [ "$METHOD" = "helm" ]; then
    echo "Error: Helm scaling requires manual values.yaml update"
    echo "Please update the values file and run: helmfile apply -n $NAMESPACE"
    exit 1
else
    echo "Error: Unknown method: $METHOD"
    exit 1
fi

# Wait for scaling to complete
echo ""
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod \
    -l llm-d.ai/role="$TYPE" \
    -n "$NAMESPACE" \
    --timeout=600s || true

# Show final status
echo ""
echo "=== Scaling Complete ==="
kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role="$TYPE"


