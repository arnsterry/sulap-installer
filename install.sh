#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer - Eggdrop + BlackTools + Botnet Hub/Spoke + Relay (Armour-inspired)
# --------------------------------------------------------------------------------------------
# Features:
#   - Auto prerequisites (TLS compile deps included)
#   - Multi-bot port registry (no collisions)
#   - Backup/delete existing bot directory
#   - Botnet hub/spoke auto-link
#   - Pre-configured relay TCL over botnet
#   - Auto firewall opening (ufw / firewalld)
#
# Usage:
#   ./install.sh -i                     Install NEW bot
#   ./install.sh -a                     Add bot under existing base dir
#   ./install.sh -l                     Load BlackTools+Relay into existing bot config (optional rehash)
#   ./install.sh -f <file> [-y]         Deploy from file (non-interactive); optional -y auto start
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

# BlackTools repo (your requested default)
SCRIPT_REPO_DEFAULT="https://github.com/mrprogrammer2938/Black-Tool.git"
SCRIPT_TARGET_NAME="BlackTools.tcl"

# Relay TCL filename (we generate it)
RELAY_TCL_NAME="sulap-relay.tcl"

# --------------------------
# Defaults
# --------------------------
DEFAULT_BASE_DIR="${HOME}/bots"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

# Port range reserved by installer
START_PORT=42420
END_PORT=42519

# Registry files (stored in base dir)
PORT_REG_FILE=".sulap-ports.registry"     # botname port
HUB_FILE=".sulap-hub"                      # hub_bot hub_port hub_ip

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
  printf "${tty_red}Error:${tty_reset} %s\n" "$*" >&2
  exit 1
}

execute() {
  if ! "$@"; then
    abort "Failed during: $(shell_join "$@")"
  fi
}

# --------------------------
# Read input even when piped (curl | bash)
# --------------------------
read_tty() {
  local __var="$1"
  if [[ -r /dev/tty ]]; then
    IFS= read -r "$__var" </dev/tty || true
  else
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

ensure_dir() { [[ -d "$1" ]] || mkdir -p "$1"; }

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
    abort "This installer supports Linux only."
  fi

  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM="Debian/Ubuntu"
    PKGMGR="apt-get"
    PKGMGR_ARGS="install -y -qq"
    PACKAGES="gcc make curl git tcl tcl-dev libssl-dev pkg-config zlib1g-dev ca-certificates tar lsof"
  elif command -v dnf >/dev/null 2>&1; then
    SYSTEM="Fedora/RHEL"
    PKGMGR="dnf"
    PKGMGR_ARGS="install -y"
    PACKAGES="gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconf-pkg-config ca-certificates tar lsof"
  elif command -v yum >/dev/null 2>&1; then
    SYSTEM="CentOS/RHEL"
    PKGMGR="yum"
    PKGMGR_ARGS="install -y"
    PACKAGES="gcc make curl git tcl tcl-devel openssl-devel zlib-devel pkgconfig ca-certificates tar lsof"
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

# --------------------------
# IP + Port management
# --------------------------
getIPv4() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    netstat -an 2>/dev/null | grep -E "LISTEN.*\.$port" >/dev/null 2>&1
  fi
}

registry_path() {
  local base_dir="$1"
  printf "%s/%s" "$base_dir" "$PORT_REG_FILE"
}

hub_path() {
  local base_dir="$1"
  printf "%s/%s" "$base_dir" "$HUB_FILE"
}

reserve_port() {
  local base_dir="$1"
  local botname="$2"
  local reg
  reg="$(registry_path "$base_dir")"
  ensure_dir "$base_dir"
  [[ -f "$reg" ]] || : > "$reg"

  # if already reserved for bot, reuse it
  local existing=""
  existing="$(awk -v b="$botname" '$1==b {print $2}' "$reg" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$existing" ]]; then
    printf "%s" "$existing"
    return 0
  fi

  local port
  for ((port=START_PORT; port<=END_PORT; port++)); do
    # skip if already reserved
    if awk -v p="$port" '$2==p {found=1} END{exit found?0:1}' "$reg" 2>/dev/null; then
      continue
    fi
    # skip if in use
    if port_in_use "$port"; then
      continue
    fi
    printf "%s %s\n" "$botname" "$port" >> "$reg"
    printf "%s" "$port"
    return 0
  done

  abort "No free port found in range ${START_PORT}-${END_PORT}"
}

