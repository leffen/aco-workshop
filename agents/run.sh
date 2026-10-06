#!/usr/bin/env bash
#
# The agent runner's seam with evals/run.py. The work is in agents/run.py.
#
# Contract with evals/run.py:
#   in:   $1 = mode (deploy|harden|incident), prompt on stdin, KUBECONFIG pinned
#   out:  one JSON object on stdout:
#           { "report": "...",            what the agent concluded, in prose
#             "iterations": 7,            loop turns taken
#             "tool_calls": [ ... ],      each {name, args, result_summary}
#             "input_tokens": 0,
#             "output_tokens": 0,
#             "safety_net": "off",        off | not needed | restored | ...
#             "cost_usd": 0.0 }
#
# Until this exists, use the free backends:
#   evals/run.py --all --agent oracle    proves scenarios are solvable
#   evals/run.py --all --agent noop      proves failures are detected
#
# When implementing:
#   * PIN the model. Not an alias that moves under us — every recorded number is
#     meaningless the moment the model changes silently.
#   * Give it the MCP server with disable_destructive, and the agent-harden
#     service account. Never your own kubeconfig identity.
#   * Cap iterations. A runaway loop should end the run, not the budget.
#   * Record every tool call. The debugging PATH is the teaching material;
#     the final answer is the least interesting part of the transcript.
set -euo pipefail
cd "$(dirname "$0")/.."
exec "${PYTHON:-python3}" agents/run.py --mode "$1" --json
