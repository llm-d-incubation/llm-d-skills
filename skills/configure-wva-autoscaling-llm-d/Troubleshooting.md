# WVA Configuration Troubleshooting

Quick reference for common WVA configuration issues. For detailed troubleshooting, see the official WVA troubleshooting guide at `${WVA_REPO_PATH}/docs/user-guide/troubleshooting.md`.

## Quick Diagnostics

```bash
# Check VariantAutoscaling status
kubectl get variantautoscaling -n <namespace>

# Check WVA controller logs
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler -f

# Check HPA status
kubectl get hpa -n <namespace>

# Verify metrics are available
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/<namespace>/wva_desired_replicas" | jq
```

## Common Issues

### 1. METRICSREADY: False

**Symptoms**: VariantAutoscaling shows `METRICSREADY: False`

**Common Causes**:
- Prometheus hasn't scraped metrics yet (wait 1-2 minutes after deployment)
- No traffic to model (metrics are zero)
- PodMonitor not configured or not matching pod labels
- Prometheus connection issues

**Solutions**:

```bash
# Wait for Prometheus scrape interval
sleep 120 && kubectl get variantautoscaling -n <namespace>

# Send test traffic to generate metrics
kubectl port-forward -n <namespace> svc/<gateway-service> 8080:80 &
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "<model-id>", "messages": [{"role": "user", "content": "test"}]}'

# Check if pods expose metrics
kubectl exec -n <namespace> <pod-name> -- curl -s localhost:8000/metrics | grep vllm

# Verify PodMonitor exists and matches labels
kubectl get podmonitor -n <namespace>
kubectl get pods -n <namespace> --show-labels
```

### 2. WVA Not Scaling

**Symptoms**: Replicas don't change despite load

**Common Causes**:
- Saturation thresholds never reached (too high)
- HPA stabilization window too long
- Mismatched variant_name label in HPA
- WVA controller not running

**Solutions**:

```bash
# Check current saturation levels
kubectl get variantautoscaling -n <namespace> -o yaml | grep -A 5 status

# Check WVA scaling decisions
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler | grep "desired replicas"

# Verify HPA is reading metrics
kubectl describe hpa -n <namespace>

# Check if variant_name matches
kubectl get hpa -n <namespace> -o yaml | grep variant_name
kubectl get variantautoscaling -n <namespace> -o yaml | grep "name:"
```

**Configuration Fixes**:
- Lower saturation thresholds (e.g., kvCacheThreshold: 0.70)
- Reduce HPA stabilization windows
- Ensure HPA variant_name label matches VariantAutoscaling name

### 3. Frequent Scaling (Flapping)

**Symptoms**: Replicas constantly scaling up and down

**Common Causes**:
- Thresholds too sensitive
- HPA stabilization window too short
- Misaligned WVA and EPP thresholds
- Insufficient spare capacity triggers

**Solutions**:

```bash
# Check scaling events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep -i scale

# Monitor saturation over time
watch -n 5 'kubectl get variantautoscaling -n <namespace>'
```

**Configuration Fixes**:
- Increase HPA stabilization windows (300s+ for scale-down)
- Increase saturation thresholds (e.g., kvCacheThreshold: 0.85)
- Align WVA and EPP thresholds
- Adjust spare capacity triggers (lower kvSpareTrigger)

### 4. Wrong Deployment Target

**Symptoms**: VariantAutoscaling exists but doesn't affect deployment

**Common Causes**:
- scaleTargetRef points to non-existent deployment
- Deployment name changed but VariantAutoscaling not updated
- Wrong namespace

**Solutions**:

```bash
# Verify deployment exists
kubectl get deployment -n <namespace> <deployment-name>

# Check VariantAutoscaling target
kubectl get variantautoscaling -n <namespace> -o yaml | grep -A 3 scaleTargetRef

# Update if needed
kubectl edit variantautoscaling -n <namespace> <name>
```

### 5. Prometheus Connection Issues

**Symptoms**: WVA controller logs show Prometheus errors

**Common Causes**:
- HTTPS required but Prometheus only has HTTP
- CA certificate issues
- Prometheus not accessible from WVA namespace
- Wrong Prometheus URL

**Solutions**:

```bash
# Check WVA Prometheus configuration
kubectl get configmap -n workload-variant-autoscaler-system \
  wva-variantautoscaling-config -o yaml | grep PROMETHEUS

# Test Prometheus connectivity from WVA pod
kubectl exec -n workload-variant-autoscaler-system \
  <wva-controller-pod> -- curl -k <prometheus-url>/api/v1/query?query=up

# For OpenShift, use Thanos Querier
# Update WVA config to use: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
```

### 6. Scale-to-Zero Not Working

**Symptoms**: Replicas don't scale to zero despite idle period

**Common Causes**:
- HPAScaleToZero feature gate not enabled
- HPA minReplicas not set to 0
- Scale-to-zero not enabled in WVA config
- Retention period not elapsed

**Solutions**:

