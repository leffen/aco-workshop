#!/usr/bin/env bash
# make setup: everything a participant needs before a cluster, in one command.
#
#   bootstrap/setup.sh          the Python environment, .env, the key, then the preflight
#   bootstrap/setup.sh venv     the Python environment only (make does this on demand)
#   bootstrap/setup.sh env      .env only
#   bootstrap/setup.sh key      ask for the key again: make key
#   bootstrap/setup.sh docker   start Colima if it is the docker context and not running
#
# Safe to run any number of times. Each step checks before it acts:
#   - .venv is created if missing or broken (a Homebrew Python upgrade leaves it
#     pointing at nothing), and pip runs only when requirements.txt has changed.
#   - .env is copied from .env.example only if it does not exist. Never overwritten.
#     ACO_DEFAULT_HARNESS, set by the Codespace, pre-selects the harness in it.
#   - The harness and its key are asked for only when .env has none, and only
#     with a person at the keyboard: a prebuild, CI or a pipe is never stopped
#     by a question. ACO_ASK=1 asks anyway (the tests use it). The key is read
#     hidden, written into .env, and never printed.
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
    # It will hold a key. A Codespace checks files out world-writable.
    chmod 600 .env
    say "created .env from .env.example"
    if [ -n "${ACO_DEFAULT_HARNESS:-}" ]; then
      env_set ACO_HARNESS "$ACO_DEFAULT_HARNESS"
      say "harness: $ACO_DEFAULT_HARNESS, this environment's default. ACO_HARNESS in .env changes it"
    fi
  fi
}

# One KEY=value out of .env, read the way participant.mk reads it.
env_get() {
  [ -f .env ] || return 0
  tr -d '\r' < .env \
    | sed -n -E "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" | tail -n 1 \
    | sed -E 's/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
}

# Replace the first KEY= line, commented out or not, or append one. Written
# through with cat, not moved over: .env keeps its permissions, and a symlink
# stays a symlink.
env_set() {
  local tmp; tmp=$(mktemp)
  awk -v k="$1" -v v="$2" '
    !done && $0 ~ ("^[#[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=") { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }' .env > "$tmp" && cat "$tmp" > .env
  rm -f "$tmp"
}

interactive() { [ -t 0 ] || [ "${ACO_ASK:-}" = 1 ]; }

# The variable a harness reads its key from, and where to get one. Empty when
# it needs none (claude on a local model, or on the participant's own login,
# ACO_BACKEND=claude-login). From generic_agent/run.py, like
# preflight, so a new backend needs no change here.
key_for() {
  case "$1" in
    claude)
      case "$(env_get ACO_BACKEND)" in ollama|claude-login) return 0 ;; esac
      echo "ANTHROPIC_API_KEY sk-ant- https://console.anthropic.com/settings/keys" ;;
    *)
      "$PYTHON" -c '
import sys; sys.path.insert(0, ".")
from generic_agent.run import BACKENDS
b = BACKENDS.get(sys.argv[1])
if b:
    print(b.key_env, *{"GEMINI_API_KEY": ["AIza|AQ.", "https://aistudio.google.com/apikey"]}.get(b.key_env, ["-", "-"]))' "$1" 2>/dev/null ;;
  esac
}

ask_harness() {
  echo
  echo "Which agent harness should the labs use?"
  echo "  1) pi-gemini   pi with Google Gemini. Needs a Gemini key with billing: the workshop hands them out."
  echo "                 Google's free tier runs out before the first lab."
  echo "  2) claude      Claude Code. Needs an Anthropic API key. What the labs were measured with."
  echo "                 No key but a Claude Pro or Max plan? Choose 2, then set ACO_BACKEND=claude-login in .env."
  local answer
  printf 'Choose 1 or 2 (Enter to decide later): '
  read -r answer || answer=
  case "$answer" in
    1|pi-gemini) env_set ACO_HARNESS pi-gemini ;;
    2|claude)    env_set ACO_HARNESS claude ;;
    "")          say "no harness chosen; set ACO_HARNESS in .env, or run make setup again"; return 1 ;;
    *)           say "'$answer' is not 1 or 2; set ACO_HARNESS in .env, or run make setup again"; return 1 ;;
  esac
  say "harness: $(env_get ACO_HARNESS), saved in .env"
}

# $1 starts with one of the |-separated prefixes in $2.
starts_with_one() {
  local prefixes p
  IFS='|' read -r -a prefixes <<<"$2"
  for p in "${prefixes[@]}"; do [ "${1#"$p"}" != "$1" ] && return 0; done
  return 1
}

# $1 = force: ask even when a key is already there (make key).
ask_key() {
  local force=${1:-} harness spec var prefix url current key yes tries=0
  harness=${ACO_HARNESS:-$(env_get ACO_HARNESS)}
  [ -n "$harness" ] || return 0
  spec=$(key_for "$harness")
  [ -n "$spec" ] || return 0
  read -r var prefix url <<<"$spec"

  if [ -n "${!var:-}" ] && [ "${!var}" != "$(env_get "$var")" ]; then
    say "$var is set in your shell, which wins over .env; using that"
    return 0
  fi
  current=$(env_get "$var")
  case "$current" in ""|sk-ant-...) current= ;; esac
  if [ -n "$current" ] && [ -z "$force" ]; then
    say "$var is already in .env; make key replaces it"
    return 0
  fi

  echo
  [ "$url" != - ] && echo "Get a key at $url"
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    if [ -n "$current" ]; then
      printf 'Paste your %s (hidden as you type; Enter keeps the one in .env): ' "$var"
    else
      printf 'Paste your %s (hidden as you type; Enter to skip): ' "$var"
    fi
    read -r -s key || key=
    echo
    # A paste often brings a newline, spaces or quotes along.
    key=$(printf '%s' "$key" | tr -d '[:space:]"'"'")
    if [ -z "$key" ]; then
      if [ -n "$current" ]; then say "kept the $var already in .env"
      else say "skipped; make key asks again"; fi
      return 0
    fi
    if ! printf '%s' "$key" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
      say "that has characters no API key has; try again"
      continue
    fi
    # prefix may list alternatives: AIza|AQ. (gcloud's keys, then AI Studio's).
    if [ "$prefix" != - ] && ! starts_with_one "$key" "$prefix"; then
      printf 'That does not look like a %s (they start %s). Save it anyway? [y/N] ' "$var" "${prefix//|/ or }"
      read -r yes || yes=
      [ "$yes" = y ] || [ "$yes" = Y ] || continue
    fi
    env_set "$var" "$key"
    chmod 600 .env
    say "saved $var in .env (${#key} characters). It is git-ignored; never commit it"
    return 0
  done
  say "no key saved; make key asks again"
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
  key)
    [ -f .env ] || env_file
    if [ -z "$(env_get ACO_HARNESS)" ] && [ -z "${ACO_HARNESS:-}" ]; then ask_harness || exit 0; fi
    ask_key force
    ;;
  docker) docker_up ;;
  all)
    venv
    env_file
    if interactive; then
      if [ -z "$(env_get ACO_HARNESS)" ] && [ -z "${ACO_HARNESS:-}" ]; then ask_harness || true; fi
      ask_key
    fi
    docker_up
    echo
    # Through make, so .env is loaded exactly as every other target sees it.
    exec "${MAKE:-make}" --no-print-directory preflight
    ;;
  *) fail "usage: $0 [venv|env|key|docker]" ;;
esac
