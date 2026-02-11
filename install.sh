#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer - Eggdrop + BlackTools (Armour-inspired)
# --------------------------------------------------------------------------------------------
# Usage:
#   ./install.sh -i                     Install NEW bot (build eggdrop, install BlackTools, configure)
#   ./install.sh -a                     Add NEW bot under existing base dir
#   ./install.sh -l                     Load BlackTools on existing bot config (optional rehash)
#   ./install.sh -f <file> [-y]         Deploy from file (non-interactive); optional -y to auto start
#   ./install.sh -h | --help            Help
# --------------------------------------------------------------------------------------------

set -u
set -o pipefail
shopt -s nocasematch

# --------------------------
# Versions / URLs
# --------------------------
PROJECT_NAME="Sulap Installer"
EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"

SCRIPT_REPO_DEFAULT="https://github.com/mrprogrammer2938/Black-Tool.git"
SCRIPT_TARGET_NAME="BlackTools.tcl"

# --------------------------
# Defaults
# --------------------------
DEFAULT_BASE_DIR="${HOME}/bots"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

# Telnet/botnet listen range (like Armour-ish)
START_PORT=42420
END_PORT=42519

# --------------------------
# TTY formatting
# --------------------------
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_underline="$(tty_escape "4;39")"
tty_red="$(tty_mkbold 31)"
tty_green="$(tty_mkbold 32)"
tty_yellow="$(tty_mkbold 33)"
tty_blue="$(tty_mkbold 34)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

shell_join() {
  local arg
  printf "%s" "$1"
  shift
  for arg in "$@"; do
    printf " %s" "${arg// /\ }"
  done
}

ohai() { printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$(shell_join "$@")"; }
warn() { printf "${tty_yellow}Warning${tty_reset}: %s\n" "$*" >&2; }
ring_bell() { [[ -t 1 ]] && printf "\a"; }

abort() {
  ring_bell
  printf "%s\n" "$*" >&2
  exit 1
}

execute() {
  if ! "$@"; then
    abort "Failed during: $(shell_join "$@")"
  fi
}

# --------------------------
# Read input even when piped
# --------------------------
read_tty() {
  # usage: read_tty varname
  local __var="$1"
  if [[ -r /dev/tty ]]; then
    IFS= read -r "$__var" </dev/tty || true
  else
    # non-interactive: empty
    printf -v "$__var" ""
  fi
}

prompt_default() {
  local prompt="$1"
  local def="$2"
  local val=""
  printf "%s [%s]: " "$prompt" "$def" >/dev/tty 2>/dev/null || true
  read_tty val
  if [[ -z "$val" ]]; then
    printf "%s" "$def"
  else
    printf "%s" "$val"
  fi
}

getc() {
  local save_state cvar
  cvar="$1"
  save_state="$(/bin/stty -g 2>/dev/null || true)"
  /bin/stty raw -echo 2>/dev/null || true
  IFS='' read -r -n 1 -d '' "$cvar" 2>/dev/null || true
  /bin/stty "${save_state}" 2>/dev/null || true
}

wait_for_user() {
  local c=""
  echo
  echo "Press ${tty_bold}RETURN${tty_reset}/${tty_bold}ENTER${tty_reset} to begin, or any other key to abort:"
  getc c
  if ! [[ "${c}" == $'\r' || "${c}" == $'\n' ]]; then
    exit 1
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || abort "Missing command: $1"; }

# --------------------------
# sudo (ask once)
# --------------------------
SUDO="sudo"
SUDO_KEEPALIVE_PID=""
ensure_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return 0
  fi
  need_cmd sudo
  ohai "Requesting sudo (you may be prompted once)..."
  sudo -v || abort "sudo authentication failed"
  ( while true; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
}

# --------------------------
# OS + package manager
# --------------------------
SYSTEM=""
PKGMGR=""
PKGMGR_ARGS=""
PACKAGES=""

detect_system() {
  local os
  os="$(uname -s)"
  if [[ "$os" != "Linux" ]]; then
    abort "This installer supports Linux only for now."
  fi

  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM="Debian/Ubuntu"
    PKGMGR="apt-get"
    PKGMGR_ARGS="install -y -qq"
    # TLS compile deps included:
    PACKAGES="gcc make curl git tcl tcl-dev libssl-dev pkg-config zlib1g-dev ca-certificates tar"
  elif command -v dnf >/dev/null 2>&1; then
    SYSTEM="Fedora/RHEL"
    PKGMGR="dnf"
    PKGMGR_ARGS="install -y"
    PACKAGES="gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconf-pkg-config ca-certificates tar"
  elif command -v yum >/dev/null 2>&1; then
    SYSTEM="CentOS/RHEL"
    PKGMGR="yum"
    PKGMGR_ARGS="install -y"
    PACKAGES="gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconfig ca-certificates tar"
  else
    abort "No supported package manager found (apt-get/dnf/yum)."
  fi
}

install_prereqs() {
  ensure_sudo
  ohai "Installing prerequisites..."
  if [[ "$PKGMGR" == "apt-get" ]]; then
    execute ${SUDO} apt-get update -qq
  fi
  execute ${SUDO} ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}
  ohai "Done."
}

