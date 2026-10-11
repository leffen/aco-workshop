#!/usr/bin/env bash
# make setup: everything a participant needs before a cluster, in one command.
#
#   bootstrap/setup.sh          the Python environment, .env, then the preflight
#   bootstrap/setup.sh venv     the Python environment only (make does this on demand)
#   bootstrap/setup.sh env      .env only
#   bootstrap/setup.sh docker   start Colima if it is the docker context and not running
#
# Safe to run any number of times. Each step checks before it acts:
#   - .venv is created if missing or broken (a Homebrew Python upgrade leaves it
#     pointing at nothing), and pip runs only when requirements.txt has changed.
#   - .env is copied from .env.example only if it does not exist. Never overwritten.
set -euo pipefail
cd "$(dirname "$0")/.."

VENV="${VENV:-.venv}"
PYTHON="${PYTHON:-python3}"
MIN_PY="3.11"

say()  { printf '==> %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

venv() {
  command -v "$PYTHON" >/dev/null 2>&1 \
    || fail "$PYTHON not found. Install Python $MIN_PY or newer (macOS: brew install python)."
  "$PYTHON" -c "import sys; sys.exit(sys.version_info < (${MIN_PY/./, }))" \
    || fail "Python $MIN_PY or newer is needed; $PYTHON is $("$PYTHON" -V 2>&1 | cut -d' ' -f2)."

  if [ -d "$VENV" ] && ! "$VENV/bin/python" -c "" >/dev/null 2>&1; then
    say "$VENV is broken (its Python moved or was upgraded); recreating it"
    rm -rf "$VENV"
  fi
  if [ ! -d "$VENV" ]; then
    say "creating $VENV"
    "$PYTHON" -m venv "$VENV" \
      || fail "could not create $VENV. On Debian/Ubuntu: sudo apt install python3-venv"
  fi

  # The stamp holds the requirements it was installed from, so a changed file
  # reinstalls and an unchanged one costs nothing, not even a network call.
  if cmp -s requirements.txt "$VENV/.installed" 2>/dev/null; then
    say "Python dependencies already installed"
  else
    say "installing Python dependencies"
    "$VENV/bin/python" -m pip install -q --disable-pip-version-check -r requirements.txt
    cp requirements.txt "$VENV/.installed"
  fi
}

env_file() {
  if [ -f .env ]; then
    say ".env exists; leaving it as it is"
  else
    cp .env.example .env
    say "created .env from .env.example. Pick your agent harness (ACO_HARNESS) and put its key in it."
  fi
}

# Colima is the one runtime we can start without a GUI, so a stopped one is
# started here. Anything else (Docker Desktop, OrbStack, ...) is left to the
# preflight, which says how to start it.
docker_up() {
  command -v docker >/dev/null 2>&1 || return 0
  docker info >/dev/null 2>&1 && return 0
  local context
  context=$(docker context show 2>/dev/null || echo default)
  command -v colima >/dev/null 2>&1 || return 0
  # colima stop switches the context back to default, so a dead default with
  # Colima installed counts too.
  case "$context" in
    colima|default) set -- ;;
    colima-*)       set -- "${context#colima-}" ;;
    *)              return 0 ;;
  esac
  say "docker is not running (context $context); starting colima"
  colima start "$@" || say "colima start failed; the preflight will report it"
}

case "${1:-all}" in
  venv) venv ;;
  env)  env_file ;;
  docker) docker_up ;;
  all)
    venv
    env_file
    docker_up
    echo
    # Through make, so .env is loaded exactly as every other target sees it.
    exec "${MAKE:-make}" --no-print-directory preflight
    ;;
  *) fail "usage: $0 [venv|env|docker]" ;;
esac
