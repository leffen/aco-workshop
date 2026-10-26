# Demo runbook: the three labs on pi + Gemini

What you type, what the room sees, and what to do when something goes wrong. Times are
from the run-throughs on 2026-10-26 with the paid key; Google's API can make them longer.

## Before the session (5 min)

```bash
cd ~/p/aco-workshop && git pull
make verify            # 10 checks passed. The contract holds.
make reset && make health     # HEALTHY — 7/7
bootstrap/gemini-key.sh check aco-workshop-2026   # every key OK
mkdir -p .local/audit-archive && mv agents/audit/*.jsonl .local/audit-archive/
```

The last line clears what `/audit` shows. Without it, `/audit` in Lab 1 prints every call
from earlier runs first: 268 lines in the dry run on 2026-10-26.

Two terminals side by side, large font:

- **Left: the agent.** Everything below happens here.
- **Right: the cluster, live.** Leave this running the whole time. The room sees pods
  appear, crash and come back as the agent works:
  ```bash
  kubectl get pods -n agentic-ops -w
  ```

At `you ›`, **Ctrl-R** plus a keyword brings back each long prompt, so you never paste in
front of the room: `web` (Lab 1 deploy), `shopfront` (Lab 1 fix and Lab 3), `harden`
(Lab 2). Lines starting with `/` run as you, not the agent; the agent never sees them.

## Lab 1: deploy, break, fix (about 3 min)

Dry run, 2026-10-26 09:38: `make lab` 13 s, deploy 59 s, `/break` 21 s, fix 38 s,
`/health` 7/7.

```bash
make lab LAB=1             # resets the namespace, prints the brief
make agent MODE=deploy
```

1. `you ›` Ctrl-R `web`, Enter: *Deploy an nginx web server called web with 3 replicas…*
   (about 1.5 min). Right pane: three `web-…` pods appear.
2. `you › /break`: you break `shopfront` (about 20 s). Right pane: a new `shopfront` pod
   goes `ErrImagePull` → `ImagePullBackOff`. **Say:** the agent was not told.
3. `you ›` Ctrl-R `shopfront`, Enter: *The shopfront deployment… is not healthy…* (about
   1.5 min).
4. `you › /health`: `HEALTHY — 7/7`. Then `you › /audit`: every call the agent made.
5. Enter on an empty line to leave.

**Point out:** it lists pods and reads the Deployment *before* it changes anything; it fixes
the image on the existing Deployment (no delete and recreate); its report names the cause,
the tag `nginx:1.27-alpine-doesnotexist`. Each `→` line is one tool call;
`← refused or failed` is the cluster saying no.

## Lab 2: harden without breaking (about 7 min)

```bash
make lab LAB=2
make agent MODE=harden
```

1. `you ›` Ctrl-R `harden`, Enter. It works one change at a time, with the referee after
   each.
2. While it runs, **say:** the referee is an independent check the agent can call but not
   change. Watch for `referee` followed by `← refused or failed`, which means it went red,
   and whether the next write undoes the change.
3. It ends with `max turns (60) reached`, and that is expected. `you › /health` shows 7/7.

**Point out:** what it rolled back. On 2026-10-26 it tried dropping capabilities and a
read-only filesystem on `shopfront`, saw the referee go red both times, and undid them.
It never finds the real fix: an unprivileged nginx on port 8080, with writable
`emptyDir` mounts. That is the brief's *it usually fails, and that is expected*. With pi
there is **no safety net**, so no `safety net:` line appears; with Claude Code there is
one.

## Lab 3: incident (about 2 min)

```bash
make lab LAB=3             # resets, and plants the fault: shopfront's image tag
make agent MODE=incident
```

1. `you ›` Ctrl-R `shopfront`, Enter.
2. `you › /health`: 7/7.

**Point out:** symptom versus cause. The symptom is a pod that won't start; the cause is a
tag that does not exist. Deleting the pod would change nothing, because the Deployment
makes the same broken one again. It runs the referee before it reports.

## If something goes wrong

| What you see | What to do |
|---|---|
| `… the model API is busy (503): retry 1/5 in 20 s` | Google is overloaded. Wait: it retries on its own. Say so to the room; it is a good moment about depending on a hosted model |
| It sits on a step for a long time | Ctrl-C stops the goal and keeps you at `you ›`. Ctrl-R the prompt and send it again |
| `max turns (N) reached` in Lab 1 or 3 | Rare. `/health` shows whether the work got done anyway |
| The app is left broken | `/reset` (or `/insecure` in Lab 2) puts the baseline back in about 12 s |
| You need the state where Lab 1 or 2 ends | `/catch-up 1` or `/catch-up 2` |
| The key stops working (402) | The prepaid credit has run out: top it up in AI Studio → Billing |
| The key stops working (400/403) | `CLIPBOARD=1 bootstrap/gemini-key.sh give aco-workshop-2026 leffen`, then `make gemini-key`, then paste |
| The cluster acts up | Leave the agent, `make cluster-up` (it repairs or reuses), then `make reset` |

## After the session

```bash
make reset
bootstrap/gemini-key.sh down aco-workshop-2026    # deletes every participant key
```
