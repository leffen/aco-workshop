#!/usr/bin/env bash
#
# The agent's one shell command.
#
# bin/health.sh runs a throwaway probe pod, and no rung of the RBAC ladder can
# create pods, so the referee cannot run as the agent. It runs as the operator
# instead, from a kubeconfig the agent has no tool to read: its only built-in
# tool is Bash, and Bash is allowlisted to exactly this file.
#
# The agent can ask for a verdict. It cannot influence one, except by making
# the application work.
set -euo pipefail
: "${ACO_REFEREE_KUBECONFIG:?run via agents/run.py}"
KUBECONFIG="${ACO_REFEREE_KUBECONFIG}" exec "$(cd "$(dirname "$0")/.." && pwd)/bin/health.sh" "$@"
