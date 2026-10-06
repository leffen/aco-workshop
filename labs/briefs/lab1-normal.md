### Your goal

You get the agent to deploy a web server and then fix a fault you plant, using prompts you
write yourself, and you check your prediction of its path against what it did.

### Start

```bash
make agent MODE=deploy
```

Stop it with an empty line after part one, then plant the fault and start it again:

```bash
make lab1-break
make agent MODE=deploy
```

### The prompt

Write your own prompt for each part, on one line: the agent reads each line you paste as a
separate message.

Part one: an nginx Deployment called `web` with 3 replicas in `agentic-ops`, and a Service
called `web` in front of it, confirmed working. A Deployment keeps a set number of
identical pods running; a Service gives them one stable address inside the cluster.

Part two: `make lab1-break` points the `shopfront` Deployment at an image tag that does not
exist, so its new pods cannot start. Ask the agent to find the problem and fix it, without
telling it what you broke.

For reference, the easy level hands out one plain sentence for part two: "The shopfront
deployment in namespace agentic-ops is not healthy. Work out what is wrong, fix it, and
confirm the pods are running again."

### What to watch for

- Before you send each prompt, predict what the agent will do first. Afterwards, compare
  your prediction with `make audit`.
- How many tool calls did each part take? The count prints after every answer.
- What does `make audit` show that the final message left out?

You may see the agent try to delete something and get refused. The refusal comes from the
cluster. The agent acts as the ServiceAccount `agent-ns`, and its Role, the list of actions
that identity may take, grants no `delete` verb, the permission to remove a resource. The
API server enforces that whatever the model decides. `make ladder` shows what each identity
can do.

### For comparison

With the easy prompts and `gpt-oss:20b`, the fault was fixed in 10 of 10 runs and the
deployment passed in 9 of 10. Those numbers belong to our prompts. Your prompt is a
different task, so one run of it sits beside them as a single data point.

### Finished early?

```bash
make lab LAB=1 LEVEL=hard
```
