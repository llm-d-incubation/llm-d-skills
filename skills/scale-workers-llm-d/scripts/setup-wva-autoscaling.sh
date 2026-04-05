#!/bin/bash
# setup-wva-autoscaling.sh
# Automatically detect cluster configuration and set up WVA (Workload Variant Autoscaler)
# for llm-d deployments

set -e

# Non-interactive by default, can be overridden with INTERACTIVE=true
NON_INTERACTIVE="${NON_INTERACTIVE:-true}"
INTERACTIVE="${INTERACTIVE:-false}"

# If INTERACTIVE is explicitly set to true, disable non-interactive mode
if [ "$INTERACTIVE" = "true" ]; then
    NON_INTERACTIVE="false"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEFAULT_NAMESPACE="llm-d-autoscaler"
DEFAULT_MON_NS="llm-d-monitoring"
WVA_VERSION="v0.5.1"

echo -e "${BLUE}=== WVA Automatic Scaling Setup ===${NC}"
echo ""

# Function to detect platform
detect_platform() {
    echo -e "${YELLOW}Detecting platform...${NC}"
    
    if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "openshift"; then
        echo "OpenShift"
    elif kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "gce"; then
        echo "GKE"
    elif kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q "kind"; then
        echo "Kind"
    else
        echo "Other Kubernetes"
    fi
}

# Function to detect existing deployments
detect_deployments() {
    echo -e "${YELLOW}Detecting existing llm-d deployments...${NC}"
    
    local deployments=$(kubectl get deployments -A -l llm-d.ai/component=modelservice -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
    local lws=$(kubectl get leaderworkersets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
    
    if [ -n "$deployments" ]; then
        echo "$deployments"
    elif [ -n "$lws" ]; then
        echo "$lws"
    else
        echo "None"
    fi
}

# Function to detect accelerator type
detect_accelerator() {
    echo -e "${YELLOW}Detecting accelerator type...${NC}"
    
    local gpu_info=$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.capacity.nvidia\.com/gpu}{" "}{.metadata.labels.accelerator}{"\n"}{end}' 2>/dev/null | grep -v "^$" | head -1)
    local node_labels=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.accelerator}{"\n"}{end}' 2>/dev/null | grep -v "^$" | head -1)
    
    if echo "$node_labels" | grep -qi "l40s"; then
        echo "L40S"
    elif echo "$node_labels" | grep -qi "a100"; then
        echo "A100"
    elif echo "$node_labels" | grep -qi "h100"; then
        echo "H100"
    elif echo "$node_labels" | grep -qi "intel"; then
        echo "Intel-Max-1550"
    else
        echo "Unknown"
    fi
}

# Function to detect model ID
detect_model_id() {
    echo -e "${YELLOW}Detecting model ID...${NC}"
    
    local model_id=$(kubectl get deployments -A -l llm-d.ai/component=modelservice -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].env[?(@.name=="MODEL_ID")].value}{"\n"}{end}' 2>/dev/null | head -1)
    
    if [ -n "$model_id" ]; then
        echo "$model_id"
    else
        echo "Unknown"
    fi
}

# Function to detect Prometheus
detect_prometheus() {
    echo -e "${YELLOW}Detecting Prometheus installation...${NC}"
    
    # Check for OpenShift Prometheus
    if kubectl get svc -n openshift-monitoring thanos-querier &>/dev/null; then
        echo "openshift-monitoring/thanos-querier"
        return
    fi
    
    # Check for standard Prometheus
    local prom=$(kubectl get svc -A -l app.kubernetes.io/name=prometheus -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1)
    
    if [ -n "$prom" ]; then
        echo "$prom"
    else
        echo "Not found"
    fi
}

# Function to detect monitoring namespace
detect_monitoring_namespace() {
    echo -e "${YELLOW}Detecting monitoring namespace...${NC}"
    
    if kubectl get namespace openshift-user-workload-monitoring &>/dev/null; then
        echo "openshift-user-workload-monitoring"
    elif kubectl get namespace llm-d-monitoring &>/dev/null; then
        echo "llm-d-monitoring"
    else
        echo "Not found"
    fi
}

# Main detection
echo -e "${GREEN}Step 1: Auto-detecting cluster configuration...${NC}"
echo ""

PLATFORM=$(detect_platform)
DEPLOYMENTS=$(detect_deployments)
ACCELERATOR=$(detect_accelerator)
MODEL_ID=$(detect_model_id)
PROMETHEUS=$(detect_prometheus)
MON_NS=$(detect_monitoring_namespace)

