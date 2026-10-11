#!/usr/bin/env bash
# Preflight: run at home, on good bandwidth, the day before.
#
# Checks the tools, pre-pulls every image the labs use and warms the MCP server
# package, so that nothing large has to come over conference Wi-Fi. Then checks
# the model backend. Exits non-zero if anything a lab needs is missing, so the
# /prepare page can tell people to run it and trust the answer.
#
# Contacts no cluster: it runs before one exists. Safe to re-run, and offline
# once it has passed: images already pulled are not pulled again.
#
# Run it through make (make preflight, or make setup), which loads .env.
set -uo pipefail
cd "$(dirname "$0")/.."

MISSING=0
ok()   { printf '  \033[32mOK\033[0m       %s\n' "$1"; }
bad()  { printf '  \033[31mMISSING\033[0m  %s\n' "$1"; MISSING=$((MISSING+1)); }
note() { printf '           %s\n' "$1"; }
warn() { printf '  \033[33mLOW\033[0m      %s\n' "$1"; }   # worth fixing, but not missing

echo ""
echo "Tools"
for t in git docker kubectl k3d python3 npx; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t — run: make install"; fi
done
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
  ok "Python $(python3 -c 'import platform; print(platform.python_version())')"
else
  bad "Python 3.11 or newer (python3 is $(python3 -V 2>&1 | cut -d' ' -f2)) — run: make install"
fi
if .venv/bin/python -c 'import yaml' >/dev/null 2>&1; then ok ".venv"
else bad ".venv is missing or incomplete — run: make setup"; fi

# Read the pins from the one place they live, rather than repeating them here.
# A bad ACO_BACKEND or ACO_OLLAMA_MODEL is reported, not a crash.
BACKEND=none MODEL=- DIGEST=- BASE_URL=- MCP_PACKAGE=
if PINS=$(python3 -c '
import sys; sys.path.insert(0, ".")
from agents.modes import MCP_PACKAGE, backend
b = backend()
print(b.name, b.model, b.digest or "-", b.base_url or "-", MCP_PACKAGE)' 2>&1); then
  read -r BACKEND MODEL DIGEST BASE_URL MCP_PACKAGE <<<"$PINS"
else
  bad "the agent settings in .env: ${PINS##*$'\n'}"
fi

echo ""
echo "Images (pulled now, so the cluster does not fetch them in the room)"
# nginx-unprivileged is where Lab 2 usually ends up; busybox is the referee's probe.
IMAGES="nginx:1.27-alpine busybox:1.36 nginxinc/nginx-unprivileged:1.27-alpine"
if docker info >/dev/null 2>&1; then
  for img in $IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then ok "$img (already pulled)"
    elif docker pull -q "$img" >/dev/null 2>&1; then ok "$img"
    else bad "$img (pull failed)"; fi
  done
  # Docker's own disk, inside its VM. k3d.sh lowers the kubelet's eviction
  # threshold to 1%, and the whole workshop came up and passed verify with 2.7 GB
  # free (2026-10-06), so only below 2 GB is it missing. Under 5 GB is a warning.
  FREE_GB=$(docker run --rm busybox:1.36 df -k / 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
  if [ -z "$FREE_GB" ]; then bad "could not measure Docker's free disk"
  elif [ "$FREE_GB" -ge 5 ]; then ok "Docker has ${FREE_GB} GB of disk free"
  elif [ "$FREE_GB" -ge 2 ]; then warn "Docker has ${FREE_GB} GB of disk free: enough, but tight. docker system prune frees more"
  else bad "Docker has only ${FREE_GB} GB of disk free; 2 GB or more is needed — run: docker system prune"; fi
else
  # Name the runner the CLI is pointed at: telling a Colima user to start
  # Docker Desktop starts the wrong one.
  CONTEXT=$(docker context show 2>/dev/null || echo default)
  case "$CONTEXT" in
    colima)          START="run: colima start" ;;
    colima-*)        START="run: colima start ${CONTEXT#colima-}" ;;
    orbstack)        START="start OrbStack" ;;
    desktop-linux)   START="start Docker Desktop" ;;
    rancher-desktop) START="start Rancher Desktop" ;;
    *) if [ -n "${DOCKER_HOST:-}" ]; then START="start whatever serves DOCKER_HOST=$DOCKER_HOST"
       elif [ "$(uname -s)" = Darwin ]; then START="start Docker Desktop, Colima or OrbStack"
       else START="run: sudo systemctl start docker"; fi ;;
  esac
  bad "docker is installed but not running (context $CONTEXT) — $START, then re-run"
fi

echo ""
echo "Agent"
if [ -n "$MCP_PACKAGE" ] && command -v npx >/dev/null 2>&1 && npx -y "$MCP_PACKAGE" --help >/dev/null 2>&1; then
  ok "$MCP_PACKAGE (cached)"
else
  bad "$MCP_PACKAGE could not be fetched"
fi

# The harness first: until one is chosen there is no telling which key it needs,
# so nothing is asked for. Names come from generic_agent/run.py, like the pins.
HARNESSES="claude, $(python3 -c 'import sys; sys.path.insert(0, "."); from generic_agent.run import BACKENDS; print(", ".join(sorted(BACKENDS)))' 2>/dev/null)"
HARNESS="${ACO_HARNESS:-}"
if [ -z "$HARNESS" ]; then
  bad "no agent harness selected — set ACO_HARNESS in .env to one of: $HARNESSES"
