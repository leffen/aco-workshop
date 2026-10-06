#!/usr/bin/env python3
"""
The agent runner.

    agents/run.py --mode incident --json < prompt.txt   one shot, for evals/run.py
    agents/run.py --mode deploy                         a REPL, for the labs
    agents/run.py --mode harden --approve manual        Claude Code's own UI, every call asked
    agents/run.py --check                               reaches the model and the cluster?

Every run: pins the operator's context once, mints a ServiceAccount token for
the mode's rung, runs claude from an empty temp directory (so no CLAUDE.md in
this repo can leak the answers), and appends every tool call to agents/audit/.

Stdlib only, on purpose: participants run this without a pip install.
"""
import argparse, contextlib, json, os, pathlib, re, shutil, signal, subprocess, sys, tempfile, urllib.request, uuid
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from agents import kubeconfig as kc
from agents import safety_net as sn
from agents.modes import (MODES, backend, backend_env, claude_command, digest_matches,
                          mcp_config)
from agents.transcript import read_jsonl, summarise

ROOT = pathlib.Path(__file__).resolve().parent.parent
AUDIT = ROOT / "agents" / "audit"
REFEREE = ROOT / "agents" / "referee.sh"
NS = os.environ.get("NAMESPACE", "agentic-ops")
# The context window each lab needs, in tokens: the largest single request seen
# in the first real sweep (3827fea, gpt-oss:20b, N=5) x 1.25, rounded up to 4096.
# Lab 1 peaked at 17,218, Lab 2 at 50,200. Re-derive these when the prompts or
# scenarios change; a guess is what they replaced.
LAB_CONTEXT = {"Lab 1": 24576, "Lab 2": 65536}


def context_verdict(ctx):
    """-> (enough for Lab 1 at least, [labs this window is enough for])."""
    labs = [lab for lab, need in LAB_CONTEXT.items() if ctx >= need]
    return bool(labs), labs


def assert_owned(op_path, context):
    """Refuse any namespace this workshop did not create, before minting a token.

    The same guard as evals/reset.sh and bootstrap/nuke.sh. Added after a test
    fell through to this runner with no KUBECONFIG set, and it tried to mint a
    token on the operator's ambient context, a staging cluster. The request was
    refused there; this makes it stop at a read instead.
    """
    out = subprocess.run(
        ["kubectl", "--kubeconfig", op_path, "get", "ns", NS, "-o",
         "jsonpath={.metadata.labels.app\\.kubernetes\\.io/part-of}"],
        capture_output=True, text=True).stdout.strip()
    if out != "agentic-cloud-ops":
        sys.exit(f"agents/run.py REFUSING to run.\n\n  context:   {context}\n"
                 f"  namespace: {NS}\n\nThe namespace is missing, or was not created by "
                 f"this workshop.\nDid your kubectl context change? Run:  make verify")


