### Your goal

In the room this lab is a demo, and this brief is for the debrief and for running it at
home.

You give an agent a broken deployment and one plain sentence, and it finds the fault and
fixes it while nobody types `kubectl`. You check whether it found the cause or only the
symptom.

### Steps

#### 1 · Start the agent

`make lab LAB=3 LEVEL=easy` has reset the namespace and broken `shopfront`. Start the
agent:

```bash
make agent MODE=incident
```

You should see `safety net off`, then the `you ›` prompt. In incident mode nothing
restores the application if the agent breaks it further.

#### 2 · Ask it to fix the incident

Paste this at `you ›`:

```prompt
The shopfront deployment in namespace agentic-ops is not healthy. Work out what is wrong, fix it, and confirm the pods are running again.
```

You should see `→` lines that read events and pods, then a write, then a `→ Bash` line
running the referee, and a report. The median of our 15 runs with `gpt-oss:20b` was under
a minute.

??? info "Kubernetes: symptom and cause"
    A pod that will not start is a symptom. The cause is the reason it cannot start: here,
    the `shopfront` Deployment names a container image tag that does not exist. Deleting
    the pod changes nothing, because the Deployment makes a new one from the same
    description and it fails the same way. Correcting the image in the Deployment fixes
    the cause.

??? info "Kubernetes: ImagePullBackOff"
    The node downloads a pod's container image before it can start it. If the download
    fails, the pod shows ImagePullBackOff and Kubernetes keeps retrying with longer and
    longer pauses. The reason is in the pod's events.

#### 3 · Stop the agent and check its work

Press Enter on an empty line to stop the agent. Ask the referee yourself, then replay the
session:

```bash
make health
make audit
```

You should see `HEALTHY — 7/7 checks passed.` if the fix held, then every tool call the
agent made, one line each.

Under each REFUSED row, `make audit` says why: `forbidden` means the cluster refused the
call, and `error converting YAML` means the agent's own write was malformed.
`Exit code 1` under a `Bash` row is the referee reporting red. Any other reason is
Kubernetes rejecting what the write contained.

### What to watch for

The agent prints each action it takes, a tool call, as a line starting `→`. Check:

- [ ] It looked around before it changed anything: events and pods first, lines such as
  `→ events_list` and `→ pods_list_in_namespace`, then its first write,
  `→ resources_create_or_update`.
- [ ] It ran the referee, a `→ Bash` line with `referee.sh`, before it reported back.
- [ ] Its report names the cause, the wrong image tag, and not only the symptom, the pod
  that would not start.

### For comparison

We ran this prompt 10 times with the default model, `gpt-oss:20b`. The fault was fixed in
10 of 10 runs.

### Finished early?

The normal level plants a fault the agent's permissions do not let it fix directly:

```bash
make lab LAB=3 LEVEL=normal
```
