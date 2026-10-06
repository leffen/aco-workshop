#!/usr/bin/env bash
# Local k3d. The path we develop against.
#
# Safe to re-run, whatever state the cluster is in: missing is created, stopped
# (after a reboot or a Docker restart) is started, running is reused. A create
# that fails half-way is deleted again, so the next run starts clean.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-agentic-ops}"

if ! command -v k3d >/dev/null 2>&1; then
  cat >&2 <<'MSG'
k3d is not installed.

  macOS   brew install k3d
  Linux   curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

Or use a different environment:
  make env-up ENV=codespaces
  make env-up ENV=byo
MSG
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Start Docker Desktop (or Colima), then re-run." >&2
  exit 1
fi

if k3d cluster get "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "==> cluster '${CLUSTER_NAME}' exists; starting it if it is stopped"
  k3d cluster start "${CLUSTER_NAME}" --wait >/dev/null
else
  echo "==> creating k3d cluster '${CLUSTER_NAME}' (one server, one agent)"
  # Eviction at 1% free, not k3s's default: a laptop with a nearly full disk
  # otherwise taints every node disk-pressure and nothing schedules, and the
  # workshop's images are a few hundred MB. Measured 2026-10-06: 97% used.
  if ! k3d cluster create "${CLUSTER_NAME}" \
      --agents 1 \
      --k3s-arg "--disable=traefik@server:0" \
      --k3s-arg "--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:*;agent:*" \
      --wait; then
    k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || true
    echo "cluster creation failed, and the half-made cluster was removed. Re-run to try again." >&2
    exit 1
  fi
fi

# Rewrite the kubeconfig entry every time rather than trusting it: it may have
# been deleted, or hold certificates from an earlier cluster of the same name.
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null

# Images pulled on the host by `make preflight` do not reach k3d's containerd on
# their own. Import whichever are present, so the room does not pull them over
# conference Wi-Fi. Anything missing is simply pulled by the cluster later.
for img in nginx:1.27-alpine busybox:1.36 nginxinc/nginx-unprivileged:1.27-alpine; do
  if docker image inspect "${img}" >/dev/null 2>&1; then
    echo "==> importing ${img} into the cluster"
    k3d image import "${img}" -c "${CLUSTER_NAME}" >/dev/null 2>&1 \
      || echo "    (import failed; the cluster will pull it instead)"
  fi
done

echo "==> context: $(kubectl config current-context)"
echo "==> waiting for the nodes to be Ready"
kubectl --context "k3d-${CLUSTER_NAME}" wait node --all --for=condition=Ready --timeout=120s >/dev/null