def _get_json(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return json.load(r)


def resident(b):
    """What the model occupies right now: weights plus the context cache, which is
    the number that decides whether it fits a laptop. Read from Ollama after the
    turn, while the model is still loaded. None when Ollama can't say."""
    none = {"resident_gb": None, "model_context": None}
    if b.base_url is None:
        return none
    try:
        loaded = _get_json(f"{b.base_url}/api/ps").get("models", [])
    except OSError:
        return none
    for m in loaded:
        if m.get("name") == b.model:
            return {"resident_gb": round(m.get("size", 0) / 1e9, 1),
                    "model_context": m.get("context_length")}
    return none


def assert_model(b, fetch=None):
    """For Ollama: the server is up and the tag still points at the pinned
    digest. `ollama pull` moves a tag silently, and a moved tag is a different
    model under the same name: every number recorded before it means nothing."""
    if b.digest is None:
        return
    try:
        tags = (fetch or _get_json)(f"{b.base_url}/api/tags")
    except OSError as e:
        raise SystemExit(f"Ollama is not reachable at {b.base_url} ({e}).\n"
                         f"Start it (ollama serve), or use ACO_BACKEND=anthropic.")
    if not digest_matches(tags, b.model, b.digest):
        raise SystemExit(f"{b.model} does not have the pinned digest {b.digest[:12]}.\n"
                         f"Either `ollama pull {b.model}` moved the tag, or it is not "
                         f"pulled. Pin the new digest in agents/modes.py on purpose, "
                         f"never by accident: it starts a new series of eval numbers.")


@contextlib.contextmanager
def session(mode):
    """Everything one agent session needs, created once and cleaned up after.

    Every credential file is registered for deletion the moment it exists, so
    cleanup holds on every exit path. It once did not: a refused token mint left
    the operator's kubeconfig in TMPDIR."""
    b = backend()
    assert_model(b)
    op = kc.operator_minified()
    files, workdir = [], tempfile.mkdtemp(prefix="aco-agent-")
    try:
        op_path = kc.write_private(op, "aco-operator-")
        files.append(op_path)
        assert_owned(op_path, op.get("current-context", "none"))
        token = kc.mint_token(MODES[mode].sa, NS, op_path)
        sa_path = kc.write_private(
            kc.for_service_account(op, token, NS, MODES[mode].sa), "aco-sa-")
        files.append(sa_path)
        extra = tuple(os.environ.get("MCP_FLAGS", "").split())   # the Lab 2 flag demonstration
        mcp_path = kc.write_private(mcp_config(mode, sa_path, extra), "aco-mcp-")
        files.append(mcp_path)
        env = {**os.environ, **backend_env(b), "KUBECONFIG": sa_path,
               "ACO_REFEREE_KUBECONFIG": op_path, "NS": NS, "NAMESPACE": NS}
        yield {"mcp": mcp_path, "env": env, "cwd": workdir, "context": op["current-context"],
               "operator": op_path}
    finally:
        for p in files:
            pathlib.Path(p).unlink(missing_ok=True)
        shutil.rmtree(workdir, ignore_errors=True)


def with_vars(cmd):
    """Substitute $NS and $REFEREE in the system prompt argument."""
    i = cmd.index("--append-system-prompt") + 1
    cmd[i] = cmd[i].replace("$NS", NS).replace("$REFEREE", str(REFEREE))
    return cmd


def turn(mode, s, prompt, max_turns, resume=None, live=False):
    """One headless turn. Streams events; renders tool calls if live."""
    cmd = with_vars(claude_command(mode, s["mcp"], str(REFEREE), max_turns, resume=resume))
    # stderr to a file, not a pipe: a chatty stderr would fill the pipe buffer
    # and hang the run while we only read stdout.
    with tempfile.TemporaryFile(mode="w+") as err:
        p = subprocess.Popen(cmd, cwd=s["cwd"], env=s["env"], text=True,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err)
        p.stdin.write(prompt)
        p.stdin.close()
        events = []
        for line in p.stdout:
            ev = read_jsonl([line])
            events += ev
            if live:
                render(ev)
        p.wait()
        err.seek(0)
        stderr = err.read()
    out = summarise(events)
    b = backend()
    out["model"], out["model_digest"] = b.model, b.digest
    if not b.priced:
        out["cost_usd"] = None      # Claude Code prices models it doesn't know
    out.update(resident(b))
    if not any(e.get("type") == "result" for e in events) and not out["error"]:
        out["error"] = (stderr.strip()[-500:] or f"claude exited {p.returncode} with no result")
    audit(mode, out)
    return out


def safety_net(mode, s, say):
    """The runner's safety net for this session, or None when it is off."""
    return sn.SafetyNet(NS, s["operator"], say) if sn.enabled(mode) else None


def guarded_turn(mode, s, net, prompt, max_turns, **kw):
    """A turn, then the safety net's verdict on it: off, not needed, restored."""
    out = turn(mode, s, prompt, max_turns, **kw)
    if net is None:
        out["safety_net"] = "off"
        return out
    def record(msg, changes):
        audit(mode, {"session_id": out.get("session_id"), "tool_calls": [
            {"name": "safety_net", "args": changes, "result_summary": msg, "is_error": False}]})
    try:
        out["safety_net"] = net.after_turn(record)
    except RuntimeError as e:
        out["safety_net"] = f"failed: {e}"
    return out


def render(events):
    for e in events:
        content = e.get("message", {}).get("content")
        for b in content if isinstance(content, list) else []:
            if b.get("type") == "tool_use":
                args = json.dumps(b.get("input", {}))[:100]
                print(f"  \033[36m→ {b['name'].removeprefix('mcp__k8s__')}\033[0m {args}")
            elif b.get("type") == "tool_result" and b.get("is_error"):
                print("  \033[31m← refused or failed\033[0m")


SECRETS = [
    (re.compile(r"eyJ[\w-]+\.[\w-]+\.[\w-]+"), "<redacted>"),                       # JWTs
    (re.compile(r"(Bearer\s+)[^\s\"']+"), r"\1<redacted>"),
    (re.compile(r"((?:token|client-key-data|client-certificate-data|password):\s*)\S+"),
     r"\1<redacted>"),                                                              # kubeconfig
]


def redact(value):
    """Mask credentials anywhere in a tool call. One run wrote the agent's live
    ServiceAccount token into the audit trail (2026-10-04)."""
    if isinstance(value, str):
        for pattern, repl in SECRETS:
            value = pattern.sub(repl, value)
        return value
    if isinstance(value, dict):
        return {k: redact(v) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def audit(mode, out):
    AUDIT.mkdir(parents=True, exist_ok=True)
    path = AUDIT / f"{datetime.now():%Y%m%d}-{out.get('session_id') or 'none'}.jsonl"
    with path.open("a") as fh:
        for c in out["tool_calls"]:
            fh.write(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "mode": mode,
                                 "sa": MODES[mode].sa, **redact(c)}) + "\n")


