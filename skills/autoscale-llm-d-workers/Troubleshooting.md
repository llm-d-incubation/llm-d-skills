# Troubleshooting Autoscaling

## Issue: WVA Controller Requires HTTPS for Prometheus

**Symptoms:**
- WVA controller pods crash-looping with error: "HTTPS is required - URL must use https:// scheme"
- Controller logs show: "TLS configuration validation failed"

**Root Cause:**
- WVA v0.5.1 requires HTTPS connections to Prometheus
- Many Prometheus installations only expose HTTP on port 9090

**Solutions:**

### Option 1: Configure Prometheus with TLS (Recommended for Production)

For OpenShift with User Workload Monitoring:
```bash
# Use Thanos Querier which has TLS enabled
export PROMETHEUS_URL="https://thanos-querier.openshift-monitoring.svc.cluster.local:9091"
export PROMETHEUS_NAMESPACE="openshift-monitoring"
```

For standard Kubernetes with kube-prometheus-stack:
```bash
# Enable TLS in Prometheus values
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  --set prometheus.prometheusSpec.web.tlsConfig.cert.secret.name=prometheus-tls \
  --set prometheus.prometheusSpec.web.tlsConfig.cert.secret.key=tls.crt \
  --set prometheus.prometheusSpec.web.tlsConfig.keySecret.name=prometheus-tls \
  --set prometheus.prometheusSpec.web.tlsConfig.keySecret.key=tls.key
```

### Option 2: Use HPA + IGW Metrics Instead

If setting up Prometheus TLS is not feasible, use HPA with IGW metrics:
```bash
# Remove WVA
helm uninstall workload-variant-autoscaler -n ${NAMESPACE}

# Follow HPA setup guide
bash .claude/skills/autoscale-llm-d-workers/scripts/create-hpa.sh \
  ${NAMESPACE} ${DEPLOYMENT_NAME} ${INFERENCEPOOL_NAME}
```

### Option 3: Deploy Prometheus with TLS in Your Namespace

```bash
# Install Prometheus with TLS in a dedicated namespace
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n llm-d-monitoring --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

## Issue: Prometheus Service Not Found

**Symptoms:**
- WVA controller logs show: "dial tcp: lookup ... no such host"
- Auto-detection script cannot find Prometheus

**Root Cause:**
- Prometheus is in a different namespace than expected
- Prometheus service has a non-standard name
- Prometheus is not installed

**Solution:**
```bash
# Find Prometheus services in cluster
kubectl get svc -A | grep prometheus

# Set explicit Prometheus URL
export PROMETHEUS_URL="http://your-prometheus-service.your-namespace.svc.cluster.local:9090"
export PROMETHEUS_NAMESPACE="your-namespace"

# Re-run deployment
bash .claude/skills/autoscale-llm-d-workers/scripts/deploy-wva-helm.sh ${NAMESPACE}
```

## Issue: WVA Controller Not Scaling

**Symptoms:**
- VariantAutoscaling resource created but replicas don't change
- Controller logs show no activity

**Root Cause:**
- RBAC permissions missing
- Controller can't find target pods
- Metrics not available from pods

**Solution:**
```bash
# Fix RBAC
bash skills/autoscale-llm-d-workers/scripts/fix-wva-rbac.sh ${NAMESPACE}

# Fix pod labels
bash skills/autoscale-llm-d-workers/scripts/fix-controller-instance-labels.sh ${NAMESPACE}

# Check controller logs
kubectl logs -n ${NAMESPACE} -l app=wva-controller
```

## Issue: HPA Shows Unknown Metrics

**Symptoms:**
- HPA status shows `<unknown>` for custom metrics
- Scaling doesn't occur

**Root Cause:**
- Prometheus Adapter not configured correctly
- Metrics not being scraped by Prometheus
- Adapter rules don't match metric names

**Solution:**
```bash
# Check if metrics are available
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1

# Check Prometheus Adapter logs
kubectl logs -n monitoring -l app=prometheus-adapter

