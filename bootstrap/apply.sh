#!/usr/bin/env bash
# Apply the base kustomization into $NAMESPACE. Environment-agnostic by design:
# whatever bootstrap/env/*.sh did to produce a kubeconfig, everything from here
# down is identical.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="${NAMESPACE:-agentic-ops}"

# The base carries `agentic-ops` as a literal placeholder. Rewriting it here
# keeps the base free of templating tools that may not be installed.
source bootstrap/lib.sh
render_base | kubectl apply -f -

# A timeout alone says nothing. Say why: a node under pressure, or the pods' own events.
explain() {
  echo "" >&2
  echo "The workload did not come up. What the cluster says:" >&2
  local taints
  taints="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .spec.taints[*]}{.key}{" "}{end}{"\n"}{end}' \
    | grep -E 'pressure|not-ready|unreachable' || true)"
  if [ -n "${taints}" ]; then
    echo "${taints}" | sed 's/^/  node /' >&2
    if echo "${taints}" | grep -q disk-pressure; then
      echo "" >&2
      echo "Docker is out of disk. Free some (docker system prune), then: make cluster-down && make cluster-up" >&2
    fi
  else
    kubectl -n "${NAMESPACE}" get pods >&2 || true
    kubectl -n "${NAMESPACE}" get events --field-selector type=Warning \
      --sort-by=.lastTimestamp 2>/dev/null | tail -n 5 >&2 || true
  fi
  exit 1
}

echo "==> waiting for the workload to settle"
kubectl -n "${NAMESPACE}" rollout status deploy/shopfront --timeout=120s || explain
kubectl -n "${NAMESPACE}" rollout status deploy/worker    --timeout=120s || explain