def repl(mode, s):
    b = backend()
    net = safety_net(mode, s, say=lambda m: print(f"\033[33m{m}\033[0m"))
    print(f"agent  mode={mode}  as={MODES[mode].sa}  namespace={NS}  model={b.model} ({b.name})")
    print(f"context {s['context']}  (pinned)   empty line or 'exit' to stop")
    print(f"safety net {'on: SAFETY_NET=off to watch without it' if net else 'off'}\n")
    sid = None
    while True:
        try:
            line = input("you › ").strip()
        except EOFError:
            break
        if line in ("", "exit", "quit"):
            break
        out = guarded_turn(mode, s, net, line, MODES[mode].max_turns, resume=sid, live=True)
        sid = out["session_id"] or sid
        cost = f"  ${out['cost_usd']:.3f}" if out["cost_usd"] else ""
        print(f"\n{out['report']}\n\033[2m{len(out['tool_calls'])} tool calls{cost}\033[0m\n")
        if out["error"]:
            print(f"\033[31m{out['error']}\033[0m\n")


def check():
    """Both directions: what must work, and what must be refused.

    A guardrail you can't verify is enforced is decoration. For each rung the
    labs use, this proves the agent can see its namespace, and that a delete is
    refused twice over: by the MCP server with its flag set (called directly,
    skipping discovery, which is exactly what CVE-2026-46519 got wrong) and by
    the API server without it. Then that the model answers at all.
    """
    from agents import mcp_probe
    from agents.modes import MCP_PACKAGE
    fails = 0

    def line(ok, msg):
        nonlocal fails
        fails += not ok
        print(f"  {'\033[32mOK\033[0m  ' if ok else '\033[31mFAIL\033[0m'}  {msg}")

    # Absent on purpose: authorization is checked before lookup, so a working
    # ladder answers "forbidden" and a broken one "not found". Nothing real is
    # ever at risk, even if RBAC is broken.
    canary = {"apiVersion": "apps/v1", "kind": "Deployment", "namespace": NS,
              "name": "agent-check-canary"}
    print(f"\nAgent check — namespace '{NS}'\n")
    try:
        assert_model(backend())
        line(True, f"{backend().model} is the pinned build" if backend().digest
             else f"backend {backend().name}")
    except SystemExit as e:
        line(False, str(e).splitlines()[0])
        print(f"\n\033[31m{fails} check(s) failed.\033[0m\n")
        return 1
    for mode in ("deploy", "incident"):
        sa = MODES[mode].sa
        with session(mode) as s:
            env = {"KUBECONFIG": s["env"]["KUBECONFIG"]}
            kube = ["kubectl", "--kubeconfig", env["KUBECONFIG"], "-n", NS, "auth", "can-i"]
            can = lambda verb: subprocess.run([*kube, verb, "deployments"],
                                              capture_output=True, text=True).stdout.strip()
            line(can("patch") == "yes", f"{sa}: RBAC allows patch deployments")
            line(can("delete") == "no", f"{sa}: RBAC refuses delete deployments")
            server = ["npx", "-y", MCP_PACKAGE]
            r = mcp_probe.call_tool(server, env, "pods_list_in_namespace", {"namespace": NS})
            line(r["refused"] is False and "shopfront" in r["text"],
                 f"{sa}: MCP server starts as {sa} and sees the workload pods")
            r = mcp_probe.call_tool([*server, "--disable-destructive"], env,
                                    "resources_delete", canary)
            line(r["refused"] and r["where"] == "tool",
                 f"{sa}: --disable-destructive refuses a direct delete call at the tool layer")
            r = mcp_probe.call_tool(server, env, "resources_delete", canary)
            line(r["refused"] and r["where"] == "api",
                 f"{sa}: without the flag, the API server refuses the same delete")
            if r["refused"] is not True:
                print(f"        {r['text'][:160]}")

    b = backend()
    cmd = ["claude", "--bare", "-p", "--model", b.model, "--output-format", "stream-json",
           "--verbose", "--max-turns", "1", "--tools", "", "--permission-mode", "dontAsk"]
    with tempfile.TemporaryDirectory(prefix="aco-agent-") as cwd:
        p = subprocess.run(cmd, input="Reply with the single word OK.", cwd=cwd,
                           env={**os.environ, **backend_env(b)},
                           capture_output=True, text=True, timeout=300)
    out = summarise(read_jsonl(p.stdout.splitlines()))
    line(not out["error"] and "OK" in out["report"],
         f"model {b.model} ({b.name}) answers" + (f" — {out['error']}" if out["error"] else ""))
    if out["error"] and "log" in out["error"].lower():
        print("        set ANTHROPIC_API_KEY: --bare never uses your Claude Code login")

    if b.name == "ollama":
        # Ollama sizes the context window to the machine, and truncates a prompt
        # that doesn't fit WITHOUT an error: the model silently loses its system
        # prompt and tool definitions. The first request is only ~4k tokens; it
        # is the conversation that grows, to 50k in Lab 2.
        try:
            loaded = {m["name"]: m.get("context_length", 0)
                      for m in _get_json(f"{b.base_url}/api/ps").get("models", [])}
        except OSError:
            loaded = {}
        ctx = loaded.get(b.model, 0)
        enough, labs = context_verdict(ctx)
        line(enough, f"Ollama context window {ctx} tokens — enough for "
                     f"{', '.join(labs) if labs else 'no lab'} "
                     f"(Lab 1 needs {LAB_CONTEXT['Lab 1']}, Lab 2 {LAB_CONTEXT['Lab 2']})")

    print(f"\n\033[{'32' if not fails else '31'}m"
          f"{'All checks passed.' if not fails else f'{fails} check(s) failed.'}\033[0m\n")
    return 0 if not fails else 1