# Present detected information
echo -e "${BLUE}=== Detected Configuration ===${NC}"
echo -e "Platform:              ${GREEN}${PLATFORM}${NC}"
echo -e "Existing Deployments:  ${GREEN}${DEPLOYMENTS}${NC}"
echo -e "Accelerator Type:      ${GREEN}${ACCELERATOR}${NC}"
echo -e "Model ID:              ${GREEN}${MODEL_ID}${NC}"
echo -e "Prometheus:            ${GREEN}${PROMETHEUS}${NC}"
echo -e "Monitoring Namespace:  ${GREEN}${MON_NS}${NC}"
echo ""

# Ask for confirmation (skip in non-interactive mode)
if [ "$NON_INTERACTIVE" = "true" ]; then
    echo -e "${GREEN}Non-interactive mode - using detected values${NC}"
    confirm="y"
else
    read -p "Is this information correct? (y/n): " confirm
fi

if [[ ! $confirm =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Please provide corrections:${NC}"
    
    if [ "$PLATFORM" = "Other Kubernetes" ]; then
        read -p "Platform (OpenShift/GKE/Kind/Other): " PLATFORM
    fi
    
    if [ "$ACCELERATOR" = "Unknown" ]; then
        read -p "Accelerator type (L40S/A100/H100/Intel-Max-1550): " ACCELERATOR
    fi
    
    if [ "$MODEL_ID" = "Unknown" ]; then
        read -p "Model ID (e.g., Qwen/Qwen3-0.6B): " MODEL_ID
    fi
fi

# Ask for target namespace (use default in non-interactive mode)
if [ "$NON_INTERACTIVE" = "true" ]; then
    NAMESPACE="${NAMESPACE:-$DEFAULT_NAMESPACE}"
    echo -e "${GREEN}Using namespace: ${NAMESPACE}${NC}"
else
    read -p "Target namespace for WVA installation [${DEFAULT_NAMESPACE}]: " NAMESPACE
    NAMESPACE=${NAMESPACE:-$DEFAULT_NAMESPACE}
fi

# Determine installation mode
if [ "$DEPLOYMENTS" = "None" ]; then
    INSTALL_MODE="full"
    echo -e "${YELLOW}No existing deployment found. Will install full llm-d stack with WVA.${NC}"
else
    if [ "$NON_INTERACTIVE" = "true" ]; then
        INSTALL_MODE="${INSTALL_MODE:-wva-only}"
        echo -e "${GREEN}Using installation mode: ${INSTALL_MODE}${NC}"
    else
        read -p "Install full stack or WVA-only? (full/wva-only) [wva-only]: " INSTALL_MODE
        INSTALL_MODE=${INSTALL_MODE:-wva-only}
    fi
fi

echo ""
echo -e "${GREEN}Step 2: Installing WVA CRDs...${NC}"
echo -e "${YELLOW}Note: WVA v0.5.1 requires scaleTargetRef field in VariantAutoscaling resources${NC}"
kubectl apply -f https://raw.githubusercontent.com/llm-d-incubation/workload-variant-autoscaler/${WVA_VERSION}/charts/workload-variant-autoscaler/crds/llmd.ai_variantautoscalings.yaml

echo ""
echo -e "${GREEN}Step 3: Creating namespace...${NC}"
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Platform-specific configuration
echo ""
echo -e "${GREEN}Step 4: Configuring platform-specific settings...${NC}"

case "$PLATFORM" in
    "OpenShift")
        echo "Configuring for OpenShift..."
        kubectl label namespace "${NAMESPACE}" openshift.io/user-monitoring=true --overwrite
        PROM_URL="https://thanos-querier.openshift-monitoring.svc.cluster.local:9091"
        MON_NS="openshift-user-workload-monitoring"
        ;;
    "GKE")
        echo "Configuring for GKE..."
        if [ "$PROMETHEUS" = "Not found" ]; then
            echo "Installing in-cluster Prometheus..."
            helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
            helm repo update
            helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n llm-d-monitoring --create-namespace
            MON_NS="llm-d-monitoring"
        fi
        PROM_URL="http://llmd-kube-prometheus-stack-prometheus.${MON_NS}.svc.cluster.local:9090"
        ;;
    "Kind")
        echo "Configuring for Kind..."
        if [ "$PROMETHEUS" = "Not found" ]; then
            echo "Installing Prometheus with TLS..."
            MON_NS="llm-d-monitoring"
            helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
            helm repo update
            helm install llmd prometheus-community/kube-prometheus-stack -n ${MON_NS} --create-namespace
            
            # Configure TLS
            echo "Configuring TLS for Prometheus..."
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout ${TMPDIR:-/tmp}/prometheus-tls.key -out ${TMPDIR:-/tmp}/prometheus-tls.crt -days 365 \
                -subj "/CN=prometheus" \
                -addext "subjectAltName=DNS:llmd-kube-prometheus-stack-prometheus.${MON_NS}.svc.cluster.local,DNS:llmd-kube-prometheus-stack-prometheus.${MON_NS}.svc,DNS:prometheus,DNS:localhost"
            
            kubectl create secret tls prometheus-web-tls \
                --cert=${TMPDIR:-/tmp}/prometheus-tls.crt \
                --key=${TMPDIR:-/tmp}/prometheus-tls.key \
                -n ${MON_NS} --dry-run=client -o yaml | kubectl apply -f -
            
            helm upgrade llmd prometheus-community/kube-prometheus-stack -n ${MON_NS} \
                --set prometheus.prometheusSpec.web.tlsConfig.cert.secret.name=prometheus-web-tls \
                --set prometheus.prometheusSpec.web.tlsConfig.cert.secret.key=tls.crt \
                --set prometheus.prometheusSpec.web.tlsConfig.keySecret.name=prometheus-web-tls \
                --set prometheus.prometheusSpec.web.tlsConfig.keySecret.key=tls.key \
                --reuse-values
        fi
        PROM_URL="https://llmd-kube-prometheus-stack-prometheus.${MON_NS}.svc.cluster.local:9090"
        ;;
    *)
        echo "Configuring for generic Kubernetes..."
        PROM_URL="http://prometheus.${MON_NS}.svc.cluster.local:9090"
        ;;
