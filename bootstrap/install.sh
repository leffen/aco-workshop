#!/usr/bin/env bash
# make install: the workshop's tools, on macOS, Linux and Windows (WSL2).
#
#   bootstrap/install.sh             install whatever is missing
#   bootstrap/install.sh --dry-run   print what it would run, and run nothing
#
# Needs only bash and curl, so it works before make does: on a fresh Ubuntu
# under WSL, which has no make, `bash bootstrap/install.sh` is the way in.
#
# Safe to run any number of times, and meant to be run again until it is done:
#   - Only what is missing or too old is installed. A second run installs nothing.
#   - Every command is printed before it runs.
#   - One failure does not stop the rest. The summary is a fresh check of every
#     tool, not a list of what was attempted, and the exit code follows it.
#   - Downloads retry, and are checked against the SHA-256 sums pinned below,
#     not against a sum fetched from the host that served the file.
#   - Pinned binaries go to ~/.local/bin, without sudo. Only the system package
#     manager (brew, apt-get, dnf) installs anything outside your home.
#   - Docker is never installed for you on Linux or WSL: there are several right
#     answers (Docker Desktop's WSL integration, Docker Engine, Podman), and the
#     wrong one is hard to undo. It is reported, with the page that explains it.
#
# ACO_PLATFORM=macos|linux|wsl|windows overrides detection; the tests use it.
set -uo pipefail
cd "$(dirname "$0")/.."

DRY=0
case "${1:-}" in
  --dry-run|-n) DRY=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

# The pins. kubectl is one minor of k3d's default k3s (v1.35); k3d is the
# version the labs were measured on; Node is the LTS line. Node must be 20.6
# or newer for the pi harness (its engines field); Claude Code installs
# natively and needs no Node at all.
KUBECTL_VERSION=v1.35.9
KUBECTL_SHA256_amd64=3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb
KUBECTL_SHA256_arm64=39c98bca82875d9a9ddfb6f3c5ab17c3f78ea0801230683e538a67d5c053308d
K3D_VERSION=v5.9.0
K3D_SHA256_amd64=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0
K3D_SHA256_arm64=03cde5cf23e6e8e67de5a039ecf26e5b85aca82fba3e5d13dadf904cd218a250
NODE_VERSION=v24.21.0
NODE_SHA256_amd64=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6
NODE_SHA256_arm64=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2
MIN_PY=3.11
MIN_NODE=20.6

BIN="$HOME/.local/bin"
TOOLS="git make curl python3 docker kubectl k3d node claude"
DOCKER_DOCS=https://docs.docker.com/engine/install/
WSL_DOCS=https://docs.docker.com/desktop/features/wsl/

say()  { printf '==> %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }

# Every command is shown; in a dry run, only shown.
run() {
  printf '  + %s\n' "$*"
  [ "$DRY" = 1 ] || "$@"
}
run_sh() {
  printf '  + %s\n' "$1"
  [ "$DRY" = 1 ] || bash -c "$1"
}

# Things only you can do, collected and shown at the end. Keyed by tool, so
# the final check can say why something is still missing.
MANUAL=""
manual() { MANUAL="${MANUAL}$1|$2"$'\n'; }
manual_for() { printf '%s' "$MANUAL" | sed -n "s/^$1|//p" | head -n 1; }

# --- where are we ---------------------------------------------------------------

platform() {
  if [ -n "${ACO_PLATFORM:-}" ]; then echo "$ACO_PLATFORM"; return; fi
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null
      then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) uname -m ;;
  esac
}

# a >= b, for dotted versions. Plain bash: macOS has no sort -V to lean on.
ver_ge() {
  local IFS=. i
  local -a a=($1) b=($2)
  for i in 0 1 2; do
    [ "${a[i]:-0}" -gt "${b[i]:-0}" ] && return 0
    [ "${a[i]:-0}" -lt "${b[i]:-0}" ] && return 1
  done
  return 0
}

py_version()   { python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null; }
node_version() { node -v 2>/dev/null | sed 's/^v//'; }

# Present, and new enough where that matters.
have() {
  case "$1" in
    python3) command -v python3 >/dev/null 2>&1 && ver_ge "$(py_version)" "$MIN_PY" ;;
    node)    command -v node >/dev/null 2>&1 && ver_ge "$(node_version)" "$MIN_NODE" ;;
    *)       command -v "$1" >/dev/null 2>&1 ;;
  esac
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Download to a file and check it against the pinned sum. A mismatch deletes
# the file and fails: a binary that does not match its pin is never installed.
fetch() {
  local url=$1 want=$2 out=$3
  run curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url" || { warn "download failed: $url"; return 1; }
  [ "$DRY" = 1 ] && return 0
  local got; got=$(sha256 "$out")
  if [ "$got" != "$want" ]; then
    warn "checksum mismatch for $url (expected ${want:0:12}…, got ${got:0:12}…); not installing it"
    rm -f "$out"
    return 1
  fi
}

