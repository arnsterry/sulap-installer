#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer (Eggdrop + BlackTools) - Armour-style auto prerequisites
# --------------------------------------------------------------------------------------------
# Usage:
#   ./install.sh -i                     Install a NEW bot (build eggdrop, install BlackTools, write config)
#   ./install.sh -a                     Add another bot under an existing base dir
#   ./install.sh -l                     Load BlackTools into an existing bot config (no rebuild)
#   ./install.sh -f <file> [-y]         Deploy from a deploy file (non-interactive), optional auto-start
#   ./install.sh -h | --help            Help
# --------------------------------------------------------------------------------------------

set -euo pipefail

# --------------------------
# Project defaults (EDIT if needed)
# --------------------------
PROJECT_NAME="Sulap Installer"
EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"

SCRIPT_REPO_DEFAULT="https://github.com/mrprogrammer2938/Black-Tool.git"
SCRIPT_TARGET_NAME="BlackTools.tcl"     # always installed in bot's default scripts folder as this name

DEFAULT_BASE_DIR="${HOME}/bots"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

# --------------------------
# Pretty output
# --------------------------
if [[ -t 1 ]]; then
  ESC=$'\033'
  BLUE="${ESC}[1;34m"
  GREEN="${ESC}[1;32m"
  YELLOW="${ESC}[1;33m"
  RED="${ESC}[1;31m"
  BOLD="${ESC}[1m"
  NC="${ESC}[0m"
else
  BLUE=""; GREEN=""; YELLOW=""; RED=""; BOLD=""; NC=""
fi

ohai() { printf "${BLUE}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}Warning:${NC} %s\n" "$*" >&2; }
die()  { printf "${RED}Error:${NC} %s\n" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Read from terminal even when piped: curl ... | bash
prompt_default() {
  local prompt="$1"
  local def="$2"
  local out=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt [$def]: " out </dev/tty || true
  else
    out=""
  fi
  if [[ -z "$out" ]]; then printf "%s" "$def"; else printf "%s" "$out"; fi
}

ensure_dir() { [[ -d "$1" ]] || mkdir -p "$1"; }

# --------------------------
# sudo handling (ask once)
# --------------------------
SUDO="sudo"
ensure_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return 0
  fi
  need_cmd sudo
  ohai "Requesting sudo (you may be prompted once)..."
  sudo -v
  # keep sudo alive while script runs
  ( while true; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
}

# --------------------------
# OS / package manager detect
# --------------------------
SYSTEM=""
PKG_INSTALL=""
PACKAGES=()

detect_system() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    die "This installer currently supports Linux only."
  fi

  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM="Debian/Ubuntu"
    PKG_INSTALL="${SUDO} apt-get update -qq && ${SUDO} apt-get install -y -qq"
    # Eggdrop build deps + TLS
    PACKAGES=(
      gcc make
      curl git
      tcl tcl-dev
      libssl-dev pkg-config
      zlib1g-dev
      ca-certificates
      tar
    )
  elif command -v dnf >/dev/null 2>&1; then
    SYSTEM="Fedora/RHEL"
    PKG_INSTALL="${SUDO} dnf install -y"
    PACKAGES=(gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconf-pkg-config ca-certificates tar)
  elif command -v yum >/dev/null 2>&1; then
    SYSTEM="CentOS/RHEL"
    PKG_INSTALL="${SUDO} yum install -y"
    PACKAGES=(gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconfig ca-certificates tar)
  else
    die "No supported package manager found (apt-get/dnf/yum)."
  fi
}

install_prereqs() {
  ohai "Detected ${SYSTEM}. Installing prerequisites..."
  # shellcheck disable=SC2086
  eval "${PKG_INSTALL} ${PACKAGES[*]}"
  ohai "Done."
}