esac

echo ""
echo -e "${GREEN}Step 5: Locating workload-autoscaling configuration...${NC}"

# Function to find llm-d repository
find_llmd_repo() {
    # Check LLMD_PATH environment variable first
    if [ -n "$LLMD_PATH" ] && [ -d "$LLMD_PATH/guides/workload-autoscaling" ]; then
        echo "$LLMD_PATH"
        return 0
    fi
    
    # Check if current directory is llm-d repository
    if [ -d "guides/workload-autoscaling" ]; then
        echo "$(pwd)"
        return 0
    fi
    
    # Check parent directory
    if [ -d "../guides/workload-autoscaling" ]; then
        echo "$(cd .. && pwd)"
        return 0
    fi
    
    return 1
}

# Try to find llm-d repository
LLMD_REPO_PATH=$(find_llmd_repo)

if [ -z "$LLMD_REPO_PATH" ]; then
    echo -e "${YELLOW}Could not find guides/workload-autoscaling directory.${NC}"
    echo ""
    echo "Options:"
    echo "  1. Provide path to llm-d repository"
    echo "  2. Download files from GitHub"
    echo ""
    
    if [ "$NON_INTERACTIVE" = "true" ]; then
        echo -e "${GREEN}Non-interactive mode - downloading from GitHub${NC}"
        USE_GITHUB="y"
    else
        read -p "Download from GitHub? (y/n): " USE_GITHUB
    fi
    
    if [[ $USE_GITHUB =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Downloading workload-autoscaling files from GitHub...${NC}"
        WORK_DIR="${TMPDIR:-/tmp}/llm-d-workload-autoscaling-$$"
        mkdir -p "$WORK_DIR"
        
        # Download necessary files
        echo "Downloading helmfile.yaml.gotmpl..."
        curl -sSL -o "$WORK_DIR/helmfile.yaml.gotmpl" \
            "https://raw.githubusercontent.com/llm-d/llm-d/main/guides/workload-autoscaling/helmfile.yaml.gotmpl"
        
        echo "Downloading values files..."
        mkdir -p "$WORK_DIR/workload-autoscaling"
        curl -sSL -o "$WORK_DIR/workload-autoscaling/values.yaml" \
            "https://raw.githubusercontent.com/llm-d/llm-d/main/guides/workload-autoscaling/workload-autoscaling/values.yaml"
        
        mkdir -p "$WORK_DIR/gaie-workload-autoscaling"
        curl -sSL -o "$WORK_DIR/gaie-workload-autoscaling/values.yaml" \
            "https://raw.githubusercontent.com/llm-d/llm-d/main/guides/workload-autoscaling/gaie-workload-autoscaling/values.yaml"
        
        mkdir -p "$WORK_DIR/ms-workload-autoscaling"
        curl -sSL -o "$WORK_DIR/ms-workload-autoscaling/values.yaml" \
            "https://raw.githubusercontent.com/llm-d/llm-d/main/guides/workload-autoscaling/ms-workload-autoscaling/values.yaml"
        
        LLMD_REPO_PATH="$WORK_DIR"
        echo -e "${GREEN}Files downloaded to: ${WORK_DIR}${NC}"
    else
        if [ "$NON_INTERACTIVE" = "true" ]; then
            echo -e "${RED}Error: LLMD_PATH not set and guides/workload-autoscaling not found${NC}"
            echo "Please set LLMD_PATH environment variable or run from llm-d repository"
            exit 1
        fi
        
        read -p "Enter path to llm-d repository: " USER_LLMD_PATH
        if [ -d "$USER_LLMD_PATH/guides/workload-autoscaling" ]; then
            LLMD_REPO_PATH="$USER_LLMD_PATH"
        else
            echo -e "${RED}Error: guides/workload-autoscaling not found in $USER_LLMD_PATH${NC}"
            exit 1
        fi
    fi
fi

echo -e "${GREEN}Using workload-autoscaling from: ${LLMD_REPO_PATH}${NC}"
cd "$LLMD_REPO_PATH/guides/workload-autoscaling"

# Update values file (this would need actual sed/yq commands based on detected values)
echo "Updating workload-autoscaling/values.yaml with detected configuration..."
echo "  - Accelerator: ${ACCELERATOR}"
echo "  - Model ID: ${MODEL_ID}"
echo "  - Prometheus URL: ${PROM_URL}"

# Deploy based on mode
if [ "$INSTALL_MODE" = "full" ]; then
    echo "Installing full llm-d stack with WVA..."
    helmfile apply -n ${NAMESPACE}
else
    echo "Installing WVA only..."
    export LLMD_NAMESPACE=$(echo "$DEPLOYMENTS" | cut -d'/' -f1 | head -1)
    export LLMD_RELEASE_NAME_POSTFIX="inference-scheduling"
    helmfile apply -e wva-only -n ${NAMESPACE}
fi

# Cleanup temporary directory if we downloaded files
if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    echo -e "${YELLOW}Cleaning up temporary files...${NC}"
    cd - > /dev/null
    rm -rf "$WORK_DIR"
fi

echo ""
echo -e "${GREEN}Step 6: Installing Prometheus Adapter...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

curl -o ${TMPDIR:-/tmp}/prometheus-adapter-values.yaml \
    https://raw.githubusercontent.com/llm-d-incubation/workload-variant-autoscaler/${WVA_VERSION}/config/samples/prometheus-adapter-values.yaml

# Update Prometheus URL in adapter values
sed -i.bak "s|url:.*|url: ${PROM_URL}|" ${TMPDIR:-/tmp}/prometheus-adapter-values.yaml

helm upgrade -i prometheus-adapter prometheus-community/prometheus-adapter \
    --version 5.2.0 -n ${MON_NS} --create-namespace -f ${TMPDIR:-/tmp}/prometheus-adapter-values.yaml

echo ""
echo -e "${GREEN}Step 7: Verifying installation...${NC}"
sleep 10

echo "Checking WVA pods..."
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=workload-variant-autoscaler

echo ""
echo "Checking Prometheus Adapter..."
kubectl get pods -n ${MON_NS} -l app.kubernetes.io/name=prometheus-adapter

echo ""
echo "Checking HPA..."
kubectl get hpa -n ${NAMESPACE}

echo ""
echo "Checking VariantAutoscaling resources..."
kubectl get variantautoscalings -n ${NAMESPACE}

echo ""
echo "Checking metrics..."
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/${NAMESPACE}/inferno_desired_replicas" | jq . || echo "Metrics not yet available (may take a few minutes)"

echo ""
echo -e "${GREEN}=== WVA Setup Complete! ===${NC}"
echo ""
echo -e "${BLUE}Configuration Summary:${NC}"
echo -e "  Platform:    ${GREEN}${PLATFORM}${NC}"
echo -e "  Namespace:   ${GREEN}${NAMESPACE}${NC}"
echo -e "  Model ID:    ${GREEN}${MODEL_ID}${NC}"
echo -e "  Accelerator: ${GREEN}${ACCELERATOR}${NC}"
echo -e "  Mode:        ${GREEN}${INSTALL_MODE}${NC}"
echo ""
echo -e "${YELLOW}WVA will now automatically scale your deployment based on saturation metrics.${NC}"
echo ""
echo "Monitor with:"
echo "  kubectl get hpa -n ${NAMESPACE}"
echo "  kubectl get variantautoscalings -n ${NAMESPACE}"
echo ""
echo "For more details, see: guides/workload-autoscaling/README.md"


