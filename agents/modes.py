"""
What each mode may do. This file is a guardrail; tests/test_modes.py asserts it.

Three layers, and this file sets two of them:
  prompt  agents/prompts/<mode>.md          guidance
  tool    the MCP flags below               enforcement, if the server is honest
  API     the ServiceAccount (RBAC ladder)  the one that's actually load-bearing
"""
import dataclasses, os, pathlib
from dataclasses import dataclass

MCP_PACKAGE = "kubernetes-mcp-server@0.0.67"  # pinned by the Task 0 spike, 2026-09-28

PROMPTS = pathlib.Path(__file__).resolve().parent / "prompts"


@dataclass(frozen=True)
class Backend:
    """Where the model runs. Claude Code is the agent either way: Ollama speaks
    the Anthropic Messages API, so only the endpoint changes, never the wiring."""
    name: str
    model: str
    base_url: str | None    # None: Anthropic's own API
    digest: str | None      # Ollama tags move like aliases; the digest does not
    priced: bool            # Claude Code's cost figure is invented for local models


# Every Ollama model the runner may use, pinned by digest. ACO_OLLAMA_MODEL picks
# one; anything not listed is refused. Pin a new one on purpose: it starts a new
# series of eval numbers. The aco-* entries are the model ladder (plan, Task 22):
# a base model with its context window baked in, so the window is pinned too.
OLLAMA_MODELS = {
    "gpt-oss:20b": "17052f91a42e97930aa6e28a6c6c06a983e6a58dbb00434885a0cf5313e376f7",
    # The model ladder, built 2026-09-29. Resident = weights + context cache at
    # that window, measured alone. Names carry :latest because Ollama reports
    # them that way, and the digest check compares names exactly.
    "aco-qwen3-1.7b-24k:latest": "2b8c8f8f3c39403347b05bb4b57754594eac01a0ec33bbdef25c25818b7811fe",  # qwen3:1.7b, num_ctx 24576, 4.4 GB resident
    "aco-llama3.2-3b-24k:latest": "eb783ab5364579bff92877f7c380e1f567ad8349736c7953700b54ce4c5f18af",  # llama3.2:3b, num_ctx 24576, 5.0 GB resident
    "aco-qwen3-4b-24k:latest": "66426c77e6734296777c05fa4277099bea707b67b0fe71314a691aa53f69b586",  # qwen3:4b, num_ctx 24576, 6.4 GB resident
    "aco-qwen3-8b-24k:latest": "12771edf4e4bd4bf3d7b91f628c06faf962edd98276ccc78f98aa2c1ae3a714e",  # qwen3:8b, num_ctx 24576, 9.1 GB resident
    "aco-llama3.2-3b-64k:latest": "65c8a8d1bf75d72ea2032ac291f3a9873029dab9c5aad5f5da5462d74e8758a4",  # llama3.2:3b, num_ctx 65536, 10.2 GB resident
    "aco-qwen3-4b-64k:latest": "55cb96e404f0fe5db5dc9d4d5e2ec42d3b30cf2ab0f4ada7ddf5e2d0a80421d3",  # qwen3:4b, num_ctx 65536, 12.9 GB resident
}

# Pinned, both of them. A moving alias or tag invalidates every recorded number.
BACKENDS = {
    "ollama": Backend(
        name="ollama", model="gpt-oss:20b",
        base_url=os.environ.get("ACO_OLLAMA_URL", "http://localhost:11434"),
        digest=OLLAMA_MODELS["gpt-oss:20b"], priced=False),
    "anthropic": Backend(name="anthropic", model="claude-sonnet-5-5", base_url=None,
                         digest=None, priced=True),
}


def backend():
    """The active backend: ACO_BACKEND, default ollama (2026-09-29)."""
    name = os.environ.get("ACO_BACKEND", "ollama")
    if name not in BACKENDS:
        raise SystemExit(f"unknown ACO_BACKEND={name!r}. One of: {', '.join(BACKENDS)}")
    b = BACKENDS[name]
    tag = os.environ.get("ACO_OLLAMA_MODEL")
    if name == "ollama" and tag:
        if tag not in OLLAMA_MODELS:
            raise SystemExit(f"ACO_OLLAMA_MODEL={tag!r} is not pinned. Add its digest to "
                             f"OLLAMA_MODELS in agents/modes.py first.")
        b = dataclasses.replace(b, model=tag, digest=OLLAMA_MODELS[tag])
    return b


def backend_env(b):
    """Environment for claude. For Ollama, a placeholder key: --bare accepts only
    ANTHROPIC_API_KEY, Ollama ignores it, and a real key never goes to it."""
    if b.base_url is None:
        return {}
    return {"ANTHROPIC_BASE_URL": b.base_url, "ANTHROPIC_API_KEY": "ollama"}


def digest_matches(tags, model, digest):
    """tags: Ollama's /api/tags response."""
    return any(m.get("name") == model and m.get("digest") == digest
               for m in tags.get("models", []))


@dataclass(frozen=True)
class Mode:
    sa: str
    mcp_flags: tuple
    max_turns: int


MODES = {
    # No MCP flag in any mode: --disable-destructive also removes the update tool
    # (spike, 0.0.67). RBAC is what refuses the delete; the flags are a Lab 2 demo.
    "deploy":   Mode(sa="agent-ns",     mcp_flags=(), max_turns=15),
    "incident": Mode(sa="agent-harden", mcp_flags=(), max_turns=20),
    "harden":   Mode(sa="agent-harden", mcp_flags=(), max_turns=40),
}


def mcp_config(mode, kubeconfig, extra_flags=()):
    # KUBECONFIG is explicit, always: the server connects at startup, and without
    # it would follow the operator's ambient context (spike, 2026-09-28).
    return {"mcpServers": {"k8s": {
        "command": "npx",
        "args": ["-y", MCP_PACKAGE, *MODES[mode].mcp_flags, *extra_flags],
        "env": {"KUBECONFIG": kubeconfig},
    }}}


def claude_command(mode, mcp_config, referee, max_turns, interactive=False,
                   approve_manual=False, resume=None, session_id=None):
    cmd = ["claude", "--bare", "--model", backend().model,
           "--strict-mcp-config", "--mcp-config", mcp_config,
           "--append-system-prompt", (PROMPTS / f"{mode}.md").read_text(),
           "--tools", "Bash",
           # Explicit, always: the user's settings may say defaultMode: auto, and
           # then the allowlist below restricts nothing (spike, 2026-09-28).
           "--permission-mode", "default" if interactive else "dontAsk"]
    if not interactive:
        cmd += ["-p", "--output-format", "stream-json", "--verbose",
                "--max-turns", str(max_turns)]
    if resume:
        cmd += ["--resume", resume]
    if session_id:
        cmd += ["--session-id", session_id]
    # The agent never needs its own credentials. configuration_view hands it
    # its kubeconfig, token included; one incident run read it and tried the
    # token outside the MCP tools (2026-10-04).
    cmd += ["--disallowedTools", "mcp__k8s__configuration_view"]
    allowed = [] if approve_manual else ["mcp__k8s"]
    # Variadic: must be last, or it swallows whatever follows.
    return cmd + ["--allowedTools", *allowed, f"Bash({referee}:*)"]
