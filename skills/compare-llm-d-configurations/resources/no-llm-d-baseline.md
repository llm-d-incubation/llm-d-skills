# no-llm-d Baseline Configuration Setup

This procedure is used when deploying a baseline configuration (one that uses direct service cluster IP instead of llm-d scheduling).
Only if the run is labeled as "baseline" or the user indicates it's a baseline configuration. It assumes a stack is already deployed.

## Steps

1. **Create or verify baseline service**:

   Check if the service exists:
   ```bash
   kubectl get svc llm-d-baseline-model-server -n $NAMESPACE
   ```

   If the service does not exist, inform the user that you will create it, then apply the baseline service YAML in the namespace:
   ```bash
   cat <<EOF | kubectl apply -n $NAMESPACE -f -
   apiVersion: v1
   kind: Service
   metadata:
     name: llm-d-baseline-model-server
   spec:
     selector:
       llm-d.ai/inference-serving: "true"
     ports:
     - name: http
       protocol: TCP
       port: 8000
       targetPort: 8000
     type: ClusterIP
   EOF
   ```

2. **Verify the service has endpoints**:
   ```bash
   kubectl get endpoints llm-d-baseline-model-server -n $NAMESPACE
   ```

   If no endpoints exist, check the running pod labels:
   ```bash
   kubectl get pods -n $NAMESPACE -l llm-d.ai/inference-serving=true
   ```

   If no pods match, list all pods and their labels to find the correct selector:
   ```bash
   kubectl get pods -n $NAMESPACE --show-labels
   ```

   Inform the user which label should be used and update the baseline service selector accordingly.

3. **Set baseline base_url**: When configuring the benchmark (in steps 1.2 or 2.2), ensure the config.yaml uses:
   ```yaml
   base_url: http://llm-d-baseline-model-server.<namespace>.svc.cluster.local:8000
   ```
