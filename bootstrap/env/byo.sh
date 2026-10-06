#!/usr/bin/env bash
# Bring your own cluster.
#
# The most realistic option and the most dangerous one: we are about to give an
# agent write access and point it at infrastructure that already exists.
#
# The real protection is that every binding in bootstrap/base is a RoleBinding,
# scoped to one namespace. The checks below are seatbelts on top of that.
set -euo pipefail

NAMESPACE="${NAMESPACE:-agentic-ops}"
ACK="${I_UNDERSTAND_THIS_CLUSTER_IS_DISPOSABLE:-}"

fail() { echo "" >&2; echo "REFUSING: $*" >&2; echo "" >&2; exit 1; }

CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "${CONTEXT}" ]] || fail "no current kubectl context. Select one with 'kubectl config use-context'."

echo "==> context:   ${CONTEXT}"
echo "==> namespace: ${NAMESPACE}"
echo ""

# --- Guard 1: production-shaped context names --------------------------------
if [[ "${CONTEXT}" =~ (^|[^a-z])(prod|production|prd|live)([^a-z]|$) ]]; then
  fail "context '${CONTEXT}' looks like production. Not proceeding, whatever the flag says."
fi

# --- Guard 2: does this cluster look inhabited? -------------------------------
NODES="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
NS_COUNT="$(kubectl get ns --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "    ${NODES} node(s), ${NS_COUNT} namespace(s)"
if [[ "${NS_COUNT}" -gt 12 ]]; then
  echo "    warning: ${NS_COUNT} namespaces — this is a busy cluster." >&2
fi
if [[ "${CONTEXT}" =~ (eks|gke|aks|arn:aws|gke_) ]]; then
  echo "    warning: this looks like a managed cloud cluster." >&2
fi

# --- Guard 3: explicit, un-defaulted acknowledgement --------------------------
if [[ "${ACK}" != "yes" ]]; then
  cat >&2 <<MSG

This will create the namespace '${NAMESPACE}' on '${CONTEXT}' and deploy a
deliberately insecure workload into it. Labs 2 and 3 will then break things
inside that namespace on purpose.

Nothing outside '${NAMESPACE}' is touched: every binding is a RoleBinding, and
the agent service accounts have no cluster-scoped permissions at all.

Two of the chaos scenarios (dns-mess, node-pressure) are cluster-scoped and are
skipped automatically here.

If you are happy with that, re-run:

    make env-up ENV=byo I_UNDERSTAND_THIS_CLUSTER_IS_DISPOSABLE=yes

MSG
  exit 1
fi

# --- Guard 4: refuse to adopt an existing namespace ---------------------------
if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  OWNED="$(kubectl get ns "${NAMESPACE}" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
  if [[ "${OWNED}" != "agentic-cloud-ops" ]]; then
    fail "namespace '${NAMESPACE}' already exists and wasn't created by this workshop.
          Pick another: make env-up ENV=byo NAMESPACE=agentic-<yourhandle> ..."
  fi
  echo "    reusing the workshop namespace from an earlier run"
fi

# --- Guard 5: can we actually do the work? ------------------------------------
if ! kubectl auth can-i create namespace >/dev/null 2>&1; then
  fail "you cannot create namespaces on this cluster. Ask for the rights, or use ENV=k3d."
fi

echo ""
echo "==> guards passed"