# --------------------------
# Firewall opening (ufw/firewalld)
# --------------------------
open_firewall_port() {
  local port="$1"
  local label="$2"

  if command -v ufw >/dev/null 2>&1; then
    ohai "Opening firewall with UFW: allow ${port}/tcp (${label})"
    # Allow only TCP
    execute ${SUDO} ufw allow "${port}/tcp" || warn "ufw allow failed"
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    ohai "Opening firewall with firewalld: add-port ${port}/tcp (${label})"
    execute ${SUDO} firewall-cmd --permanent --add-port="${port}/tcp" || warn "firewalld add-port failed"
    execute ${SUDO} firewall-cmd --reload || warn "firewalld reload failed"
    return 0
  fi

  warn "No UFW/firewalld detected. Please open TCP port ${port} manually if needed."
}

# --------------------------
# Eggdrop build/install
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

  ensure_dir "${bot_dir}/scripts"

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
# Relay TCL generator (pre-configured botnet relay)
# --------------------------
write_relay_tcl() {
  local bot_dir="$1"
  local botname="$2"

  ensure_dir "${bot_dir}/scripts"

  cat > "${bot_dir}/scripts/${RELAY_TCL_NAME}" <<'EOF'
# --------------------------------------------------------------------------------------------
# sulap-relay.tcl - Simple botnet relay helper (hub/spoke friendly)
#
# Usage (from channel by +m/+n users):
#   !relay #channel message...
#
# What it does:
#   - Sends relay request to all linked bots via putbot
#   - Bots receiving it will say the message to the channel
#
# Notes:
#   - Requires botnet links between bots.
#   - Uses a simple botnet command token: "SULAP_RELAY"
# --------------------------------------------------------------------------------------------

set sulap_relay(cmdchar) "!"
set sulap_relay(flags) "mn|-"

bind pub  $sulap_relay(flags) "relay" sulap:relay_pub
bind bot  - "SULAP_RELAY"      sulap:relay_bot

proc sulap:relay_pub {nick uhost hand chan text} {
    if {[llength $text] < 2} {
        putserv "PRIVMSG $chan :Usage: $::sulap_relay(cmdchar)relay #channel message..."
        return
    }
    set tgt [lindex $text 0]
    set msg [join [lrange $text 1 end] " "]

    # Send to all linked bots (including hub/spokes)
    foreach b [bots] {
        putbot $b "SULAP_RELAY $tgt $nick $msg"
    }

    # Also echo locally
    putserv "PRIVMSG $tgt :[format {[%s] %s} $nick $msg]"
}

proc sulap:relay_bot {frombot cmd text} {
    # text: <#chan> <nick> <message...>
    if {[llength $text] < 3} { return }
    set tgt  [lindex $text 0]
    set nick [lindex $text 1]
    set msg  [join [lrange $text 2 end] " "]
    putserv "PRIVMSG $tgt :[format {[%s] %s} $nick $msg]"
}

putlog "sulap-relay.tcl loaded."
EOF

  ohai "Installed relay -> ${tty_green}${bot_dir}/scripts/${RELAY_TCL_NAME}${tty_reset}"
}

