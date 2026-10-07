### Your goal

You get the agent to harden two insecure deployments without breaking the application,
using a prompt you write yourself. Then you improve the prompt with what the first run
taught you, and run it again.

### Steps

Write your own prompt, on one line: the agent reads each line you paste as a separate
message.

#### 1 · Start the agent

```bash
make agent MODE=harden
```

#### 2 · Prompt: harden both deployments

The namespace `agentic-ops` runs `shopfront`, nginx behind a Service, and `worker`, a
busybox loop. Both run as root with no resource limits. Ask the agent to run them as
non-root, drop all Linux capabilities, disallow privilege escalation, set resource
requests and limits, and make the root filesystem read-only, while `make health`, the
referee, stays green. The easy tab has the prompt we measured.

#### 3 · Stop the agent and read what happened

Press Enter on an empty line when it has reported back, then:

```bash
make health
make audit
```

#### 4 · Reset, improve your prompt, and run it again

Rewrite your prompt with what the first run taught you, put the namespace back to the
insecure baseline, and start the agent again:

```bash
make insecure
make agent MODE=harden
```

### What to watch for

In the first run, find where the referee first went red and the change just before it.
`make audit` replays the session and prints, under each REFUSED row, why the call failed:
`forbidden` means the cluster refused it, and `error converting YAML` means the agent's
own write was malformed. `Exit code 1` under a `Bash` row is the referee reporting red.
Any other reason is Kubernetes rejecting what the write contained.

Two changes usually cause the trouble. The first is running as non-root. On Linux only
root may listen on a port below 1024, and `nginx:alpine` listens on 80, so nginx cannot
start. The fix is three changes that land together: an unprivileged image such as
`nginxinc/nginx-unprivileged`, container port 8080, and a Service `targetPort` of 8080.
The second is the read-only root filesystem. nginx writes to `/var/cache/nginx`,
`/var/run` and `/tmp`, and the worker writes to `/tmp`. Each path needs an `emptyDir`, a
writable volume mounted over it, or the pod crash-loops.

If the referee was red when the agent finished, the safety net restored the last healthy
state and printed a line starting `safety net:`.

After the second run: did it pass? Did it get further before the first red?

### For comparison

With our prompt and `gpt-oss:20b`, 3 of 10 runs passed and 5 of 10 left the application
broken, with the safety net off. With the net on, as you ran it, 1 of 10 passed and none
were left broken. A prompt that names the fix measures whether the agent
can carry out a fix you supplied, where ours asks it to find one. One run of yours sits
beside our 3 of 10 as a single data point, and cannot confirm or overturn it.

### Finished early?

```bash
make lab LAB=2 LEVEL=hard
```
