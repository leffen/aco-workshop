# Agentic Cloud Ops — workshop repository

Everything you run in the **Agentic Cloud Ops** workshop at
[Cloud Native Days Norway 2026](https://2026.cloudnativedays.no/), Bergen, 26–27 October:
we let an AI agent deploy, debug and harden a live Kubernetes namespace, and look at where
the line is between useful and reckless.

**Prepare at home.** The full checklist, with per-OS install commands and the errors you
are likely to meet, is at **<https://aco.hlutur.no/prepare>**. It takes about fifteen
minutes, and a room full of laptops on conference Wi-Fi is the most likely way this
workshop fails.

## Prepare

You need at least 8 GB of free RAM, and these tools: Git, Docker (or Podman/Colima),
kubectl, k3d, make, Python 3.11 or newer, Node.js 20.6 or newer and Claude Code.
`make install` installs whichever are missing, on macOS, Linux and Windows (WSL2):

```bash
git clone https://github.com/leffen/aco-workshop.git
cd aco-workshop

make install               # the tools above; only what is missing. No make yet? bash bootstrap/install.sh
make setup                 # Python environment, .env, then the preflight
$EDITOR .env               # set ANTHROPIC_API_KEY
make preflight             # every line must say OK; it tells you what to fix if not
```

`make install` prints every command before it runs it; `make install DRY_RUN=1` prints them
and runs nothing. It uses Homebrew on macOS and apt or dnf on Linux, and puts kubectl, k3d
and Node in `~/.local/bin` there, each checked against a pinned checksum. It never installs
Docker on Linux or WSL: it tells you the step to take instead. On Windows, run it inside
WSL2 Ubuntu, not in PowerShell; outside WSL it prints the steps to get there.

Every command here is safe to re-run: `make install` and `make setup` only do what is not
done yet, and `make cluster-up` starts, repairs or reuses the cluster it finds. When in
doubt, run it again.

`.env` is git-ignored. Never commit it, and use a key you can rotate afterwards.

## On the day

```bash
make cluster-up            # a local k3d cluster, plus the workshop namespace
make agent-check           # the agent reaches the model and the cluster, and the guardrails hold
make lab LAB=1             # start a lab; LEVEL=easy|normal|hard picks your level
```

The agent runs inside Claude Code by default. To try another harness, add `HARNESS=` to one
command, or set `ACO_HARNESS` in `.env` to switch for good:

```bash
make agent-check HARNESS=pi-gemini      # needs GEMINI_API_KEY in .env
make agent MODE=incident HARNESS=pi-gemini
```

The labs were written and measured with Claude Code. Another harness has no `APPROVE=manual`
and no safety net, and its numbers are a series of their own.

`make help` lists every command. Prefer not to run a cluster locally? Open this repository
in a GitHub Codespace and run `make env-up ENV=codespaces` instead of `make cluster-up`.
Bringing your own cluster is `make env-up ENV=byo`.

> [!WARNING]
> **Use a throwaway cluster.** The agent gets write access to one namespace. Point it only
> at the local cluster, never at production, and never at a kubeconfig that shares
> credentials with production.

## Afterwards

```bash
make nuke                  # delete exactly the workshop namespace
make cluster-down          # delete the whole local cluster
```

## About this repository

It is generated from the workshop's development repository, one commit per published
snapshot, so `git pull` brings you the latest. Found something broken? Open an issue here,
or tell us in the room.

Leif Terje Fonnes and Lars Søraas