# --------------------------
# Backup/delete existing bot directory
# --------------------------
handle_existing_botdir() {
  local bot_dir="$1"
  if [[ ! -d "$bot_dir" ]]; then
    return 0
  fi

  ring_bell
  echo
  warn "Directory already exists: ${bot_dir}"
  echo
  ohai "Do you wish to (${tty_green}D${tty_reset})elete, (${tty_green}B${tty_reset})ackup, or (${tty_green}E${tty_reset})xit?"
  local input=""
  getc input
  if [[ "${input}" == "e" ]]; then
    abort "Installation halted by user."
  elif [[ "${input}" == "d" ]]; then
    execute rm -rf "$bot_dir"
  elif [[ "${input}" == "b" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    execute mv "$bot_dir" "${bot_dir}-backup-${ts}"
    ohai "Backed up to: ${tty_green}${bot_dir}-backup-${ts}${tty_reset}"
  else
    handle_existing_botdir "$bot_dir"
  fi
}

# --------------------------
# Botnet hub/spoke config helpers
# --------------------------
set_hub() {
  local base_dir="$1"
  local hub_bot="$2"
  local hub_port="$3"
  local hub_ip="$4"
  local hubfile
  hubfile="$(hub_path "$base_dir")"
  printf "%s %s %s\n" "$hub_bot" "$hub_port" "$hub_ip" > "$hubfile"
  ohai "Hub saved: ${tty_green}${hub_bot}${tty_reset} @ ${tty_green}${hub_ip}:${hub_port}${tty_reset}"
}

get_hub() {
  local base_dir="$1"
  local hubfile
  hubfile="$(hub_path "$base_dir")"
  if [[ -f "$hubfile" ]]; then
    cat "$hubfile"
  else
    echo ""
  fi
}

# --------------------------
# Config writer (Eggdrop + BlackTools + Relay + Botnet)
# --------------------------
write_bot_config() {
  local base_dir="$1"
  local bot_dir="$2"
  local botname="$3"
  local server="$4"
  local irc_port="$5"
  local channel="$6"
  local realname="$7"
  local username="$8"
  local owner="$9"
  local is_hub="${10}"
  local do_link="${11}"

  local cfg="${bot_dir}/${botname}.conf"
  ohai "Writing config: ${tty_green}${cfg}${tty_reset}"

  local listen_port
  listen_port="$(reserve_port "$base_dir" "$botname")"

  local ip4
  ip4="$(getIPv4 || true)"

  # Hub info for spokes
  local hub_line=""
  hub_line="$(get_hub "$base_dir")"
  local hub_bot="" hub_port="" hub_ip=""
  if [[ -n "$hub_line" ]]; then
    hub_bot="$(echo "$hub_line" | awk '{print $1}')"
    hub_port="$(echo "$hub_line" | awk '{print $2}')"
    hub_ip="$(echo "$hub_line" | awk '{print $3}')"
  fi

  # Botnet nick (must be unique)
  local botnet_nick="${botname}"

  cat > "$cfg" <<EOF
# --- Generated by Sulap Installer ---
set nick "$botname"
set altnick "${botname}-"
set username "$username"
set realname "$realname"

set owner "$owner"
set admin "$owner"

# IRC server list
set servers { $server:$irc_port }

# Modules
loadmodule server
loadmodule channels
loadmodule irc

# ---------------------------
# BOTNET / LINKING
# ---------------------------
# Botnet nick (unique per bot)
set botnet-nick "$botnet_nick"
# User shown in botnet
set botnet-user "$owner"

# Listen port used for botnet + partyline (DCC/telnet) - be careful exposing publicly
listen $listen_port all

# ---------------------------
# CHANNELS
# ---------------------------
channel add $channel {
  chanmode "+nt"
  idle-kick 0
}

# Default eggdrop base config
source eggdrop.conf

# BlackTools + Relay
source scripts/${SCRIPT_TARGET_NAME}
source scripts/${RELAY_TCL_NAME}
EOF

  ohai "Reserved listen port: ${tty_green}${listen_port}${tty_reset}"

  # Save hub if requested
  if [[ "$is_hub" == "1" ]]; then
    # Prefer public-ish IP (detected IPv4); if empty, fallback to 127.0.0.1
    if [[ -z "${ip4:-}" ]]; then ip4="127.0.0.1"; fi
    set_hub "$base_dir" "$botname" "$listen_port" "$ip4"
  fi

  # Link to hub if requested and hub exists
  if [[ "$do_link" == "1" && -n "$hub_bot" && -n "$hub_port" && -n "$hub_ip" ]]; then
    if [[ "$hub_bot" != "$botname" ]]; then
      cat >> "$cfg" <<EOF

# Auto-link to hub
# NOTE: Ensure hub's firewall allows inbound TCP on hub_port
link "$hub_bot" "$hub_ip" "$hub_port"
EOF
      ohai "Added link to hub: ${tty_green}${hub_bot}${tty_reset} @ ${tty_green}${hub_ip}:${hub_port}${tty_reset}"
    fi
  fi

  # Offer firewall opening for this bot's listen port
  echo
  ohai "Open firewall for bot listen port ${tty_green}${listen_port}/tcp${tty_reset}? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
  local fw=""
  getc fw
  if [[ "${fw}" == "y" ]]; then
    ensure_sudo
    open_firewall_port "$listen_port" "eggdrop-${botname}"
  else
    warn "Firewall not modified. If linking bots across servers, open TCP ${listen_port} on the HUB."
  fi

  # Helpful summary
  echo
  if [[ -n "${ip4:-}" ]]; then
    ohai "Partyline (if exposed): ${tty_green}telnet ${ip4} ${listen_port}${tty_reset}"
  fi
}

append_loaders_to_existing_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || abort "Config not found: $cfg"

  local bt="source scripts/${SCRIPT_TARGET_NAME}"
  local rl="source scripts/${RELAY_TCL_NAME}"

  if ! grep -Fq "$bt" "$cfg"; then
    echo -e "\n# BlackTools\n${bt}" >> "$cfg"
    ohai "Added BlackTools loader"
  else
    ohai "BlackTools already loaded"
  fi

  if ! grep -Fq "$rl" "$cfg"; then
    echo -e "\n# Sulap Relay\n${rl}" >> "$cfg"
    ohai "Added relay loader"
  else
    ohai "Relay already loaded"
  fi
}

# --------------------------
# Start / rehash
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

  # auto prerequisites like Armour style (ask once; default yes)
  echo
  ohai "Install prerequisites automatically? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
  local inp=""
  getc inp
  if [[ "${inp}" != "n" ]]; then
    install_prereqs
  else
    warn "Skipping prerequisites. Build may fail if deps are missing."
  fi

  local base_dir botname server irc_port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Eggdrop base dir" "$DEFAULT_BASE_DIR")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  irc_port="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  ensure_dir "$base_dir"
  bot_dir="${base_dir}/${botname}"

  handle_existing_botdir "$bot_dir"
  ensure_dir "$bot_dir"

  # Hub/spoke choice
  local is_hub="0"
  local do_link="0"

  local hub_line
  hub_line="$(get_hub "$base_dir")"
  if [[ -z "$hub_line" ]]; then
    echo
    ohai "No hub found in ${tty_green}${base_dir}${tty_reset}. Make this bot the HUB? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
    local h=""
    getc h
    if [[ "$h" == "y" ]]; then
      is_hub="1"
      do_link="0"
    fi
  else
    echo
    ohai "Hub found. Link this bot to hub automatically? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
    local l=""
    getc l
    if [[ "$l" == "y" ]]; then
      do_link="1"
    fi
  fi

  download_and_build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir" "$botname"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server" "$irc_port" "$channel" "$realname" "$username" "$owner" "$is_hub" "$do_link"

  echo
  ohai "${tty_green}Installation complete!${tty_reset}"
  echo "Start:"
  echo "  ${tty_blue}cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\"${tty_reset}"
  echo
  echo "Relay usage (in channel):"
  echo "  ${tty_green}!relay #channel message...${tty_reset}"
}

