# Agentic Cloud Ops — workshop repository

The labs from the **Agentic Cloud Ops** workshop at
[Cloud Native Days Norway 2026](https://2026.cloudnativedays.no/), Bergen, 26–27 October.
You let an AI agent deploy, debug and harden a live Kubernetes namespace, and look at where
the line is between useful and reckless.

The workshop is over, and this repository stays up so you can run the labs again, at your
own pace. Everything in it works without us in the room. The lab pages with the background
and the debrief are at **<https://aco.hlutur.no/>**, and the setup checklist, with per-OS
install commands and the errors you are likely to meet, is at
**<https://aco.hlutur.no/prepare>**.

## What you need

- **A cluster you can throw away.** A local k3d cluster that `make` builds for you, or a
  GitHub Codespace.
- **A model.** One of:
  - **Google Gemini through pi**, with your own Gemini API key from
    [Google AI Studio](https://aistudio.google.com/apikey). The key's Google project needs
    billing: a free-tier key allows 20 requests a day and runs out before the first lab
    ends, and `make gemini-key` refuses one that already has. In the workshop the three
    labs came to about 160 model calls per person, roughly 100 kr at list price. Set a
    budget alert on the project before you start.
  - **Claude Code**, with an Anthropic API key or your Claude Pro or Max login. The labs
    were written and measured with it.
  - **A local model with Ollama**, if your machine has the memory for it (below).

## Run it in a Codespace: nothing to install

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/leffen/aco-workshop?quickstart=1)

The cluster and the agent run in the Codespace, and your laptop needs only a browser. The
agent runs in pi with Gemini there.

1. **Raise your idle timeout first**, at <https://github.com/settings/codespaces>, to
   120 minutes. The default 30 stops a Codespace in the middle of a long lab.
2. Open the Codespace with the button above, and wait for the terminal.
3. Run:

   ```bash
   make env-up ENV=codespaces  # the cluster, about a minute
   make gemini-key             # paste your Gemini key; it is checked, never shown
   make agent-check            # the agent reaches the model and the cluster
   ```

A 4-core Codespace uses about 12 of your 120 free core-hours a month for the three labs.
Delete it when you are done, at <https://github.com/codespaces>.
To use Claude Code instead, set `ACO_HARNESS=claude` in `.env` and run `make key`.

## Run it on your laptop

You need at least 8 GB of free RAM, and these tools: Git, Docker (or Podman/Colima),
kubectl, k3d, make, Python 3.11 or newer, Node.js 20.6 or newer and Claude Code.
Running the model locally with Ollama takes the model's own size plus about 6 GB for the
cluster and your apps: 13 GB of RAM for `aco-qwen3-4b-24k`, 20 GB for `gpt-oss:20b`. With
less, it swaps until every agent run times out. `make preflight` warns when yours has less.
On a smaller machine, use a Codespace (above): the cluster and the model then both run off
your laptop.

`make install` installs whichever are missing, on macOS, Linux and Windows (WSL2):

```bash
git clone https://github.com/leffen/aco-workshop.git
cd aco-workshop

make install               # the tools above; only what is missing. No make yet? bash bootstrap/install.sh
make setup                 # Python environment, .env, your harness and its key (it asks), then the preflight
make preflight             # every line must say OK or LOW; it tells you what to fix if not
make cluster-up            # a local k3d cluster, plus the workshop namespace
make agent-check           # the agent reaches the model and the cluster, and the guardrails hold
```

`make install` prints every command before it runs it; `make install DRY_RUN=1` prints them
and runs nothing. It uses Homebrew on macOS and apt or dnf on Linux, and puts kubectl, k3d
and Node in `~/.local/bin` there, each checked against a pinned checksum. It never installs
Docker on Linux or WSL: it tells you the step to take instead. On Windows, run it inside
WSL2 Ubuntu, not in PowerShell; outside WSL it prints the steps to get there.

Every command here is safe to re-run: `make install` and `make setup` only do what is not
done yet, and `make cluster-up` starts, repairs or reuses the cluster it finds. When in
doubt, run it again.

`make setup` asks which harness to use and for its key, and writes both into `.env`; the
key is read hidden and never printed. `make key` asks for the key again. `.env` is
git-ignored. Never commit it, and use a key you can rotate afterwards.

No API key? If you have a Claude Pro or Max plan, choose `claude` when `make setup` asks,
press Enter to skip the key, set `ACO_BACKEND=claude-login` in `.env`, and log in once with
`claude auth login`. The agent then runs on your own Claude Code login,
the same model with the same tools and limits, and `make preflight` checks the login
instead of a key. Your own CLAUDE.md, hooks, plugins and skills are kept out of it.

## The labs

Each lab starts from a known state and prints its brief. Pick a level with `LEVEL=`:
`easy` (the default) gives you the prompts, `normal` has you write your own, and `hard`
asks a harder question of the same lab, such as which guardrail layer stops the agent. The
briefs are also in `labs/briefs/`.

```bash
make lab LAB=1             # Lab 1: the agent deploys a web server, then fixes a fault you plant
make lab LAB=2             # Lab 2: it hardens two insecure deployments without breaking them
make lab LAB=3             # Lab 3: an incident whose obvious fix is out of the agent's reach
make agent MODE=deploy     # start the agent; the brief says which MODE each step uses
```

Commands you will use along the way:

| Command | What it does |
|---|---|
| `make health` | The referee: checks that the app actually works. The agent may run it, never change it. |
| `make audit` | Every tool call the agent made. |
| `make reset` | The namespace back to its starting state, in about 12 seconds. |
| `make catch-up LAB=1` | Puts the namespace where a lab ends, to skip ahead. |
| `make chaos` | Breaks something at random, for Lab 3 or for practice. |
| `make help` | Every command. |

The harness the agent runs inside is `ACO_HARNESS` in `.env`: `claude` (Claude Code) or
`pi-gemini`. A Codespace starts on `pi-gemini`; on a laptop, `make setup` asks. To try
another for a single command, add `HARNESS=`:

```bash
make agent-check HARNESS=pi-gemini      # needs GEMINI_API_KEY in .env
make agent MODE=incident HARNESS=pi-gemini
```

The labs were written and measured with Claude Code. Another harness has no `APPROVE=manual`
and no safety net, and its numbers are a series of their own. Expect Lab 2 to go wrong in
places: the agent rarely finds the full fix on its own, and seeing where it stops is the
point of the lab.

Bringing your own cluster is `make env-up ENV=byo`.

> [!WARNING]
> **Use a throwaway cluster.** The agent gets write access to one namespace. Point it only
> at the local cluster, never at production, and never at a kubeconfig that shares
> credentials with production.

## Quests

The quest board from the workshop is still open at <https://quests.aco.hlutur.no/>, with
the results from the day. Solve a quest on your own cluster and submit the answer:

```bash
make quest-list                             # every quest, its level and XP
make quest-show QUEST=first-blood           # one quest's card
make quest-submit QUEST=<id> ANSWER=<answer> HANDLE=<nickname>
make quest-board                            # the top ten
```

Your handle is shown on the board, so pick a nickname, not your real name.

## When you are done

```bash
make nuke                  # delete exactly the workshop namespace
make cluster-down          # delete the whole local cluster
```

Then delete your Codespace if you used one, and rotate or delete the API key you used.

## About this repository

It is generated from the workshop's development repository, one commit per published
snapshot, so `git pull` brings you the latest. Found something broken, or a question the
lab pages don't answer? [Open an issue](https://github.com/leffen/aco-workshop/issues).

Leif Terje Fonnes and Lars Søraas
