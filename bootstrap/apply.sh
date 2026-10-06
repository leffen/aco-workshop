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

echo "==> waiting for the workload to settle"
kubectl -n "${NAMESPACE}" rollout status deploy/shopfront --timeout=120s
kubectl -n "${NAMESPACE}" rollout status deploy/worker    --timeout=120s