ask_for_prereq() {
  local input=""
  echo
  ohai "Install prerequisite packages automatically? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
  echo "    ${SUDO} ${PKGMGR} ${PKGMGR_ARGS} ${PACKAGES}"
  echo
  getc input
  if [[ "${input}" == "n" ]]; then
    warn "Skipping prerequisites. Build may fail if deps are missing."
  else
    install_prereqs
  fi
}

# --------------------------
# Networking helpers
# --------------------------
getIPv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

getPort() {
  local port
  for ((port=START_PORT; port<=END_PORT; port++)); do
    if command -v lsof >/dev/null 2>&1; then
      if ! lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        printf "%s" "$port"; return 0
      fi
    else
      # fallback: netstat
      if ! netstat -an 2>/dev/null | grep -E "LISTEN.*\.$port" >/dev/null 2>&1; then
        printf "%s" "$port"; return 0
      fi
    fi
  done
  abort "No free port found in range ${START_PORT}-${END_PORT}"
}

# --------------------------
# Eggdrop build
# --------------------------
download_and_build_eggdrop() {
  need_cmd curl
  need_cmd tar
  need_cmd make
  need_cmd gcc

  local tarball="eggdrop-${EGGDROP_VER}.tar.gz"
  local srcdir="eggdrop-${EGGDROP_VER}"
  local install_dir="$1"

  ohai "Preparing Eggdrop ${EGGDROP_VER}..."
  if [[ ! -f "$tarball" ]]; then
    ohai "Downloading ${EGGDROP_URL}"
    execute curl -L --progress-bar -o "$tarball" "$EGGDROP_URL"
  else
    ohai "Using existing tarball: $tarball"
  fi

  if [[ -d "$srcdir" ]]; then
    warn "Source dir exists: $srcdir — cleaning for fresh build."
    rm -rf "$srcdir"
  fi

  ohai "Extracting..."
  execute tar -zxf "$tarball"

  ohai "Building + installing to: ${tty_green}${install_dir}${tty_reset}"
  pushd "$srcdir" >/dev/null
  execute ./configure --prefix="$install_dir"
  execute make config
  execute make -j"$(nproc 2>/dev/null || echo 1)"
  execute make install
  popd >/dev/null

  [[ -x "${install_dir}/eggdrop" ]] || abort "Eggdrop install failed: ${install_dir}/eggdrop not found."
  ohai "Eggdrop installed."
}

