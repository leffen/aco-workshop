### Your goal

You give an agent a one-sentence goal and it deploys a web server. Then you break an
application on purpose, and the agent finds the fault and fixes it while you watch.

### Start

```bash
make agent MODE=deploy
```

The agent starts and waits at `you ›`. Paste the first prompt below. When it has reported
back, press Enter on an empty line to stop it, then plant the fault and start it again for
the second prompt:

```bash
make lab1-break
make agent MODE=deploy
```

### The prompt

Part one, the deployment:

```prompt
Deploy an nginx web server called web with 3 replicas in namespace agentic-ops, and expose it inside the cluster with a Service called web. Confirm it is running.
```

??? info "Kubernetes: Deployment and Service"
    A Deployment keeps a set number of identical pods running and replaces any that stop.
    A Service gives those pods one stable name and address inside the cluster, so other
    programs can reach them without knowing which pods exist right now.

Part two, after `make lab1-break`, the fault:

```prompt
The shopfront deployment in namespace agentic-ops is not healthy. Work out what is wrong, fix it, and confirm the pods are running again.
```

??? info "Kubernetes: ImagePullBackOff"
    A pod runs a container image that the node downloads first. If the download fails,
    for example because the tag does not exist, the pod shows ImagePullBackOff and
    Kubernetes keeps retrying with longer and longer pauses. The reason is in the pod's
    events.

### What to watch for

The agent prints each action it takes, a tool call, as it happens. Check:

- [ ] Part two: it listed the pods before it changed anything.
- [ ] Part two: it read the events before it changed the image.
- [ ] Part two: it changed the image on the existing `shopfront` deployment and did not
  try to delete and recreate it.
- [ ] Its final report matches `make health`, the referee: an independent check of
  whether the application works.

```bash
make health
```

Then replay the whole session, one tool call at a time:

```bash
make audit
```

### For comparison

We ran both prompts repeatedly with the default model, `gpt-oss:20b`. The fault was fixed in
10 of 10 runs. The deployment passed in 9 of 10; in the one failure `web` never reached 3
ready replicas with endpoints.

### Finished early?

Try the same lab writing your own prompts:

```bash
make lab LAB=1 LEVEL=normal
```
