#!/usr/bin/env bash
# Preflight: run at home, on good bandwidth, the day before.
#
# Checks the tools, pre-pulls every image the labs use and warms the MCP server
# package, so that nothing large has to come over conference Wi-Fi. Then checks
# the model backend. Exits non-zero if anything a lab needs is missing, so the
# /prepare page can tell people to run it and trust the answer.
#
# Contacts no cluster: it runs before one exists.
set -uo pipefail
cd "$(dirname "$0")/.."

MISSING=0
ok()   { printf '  \033[32mOK\033[0m       %s\n' "$1"; }
bad()  { printf '  \033[31mMISSING\033[0m  %s\n' "$1"; MISSING=$((MISSING+1)); }
note() { printf '           %s\n' "$1"; }

echo ""
echo "Tools"
for t in git docker kubectl k3d python3 claude npx; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t"; fi
done

# Read the pins from the one place they live, rather than repeating them here.
read -r BACKEND MODEL DIGEST BASE_URL MCP_PACKAGE < <(python3 -c '
import sys; sys.path.insert(0, ".")
from agents.modes import MCP_PACKAGE, backend
b = backend()
print(b.name, b.model, b.digest or "-", b.base_url or "-", MCP_PACKAGE)')

echo ""
echo "Images (pulled now, so the cluster does not fetch them in the room)"
# nginx-unprivileged is where Lab 2 usually ends up; busybox is the referee's probe.
IMAGES="nginx:1.27-alpine busybox:1.36 nginxinc/nginx-unprivileged:1.27-alpine"
if docker info >/dev/null 2>&1; then
  for img in $IMAGES; do
    if docker pull -q "$img" >/dev/null 2>&1; then ok "$img"; else bad "$img (pull failed)"; fi
  done
else
  bad "docker is installed but not running — start Docker Desktop, then re-run"
fi

echo ""
echo "Agent"
if command -v npx >/dev/null 2>&1 && npx -y "$MCP_PACKAGE" --help >/dev/null 2>&1; then
  ok "$MCP_PACKAGE (cached)"
else
  bad "$MCP_PACKAGE could not be fetched"
fi

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
      bad "$MODEL is not pulled, or not the pinned build — run: ollama pull $MODEL"
    fi
    ;;
  anthropic)
    # Say whether it is set. Never print it.
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then ok "ANTHROPIC_API_KEY is set"
    else bad "ANTHROPIC_API_KEY (the model backend is $MODEL)"; fi
    ;;
esac

echo ""
if [ "$MISSING" -eq 0 ]; then
  printf '\033[32mReady. Next: make cluster-up\033[0m\n\n'
  exit 0
fi
printf '\033[31m%s missing. Fix those, then run make preflight again.\033[0m\n\n' "$MISSING"
exit 1
