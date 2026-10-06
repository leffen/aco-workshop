"""
Talk to an MCP server directly over stdio, the way an attacker would.

CVE-2026-46519 was a server whose read-only mode hid tools from `tools/list`
but executed them anyway when called by name. Checking the tool list proves
nothing; calling the forbidden tool proves the flag is enforced. This module
does the calling, so `make agent-check` can assert the refusal, not assume it.
"""
import json, os, select, subprocess, time

INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {},
    "clientInfo": {"name": "aco-agent-check", "version": "1"}}}


def _session(cmd, env, requests, timeout=60):
    """Send requests after the handshake; return {id: response}.
    A server that dies or stalls yields {"error": ...}, never a hang."""
    # Binary, unbuffered, read from the raw fd. select() watches the fd; a
    # buffered readline() reads ahead, leaves lines in Python's buffer where
    # select() cannot see them, and every call then waits out its timeout.
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, bufsize=0, env={**os.environ, **env})
    want = {1} | {r["id"] for r in requests}
    got, buf, deadline = {}, b"", time.time() + timeout
    fd = p.stdout.fileno()
    try:
        for m in [INIT, {"jsonrpc": "2.0", "method": "notifications/initialized"}, *requests]:
            p.stdin.write((json.dumps(m) + "\n").encode())
        while want - got.keys():
            while b"\n" in buf and want - got.keys():
                line, buf = buf.split(b"\n", 1)
                try:
                    m = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if m.get("id") in want:
                    got[m["id"]] = m
            if not want - got.keys():
                break
            left = deadline - time.time()
            if left <= 0:
                return {"error": f"no answer within {timeout}s"}
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                return {"error": f"server exited (code {p.wait()})"}
            buf += chunk
        return got
    except BrokenPipeError:
        return {"error": f"server exited (code {p.wait()})"}
    finally:
        p.kill()
        p.wait()


def list_tools(cmd, env, timeout=60):
    r = _session(cmd, env, [{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}], timeout)
    if "error" in r:
        raise RuntimeError(r["error"])
    return sorted(t["name"] for t in r[2]["result"]["tools"])


def call_tool(cmd, env, name, arguments, timeout=60):
    """-> {"refused": True|False|None, "where": "tool"|"api"|None, "text": str}
    refused=None means we could not tell: the probe itself failed."""
    r = _session(cmd, env, [{"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                             "params": {"name": name, "arguments": arguments}}], timeout)
    if "error" in r and 2 not in r:
        return {"refused": None, "where": None, "text": r["error"]}
    m = r[2]
    if "error" in m:
        return {"refused": True, "where": "tool", "text": m["error"].get("message", "")}
    res = m["result"]
    text = " ".join(c.get("text", "") for c in res.get("content", []))
    if res.get("isError") and "forbidden" in text.lower():
        return {"refused": True, "where": "api", "text": text}
    return {"refused": False, "where": None, "text": text}
