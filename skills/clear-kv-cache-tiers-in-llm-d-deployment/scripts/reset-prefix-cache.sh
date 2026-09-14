#!/bin/bash
# Resets the vLLM prefix cache on all pods in an llm-d deployment.
# Requires: NAMESPACE, VLLM_PORT (default 8000), and optionally LABEL_SELECTOR.
set -euo pipefail

NAMESPACE="${NAMESPACE:?NAMESPACE must be set}"
VLLM_PORT="${VLLM_PORT:-8000}"
LABEL_SELECTOR="${LABEL_SELECTOR:-app.kubernetes.io/component=vllm}"
RESET_RUNNING="${RESET_RUNNING_REQUESTS:-true}"
RESET_EXTERNAL="${RESET_EXTERNAL:-true}"

echo "=== Resetting vLLM prefix cache ==="
echo "Namespace:       $NAMESPACE"
echo "Label selector:  $LABEL_SELECTOR"
echo "Port:            $VLLM_PORT"
echo "Reset running:   $RESET_RUNNING"
echo "Reset external:  $RESET_EXTERNAL"
echo ""

POD_NAMES=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

if [ -z "$POD_NAMES" ]; then
  echo "ERROR: No running vLLM pods found with selector '$LABEL_SELECTOR' in namespace '$NAMESPACE'"
  echo ""
  echo "Trying broader search..."
  kubectl get pods -n "$NAMESPACE" -o wide
  exit 1
fi

POD_COUNT=$(echo "$POD_NAMES" | wc -w | tr -d ' ')
echo "Found $POD_COUNT vLLM pod(s)"
echo ""

RETRY_COUNT="${RESET_RETRY_COUNT:-3}"
RETRY_DELAY="${RESET_RETRY_DELAY:-2}"

SUCCESS=0
FAILED=0
FAILED_PODS=""

for POD in $POD_NAMES; do
  echo -n "Resetting $POD ... "

  EXEC_ERR=""
  RESPONSE=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
    curl -s -w "\n%{http_code}" -X POST \
    "http://localhost:${VLLM_PORT}/reset_prefix_cache?reset_running_requests=${RESET_RUNNING}&reset_external=${RESET_EXTERNAL}" \
    2>/dev/null) 2>&1 || EXEC_ERR="$?"

  if [ -n "$EXEC_ERR" ]; then
      echo "FAILED (kubectl exec error, exit code: $EXEC_ERR)"
      FAILED=$((FAILED + 1))
      FAILED_PODS="${FAILED_PODS} ${POD}"
      continue
  fi

  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" = "200" ]; then
    # vLLM >= 0.26.0 returns 200 with {"success": false} when blocks are still
    # held by in-flight offload transfers. Retry until success or limit reached.
    # No "success: false" in body (or empty body) means success — old vLLM returns empty or {"success": true}.
    ATTEMPT=0
    RESET_FAILED=false
    while [ -n "$BODY" ] && echo "$BODY" | grep -q '"success"[[:space:]]*:[[:space:]]*false'; do
      ATTEMPT=$((ATTEMPT + 1))
      if [ "$ATTEMPT" -gt "$RETRY_COUNT" ]; then
        echo "FAILED (success:false after $RETRY_COUNT retries — in-flight blocks still held)"
        RESET_FAILED=true
        break
      fi
      echo -n "(success:false, retry $ATTEMPT/$RETRY_COUNT) "
      sleep "$RETRY_DELAY"
      RESPONSE=$(kubectl exec -n "$NAMESPACE" "$POD" -- \
        curl -s -w "\n%{http_code}" -X POST \
        "http://localhost:${VLLM_PORT}/reset_prefix_cache?reset_running_requests=${RESET_RUNNING}&reset_external=${RESET_EXTERNAL}" \
        2>/dev/null) || true
      HTTP_CODE=$(echo "$RESPONSE" | tail -1)
      BODY=$(echo "$RESPONSE" | sed '$d')
      if [ "$HTTP_CODE" != "200" ]; then
        echo "FAILED (HTTP $HTTP_CODE on retry $ATTEMPT)"
        RESET_FAILED=true
        break
      fi
    done
    if $RESET_FAILED; then
      FAILED=$((FAILED + 1))
      FAILED_PODS="${FAILED_PODS} ${POD}"
    else
      echo "OK"
      SUCCESS=$((SUCCESS + 1))
    fi
  elif [ "$HTTP_CODE" = "404" ]; then
    echo "FAILED (endpoint not found — is VLLM_SERVER_DEV_MODE=1 set?)"
    FAILED=$((FAILED + 1))
    FAILED_PODS="${FAILED_PODS} ${POD}"
  else
    echo "FAILED (HTTP $HTTP_CODE: $BODY)"
    FAILED=$((FAILED + 1))
    FAILED_PODS="${FAILED_PODS} ${POD}"
  fi
done

echo ""
echo "=== Results ==="
echo "Success: $SUCCESS / $POD_COUNT"
echo "Failed:  $FAILED / $POD_COUNT"

if [ $FAILED -gt 0 ]; then
  echo "Failed pods:$FAILED_PODS"
  exit 1
fi

echo ""
echo "All vLLM pods cache cleared. Wait 2s before running benchmarks."
exit 0
