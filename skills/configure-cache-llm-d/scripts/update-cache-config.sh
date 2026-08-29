#!/bin/bash
# Update cache configuration for llm-d deployment

set -e

usage() {
    cat << EOF
Update cache configuration for llm-d deployment

Usage: $0 -n <namespace> [options]

Required:
  -n <namespace>          Target namespace

Cache Options (at least one required):
  -g <value>              GPU memory utilization (0.0-1.0, e.g., 0.90)
  -b <value>              Block size in tokens (e.g., 32, 64)
  -m <value>              Max model length in tokens (e.g., 8192, 16384)
  -s <value>              Shared memory size (e.g., 20Gi, 30Gi)

Deployment Options:
  -d <deployment-dir>     Deployment directory (auto-detected if not provided)
  -r <release-name>       Helm release name (auto-detected if not provided)
  --dry-run               Show changes without applying

Examples:
  # Increase cache capacity
  $0 -n llmd-ns -g 0.90 -b 32

  # Support longer contexts
  $0 -n llmd-ns -m 16384 -g 0.85 -s 30Gi

  # Preview changes
  $0 -n llmd-ns -g 0.90 --dry-run

EOF
    exit 1
}

# Parse arguments
NAMESPACE=""
GPU_MEM=""
BLOCK_SIZE=""
MAX_LEN=""
SHM_SIZE=""
DEPLOY_DIR=""
RELEASE_NAME=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -n) NAMESPACE="$2"; shift 2 ;;
        -g) GPU_MEM="$2"; shift 2 ;;
        -b) BLOCK_SIZE="$2"; shift 2 ;;
        -m) MAX_LEN="$2"; shift 2 ;;
        -s) SHM_SIZE="$2"; shift 2 ;;
        -d) DEPLOY_DIR="$2"; shift 2 ;;
        -r) RELEASE_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required arguments
if [ -z "$NAMESPACE" ]; then
    echo "Error: Namespace is required"
    usage
fi

if [ -z "$GPU_MEM" ] && [ -z "$BLOCK_SIZE" ] && [ -z "$MAX_LEN" ] && [ -z "$SHM_SIZE" ]; then
    echo "Error: At least one cache option must be specified"
    usage
fi

# Auto-detect deployment directory if not provided
if [ -z "$DEPLOY_DIR" ]; then
    echo "Auto-detecting deployment directory..."
    DEPLOY_DIR=$(find deployments -type f -name "ms-values.yaml" -path "*/deploy-*/*" | head -1 | xargs dirname)
    if [ -z "$DEPLOY_DIR" ]; then
        echo "Error: Could not auto-detect deployment directory"
        echo "Please specify with -d option"
        exit 1
    fi
    echo "Found: $DEPLOY_DIR"
fi

# Verify deployment directory exists
if [ ! -d "$DEPLOY_DIR" ]; then
    echo "Error: Deployment directory not found: $DEPLOY_DIR"
    exit 1
fi

MS_VALUES="$DEPLOY_DIR/ms-values.yaml"
GAIE_VALUES="$DEPLOY_DIR/gaie-values.yaml"

if [ ! -f "$MS_VALUES" ]; then
    echo "Error: ms-values.yaml not found in $DEPLOY_DIR"
    exit 1
fi

echo "=== Cache Configuration Update ==="
echo "Namespace: $NAMESPACE"
echo "Deployment: $DEPLOY_DIR"
echo ""

# Show current configuration
echo "Current Configuration:"
if [ -f "$MS_VALUES" ]; then
    echo "  GPU Memory Utilization: $(grep -o 'gpu-memory-utilization=[0-9.]*' "$MS_VALUES" || echo 'not set')"
    echo "  Block Size: $(grep -o 'block-size=[0-9]*' "$MS_VALUES" || echo 'not set')"
    echo "  Max Model Length: $(grep -o 'max-model-len=[0-9]*' "$MS_VALUES" || echo 'not set')"
    echo "  Shared Memory: $(grep -A 2 'name: shm' "$MS_VALUES" | grep 'sizeLimit:' | awk '{print $2}' || echo 'not set')"
fi
echo ""

# Show proposed changes
echo "Proposed Changes:"
[ -n "$GPU_MEM" ] && echo "  GPU Memory Utilization: $GPU_MEM"
[ -n "$BLOCK_SIZE" ] && echo "  Block Size: $BLOCK_SIZE"
[ -n "$MAX_LEN" ] && echo "  Max Model Length: $MAX_LEN"
[ -n "$SHM_SIZE" ] && echo "  Shared Memory: $SHM_SIZE"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN - No changes will be applied"
    echo ""
    echo "To apply these changes, run without --dry-run flag"
    exit 0
fi

