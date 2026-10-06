#!/usr/bin/env bash
# Prove the environment contract holds — identically, in every environment.
#
# The five assertions in docs/workshop/environments.md §2. If this exits 0, every
# make target downstream (agent, health, chaos, eval, prove) is safe to run, and
# no lab instruction needs to know which environment it is in.
set -uo pipefail

NAMESPACE="${NAMESPACE:-agentic-ops}"
PASS=0; FAIL=0

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$1"; }

echo ""
echo "Environment contract — namespace '${NAMESPACE}'"
echo ""

# --- 1. a working context ----------------------------------------------------
CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
if [[ -n "${CONTEXT}" ]] && kubectl version -o json >/dev/null 2>&1; then
  ok "context reachable: ${CONTEXT}"
else
  bad "no reachable cluster (context: ${CONTEXT:-none})"
  note "run: make env-up ENV=codespaces|k3d|byo"
  echo ""; exit 1
fi

# --- 2. the namespace exists and is ours -------------------------------------
OWNED="$(kubectl get ns "${NAMESPACE}" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
if [[ "${OWNED}" == "agentic-cloud-ops" ]]; then
  ok "namespace '${NAMESPACE}' exists and is labelled as ours"
else
  bad "namespace '${NAMESPACE}' missing or not created by this workshop"
fi

# --- 3. the RBAC ladder ------------------------------------------------------
for sa in agent-ro agent-ns agent-harden; do
  if kubectl -n "${NAMESPACE}" get sa "${sa}" >/dev/null 2>&1; then
    ok "service account ${sa}"
  else
    bad "service account ${sa} missing"
  fi
done

# The rung that carries the teaching point: agent-harden must be able to patch
# a deployment, and must NOT be able to delete one. Assert both directions —
# a guardrail nobody tests is decoration.
AS="system:serviceaccount:${NAMESPACE}:agent-harden"
if kubectl auth can-i patch deployments --as="${AS}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  ok "agent-harden CAN patch deployments"
else
  bad "agent-harden cannot patch deployments — Lab 2 will not work"
fi
if kubectl auth can-i delete deployments --as="${AS}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  bad "agent-harden CAN delete deployments — the ladder is broken"
else
  ok "agent-harden CANNOT delete deployments (the delete verb is absent)"
fi

# No agent service account may hold cluster-scoped power. This is the assertion
# that makes bring-your-own-cluster defensible.
LEAKED=0
for sa in agent-ro agent-ns agent-harden agent-admin; do
  if kubectl auth can-i list nodes --as="system:serviceaccount:${NAMESPACE}:${sa}" >/dev/null 2>&1; then
    bad "${sa} has cluster-scoped access (can list nodes)"
    LEAKED=1
  fi
done
[[ "${LEAKED}" -eq 0 ]] && ok "no agent service account has cluster-scoped access"

# --- 4. the workload ---------------------------------------------------------
for d in shopfront worker; do
  READY="$(kubectl -n "${NAMESPACE}" get deploy "${d}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  if [[ -n "${READY}" && "${READY}" -gt 0 ]]; then
    ok "deployment ${d} has ${READY} ready replica(s)"
  else
    bad "deployment ${d} not ready"
  fi
done

# --- 5. environment capabilities ---------------------------------------------
if kubectl auth can-i get nodes >/dev/null 2>&1; then
  note ""
  note "cluster-scoped chaos scenarios available (dns-mess, node-pressure)"
else
  note ""
  note "namespace-scoped only: dns-mess and node-pressure will be skipped"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  printf '\033[32m%s checks passed. The contract holds.\033[0m\n\n' "${PASS}"
  exit 0
fi
printf '\033[31m%s passed, %s failed.\033[0m\n' "${PASS}" "${FAIL}"
printf 'Try: make env-up ENV=<your environment>\n\n'
exit 1