elif [ "$HARNESS" = claude ]; then
  if command -v claude >/dev/null 2>&1; then ok "claude (harness claude)"
  else bad "claude — run: make install"; fi
  case "$BACKEND" in
    ollama)
      if ! command -v ollama >/dev/null 2>&1; then
        bad "ollama (the model backend is $MODEL, local)"
      elif ! curl -s -m 5 "$BASE_URL/api/tags" >/dev/null 2>&1; then
        bad "ollama is installed but not answering at $BASE_URL — run: ollama serve"
      elif curl -s -m 5 "$BASE_URL/api/tags" | python3 -c '
import json, sys
tags = json.load(sys.stdin)
sys.exit(0 if any(m["name"] == sys.argv[1] and m["digest"] == sys.argv[2]
                  for m in tags.get("models", [])) else 1)' "$MODEL" "$DIGEST"; then
        ok "$MODEL, the pinned build ${DIGEST:0:12}"
      else
        # The aco-* ladder models are built here from a Modelfile, not pulled.
        TAG="${MODEL%:latest}" FIX="ollama pull $MODEL"
        if [ -f "agents/ladder/$TAG.Modelfile" ]; then
          FIX="ollama pull $(awk '$1 == "FROM" {print $2}' "agents/ladder/$TAG.Modelfile") && ollama create $TAG -f agents/ladder/$TAG.Modelfile"
        fi
        HAVE=$(curl -s -m 5 "$BASE_URL/api/tags" | python3 -c '
import json, sys
print(next((m["digest"] for m in json.load(sys.stdin).get("models", [])
            if m["name"] == sys.argv[1]), ""))' "$MODEL" 2>/dev/null)
        if [ -z "$HAVE" ]; then
          bad "$MODEL is not on this machine — run: $FIX"
        else
          bad "$MODEL is build ${HAVE:0:12}, not the pinned ${DIGEST:0:12} — run: $FIX. Still different after that: its tag has moved upstream, and it is a model nobody has measured yet"
        fi
      fi
      # The model and the cluster share this machine's memory. On an 8 GB Mac
      # (2026-10-11) aco-qwen3-4b-24k took 6.7 GB beside an 8 GiB Colima VM: it
      # swapped, ran at 0.2 tokens/s, and every eval run timed out without a
      # single tool call. Under 16 GB is a warning, not missing: the hosted
      # backend still works.
      case "$(uname -s)" in
        Darwin) RAM_GB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) ;;
        *)      RAM_GB=$(awk '/^MemTotal:/ {print int($2/1048576)}' /proc/meminfo 2>/dev/null || echo 0) ;;
      esac
      VM=""
      if [ "$(uname -s)" = Darwin ] && VM_GB=$(docker info --format '{{.MemTotal}}' 2>/dev/null); then
        VM=" and Docker's VM claims $(( VM_GB / 1073741824 )) GB of it"
      fi
      if [ "${RAM_GB:-0}" -eq 0 ]; then :
      elif [ "$RAM_GB" -ge 16 ]; then ok "${RAM_GB} GB of RAM, enough for $MODEL beside the cluster"
      else
        warn "${RAM_GB} GB of RAM${VM}: too little to run $MODEL beside the cluster. It swaps, and agent runs time out"
        note "use the hosted model instead: ACO_BACKEND=anthropic and ANTHROPIC_API_KEY in .env"
      fi
      ;;
    anthropic)
      # Say what is wrong with it. Never print it.
      KEY="${ANTHROPIC_API_KEY:-}"
      case "$KEY" in
        "")            bad "ANTHROPIC_API_KEY is not set — put it in .env (the backend is $MODEL)" ;;
        "sk-ant-...")  bad "ANTHROPIC_API_KEY is still the placeholder from .env.example — put your key in .env" ;;
        *[\"\'\ ]*)    bad "ANTHROPIC_API_KEY has quotes or spaces in it — .env takes plain KEY=value" ;;
        sk-ant-*)      ok "ANTHROPIC_API_KEY is set (backend $MODEL)" ;;
        *)             bad "ANTHROPIC_API_KEY does not look like an Anthropic key (they start sk-ant-)" ;;
      esac
      ;;
  esac
# Another harness: check its key and warm its package. Say what is wrong with
# the key, never print it.
elif H=$(python3 -c '
import sys; sys.path.insert(0, ".")
from generic_agent.run import BACKENDS, PI_PACKAGE
b = BACKENDS[sys.argv[1]]
print(b.key_env, PI_PACKAGE if b.harness == "pi" else "-")' "$HARNESS" 2>/dev/null); then
  read -r KEY_ENV H_PACKAGE <<<"$H"
  if [ -n "${!KEY_ENV:-}" ]; then ok "$KEY_ENV is set (harness $HARNESS)"
  else bad "$KEY_ENV is not set — put it in .env (the harness is $HARNESS)"; fi
  if [ "$H_PACKAGE" = - ]; then :
  elif npx -y "$H_PACKAGE" --version >/dev/null 2>&1; then ok "$H_PACKAGE (cached)"
  else bad "$H_PACKAGE could not be fetched"; fi
else
  bad "ACO_HARNESS=$HARNESS is not a harness. One of: $HARNESSES"
fi

echo ""
if [ "$MISSING" -eq 0 ]; then
  printf '\033[32mReady. Next: make cluster-up\033[0m\n\n'
  exit 0
fi
printf '\033[31m%s missing. Fix those, then run make preflight again.\033[0m\n\n' "$MISSING"
exit 1
