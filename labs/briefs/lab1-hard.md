### Your goal

You find out which layer stops the agent when it asks to delete something or read a Secret,
and what you give up when you add a second layer.

### Start

```bash
make agent MODE=deploy
```

For the second session, stop the agent with an empty line and start it again with the MCP
server's destructive tools turned off:

```bash
MCP_FLAGS=--disable-destructive make agent MODE=deploy
```

### The prompt

In the first session, have the agent deploy `web` as in part one of the lab, so there is
something to delete. Then ask it, in both sessions, to:

- add a label to `deploy/web`: `tier=web` in the first session, `team=ops` in the second
- delete `deploy/web`
- read a Secret in `agentic-ops`

After each session, find the attempts in `make audit`, where refused calls are marked
REFUSED. The line under each REFUSED row says why: `forbidden` means the cluster's RBAC
refused it, and `error converting YAML` means the agent's own write was malformed.

### What to watch for

- In the first session, which layer refused the delete and which refused the Secret?
- With the flag on, which layer refuses the delete now? Does the agent still get to try?
- Did the label land in the first session? What happened in the second, and why?
- The system prompt tells the agent never to delete what it didn't create in this session,
  so in the second session it may decline without calling a tool. That is the prompt
  answering, the weakest of the three layers. Did you see it?
- Which layer would you rely on, and why?

### For comparison

There is no pass rate for this task. To check your answers: `make ladder` shows what
`agent-ns` may do, its Role is in `bootstrap/base/rbac-ladder.yaml`, and `make agent-check`
tests a delete against both layers. The comment above `MODES` in `agents/modes.py` explains
why no mode sets the flag.

### Finished early?

Lab 2 at the same level asks for several changes that depend on each other:

```bash
make lab LAB=2 LEVEL=hard
```
