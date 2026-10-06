#!/usr/bin/env bash
# Rebuild the model ladder's rungs from the Modelfiles here, and print each
# one's digest. Compare them with OLLAMA_MODELS in agents/modes.py: a mismatch
# means a base model moved, and that rung's numbers belong to a different model.
set -euo pipefail
cd "$(dirname "$0")"
for mf in *.Modelfile; do
  tag="${mf%.Modelfile}"
  ollama create "$tag" -f "$mf" >/dev/null
  curl -s localhost:11434/api/tags | python3 -c 'import sys,json
for m in json.load(sys.stdin)["models"]:
  if m["name"] == sys.argv[1] + ":latest": print(m["name"], m["digest"])' "$tag"
done