def cleanup_on_sigterm():
    """Turn SIGTERM into an ordinary exit, so every `finally` runs and the
    credential files session() wrote are deleted. Python's default is to die on
    the spot: a timed-out run left operator and ServiceAccount kubeconfigs in
    TMPDIR that way (2026-09-29). The harness sends SIGTERM before SIGKILL."""
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))


def main():
    cleanup_on_sigterm()
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=sorted(MODES))
    ap.add_argument("--json", action="store_true", help="one shot: prompt on stdin")
    ap.add_argument("--approve", choices=["auto", "manual"], default="auto")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        return check()
    if not a.mode:
        ap.error("--mode is required")
    with session(a.mode) as s:
        if a.json:
            turns = int(os.environ.get("MAX_TURNS", MODES[a.mode].max_turns))
            net = safety_net(a.mode, s, say=lambda m: print(m, file=sys.stderr))
            out = guarded_turn(a.mode, s, net, sys.stdin.read(), turns)
            print(json.dumps(out))
            return 0 if not out["error"] else 1
        if a.approve == "manual":
            sid = str(uuid.uuid4())
            cmd = with_vars(claude_command(a.mode, s["mcp"], str(REFEREE), 0, interactive=True,
                                           approve_manual=True, session_id=sid))
            print(f"session {sid} — `make audit` reads it afterwards")
            return subprocess.call(cmd, cwd=s["cwd"], env=s["env"])
        repl(a.mode, s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
