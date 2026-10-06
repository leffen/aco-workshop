# The participant's Makefile.
#
# Everything a participant runs on the day, and nothing else. The developer
# Makefile includes this file; participant/export.py ships it as the
# participant repository's Makefile. One source, so the two cannot drift.
# Keep developer-only targets (docs, web, evals sweeps, quest server) out of
# here: tests/test_participant_export.py fails if a brief names a target the
# participant repository does not have.

CLUSTER_NAME ?= agentic-ops
KUBE_CONTEXT ?= k3d-$(CLUSTER_NAME)
VENV ?= .venv
PY   ?= $(VENV)/bin/python

.DEFAULT_GOAL := help

# .env holds your settings (ANTHROPIC_API_KEY, ACO_BACKEND), and every target
# sees them. make setup creates it from .env.example. As with any dotenv, what
# you set in the shell or on the command line wins over the file. Tolerated:
# `export KEY=value`, quotes around the value, Windows line endings.
# Written for GNU Make 3.81 too: that is what macOS ships as /usr/bin/make.
ifneq ($(wildcard .env),)
ENV_FILE_VARS := $(shell sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' .env)
env_file_value = $(shell tr -d '\r' < .env | sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?$(1)[[:space:]]*=[[:space:]]*//p' | tail -n 1 | sed -E 's/[[:space:]]+$$//; s/^"(.*)"$$/\1/; s/^'"'"'(.*)'"'"'$$/\1/')
$(foreach v,$(ENV_FILE_VARS),$(eval $(v) ?= $(call env_file_value,$(v))))
export $(ENV_FILE_VARS)
endif

.PHONY: help
help: ## Show available commands
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: setup
setup: ## Python environment, .env, then the preflight. Safe to re-run
	@VENV=$(VENV) MAKE="$(MAKE)" bootstrap/setup.sh

# Targets that run the harness depend on this, so a skipped make setup is
# repaired on demand instead of failing on a missing .venv/bin/python.
$(VENV)/.installed: requirements.txt
	@VENV=$(VENV) bootstrap/setup.sh venv

## --- Environments ---
## One contract, three ways in: codespaces, k3d or your own cluster.

ENV       ?= k3d
NAMESPACE ?= agentic-ops
export NAMESPACE

.PHONY: env-up
env-up: ## Bring up an environment. Usage: make env-up ENV=codespaces|k3d|byo
	@test -x bootstrap/env/$(ENV).sh || { \
		echo "unknown ENV='$(ENV)'. One of: codespaces, k3d, byo"; exit 1; }
	@bootstrap/env/$(ENV).sh
	@bootstrap/apply.sh
	@$(MAKE) --no-print-directory verify

.PHONY: verify
verify: ## Prove the environment contract holds, whatever the environment
	@bootstrap/verify.sh

.PHONY: ladder
ladder: ## Show what each rung of the RBAC ladder can do
	@for sa in agent-ro agent-ns agent-harden; do \
		echo ""; echo "=== $$sa ==="; \
		kubectl auth can-i --list \
			--as=system:serviceaccount:$(NAMESPACE):$$sa \
			-n $(NAMESPACE) 2>/dev/null; \
	done

.PHONY: nuke
nuke: ## Delete exactly the workshop namespace, after printing what will go
	@bootstrap/nuke.sh

.PHONY: prove
prove: $(VENV)/.installed ## Check a quest on your namespace, print its proof. Reads, plus the referee's probe pod; honour system. Usage: make prove QUEST=<id>
	@test -n "$(QUEST)" || { echo "usage: make prove QUEST=first-blood|harden-without-breaking"; exit 1; }
	@$(PY) evals/run.py --prove "$(QUEST)"

## --- Cluster (thin aliases over the environment contract) ---

.PHONY: preflight
preflight: ## Check tools, pre-pull images, warm the agent. Exits non-zero if anything is missing
	@bootstrap/preflight.sh

.PHONY: cluster-up
cluster-up: ## Alias for: make env-up ENV=k3d
	@$(MAKE) --no-print-directory env-up ENV=k3d

.PHONY: cluster-down
cluster-down: ## Delete the whole local k3d cluster (see also: make nuke)
	k3d cluster delete $(CLUSTER_NAME)

## --- Quests ---
# Playing: one command each. quests/cli.py is stdlib-only, so python3, no venv.
# QUEST, ANSWER and HANDLE reach it through the environment, via $(value ...):
# never spliced into a shell or JSON string (a proof string carries `:` and `,`),
# and not even make expands a `$` in them. The claim token is kept in
# .local/quests.json, per server, after the first submission.
QUEST_SERVER ?= https://quests.aco.hlutur.no
export QUEST_SERVER

quest-show quest-submit: export QUEST_ID = $(value QUEST)
quest-submit: export QUEST_ANSWER = $(value ANSWER)
quest-submit: export QUEST_HANDLE = $(value HANDLE)

.PHONY: quest-list
quest-list: ## The quest board: id, title, level, XP, how many solved it. [QUEST_SERVER=]
	@python3 quests/cli.py list

.PHONY: quest-show
quest-show: ## One quest's card. Usage: make quest-show QUEST=<id>
	@python3 quests/cli.py show

.PHONY: quest-submit
quest-submit: ## Submit an answer. Usage: make quest-submit QUEST=<id> ANSWER=<answer> [HANDLE=<handle>, first time]
	@python3 quests/cli.py submit

.PHONY: quest-board
quest-board: ## The top ten on the scoreboard
	@python3 quests/cli.py board

## --- Evals ---

AGENT ?= claude

.PHONY: eval
eval: $(VENV)/.installed ## Run one scenario. Usage: make eval SCENARIO=<id> N=10 [AGENT=oracle]
	@$(PY) evals/run.py --scenario $(SCENARIO) --runs $(or $(N),10) --agent $(AGENT)

.PHONY: reset
reset: ## Reset the namespace to a known-good baseline (~12s)
	@evals/reset.sh && echo "baseline restored"

.PHONY: audit
audit: ## Show the agent's tool-call audit log. [SESSION=<id>] for an APPROVE=manual run
	@python3 agents/audit.py $(if $(SESSION),--session $(SESSION))

## --- Labs ---

.PHONY: agent-check
agent-check: ## Verify the agent reaches the model and the cluster, and both guardrail layers hold
	@python3 agents/run.py --check

MODE    ?= deploy
APPROVE ?= auto
SAFETY_NET ?=

# python3, not $(PY): the runner is stdlib-only so participants need no venv.
.PHONY: agent
agent: ## Run the agent. Usage: make agent MODE=deploy|harden|incident [APPROVE=manual] [SAFETY_NET=off]
	@$(if $(SAFETY_NET),ACO_SAFETY_NET=$(SAFETY_NET) )python3 agents/run.py --mode $(MODE) --approve $(APPROVE)

# The labs replay the eval scenarios' own steps, so a lab and its measurement
# cannot drift apart. Every one of these goes through the harness's ownership
# guard and pinned context.
.PHONY: lab1-break
lab1-break: $(VENV)/.installed ## Lab 1: plant an ImagePullBackOff
	@$(PY) evals/run.py --scenario imagepullbackoff --phase break

LEVEL ?= easy
.PHONY: lab
lab: $(VENV)/.installed ## Start a lab at your level. Usage: make lab LAB=1|2|3 [LEVEL=easy|normal|hard]
	@test -n "$(LAB)" || { echo "Usage: make lab LAB=1|2|3 [LEVEL=easy|normal|hard]"; exit 1; }
	@$(PY) bin/lab.py --lab $(LAB) --level $(or $(LEVEL),easy)

CATCHUP_1 = deploy-web
CATCHUP_2 = harden-restricted

.PHONY: catch-up
catch-up: $(VENV)/.installed ## Put the namespace where lab N ends. Usage: make catch-up LAB=1|2
	@test -n "$(CATCHUP_$(LAB))" || { echo "LAB must be 1 or 2"; exit 1; }
	@evals/reset.sh
	@$(PY) evals/run.py --scenario $(CATCHUP_$(LAB)) --phase fix

.PHONY: insecure
insecure: ## Lab 2: back to the deliberately insecure baseline (it IS the baseline)
	@evals/reset.sh && echo "insecure baseline restored"

.PHONY: health
health: ## The referee. Deterministic; the agent may run it, never change it
	@bin/health.sh

.PHONY: chaos
chaos: $(VENV)/.installed ## Lab 3: break something. SCENARIO=<id> picks it; otherwise a random chaos scenario
	@$(PY) evals/run.py $(if $(SCENARIO),--scenario $(SCENARIO),--chaos) --phase setup,break