# --------------------------
# Eggdrop build/install
# --------------------------
download_and_build_eggdrop() {
  local install_dir="$1"

  need_cmd curl
  need_cmd tar
  need_cmd make
  need_cmd gcc

  local tarball="eggdrop-${EGGDROP_VER}.tar.gz"
  local srcdir="eggdrop-${EGGDROP_VER}"

  ohai "Preparing Eggdrop ${EGGDROP_VER}..."

  if [[ ! -f "$tarball" ]]; then
    ohai "Downloading ${EGGDROP_URL}"
    curl -L --progress-bar -o "$tarball" "$EGGDROP_URL"
  else
    ohai "Using existing tarball: $tarball"
  fi

  # Clean source dir to avoid stale configure issues
  if [[ -d "$srcdir" ]]; then
    warn "Source dir already exists: $srcdir — cleaning it for a fresh build."
    rm -rf "$srcdir"
  fi

  ohai "Extracting..."
  tar -zxf "$tarball"

  ohai "Building + installing to: $install_dir"
  pushd "$srcdir" >/dev/null

  # TLS should work now because we installed openssl dev libs.
  ./configure --prefix="$install_dir" >/dev/null
  make config >/dev/null
  make -j"$(nproc 2>/dev/null || echo 1)" >/dev/null
  make install >/dev/null

  popd >/dev/null

  [[ -x "${install_dir}/eggdrop" ]] || die "Eggdrop build failed: ${install_dir}/eggdrop not found."
  ohai "Eggdrop installed."
}

# --------------------------
# Install BlackTools into bot default scripts folder
# --------------------------
install_blacktools() {
  local bot_dir="$1"
  local repo_url="$2"

  need_cmd git
  ensure_dir "${bot_dir}/scripts"

  # Clone/update into scripts/_repo
  if [[ -d "${bot_dir}/scripts/_repo/.git" ]]; then
    ohai "Updating BlackTools repo..."
    git -C "${bot_dir}/scripts/_repo" pull --ff-only >/dev/null || die "git pull failed"
  else
    rm -rf "${bot_dir}/scripts/_repo" 2>/dev/null || true
    ohai "Cloning BlackTools repo..."
    git clone "$repo_url" "${bot_dir}/scripts/_repo" >/dev/null || die "git clone failed"
  fi

  # Auto-find the first .tcl file (repo may change layout)
  local tcl_file=""
  tcl_file="$(find "${bot_dir}/scripts/_repo" -maxdepth 6 -type f -name "*.tcl" | head -n 1 || true)"
  [[ -n "$tcl_file" ]] || die "No .tcl file found inside repo: $repo_url"

  cp -f "$tcl_file" "${bot_dir}/scripts/${SCRIPT_TARGET_NAME}"
  ohai "Installed: ${bot_dir}/scripts/${SCRIPT_TARGET_NAME}"
}

# --------------------------
# Config generation / loading
# --------------------------
write_bot_config() {
  local bot_dir="$1"
  local botname="$2"
  local server="$3"
  local port="$4"
  local channel="$5"
  local realname="$6"
  local username="$7"
  local owner="$8"

  local cfg="${bot_dir}/${botname}.conf"
  ohai "Writing config: $cfg"

  cat > "$cfg" <<EOF
# --- Generated by Sulap Installer ---
set nick "$botname"
set altnick "${botname}-"
set username "$username"
set realname "$realname"

# eggdrop owner info (optional)
set owner "$owner"
set admin "$owner"

set servers { $server:$port }

loadmodule server
loadmodule channels
loadmodule irc

channel add $channel {
  chanmode "+nt"
  idle-kick 0
}

# default eggdrop base config
source eggdrop.conf

# BlackTools (installed in default scripts folder)
source scripts/${SCRIPT_TARGET_NAME}
EOF

  ohai "Done."
}

append_blacktools_to_existing_config() {
  local cfg="$1"
  local line="source scripts/${SCRIPT_TARGET_NAME}"
  [[ -f "$cfg" ]] || die "Config not found: $cfg"

  if grep -Fq "$line" "$cfg"; then
    ohai "BlackTools already loaded in config."
    return 0
  fi

  ohai "Appending BlackTools loader to config..."
  printf "\n# BlackTools\n%s\n" "$line" >> "$cfg"
  ohai "Done."
}

start_bot() {
  local bot_dir="$1"
  local botname="$2"
  local cfg="${bot_dir}/${botname}.conf"

  [[ -x "${bot_dir}/eggdrop" ]] || die "eggdrop binary not found in: $bot_dir"
  [[ -f "$cfg" ]] || die "config not found: $cfg"

  ohai "Starting eggdrop..."
  pushd "$bot_dir" >/dev/null
  ./eggdrop -m "${botname}.conf" >/dev/null 2>&1 || true
  popd >/dev/null

  if pgrep -af "eggdrop.*${botname}\.conf" >/dev/null 2>&1; then
    ohai "${GREEN}Running${NC}: $(pgrep -af "eggdrop.*${botname}\.conf" | head -n 1)"
  else
    warn "Eggdrop did not stay running. Check logs in: ${bot_dir}"
  fi
}