# Backup original files
BACKUP_DIR="$DEPLOY_DIR/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
cp "$MS_VALUES" "$BACKUP_DIR/ms-values.yaml.$TIMESTAMP"
echo "Backed up ms-values.yaml to $BACKUP_DIR/ms-values.yaml.$TIMESTAMP"

if [ -f "$GAIE_VALUES" ] && [ -n "$BLOCK_SIZE" ]; then
    cp "$GAIE_VALUES" "$BACKUP_DIR/gaie-values.yaml.$TIMESTAMP"
    echo "Backed up gaie-values.yaml to $BACKUP_DIR/gaie-values.yaml.$TIMESTAMP"
fi
echo ""

# Update ms-values.yaml
echo "Updating $MS_VALUES..."

if [ -n "$GPU_MEM" ]; then
    if grep -q "gpu-memory-utilization=" "$MS_VALUES"; then
        sed -i.tmp "s/--gpu-memory-utilization=[0-9.]*/--gpu-memory-utilization=$GPU_MEM/" "$MS_VALUES"
        echo "  Updated GPU memory utilization to $GPU_MEM"
    else
        echo "  Warning: gpu-memory-utilization not found in file"
    fi
fi

if [ -n "$BLOCK_SIZE" ]; then
    if grep -q "block-size=" "$MS_VALUES"; then
        sed -i.tmp "s/--block-size=[0-9]*/--block-size=$BLOCK_SIZE/" "$MS_VALUES"
        echo "  Updated block size to $BLOCK_SIZE"
    else
        echo "  Warning: block-size not found in file"
    fi
fi

if [ -n "$MAX_LEN" ]; then
    if grep -q "max-model-len=" "$MS_VALUES"; then
        sed -i.tmp "s/--max-model-len=[0-9]*/--max-model-len=$MAX_LEN/" "$MS_VALUES"
        echo "  Updated max model length to $MAX_LEN"
    else
        echo "  Warning: max-model-len not found in file"
    fi
fi

if [ -n "$SHM_SIZE" ]; then
    if grep -q "sizeLimit:" "$MS_VALUES"; then
        sed -i.tmp "/name: shm/,/sizeLimit:/ s/sizeLimit: .*/sizeLimit: $SHM_SIZE/" "$MS_VALUES"
        echo "  Updated shared memory to $SHM_SIZE"
    else
        echo "  Warning: sizeLimit not found in file"
    fi
fi

# Clean up temp files
rm -f "$MS_VALUES.tmp"

# Update gaie-values.yaml if block size changed
if [ -n "$BLOCK_SIZE" ] && [ -f "$GAIE_VALUES" ]; then
    echo ""
    echo "Updating $GAIE_VALUES..."
    if grep -q "blockSize:" "$GAIE_VALUES"; then
        sed -i.tmp "s/blockSize: [0-9]*/blockSize: $BLOCK_SIZE/" "$GAIE_VALUES"
        echo "  Updated blockSize to $BLOCK_SIZE (must match vLLM)"
        rm -f "$GAIE_VALUES.tmp"
    else
        echo "  Note: blockSize not found (may not be using precise prefix cache)"
    fi
fi

echo ""
echo "=== Applying Changes ==="
echo "Running: helmfile apply -n $NAMESPACE"
echo ""

cd "$DEPLOY_DIR"
helmfile apply -n "$NAMESPACE"

echo ""
echo "=== Verifying Deployment ==="
echo "Waiting for rollout to complete..."
sleep 5

# Wait for rollout
DEPLOYMENTS=$(kubectl get deployment -n "$NAMESPACE" -l llm-d.ai/role=decode -o name 2>/dev/null || true)
for DEPLOY in $DEPLOYMENTS; do
    echo "Checking $DEPLOY..."
    kubectl rollout status "$DEPLOY" -n "$NAMESPACE" --timeout=300s || true
done

echo ""
echo "=== New Configuration ==="
POD=$(kubectl get pods -n "$NAMESPACE" -l llm-d.ai/role=decode --field-selector=status.phase=Running -o name 2>/dev/null | head -1)
if [ -n "$POD" ]; then
    echo "Verifying settings in pod..."
    kubectl logs "$POD" -n "$NAMESPACE" --tail=100 | grep -E "gpu_memory_utilization|block_size|max_model_len" || echo "Settings not yet in logs (pod may still be starting)"
fi

echo ""
echo "✓ Cache configuration updated successfully!"
echo ""
echo "To verify:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl logs <pod-name> -n $NAMESPACE | grep -E 'gpu_memory_utilization|block_size|max_model_len'"
echo ""
echo "To rollback:"
echo "  cp $BACKUP_DIR/ms-values.yaml.$TIMESTAMP $MS_VALUES"
echo "  cd $DEPLOY_DIR && helmfile apply -n $NAMESPACE"