# --- the pinned binaries, for Linux and WSL ---------------------------------------

install_kubectl() {
  local a; a=$(arch); local sum_var="KUBECTL_SHA256_$a"
  [ -n "${!sum_var:-}" ] || { warn "no kubectl pin for $a"; return 1; }
  fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$a/kubectl" "${!sum_var}" "$TMP/kubectl" \
    && run install -m 0755 "$TMP/kubectl" "$BIN/kubectl"
}

install_k3d() {
  local a; a=$(arch); local sum_var="K3D_SHA256_$a"
  [ -n "${!sum_var:-}" ] || { warn "no k3d pin for $a"; return 1; }
  fetch "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-$a" "${!sum_var}" "$TMP/k3d" \
    && run install -m 0755 "$TMP/k3d" "$BIN/k3d"
}

# Into ~/.local/lib, linked from ~/.local/bin, which sits ahead of /usr/bin on
# PATH. That is what lets it stand in for a distribution's older node (Ubuntu
# 24.04 ships 18) without removing it.
install_node() {
  local a; a=$(arch); local sum_var="NODE_SHA256_$a"
  [ -n "${!sum_var:-}" ] || { warn "no Node pin for $a"; return 1; }
  local na=$a; [ "$a" = amd64 ] && na=x64
  local name="node-$NODE_VERSION-linux-$na"
  fetch "https://nodejs.org/dist/$NODE_VERSION/$name.tar.xz" "${!sum_var}" "$TMP/node.tar.xz" \
    && run mkdir -p "$HOME/.local/lib" \
    && run tar -xJf "$TMP/node.tar.xz" -C "$HOME/.local/lib" \
    && run ln -sf "$HOME/.local/lib/$name/bin/node" "$HOME/.local/lib/$name/bin/npm" \
                  "$HOME/.local/lib/$name/bin/npx" "$BIN/"
}

# Anthropic's native installer, the same on every platform: into ~/.local/bin,
# no Node, no sudo.
install_claude() {
  run_sh "curl -fsSL --retry 3 https://claude.ai/install.sh | bash"
}

# --- per platform -------------------------------------------------------------------

docker_or_alternative() {
  local alt
  for alt in colima podman orbstack; do command -v "$alt" >/dev/null 2>&1 && { echo "$alt"; return; }; done
}

plan_macos() {
  if ! have git || ! have make; then
    run xcode-select --install || true
    manual git "finish the Xcode Command Line Tools dialog that just opened, then run make install again"
    manual make "finish the Xcode Command Line Tools dialog, then run make install again"
  fi
  if ! command -v brew >/dev/null 2>&1; then
    local t
    for t in python3 kubectl k3d node docker; do
      have "$t" || manual "$t" "install Homebrew first (https://brew.sh), then run make install again"
    done
  else
    local pkgs="" t
    have python3 || pkgs="$pkgs python@3.12"
    have kubectl || pkgs="$pkgs kubectl"
    have k3d     || pkgs="$pkgs k3d"
    have node    || pkgs="$pkgs node"
    # shellcheck disable=SC2086  # word-splitting the package list is the point
    [ -n "$pkgs" ] && run brew install $pkgs
    if ! have docker; then
      local alt; alt=$(docker_or_alternative)
      if [ -n "$alt" ]; then
        manual docker "$alt is installed but there is no docker command; install the docker CLI (brew install docker) and point it at $alt"
      else
        run brew install --cask docker
        manual docker "start Docker Desktop once (open -a Docker) and leave it running"
      fi
    fi
  fi
  have claude || install_claude
}

