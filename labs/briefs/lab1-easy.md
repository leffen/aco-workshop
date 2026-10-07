### Your goal

You give an agent a one-sentence goal and it deploys a web server. Then you break an
application on purpose, and the agent finds the fault and fixes it while you watch.

### Steps

#### 1 · Start the agent

```bash
make agent MODE=deploy
```

You should see a line starting `agent  mode=deploy  as=agent-ns`, then the `you ›` prompt,
where the agent waits for you. The whole lab happens at this prompt: you paste goals for
the agent, and type commands that start with `/` for yourself.

#### 2 · Ask it to deploy a web server

Paste this at `you ›`:

```prompt
Deploy an nginx web server called web with 3 replicas in namespace agentic-ops, and expose it inside the cluster with a Service called web. Confirm it is running.
```

Each action the agent takes, a tool call, prints as a line starting `→`. On a local model
the first reply can take a minute while the model loads.

You should see a few `→` lines as it creates the Deployment and the Service, then a report
that `web` has 3 pods running.

??? info "Kubernetes: Deployment and Service"
    A Deployment keeps a set number of identical pods running and replaces any that stop.
    A Service gives those pods one stable name and address inside the cluster, so other
    programs can reach them without knowing which pods exist right now.

#### 3 · Break something

Break the `shopfront` application on purpose. Type this at `you ›`:

```slash
/break
```

A command starting with `/` runs as you, not as the agent, and the agent never sees it.
This one runs `make lab1-break`. It takes about 20 seconds. You should see
`imagepullbackoff: applied break in namespace agentic-ops`, then a line saying the agent
was not told.

#### 4 · Ask it to fix the fault

Paste this at `you ›`:

```prompt
The shopfront deployment in namespace agentic-ops is not healthy. Work out what is wrong, fix it, and confirm the pods are running again.
```

The agent starts a new conversation here, so it knows nothing about what you broke.

You should see `→` lines that read the pods and their events, then one that changes the
image, and a report that the `shopfront` pods are running again.

??? info "Kubernetes: ImagePullBackOff"
    A pod runs a container image that the node downloads first. If the download fails,
    for example because the tag does not exist, the pod shows ImagePullBackOff and
    Kubernetes keeps retrying with longer and longer pauses. The reason is in the pod's
    events.

#### 5 · Check its work

Ask the referee, an independent check of whether the application works, then replay the
whole session one tool call at a time:

```slash
/health
/audit
```

You should see `HEALTHY — 7/7 checks passed.` from the referee, then every tool call the
agent made, one line each, with `--- you ran make lab1-break ---` where you broke
`shopfront`. Press Enter on an empty line to leave the agent.

### What to watch for

- [ ] Step 4: it listed the pods before it changed anything.
- [ ] Step 4: it read the events before it changed the image.
- [ ] Step 4: it changed the image on the existing `shopfront` deployment and did not try
  to delete and recreate it.
- [ ] Its final report matches what `/health` says.

### For comparison

We ran both prompts repeatedly with the default model, `gpt-oss:20b`. The fault was fixed in
10 of 10 runs. The deployment passed in 9 of 10; in the one failure `web` never reached 3
ready replicas with endpoints.

### Finished early?

Try the same lab writing your own prompts:

```bash
make lab LAB=1 LEVEL=normal
```