add_bot() {
  detect_system
  install_prereqs

  local base_dir botname server irc_port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Existing base dir" "$DEFAULT_BASE_DIR")"
  [[ -d "$base_dir" ]] || abort "Base dir not found: $base_dir"

  botname="$(prompt_default "New bot nickname" "sulap_bot2")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  irc_port="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  bot_dir="${base_dir}/${botname}"
  handle_existing_botdir "$bot_dir"
  ensure_dir "$bot_dir"

  # hub exists? link it
  local do_link="0"
  local is_hub="0"
  if [[ -n "$(get_hub "$base_dir")" ]]; then
    echo
    ohai "Hub found. Link this bot to hub automatically? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
    local l=""
    getc l
    [[ "$l" == "y" ]] && do_link="1"
  else
    echo
    ohai "No hub found. Make this bot the HUB? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
    local h=""
    getc h
    [[ "$h" == "y" ]] && is_hub="1"
  fi

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  else
    ohai "Eggdrop already present, skipping build."
  fi

  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir" "$botname"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server" "$irc_port" "$channel" "$realname" "$username" "$owner" "$is_hub" "$do_link"

  ohai "${tty_green}Bot added!${tty_reset}"
}

load_only() {
  detect_system
  install_prereqs

  local bot_dir botname cfg repo
  bot_dir="$(prompt_default "Bot directory" "${DEFAULT_BASE_DIR}/sulap_bot")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  cfg="${bot_dir}/${botname}.conf"
  [[ -d "$bot_dir" ]] || abort "Bot directory not found: $bot_dir"
  [[ -f "$cfg" ]] || abort "Config not found: $cfg"

  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir" "$botname"
  append_loaders_to_existing_config "$cfg"

  echo
  ohai "Rehash bot now if running? (${tty_green}Y${tty_reset})es / (${tty_green}N${tty_reset})o"
  local r=""
  getc r
  if [[ "$r" == "y" ]]; then
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
  local make_hub="${make_hub:-0}"
  local link_to_hub="${link_to_hub:-1}"

  detect_system
  install_prereqs

  ensure_dir "$base_dir"
  local bot_dir="${base_dir}/${botname}"
  handle_existing_botdir "$bot_dir"
  ensure_dir "$bot_dir"

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  fi

  install_blacktools "$bot_dir" "$repo_v"
  write_relay_tcl "$bot_dir" "$botname"

  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server_v" "$port_v" "$channel_v" "$realname_v" "$username_v" "$owner_v" "$make_hub" "$link_to_hub"

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
  echo "  -l                 Load BlackTools+Relay on existing bot"
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