plan_linux() {   # $1: linux or wsl
  local sudo=""; [ "$(id -u)" -eq 0 ] || sudo="sudo"
  local pkgs="" pm=""
  if command -v apt-get >/dev/null 2>&1; then pm=apt
  elif command -v dnf >/dev/null 2>&1; then pm=dnf; fi

  have git  || pkgs="$pkgs git"
  have make || pkgs="$pkgs make"
  have curl || pkgs="$pkgs curl"
  # Only the Node tarball needs xz.
  have node || command -v xz >/dev/null 2>&1 || pkgs="$pkgs xz-utils"
  command -v python3 >/dev/null 2>&1 || pkgs="$pkgs python3"
  # Debian and Ubuntu split venv out of python3, and python3 -m venv fails
  # without it. dnf's python3 carries it already.
  if [ "$pm" = apt ] && ! python3 -c 'import ensurepip' >/dev/null 2>&1; then
    pkgs="$pkgs python3-venv"
  fi
  [ "$pm" = dnf ] && pkgs=${pkgs/xz-utils/xz}

  if [ -n "$pkgs" ]; then
    case "$pm" in
      # shellcheck disable=SC2086
      apt) run $sudo apt-get update -q && run $sudo apt-get install -y -q $pkgs ;;
      # shellcheck disable=SC2086
      dnf) run $sudo dnf install -y $pkgs ;;
      *)   for t in $pkgs; do manual "$t" "no apt-get or dnf here; install $t with your package manager"; done ;;
    esac
  fi

  # A python3 that is there but too old is not ours to replace: it is the
  # system's. Ubuntu 22.04 ships 3.10.
  if command -v python3 >/dev/null 2>&1 && ! have python3; then
    manual python3 "python3 is $(py_version); $MIN_PY or newer is needed. Ubuntu 24.04 and Debian 12 have it; on an older release, upgrade it or use a Codespace"
  fi

  [ -d "$BIN" ] || run mkdir -p "$BIN"
  have kubectl || install_kubectl
  have k3d     || install_k3d
  have node    || install_node
  have claude  || install_claude

  if ! have docker; then
    if [ "$1" = wsl ]; then
      manual docker "in Windows, start Docker Desktop, then Settings > Resources > WSL integration: turn on this distribution ($WSL_DOCS)"
    elif [ -n "$(docker_or_alternative)" ]; then
      manual docker "$(docker_or_alternative) is installed but there is no docker command; install its docker CLI shim"
    else
      manual docker "install Docker Engine for your distribution, and add yourself to the docker group: $DOCKER_DOCS"
    fi
  fi
}

windows() {
  cat >&2 <<'EOF'
This is Windows outside WSL. The workshop runs in WSL2. In PowerShell, as Administrator:

    wsl --install -d Ubuntu-24.04
    winget install -e --id Docker.DockerDesktop

Restart, start Docker Desktop, and turn on Settings > Resources > WSL integration for
Ubuntu-24.04. Then open Ubuntu from the Start menu, clone the repository into your
Ubuntu home (cd ~, not under /mnt/c), and run:

    bash bootstrap/install.sh
EOF
  exit 1
}

# ~/.local/bin on PATH, for this run and every later shell. Appending with >>
# writes through a symlinked rc file instead of replacing it.
path_line() {
  case ":$PATH:" in *":$BIN:"*) return ;; esac
  export PATH="$BIN:$PATH"
  local rc
  case "${SHELL:-}" in
    */zsh) rc="$HOME/.zshrc" ;;
    *)     rc="$HOME/.bashrc" ;;
  esac
  local line='export PATH="$HOME/.local/bin:$PATH"   # added by the workshop: make install'
  if grep -qsF '.local/bin' "$rc"; then return; fi
  printf '  + echo %q >> %s\n' "$line" "$rc"
  [ "$DRY" = 1 ] || printf '\n%s\n' "$line" >> "$rc"
  NEW_SHELL=1
}

# --- go ----------------------------------------------------------------------------

P=$(platform)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NEW_SHELL=0
[ "$DRY" = 1 ] && say "dry run: nothing below is executed"

case "$P" in
  windows) windows ;;
  macos|linux|wsl) ;;
  *) echo "unsupported platform: $(uname -s). macOS, Linux and Windows (WSL2) are." >&2; exit 1 ;;
esac

MISSING_BEFORE=""
for t in $TOOLS; do have "$t" || MISSING_BEFORE="$MISSING_BEFORE $t"; done
if [ -z "$MISSING_BEFORE" ]; then
  say "every tool is already installed ($P): nothing to do. Next: make setup"
  exit 0
fi

say "platform: $P; missing or too old:$MISSING_BEFORE"
path_line
case "$P" in
  macos) plan_macos ;;
  *)     plan_linux "$P" ;;
esac

if [ "$DRY" = 1 ]; then
  echo
  [ -n "$MANUAL" ] && { say "would still need you:"; printf '%s' "$MANUAL" | sed 's/^\([^|]*\)|/    \1: /'; }
  exit 0
fi

# The summary is what is true now, checked again, not what was attempted.
echo
say "checking again"
LEFT=0
for t in $TOOLS; do
  if have "$t"; then printf '  \033[32mOK\033[0m       %s\n' "$t"
  else
    LEFT=$((LEFT+1))
    why=$(manual_for "$t")
    printf '  \033[31mMISSING\033[0m  %s%s\n' "$t" "${why:+ — $why}"
  fi
done
echo
[ "$NEW_SHELL" = 1 ] && say "open a new terminal (or run: export PATH=\"\$HOME/.local/bin:\$PATH\") so your shell finds what was installed in ~/.local/bin"
if [ "$LEFT" -eq 0 ]; then
  printf '\033[32mEverything is installed. Next: make setup\033[0m\n\n'
  exit 0
fi
printf '\033[31m%s still missing. Do what it says above, then run make install again.\033[0m\n\n' "$LEFT"
exit 1