# --------------------------
# BlackTools install (always to scripts/)
# --------------------------
install_blacktools() {
  local bot_dir="$1"
  local repo_url="$2"
  need_cmd git

  mkdir -p "${bot_dir}/scripts"

  if [[ -d "${bot_dir}/scripts/_repo/.git" ]]; then
    ohai "Updating BlackTools repo..."
    execute git -C "${bot_dir}/scripts/_repo" pull --ff-only
  else
    rm -rf "${bot_dir}/scripts/_repo" 2>/dev/null || true
    ohai "Cloning BlackTools repo..."
    execute git clone "$repo_url" "${bot_dir}/scripts/_repo"
  fi

  local tcl_file=""
  tcl_file="$(find "${bot_dir}/scripts/_repo" -maxdepth 6 -type f -name "*.tcl" | head -n 1 || true)"
  [[ -n "$tcl_file" ]] || abort "No .tcl file found inside repo: $repo_url"

  execute cp -f "$tcl_file" "${bot_dir}/scripts/${SCRIPT_TARGET_NAME}"
  ohai "Installed script -> ${tty_green}${bot_dir}/scripts/${SCRIPT_TARGET_NAME}${tty_reset}"
}

# --------------------------
# Config writer (Eggdrop + BlackTools)
# --------------------------
write_bot_config() {
  local bot_dir="$1" botname="$2" server="$3" port="$4" channel="$5" realname="$6" username="$7" owner="$8"

  local cfg="${bot_dir}/${botname}.conf"
  ohai "Writing config: ${tty_green}${cfg}${tty_reset}"

  local listen_port
  listen_port="$(getPort)"
  local ip4
  ip4="$(getIPv4 || true)"

  cat > "$cfg" <<EOF
# --- Generated by Sulap Installer ---
set nick "$botname"
set altnick "${botname}-"
set username "$username"
set realname "$realname"

set owner "$owner"
set admin "$owner"

set servers { $server:$port }

loadmodule server
loadmodule channels
loadmodule irc

# Telnet/DCC listen
listen $listen_port all

channel add $channel {
  chanmode "+nt"
  idle-kick 0
}

source eggdrop.conf

# BlackTools
source scripts/${SCRIPT_TARGET_NAME}
EOF

  ohai "Listen port chosen: ${tty_green}${listen_port}${tty_reset}"
  if [[ -n "${ip4:-}" ]]; then
    ohai "Partyline (telnet) likely: ${tty_green}telnet ${ip4} ${listen_port}${tty_reset}"
  fi
}

append_blacktools_to_existing_config() {
  local cfg="$1"
  local line="source scripts/${SCRIPT_TARGET_NAME}"
  [[ -f "$cfg" ]] || abort "Config not found: $cfg"

  if grep -Fq "$line" "$cfg"; then
    ohai "BlackTools already loaded."
    return 0
  fi
  ohai "Appending BlackTools loader..."
  printf "\n# BlackTools\n%s\n" "$line" >> "$cfg"
}

# --------------------------
# Start / rehash helpers
# --------------------------
start_bot() {
  local bot_dir="$1" botname="$2"
  [[ -x "${bot_dir}/eggdrop" ]] || abort "eggdrop binary not found in $bot_dir"
  [[ -f "${bot_dir}/${botname}.conf" ]] || abort "Config not found: ${bot_dir}/${botname}.conf"

  ohai "Starting eggdrop..."
  pushd "$bot_dir" >/dev/null
  ./eggdrop -m "${botname}.conf" >/dev/null 2>&1 || true
  popd >/dev/null

  if pgrep -af "eggdrop.*${botname}\.conf" >/dev/null 2>&1; then
    ohai "${tty_green}Running${tty_reset}: $(pgrep -af "eggdrop.*${botname}\.conf" | head -n 1)"
  else
    warn "Eggdrop did not stay running. Check logs in: $bot_dir"
  fi
}

rehash_if_running() {
  local botname="$1"
  local pid=""
  pid="$(pgrep -af "eggdrop.*${botname}\.conf" | awk '{print $1}' | head -n 1 || true)"
  if [[ -n "$pid" ]]; then
    ohai "Rehashing eggdrop (PID ${tty_green}${pid}${tty_reset})..."
    kill -HUP "$pid" || warn "Rehash failed"
  else
    warn "Bot not detected running; restart manually to load changes."
  fi
}

