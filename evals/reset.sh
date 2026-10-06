#!/usr/bin/env bash
#
# Reset the namespace to a known-good baseline.
#
# THIS IS THE PIECE THAT DECIDES WHETHER THE HARNESS GETS USED.
#
# Recreating a cluster measured at ~2 minutes. At 10 runs x 4 scenarios that is
# 80 minutes per sweep, which means we would run it twice and give up. Resetting
# a namespace is seconds, so a full sweep fits in a coffee break and we actually
# get numbers.
#
# This is the same insight that makes three cluster environments possible: the
# namespace is the unit of work, not the cluster.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE="${NAMESPACE:-agentic-ops}"

# ---------------------------------------------------------------------------
# Ownership guard. This script DELETES things, so it must be at least as careful
# as bin/../bootstrap/nuke.sh.
#
# Added after this ran against a real production-adjacent cluster during
# development: the kubectl context changed mid-sweep and the harness followed it
# without noticing. Nothing was harmed, but only because every delete below is
# namespace-scoped and the namespace did not exist there. That was luck wearing
# the costume of design.
#
# "The agent inherits your active context" is the first thing we tell
# participants. The tooling has to obey it too.
# ---------------------------------------------------------------------------
CONTEXT="$(kubectl config current-context 2>/dev/null || echo none)"
OWNED="$(kubectl get ns "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"

if [ "$OWNED" != "agentic-cloud-ops" ]; then
  cat >&2 <<MSG
reset.sh REFUSING to run.

  context:   ${CONTEXT}
  namespace: ${NAMESPACE}

The namespace is missing, or was not created by this workshop. This script
deletes resources, so it will not touch a namespace it does not own.

Did your kubectl context change? Run:  make verify
MSG
  exit 1
fi

# Delete the workload and anything the agent may have created, but keep the
# namespace, the service accounts and the RBAC ladder — those are environment,
# not state under test. Deleting the namespace would cost ~30s of finalisers.
kubectl -n "$NAMESPACE" delete deploy,svc,networkpolicy,configmap,secret,pod \
  -l app.kubernetes.io/part-of=agentic-cloud-ops \
  --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

# The agent's own creations do not carry our label, so sweep by exclusion.
for kind in deployments services networkpolicies; do
  kubectl -n "$NAMESPACE" get "$kind" -o name 2>/dev/null \
    | grep -vE "(agent-ro|agent-ns|agent-harden|agent-admin)" \
    | xargs -r kubectl -n "$NAMESPACE" delete --ignore-not-found --wait=true >/dev/null 2>&1 || true
done
kubectl -n "$NAMESPACE" delete secret,configmap --all \
  --ignore-not-found >/dev/null 2>&1 || true

# Reapply the baseline workload only. The namespace and RBAC are already there.
source bootstrap/lib.sh
render_base | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" rollout status deploy/shopfront --timeout=120s >/dev/null
kubectl -n "$NAMESPACE" rollout status deploy/worker    --timeout=120s >/dev/null

# The baseline must be green, or the run that follows measures our mess rather
# than the agent's. Fail loudly.
if ! bin/health.sh --quiet; then
  echo "reset.sh: baseline is not healthy after reset — refusing to run" >&2
  bin/health.sh >&2
  exit 1
fi
