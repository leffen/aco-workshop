# Run-through 2: all three labs on a paid key

**Date:** 2026-10-26, 06:49–07:01 CET, the morning of the workshop
**Harness:** `pi-gemini` with the new `you ›` prompt, model `gemini-flash-latest` (= `gemini-3.8-flash`)
**Key:** `key-1` from `bootstrap/gemini-key.sh up aco-workshop-2026`, a prepaid billing account
**How:** every lab at level easy, typed through the prompt as a participant would
(`/lab N`, the brief's goal, `/break`, `/health`), one runner per goal so each keeps its own
pi event stream. Logs: [`logs/`](logs/).

Previous run on free keys: [`../2026-10-25-pi-gemini/`](../2026-10-25-pi-gemini/README.md).

## Results

| Goal | Outcome | Referee | Time | Model calls | Cost (upper bound) |
|---|---|---|---|---|---|
| Lab 1, deploy `web` | `web` ran 3/3, but **max turns (15)** before the report | – | 93 s | 16 | $0.15 |
| Lab 1, fix `shopfront` after `/break` | **fixed**, cause named | 7/7 | 98 s | 7 | $0.09 |
| Lab 2, harden | `worker` fully hardened, `shopfront` partly; **max turns (40)**; app still serving | 7/7 | 359 s | 41 | $1.08 |
| Lab 3, incident | **fixed**, cause named, referee before the report | 7/7 | 122 s | 5 | $0.12 |
| **Total** | | | **~11 min** | 69 | **≤ $1.45** |

No retries at all: not one 429 or 503 on the paid tier, against 26 retries for Lab 2 alone
on free Gemma last night.

## Cost per participant

Tokens: 475K input, 1.30M cached input, 31K output (thinking included). The cost column
charges cached tokens at the full input price, $0.75 per million (output: $3.75 per
million). Google bills cached tokens for less, so the real figure is lower.

**Budget about $1.50 per participant for the three easy labs.** Lab 2 is three
quarters of it: each of its 41 calls carries the whole run so far, about 33K tokens
on average. Normal and hard levels, `make agent-check` and second attempts come on top, so
prepay **$2–3 per participant**. Prices double on 2027-01-01.

## What the agent did

**Lab 1, deploy.** It went exploring before it deployed anything: the referee, events,
Nodes (refused: no cluster scope), the `worker` Deployment, and `pods_exec` to ping
8.8.8.8 from inside the worker pod (refused by RBAC). Then it created `web` and its
Service, and ran out of turns while confirming. `web` did reach 3/3: the fix step's pod list
shows three `web` pods Running. A participant sees `max turns (15) reached` and no report.
This is the brief's own goal, so on Flash the deploy limit of 15 turns is tight.

**Lab 1, fix.** It listed pods, read the Deployment, restored `nginx:1.27-alpine` on the
existing Deployment, ran the referee and reported the cause
(`nginx:1.27-alpine-doesnotexist`). Brief checklist: all four ✔.

**Lab 2, harden.** It took the prompt literally, one change at a time, with the referee
after each:

```
worker     limits + readOnlyRootFilesystem              → referee 7/7
worker     + allowPrivilegeEscalation: false            → 7/7
worker     + drop ALL capabilities                      → 7/7
worker     + runAsNonRoot                               → 7/7  (worker done)
shopfront  limits                                       → 7/7
shopfront  + allowPrivilegeEscalation: false            → 6/7 during the rollout, re-ran → 7/7
… out of turns (40)
```

It re-ran the referee after the red result during the rollout instead of rolling back,
which is what the brief's checklist asks for. It never reached the hard part, non-root
nginx on port 80, so the trap that broke `shopfront` last night was not tested. The
application served traffic throughout. Each change cost a write, a referee call, a pod
list and logs, so 40 turns covered about 7 changes.

**Lab 3, incident.** It ran the referee, listed pods and events, read the Deployment, then
fixed the image and ran the referee again. Its report names the cause, not the symptom.
Brief checklist: all ✔.

## Findings

1. **The paid key removes every problem from the first run.** No quota errors, no
   retries, and about 11 minutes for all three labs (last night: one lab took 25 minutes and
   died).
2. **The turn limits are tight for Flash.** It explores more than the briefs assume. Lab
   1's deploy ran out at 15 with the work done but no report, and Lab 2 ran out at 40 with
   only 7 changes made. The limits in `agents/modes.py` were set for Claude Code, so a
   higher limit for `pi-gemini` (say 25 for deploy, 60 for harden) would make the briefs'
   "you should see a report" true. More turns cost more, though: Lab 2 at 60 turns comes to
   about $2.
   *Done the same morning:* the `pi-gemini` backend now allows 25 turns for deploy and
   60 for harden (`max_turns` in `generic_agent/run.py`); incident stays at 20. Lab 1's
   deploy, rerun with 25: 20 turns, `web` 3/3, a full report, referee 7/7
   (`logs/lab1-a-deploy-25turns.log`).

## Lab 2 again, at 60 turns (09:15)

`logs/lab2-harden-60turns.log`. It ran out of turns again (60), in 6 min 48 s, with no
retries, for at most **$2.34**: 61 calls, 3.0M input tokens (2.75M of them cached), 23K output.
It never wrote a final report, but the referee showed **7/7** at the end. This time it
started with `shopfront`:

```
shopfront  limits                     → one malformed YAML write (refused), then ok → 7/7
shopfront  + allowPrivilegeEscalation → 7/7
shopfront  + drop ALL capabilities    → 6/7 → rolled back → 7/7
shopfront  + runAsNonRoot             → reverted after two writes, without the referee
shopfront  + readOnlyRootFilesystem   → 6/7 → rolled back → 7/7
worker     limits + readOnlyRootFilesystem + emptyDir /tmp
… out of turns
```

It did what the prompt asks: each change that went red was rolled back, so the app
served traffic throughout. It never found the real fix for `shopfront`, an unprivileged
image on port 8080 with an `emptyDir` for each path nginx writes to. Instead it kept
`shopfront` at limits plus no privilege escalation, and spent the turns that were left
on `worker`.

So 60 turns made the run longer and safer, but it still doesn't finish. On Flash, Lab 2
is the lab where the brief's "it usually fails, and that is expected" comes true: the
application survives, but nothing gets fully hardened. More turns would mostly add cost:
each call carries the whole run so far, about 50K tokens per call by the end.
3. **The prompt works as a participant would use it.** `/lab`, `/break` and `/health`
   all ran inside the same `you ›` session, and the briefs needed no changes.
4. **RBAC did its job.** The two forbidden calls (Nodes, `pods_exec`) came back refused
   on the cluster side. Last night's agent check could not show that, because the model
   never tried.
