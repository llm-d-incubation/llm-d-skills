#!/bin/bash
# Lists the llm-d related resources of a namespace, grouped by how they are removed.
# Usage: inventory.sh <namespace> [guide]
#   guide   value of the llm-d.ai/guide label (the guide directory name, e.g. optimized-baseline);
#           when given, label-selected sections are narrowed to that guide.
# Read-only. Resource kinds whose CRDs are absent from the cluster are skipped silently.
set -uo pipefail

NS="${1:?usage: inventory.sh <namespace> [guide]}"
GUIDE="${2:-}"

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "ERROR: namespace '$NS' not found or cluster unreachable" >&2
  exit 1
fi

SEL=()
if [ -n "$GUIDE" ]; then
  SEL=(-l "llm-d.ai/guide=${GUIDE}")
fi
# ${SEL[@]+"${SEL[@]}"} expands to nothing when SEL is empty; a bare "${SEL[@]}" is an
# unbound-variable error under set -u on bash 3.2 (the macOS default).

section() { printf '\n== %s\n' "$1"; }

# get <kind> [kubectl args...]: print the table for <kind> when the kind exists and has objects.
get() {
  local kind="$1"; shift
  local out
  out=$(kubectl get "$kind" -n "$NS" "$@" 2>/dev/null) || return 0
  if [ -n "$out" ]; then
    echo "-- $kind"
    echo "$out"
  fi
}

section "Helm releases in $NS (removed with: helm uninstall <release> -n $NS)"
helm list -n "$NS" 2>/dev/null || echo "(helm not available or no releases)"
if command -v jq >/dev/null 2>&1; then
  ROUTER=$(helm list -n "$NS" -o json 2>/dev/null | jq -r '.[] | select(.chart | startswith("llm-d-router")) | .name' | tr '\n' ' ')
  [ -n "${ROUTER// }" ] && echo "llm-d router releases (chart llm-d-router-*): ${ROUTER}"
fi

section "Model server workloads (removed with the guide's cleanup.modelserver / kubectl delete -k <overlay>)"
get deployments ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide,llm-d.ai/role,llm-d.ai/engine-type
get statefulsets ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide,llm-d.ai/role
get disaggregatedsets.disaggregatedset.x-k8s.io ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide
get leaderworkersets.leaderworkerset.x-k8s.io -L llm-d.ai/guide,disaggregatedset.x-k8s.io/name
echo "-- pods by guide and role label"
kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.labels.llm-d\.ai/guide}{"\t"}{.metadata.labels.llm-d\.ai/role}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '{g=($1==""?"(no llm-d.ai/guide label)":$1); r=($2==""?"-":$2); c[g" role="r]++} END {for (k in c) printf "  %-50s %d pod(s)\n", k, c[k]}' | sort
echo "-- guide-labelled supporting objects"
get services ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide
get serviceaccounts ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide
get configmaps ${SEL[@]+"${SEL[@]}"} -L llm-d.ai/guide

section "Routing (InferencePool and chart-created HTTPRoute go with helm uninstall; Gateway is user-owned)"
get inferencepools.inference.networking.k8s.io
get inferenceobjectives
get httproutes.gateway.networking.k8s.io
get gateways.gateway.networking.k8s.io

section "Autoscaling objects (part of an autoscaling guide, not of the router release)"
get scaledobjects.keda.sh
get triggerauthentications.keda.sh
get horizontalpodautoscalers

section "Monitoring objects (removed with: kubectl delete -k guides/recipes/modelserver/components/monitoring[-pd])"
get podmonitors.monitoring.coreos.com
get servicemonitors.monitoring.coreos.com
get podmonitorings.monitoring.googleapis.com
get prometheusrules.monitoring.coreos.com

section "DRA claims and jobs"
get resourceclaimtemplates.resource.k8s.io
get resourceclaims.resource.k8s.io
get jobs

section "Kept unless the user asks (storage, credentials)"
get persistentvolumeclaims
get secrets -o custom-columns=NAME:.metadata.name,TYPE:.type

section "Cluster-scoped objects named after the namespace or guide (informational; removed only by the guide's cleanup with explicit confirmation)"
PATTERN="(^|/)(${NS}-|${GUIDE:-__none__}-)"
kubectl get clusterrolebindings,clusterroles -o name 2>/dev/null | grep -E "$PATTERN" || echo "(none matching)"