# --------------------------
# Flows
# --------------------------
install_new() {
  echo
  ohai "${tty_green}${PROJECT_NAME}${tty_reset}"
  wait_for_user

  detect_system
  ohai "Detected ${tty_green}${SYSTEM}${tty_reset}"
  ask_for_prereq

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

  mkdir -p "$base_dir"
  bot_dir="${base_dir}/${botname}"
  [[ -d "$bot_dir" ]] && abort "Bot dir already exists: $bot_dir"

  mkdir -p "$bot_dir"
  download_and_build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_bot_config "$bot_dir" "$botname" "$server" "$port" "$channel" "$realname" "$username" "$owner"

  echo
  ohai "${tty_green}Installation complete!${tty_reset}"
  echo "Start:"
  echo "  ${tty_blue}cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\"${tty_reset}"
}

add_bot() {
  detect_system
  ask_for_prereq

  local base_dir botname server port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Existing base dir" "$DEFAULT_BASE_DIR")"
  [[ -d "$base_dir" ]] || abort "Base dir not found: $base_dir"

  botname="$(prompt_default "New bot nickname" "sulap_bot2")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  port="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  bot_dir="${base_dir}/${botname}"
  mkdir -p "$bot_dir"
  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  else
    ohai "Eggdrop already present, skipping build."
  fi

  install_blacktools "$bot_dir" "$repo"
  write_bot_config "$bot_dir" "$botname" "$server" "$port" "$channel" "$realname" "$username" "$owner"

  ohai "${tty_green}Bot added!${tty_reset}"
}

load_only() {
  detect_system
  ask_for_prereq

  local bot_dir botname cfg repo
  bot_dir="$(prompt_default "Bot directory" "${DEFAULT_BASE_DIR}/sulap_bot")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  cfg="${bot_dir}/${botname}.conf"
  [[ -d "$bot_dir" ]] || abort "Bot directory not found: $bot_dir"
  [[ -f "$cfg" ]] || abort "Config not found: $cfg"

  install_blacktools "$bot_dir" "$repo"
  append_blacktools_to_existing_config "$cfg"

  local input=""
  echo
  ohai "Rehash bot now if running? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
  getc input
  if [[ "${input}" == "y" ]]; then
    rehash_if_running "$botname"
  fi

  ohai "Done."
}

deploy_from_file() {
  local file="${1:-}"
  local flag="${2:-}"
  [[ -n "$file" ]] || abort "Usage: ./install.sh -f <file> [-y]"
  [[ -f "$file" ]] || abort "Deploy file not found: $file"

  local launch=0
  [[ "${flag:-}" == "-y" ]] && launch=1

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

  detect_system
  install_prereqs

  mkdir -p "$base_dir"
  local bot_dir="${base_dir}/${botname}"
  mkdir -p "$bot_dir"

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  fi

  install_blacktools "$bot_dir" "$repo_v"
  write_bot_config "$bot_dir" "$botname" "$server_v" "$port_v" "$channel_v" "$realname_v" "$username_v" "$owner_v"

  ohai "Deployed: ${tty_green}${botname}${tty_reset} -> ${tty_green}${bot_dir}${tty_reset}"
  if [[ "$launch" -eq 1 ]]; then
    start_bot "$bot_dir" "$botname"
  fi
}

usage() {
  echo
  echo "${PROJECT_NAME}"
  echo "Usage: ./install.sh [options]"
  echo "  -i                 Install NEW bot"
  echo "  -a                 Add bot"
  echo "  -l                 Load BlackTools on existing bot"
  echo "  -f <file> [-y]     Deploy from file; optional -y auto-start"
  echo "  -h, --help         Help"
  echo
  exit 0
}

# --------------------------
# Entry
# --------------------------
if [[ $# -gt 0 ]]; then
  case "$1" in
    -h|--help) usage ;;
    -i) install_new ;;
    -a) add_bot ;;
    -l) load_only ;;
    -f) deploy_from_file "${2:-}" "${3:-}" ;;
    *) warn "Unknown option: $1"; usage ;;
  esac
else
  usage
fi