# --------------------------
# Flows
# --------------------------
install_new() {
  ensure_sudo
  detect_system
  install_prereqs

  local base_dir botname server port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Eggdrop base dir" "$DEFAULT_BASE_DIR")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  port="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  ensure_dir "$base_dir"
  bot_dir="${base_dir}/${botname}"

  if [[ -d "$bot_dir" ]]; then
    die "Bot directory already exists: $bot_dir (choose a different botname)."
  fi
  ensure_dir "$bot_dir"

  download_and_build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_bot_config "$bot_dir" "$botname" "$server" "$port" "$channel" "$realname" "$username" "$owner"

  ohai "Install complete."
  echo "Start:"
  echo "  cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\""
}

add_bot() {
  ensure_sudo
  detect_system
  install_prereqs

  local base_dir botname server port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Existing base dir" "$DEFAULT_BASE_DIR")"
  [[ -d "$base_dir" ]] || die "Base dir not found: $base_dir"

  botname="$(prompt_default "New bot nickname" "sulap_bot2")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  port="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  bot_dir="${base_dir}/${botname}"
  ensure_dir "$bot_dir"

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  else
    ohai "Eggdrop already present in ${bot_dir}, skipping build."
  fi

  install_blacktools "$bot_dir" "$repo"
  write_bot_config "$bot_dir" "$botname" "$server" "$port" "$channel" "$realname" "$username" "$owner"

  ohai "Bot added."
  echo "Start:"
  echo "  cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\""
}

load_only() {
  ensure_sudo
  detect_system
  install_prereqs

  local bot_dir botname cfg repo
  bot_dir="$(prompt_default "Bot directory" "${DEFAULT_BASE_DIR}/sulap_bot")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  cfg="${bot_dir}/${botname}.conf"
  [[ -d "$bot_dir" ]] || die "Bot directory not found: $bot_dir"
  [[ -f "$cfg" ]] || die "Config not found: $cfg"

  install_blacktools "$bot_dir" "$repo"
  append_blacktools_to_existing_config "$cfg"

  ohai "Load complete. Rehash or restart the bot."
}

deploy_from_file() {
  local file="${1:-}"
  local launch_flag="${2:-}"

  [[ -n "$file" ]] || die "Usage: ./install.sh -f <file> [-y]"
  [[ -f "$file" ]] || die "Deploy file not found: $file"

  local launch=0
  if [[ "$launch_flag" == "-y" ]]; then
    launch=1
  fi

  # shellcheck disable=SC1090
  source "$file"

  : "${botname:?missing botname= in deploy file}"

  local base_dir="${install_dir:-$DEFAULT_BASE_DIR}"
  local server_v="${server:-$DEFAULT_SERVER}"
  local port_v="${port:-$DEFAULT_PORT}"
  local channel_v="${channel:-$DEFAULT_CHAN}"
  local realname_v="${realname:-$DEFAULT_REALNAME}"
  local username_v="${username:-$(whoami)}"
  local owner_v="${owner:-$(whoami)}"
  local repo_v="${script_repo:-$SCRIPT_REPO_DEFAULT}"

  ensure_sudo
  detect_system
  install_prereqs

  ensure_dir "$base_dir"
  local bot_dir="${base_dir}/${botname}"
  ensure_dir "$bot_dir"

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  fi

  install_blacktools "$bot_dir" "$repo_v"
  write_bot_config "$bot_dir" "$botname" "$server_v" "$port_v" "$channel_v" "$realname_v" "$username_v" "$owner_v"

  ohai "Deployed bot: $botname"
  echo "Dir: $bot_dir"
  if [[ "$launch" == "1" ]]; then
    start_bot "$bot_dir" "$botname"
  else
    echo "Start:"
    echo "  cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\""
  fi
}

usage() {
  cat <<EOF

${PROJECT_NAME}
Usage:
  ./install.sh -i
  ./install.sh -a
  ./install.sh -l
  ./install.sh -f <file> [-y]
  ./install.sh -h | --help

EOF
  exit 0
}

case "${1:-}" in
  -h|--help) usage ;;
  -i) install_new ;;
  -a) add_bot ;;
  -l) load_only ;;
  -f)
    [[ $# -ge 2 ]] || die "Usage: ./install.sh -f <file> [-y]"
    deploy_from_file "${2}" "${3:-}"
    ;;
  *)
    die "Unknown option: ${1:-<none>}. Use -h for help."
    ;;
esac
