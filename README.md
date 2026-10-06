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

You need Git, Docker (or Podman/Colima), kubectl, k3d, make and Python 3.11 or newer, and
at least 8 GB of free RAM.

```bash
git clone https://github.com/leffen/aco-workshop.git
cd aco-workshop

make setup                 # a virtual environment in .venv, with the one dependency
make preflight             # every line must say OK; it tells you what to fix if not

cp .env.example .env       # then set ANTHROPIC_API_KEY in it
```

`.env` is git-ignored. Never commit it, and use a key you can rotate afterwards.

## On the day

```bash
make cluster-up            # a local k3d cluster, plus the workshop namespace
make agent-check           # the agent reaches the model and the cluster, and the guardrails hold
make lab LAB=1             # start a lab; LEVEL=easy|normal|hard picks your level
```

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
