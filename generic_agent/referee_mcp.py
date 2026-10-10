#!/usr/bin/env python3
"""
The referee as an MCP tool, so a harness can run with no shell at all.

agents/run.py gives Claude Code a Bash tool allowlisted to agents/referee.sh.
Not every harness can narrow its shell to one command (Codex can't; pi has no
permission layer at all), and an allowlist that matches command strings let
echo, pwd and sleep through on 2026-10-07. A tool that only exists to run the
referee is the stronger guardrail: there is no shell to narrow.

One tool, `referee`, no arguments. It runs agents/referee.sh --json, which
runs bin/health.sh as the operator, from ACO_REFEREE_KUBECONFIG: a kubeconfig
the agent has no tool to read. The agent can ask for a verdict, not change one.

MCP over stdio: newline-delimited JSON-RPC 2.0 on stdin and stdout, logs on
stderr. Stdlib only.
"""
import json, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REFEREE = ROOT / "agents" / "referee.sh"
PROTOCOL = "2025-06-18"
TIMEOUT_S = 180
TOOL = {
    "name": "referee",
    "description": ("Reports whether the workshop application in the namespace is healthy: "
                    "the deployments, the service, real HTTP traffic and the worker. Returns "
                    "JSON with healthy, passed, failed and each check. Run it after every change."),
    "inputSchema": {"type": "object", "properties": {}},
}


def verdict(run=subprocess.run):
    """-> (text, is_error). Red is an error, as Claude Code reports exit 1."""
    try:
        p = run([str(REFEREE), "--json"], capture_output=True, text=True, timeout=TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return f"referee timed out after {TIMEOUT_S}s", True
    return (p.stdout.strip() or p.stderr.strip() or f"referee exited {p.returncode}"), p.returncode != 0


def handle(msg, run=subprocess.run):
    """One request -> one response, or None for a notification."""
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": msg.get("params", {}).get("protocolVersion", PROTOCOL),
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "aco-referee", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": [TOOL]}
    elif method == "tools/call":
        name = msg.get("params", {}).get("name")
        if name != "referee":
            return {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32602, "message": f"unknown tool: {name}"}}
        text, is_error = verdict(run)
        result = {"content": [{"type": "text", "text": text}], "isError": is_error}
    elif method == "ping":
        result = {}
    else:
        return {"jsonrpc": "2.0", "id": mid,
                "error": {"code": -32601, "message": f"method not found: {method}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def main(stdin=sys.stdin, stdout=sys.stdout):
    for line in stdin:
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            stdout.write(json.dumps({"jsonrpc": "2.0", "id": None,
                                     "error": {"code": -32700, "message": "parse error"}}) + "\n")
            stdout.flush()
            continue
        reply = handle(msg)
        if reply is not None:
            stdout.write(json.dumps(reply) + "\n")
            stdout.flush()


if __name__ == "__main__":
    main()
