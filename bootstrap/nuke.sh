#!/usr/bin/env bash
# Delete exactly the workshop namespace, and say what will go before it goes.
#
# Deliberately precise: on a bring-your-own cluster this is the only destructive
# command in the workshop, and it must never reach past its own namespace.
set -euo pipefail

NAMESPACE="${NAMESPACE:-agentic-ops}"

if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "namespace '${NAMESPACE}' does not exist. Nothing to do."
  exit 0
fi

OWNED="$(kubectl get ns "${NAMESPACE}" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
if [[ "${OWNED}" != "agentic-cloud-ops" ]]; then
  echo "REFUSING: '${NAMESPACE}' was not created by this workshop." >&2
  exit 1
fi

echo ""
echo "About to delete namespace '${NAMESPACE}' on context '$(kubectl config current-context)',"
echo "and everything in it:"
echo ""
kubectl -n "${NAMESPACE}" get all,networkpolicies,serviceaccounts,roles,rolebindings \
  --no-headers 2>/dev/null | sed 's/^/    /' || true
echo ""

if [[ "${YES:-}" != "yes" ]]; then
  read -r -p "Type the namespace name to confirm: " CONFIRM
  [[ "${CONFIRM}" == "${NAMESPACE}" ]] || { echo "Aborted."; exit 1; }
fi

kubectl delete ns "${NAMESPACE}" --wait=true
echo "Done. Nothing outside '${NAMESPACE}' was touched."
