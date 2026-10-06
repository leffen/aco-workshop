#!/usr/bin/env bash
# make setup: everything a participant needs before a cluster, in one command.
#
#   bootstrap/setup.sh          the Python environment, .env, then the preflight
#   bootstrap/setup.sh venv     the Python environment only (make does this on demand)
#   bootstrap/setup.sh env      .env only
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
    say "created .env from .env.example. Put your ANTHROPIC_API_KEY in it."
  fi
}

case "${1:-all}" in
  venv) venv ;;
  env)  env_file ;;
  all)
    venv
    env_file
    echo
    # Through make, so .env is loaded exactly as every other target sees it.
    exec "${MAKE:-make}" --no-print-directory preflight
    ;;
  *) fail "usage: $0 [venv|env]" ;;
esac