# Verify Prometheus is scraping IGW
# Check Prometheus UI for igw_queue_depth and igw_running_requests
```

## Issue: Wrong Deployment Name in VariantAutoscaling

**Symptoms:**
- VariantAutoscaling resource exists but doesn't scale
- Controller logs show: "deployment not found"
- Metrics show "METRICSREADY: False"

**Root Cause:**
- VariantAutoscaling `scaleTargetRef` points to non-existent deployment
- Deployment name changed but VariantAutoscaling not updated
- Using wrong naming convention (e.g., `ms-pd-*` vs `ms-inference-scheduling-*`)

**Solution:**
```bash
# Find actual deployment name
kubectl get deployments -n ${NAMESPACE} | grep modelservice

# Delete old VariantAutoscaling
kubectl delete variantautoscaling -n ${NAMESPACE} --all

# Create new one with correct deployment name
bash .claude/skills/autoscale-llm-d-workers/scripts/create-variantautoscaling.sh \
  ${NAMESPACE} my-autoscaler ms-inference-scheduling-llm-d-modelservice
```

## Issue: Model ID Detection Fails

**Symptoms:**
- VariantAutoscaling created with wrong model ID
- Controller can't find metrics for the model
- Pods are not healthy so model query fails

**Root Cause:**
- Pods not ready when trying to detect model ID
- Model ID doesn't match what's actually running
- vLLM /v1/models endpoint not accessible

**Solution:**
```bash
# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=llm-d-modelservice -n ${NAMESPACE} --timeout=300s

# Manually query model ID
POD=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=llm-d-modelservice -o name | head -1)
kubectl exec -n ${NAMESPACE} $POD -- curl -s localhost:8000/v1/models | jq -r '.data[0].id'

# Set explicitly when deploying
export MODEL_ID="Qwen/Qwen3-32B"
bash .claude/skills/autoscale-llm-d-workers/scripts/deploy-wva-helm.sh ${NAMESPACE}
```

## Issue: Helm Installation Conflicts with Manual Resources

**Symptoms:**
- Helm install fails with: "exists and cannot be imported into the current release"
- Error mentions missing Helm labels/annotations
- Resources created manually before Helm install

**Root Cause:**
- Resources (ConfigMaps, ServiceAccounts, etc.) created manually
- Helm cannot adopt resources without proper labels
- Previous failed installation left orphaned resources

**Solution:**
```bash
# Clean up manually created resources
kubectl delete serviceaccount,role,rolebinding,configmap -n ${NAMESPACE} \
  -l app.kubernetes.io/name=workload-variant-autoscaler 2>/dev/null || true

# Delete specific resources if needed
kubectl delete configmap workload-variant-autoscaler-variantautoscaling-config -n ${NAMESPACE}
kubectl delete configmap workload-variant-autoscaler-wva-saturation-scaling-config -n ${NAMESPACE}
kubectl delete configmap workload-variant-autoscaler-service-classes-config -n ${NAMESPACE}

# Delete cluster-level resources
kubectl delete clusterrolebinding workload-variant-autoscaler-${NAMESPACE}-monitoring 2>/dev/null || true

# Retry Helm installation
bash .claude/skills/autoscale-llm-d-workers/scripts/deploy-wva-helm.sh ${NAMESPACE}
```

## Issue: Autoscaling Too Aggressive

**Symptoms:**
- Frequent scale up/down cycles
- Pods constantly being created/terminated
- Performance instability

**Root Cause:**
- Thresholds too sensitive
- Cooldown periods too short
- Min/max replicas not set appropriately

**Solution:**
```bash
# For WVA: Adjust saturation thresholds in VariantAutoscaling
kubectl edit variantautoscaling <name> -n ${NAMESPACE}

# For HPA: Adjust target values and behavior
kubectl edit hpa <name> -n ${NAMESPACE}

# Increase cooldown periods
# Set more conservative min/max replicas