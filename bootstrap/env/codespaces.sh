#!/usr/bin/env bash
# GitHub Codespaces: k3d inside the codespace, via docker-in-docker.
#
# This is the recommended default. It removes the two risks most likely to sink
# the room — conference Wi-Fi and locked-down corporate laptops — because
# nothing runs on the participant's machine but a browser.
set -euo pipefail

if [[ -z "${CODESPACES:-}" ]]; then
  echo "warning: CODESPACES is not set — this doesn't look like a Codespace." >&2
  echo "         It will still work anywhere Docker runs. Continuing." >&2
fi

if ! docker info >/dev/null 2>&1; then
  echo "error: Docker is not reachable. The devcontainer needs the" >&2
  echo "       docker-in-docker feature. See .devcontainer/devcontainer.json." >&2
  exit 1
fi

# Same cluster shape as local k3d — the environments must not drift.
exec "$(dirname "$0")/k3d.sh"
