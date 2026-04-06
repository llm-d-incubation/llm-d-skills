# Troubleshooting Autoscaling

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