```bash
# Check HPA minReplicas
kubectl get hpa -n <namespace> -o yaml | grep minReplicas

# Check scale-to-zero config
kubectl get configmap -n workload-variant-autoscaler-system \
  wva-model-scale-to-zero-config -o yaml

# Check WVA controller logs for scale-to-zero decisions
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler | grep "scale.*zero"
```

**Configuration Fixes**:
- Enable HPAScaleToZero feature gate in cluster
- Set HPA minReplicas: 0
- Enable scale-to-zero in WVA Helm values or ConfigMap
- Adjust retention period if needed

### 7. Multi-Variant Cost Optimization Not Working

**Symptoms**: WVA scales expensive variant instead of cheap one

**Common Causes**:
- variantCost not set or set incorrectly
- All variants have same cost
- Cheap variant at maxReplicas
- Model IDs don't match

**Solutions**:

```bash
# Check variant costs
kubectl get variantautoscaling -n <namespace> -o yaml | grep -A 2 variantCost

# Verify model IDs match
kubectl get variantautoscaling -n <namespace> -o yaml | grep modelID

# Check current replica counts
kubectl get variantautoscaling -n <namespace>
```

**Configuration Fixes**:
- Set different variantCost values (e.g., H100: "80.0", A100: "40.0")
- Ensure model IDs are identical across variants
- Increase maxReplicas on cheaper variant

## Threshold Tuning Guide

### Understanding Saturation Metrics

**KV Cache Utilization**: Percentage of KV cache memory used (0.0-1.0)
- 0.80 = 80% of KV cache filled
- Higher values = more memory pressure

**Queue Length**: Number of requests waiting in queue
- Higher values = more backlog

### Tuning Strategy

1. **Start with defaults** and monitor for 24 hours
2. **Observe saturation patterns** in Prometheus/Grafana
3. **Adjust based on behavior**:
   - Frequent saturation → Lower thresholds
   - Never saturated → Raise thresholds
   - Flapping → Increase stabilization windows

### Threshold Recommendations by Use Case

| Use Case | kvCacheThreshold | queueLengthThreshold | kvSpareTrigger | Stabilization |
|----------|------------------|----------------------|----------------|---------------|
| Low Latency | 0.70 | 3 | 0.15 | 60s up, 300s down |
| Balanced | 0.80 | 5 | 0.10 | 120s up, 300s down |
| Cost Optimized | 0.85 | 8 | 0.05 | 180s up, 600s down |
| Development | 0.75 | 5 | 0.10 | 60s up, 120s down |

## Alignment with Inference Scheduler (EPP)

**Critical**: WVA and EPP must use the same thresholds.

### Check EPP Configuration

```bash
# Get GAIE deployment values
kubectl get deployment -n <namespace> <gaie-deployment> -o yaml | grep -A 10 env

# Look for EPP threshold environment variables
# - KV_CACHE_THRESHOLD
# - QUEUE_LENGTH_THRESHOLD
```

### Update Both Together

When changing thresholds:
1. Update WVA saturation ConfigMap
2. Update EPP environment variables in GAIE deployment
3. Restart both controllers

```bash
# Update WVA ConfigMap
kubectl edit configmap -n workload-variant-autoscaler-system \
  wva-saturation-scaling-config

# Update GAIE deployment
kubectl set env deployment/<gaie-deployment> -n <namespace> \
  KV_CACHE_THRESHOLD=0.80 \
  QUEUE_LENGTH_THRESHOLD=5

# Restart WVA controller
kubectl rollout restart deployment -n workload-variant-autoscaler-system \
  workload-variant-autoscaler-controller-manager
```

## Getting Help

For issues not covered here:

1. **Check official docs**:
   - WVA Troubleshooting: `${WVA_REPO_PATH}/docs/user-guide/troubleshooting.md`
   - WVA Configuration: `${WVA_REPO_PATH}/docs/user-guide/configuration.md`
   - llm-d WVA Guide: `${LLMD_REPO_PATH}/guides/workload-autoscaling/README.wva.md`
2. **Review WVA logs**: Look for ERROR or WARN messages
3. **Check Prometheus metrics**: Verify vLLM metrics are being scraped
4. **Test with llm-d-benchmark**: Use benchmark templates to validate behavior
   - Templates: `deployments/*/benchmark-templates/` (guide.yaml, guidellm.yaml, sanity.yaml, shared_prefix.yaml)
5. **Community support**: Join llm-d Slack or GitHub discussions

## Useful Commands Reference

```bash
# Watch VariantAutoscaling status
watch -n 5 'kubectl get variantautoscaling -n <namespace>'

# Stream WVA controller logs
kubectl logs -n workload-variant-autoscaler-system \
  -l app.kubernetes.io/name=workload-variant-autoscaler -f

# Check all WVA resources
kubectl get variantautoscaling,hpa,podmonitor -n <namespace>

# View recent scaling events
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | grep -i scale | tail -20

# Check Prometheus metrics directly
kubectl port-forward -n <namespace> <pod-name> 8000:8000 &
curl -s localhost:8000/metrics | grep vllm_kv_cache_usage_perc

# Verify external metrics API
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1" | jq

# Check Prometheus Adapter
kubectl logs -n <monitoring-namespace> -l app.kubernetes.io/name=prometheus-adapter