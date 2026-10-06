#!/usr/bin/env bash
# Local k3d. The path we develop against.
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

if k3d cluster list "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "==> cluster '${CLUSTER_NAME}' already exists, reusing it"
else
  echo "==> creating k3d cluster '${CLUSTER_NAME}' (one server, one agent)"
  k3d cluster create "${CLUSTER_NAME}" \
    --agents 1 \
    --k3s-arg "--disable=traefik@server:0" \
    --wait
fi

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

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
echo "==> context: $(kubectl config current-context)"
