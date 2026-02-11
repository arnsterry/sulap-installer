#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer - Eggdrop + BlackTools + Botnet Hub/Spoke + Relay (FIXED FOR curl | bash)
# --------------------------------------------------------------------------------------------
# Usage:
#   ./install.sh -i [--yes]             Install NEW bot
#   ./install.sh -a [--yes]             Add bot under existing base dir
#   ./install.sh -l [--yes]             Load BlackTools+Relay into existing bot config
#   ./install.sh -f <file> [-y]         Deploy from file; optional -y auto-start
#   ./install.sh -h | --help            Help
#
# Run (recommended):
#   curl -fsSL https://install.sulapradio.com/install.sh | bash -s -- -i
#   curl -fsSL https://install.sulapradio.com/install.sh | bash -s -- -i --yes
# --------------------------------------------------------------------------------------------

set -euo pipefail
shopt -s nocasematch

# --------------------------
# Versions / URLs
# --------------------------
PROJECT_NAME="Sulap Installer"
EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"

SCRIPT_REPO_DEFAULT="https://github.com/mrprogrammer2938/Black-Tool.git"
SCRIPT_TARGET_NAME="BlackTools.tcl"

RELAY_TCL_NAME="sulap-relay.tcl"

# --------------------------
# Defaults
# --------------------------
DEFAULT_BASE_DIR="${HOME}/bots"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_IRC_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

START_PORT=42420
END_PORT=42519

PORT_REG_FILE=".sulap-ports.registry"  # "botname port"
HUB_FILE=".sulap-hub"                  # "hub_bot hub_port hub_ip"

# --------------------------
# Parse flags (including --yes)
# --------------------------
AUTO_YES=0
AUTO_START=0
for a in "${@:-}"; do
  case "$a" in
    -y|--yes) AUTO_YES=1 ;;
  esac
done

# --------------------------
# TTY formatting
# --------------------------
if [[ -t 1 ]]; then
  tty_escape() { printf "\033[%sm" "$1"; }
else
  tty_escape() { :; }
fi
tty_mkbold() { tty_escape "1;$1"; }
tty_red="$(tty_mkbold 31)"
tty_green="$(tty_mkbold 32)"
tty_yellow="$(tty_mkbold 33)"
tty_blue="$(tty_mkbold 34)"
tty_bold="$(tty_mkbold 39)"
tty_reset="$(tty_escape 0)"

ohai() { printf "${tty_blue}==>${tty_bold} %s${tty_reset}\n" "$*"; }
warn() { printf "${tty_yellow}Warning${tty_reset}: %s\n" "$*" >&2; }
die()  { printf "${tty_red}Error${tty_reset}: %s\n" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# --------------------------
# Robust input helpers (FIXED FOR curl | bash)
# --------------------------
have_tty() { [[ -r /dev/tty ]]; }

read_line_tty() {
  # usage: read_line_tty VAR
  local __var="$1"
  local line=""
  if have_tty; then
    IFS= read -r line </dev/tty || true
  else
    line=""
  fi
  printf -v "$__var" "%s" "$line"
}

read_key_tty() {
  # usage: read_key_tty VAR
  local __var="$1"
  local c=""
  if have_tty; then
    local save
    save="$(stty -g </dev/tty 2>/dev/null || true)"
    stty raw -echo </dev/tty 2>/dev/null || true
    IFS= read -r -n 1 c </dev/tty 2>/dev/null || true
    stty "$save" </dev/tty 2>/dev/null || true
  else
    c=""
  fi
  printf -v "$__var" "%s" "$c"
}

prompt_default() {
  # usage: prompt_default "Question" "default"
  local q="$1"
  local def="$2"
  local ans=""
  if have_tty; then
    printf "%s [%s]: " "$q" "$def" >/dev/tty
    read_line_tty ans
  fi
  if [[ -z "${ans}" ]]; then printf "%s" "$def"; else printf "%s" "$ans"; fi
}

ask_yn() {
  # usage: ask_yn "Question" default(Y/N)
  # returns 0 for yes, 1 for no
  local q="$1"
  local def="${2:-Y}"
  if [[ "$AUTO_YES" == "1" ]]; then
    return 0
  fi
  if ! have_tty; then
    # Non-interactive environment: default YES
    return 0
  fi
  local c=""
  printf "%s (%s/%s) [%s]: " "$q" "Y" "N" "$def" >/dev/tty
  read_key_tty c
  printf "\n" >/dev/tty
  if [[ -z "$c" ]]; then c="$def"; fi
  if [[ "$c" == "y" || "$c" == "Y" ]]; then return 0; else return 1; fi
}

wait_for_user() {
  echo
  ohai "${tty_green}${PROJECT_NAME}${tty_reset}"
  if [[ "$AUTO_YES" == "1" ]]; then
    ohai "Auto-yes enabled; continuing..."
    return 0
  fi
  if have_tty; then
    echo "Press ${tty_bold}ENTER${tty_reset} to begin, or type anything then ENTER to abort:" >/dev/tty
    local line=""
    read_line_tty line
    if [[ -n "$line" ]]; then
      exit 1
    fi
  else
    ohai "No TTY detected; continuing without prompt..."
  fi
}

# --------------------------
# sudo (ask once, keep alive)
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
  sudo -v || die "sudo authentication failed"
  ( while true; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[[ -n "${SUDO_KEEPALIVE_PID}" ]] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true' EXIT
}

# --------------------------
# OS / package manager
# --------------------------
SYSTEM=""
PKGMGR=""
PKGMGR_ARGS=""
PACKAGES=()

detect_system() {
  [[ "$(uname -s)" == "Linux" ]] || die "Linux only (for now)."

  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM="Debian/Ubuntu"
    PKGMGR="apt-get"
    PKGMGR_ARGS="install -y -qq"
    PACKAGES=(
      gcc make curl git tar ca-certificates
      tcl tcl-dev
      libssl-dev pkg-config zlib1g-dev
      lsof
    )
  elif command -v dnf >/dev/null 2>&1; then
    SYSTEM="Fedora/RHEL"
    PKGMGR="dnf"
    PKGMGR_ARGS="install -y"
    PACKAGES=(gcc make curl git tar ca-certificates tcl tcl-devel openssl-devel zlib-devel pkgconf-pkg-config lsof)
  elif command -v yum >/dev/null 2>&1; then
    SYSTEM="CentOS/RHEL"
    PKGMGR="yum"
    PKGMGR_ARGS="install -y"
    PACKAGES=(gcc make curl git tar ca-certificates tcl tcl-devel openssl-devel zlib-devel pkgconfig lsof)
  else
    die "No supported package manager found (apt-get/dnf/yum)."
  fi
}

install_prereqs() {
  ensure_sudo
  ohai "Detected ${SYSTEM}. Installing prerequisites..."
  if [[ "$PKGMGR" == "apt-get" ]]; then
    ${SUDO} apt-get update -qq
  fi
  ${SUDO} ${PKGMGR} ${PKGMGR_ARGS} "${PACKAGES[@]}"
  ohai "Done."
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

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    netstat -an 2>/dev/null | grep -E "LISTEN.*\.$port" >/dev/null 2>&1
  fi
}

registry_path() { printf "%s/%s" "$1" "$PORT_REG_FILE"; }
hub_path()      { printf "%s/%s" "$1" "$HUB_FILE"; }

reserve_port() {
  local base_dir="$1"
  local botname="$2"
  local reg; reg="$(registry_path "$base_dir")"
  mkdir -p "$base_dir"
  [[ -f "$reg" ]] || : > "$reg"

  # reuse if already reserved
  local existing=""
  existing="$(awk -v b="$botname" '$1==b {print $2}' "$reg" | head -n 1 || true)"
  if [[ -n "$existing" ]]; then
    printf "%s" "$existing"
    return 0
  fi

  local port
  for ((port=START_PORT; port<=END_PORT; port++)); do
    if awk -v p="$port" '$2==p {found=1} END{exit found?0:1}' "$reg" 2>/dev/null; then
      continue
    fi
    if port_in_use "$port"; then
      continue
    fi
    printf "%s %s\n" "$botname" "$port" >> "$reg"
    printf "%s" "$port"
    return 0
  done

  die "No free port found in range ${START_PORT}-${END_PORT}"
}

# --------------------------
# Firewall opening (ufw/firewalld)
# --------------------------
open_firewall_port() {
  local port="$1"
  local label="$2"

  if command -v ufw >/dev/null 2>&1; then
    ohai "Opening firewall with UFW: allow ${port}/tcp (${label})"
    ${SUDO} ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "ufw allow failed"
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    ohai "Opening firewall with firewalld: add-port ${port}/tcp (${label})"
    ${SUDO} firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || warn "firewalld add-port failed"
    ${SUDO} firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload failed"
    return 0
  fi

  warn "No ufw/firewalld detected. Open TCP ${port} manually if needed."
}

# --------------------------
# Backup/delete existing bot directory
# --------------------------
handle_existing_botdir() {
  local bot_dir="$1"
  [[ -d "$bot_dir" ]] || return 0

  warn "Directory already exists: $bot_dir"
  if [[ "$AUTO_YES" == "1" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    mv "$bot_dir" "${bot_dir}-backup-${ts}"
    ohai "Auto-yes: backed up to ${bot_dir}-backup-${ts}"
    return 0
  fi

  if ! have_tty; then
    die "Existing directory found but no TTY to ask. Re-run with --yes or delete/rename it: $bot_dir"
  fi

  echo "Choose: (D)elete  (B)ackup  (E)xit" >/dev/tty
  local c=""
  read_key_tty c
  echo >/dev/tty
  case "$c" in
    d|D) rm -rf "$bot_dir" ;;
    b|B)
      local ts; ts="$(date +%Y%m%d-%H%M%S)"
      mv "$bot_dir" "${bot_dir}-backup-${ts}"
      ohai "Backed up to ${bot_dir}-backup-${ts}"
      ;;
    *) die "Aborted." ;;
  esac
}

# --------------------------
# Eggdrop build/install
# --------------------------
download_and_build_eggdrop() {
  need_cmd curl
  need_cmd tar
  need_cmd make
  need_cmd gcc

  local install_dir="$1"
  local tarball="eggdrop-${EGGDROP_VER}.tar.gz"
  local srcdir="eggdrop-${EGGDROP_VER}"

  ohai "Preparing Eggdrop ${EGGDROP_VER}..."

  if [[ ! -f "$tarball" ]]; then
    ohai "Downloading ${EGGDROP_URL}"
    curl -L --progress-bar -o "$tarball" "$EGGDROP_URL"
  else
    ohai "Using existing tarball: $tarball"
  fi

  # Always clean source dir to avoid stale configure cache
  if [[ -d "$srcdir" ]]; then
    warn "Source dir exists: $srcdir — cleaning for a fresh build."
    rm -rf "$srcdir"
  fi

  ohai "Extracting..."
  tar -zxf "$tarball"

  ohai "Building + installing to: $install_dir"
  pushd "$srcdir" >/dev/null
  ./configure --prefix="$install_dir" >/dev/null
  make config >/dev/null
  make -j"$(nproc 2>/dev/null || echo 1)" >/dev/null
  make install >/dev/null
  popd >/dev/null

  [[ -x "${install_dir}/eggdrop" ]] || die "Eggdrop build failed: ${install_dir}/eggdrop not found."
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
    git -C "${bot_dir}/scripts/_repo" pull --ff-only >/dev/null || die "git pull failed"
  else
    rm -rf "${bot_dir}/scripts/_repo" 2>/dev/null || true
    ohai "Cloning BlackTools repo..."
    git clone "$repo_url" "${bot_dir}/scripts/_repo" >/dev/null || die "git clone failed"
  fi

  local tcl_file=""
  tcl_file="$(find "${bot_dir}/scripts/_repo" -maxdepth 6 -type f -name "*.tcl" | head -n 1 || true)"
  [[ -n "$tcl_file" ]] || die "No .tcl file found inside repo: $repo_url"

  cp -f "$tcl_file" "${bot_dir}/scripts/${SCRIPT_TARGET_NAME}"
  ohai "Installed: ${bot_dir}/scripts/${SCRIPT_TARGET_NAME}"
}

# --------------------------
# Relay TCL generator
# --------------------------
write_relay_tcl() {
  local bot_dir="$1"
  mkdir -p "${bot_dir}/scripts"

  cat > "${bot_dir}/scripts/${RELAY_TCL_NAME}" <<'EOF'
# sulap-relay.tcl - Botnet relay helper
# Public usage (requires +m/+n): !relay #channel message...
set sulap_relay(cmdchar) "!"
set sulap_relay(flags) "mn|-"

bind pub $sulap_relay(flags) "relay" sulap:relay_pub
bind bot - "SULAP_RELAY" sulap:relay_bot

proc sulap:relay_pub {nick uhost hand chan text} {
  if {[llength $text] < 2} {
    putserv "PRIVMSG $chan :Usage: $::sulap_relay(cmdchar)relay #channel message..."
    return
  }
  set tgt [lindex $text 0]
  set msg [join [lrange $text 1 end] " "]
  foreach b [bots] {
    putbot $b "SULAP_RELAY $tgt $nick $msg"
  }
  putserv "PRIVMSG $tgt :[format {[%s] %s} $nick $msg]"
}

proc sulap:relay_bot {frombot cmd text} {
  if {[llength $text] < 3} { return }
  set tgt  [lindex $text 0]
  set nick [lindex $text 1]
  set msg  [join [lrange $text 2 end] " "]
  putserv "PRIVMSG $tgt :[format {[%s] %s} $nick $msg]"
}

putlog "sulap-relay.tcl loaded."
EOF
  ohai "Installed: ${bot_dir}/scripts/${RELAY_TCL_NAME}"
}

# --------------------------
# Hub storage / retrieval
# --------------------------
set_hub() {
  local base_dir="$1" hub_bot="$2" hub_port="$3" hub_ip="$4"
  printf "%s %s %s\n" "$hub_bot" "$hub_port" "$hub_ip" > "$(hub_path "$base_dir")"
}

get_hub_line() {
  local base_dir="$1"
  local f; f="$(hub_path "$base_dir")"
  if [[ -f "$f" ]]; then cat "$f"; else echo ""; fi
}

# --------------------------
# Config writer (Eggdrop + BlackTools + Relay + Botnet link)
# --------------------------
write_bot_config() {
  local base_dir="$1"
  local bot_dir="$2"
  local botname="$3"
  local irc_server="$4"
  local irc_port="$5"
  local channel="$6"
  local realname="$7"
  local username="$8"
  local owner="$9"
  local make_hub="${10}"
  local link_to_hub="${11}"

  local cfg="${bot_dir}/${botname}.conf"
  local listen_port; listen_port="$(reserve_port "$base_dir" "$botname")"
  local ip4; ip4="$(getIPv4 || true)"
  [[ -n "$ip4" ]] || ip4="127.0.0.1"

  # read hub if exists
  local hub_line hub_bot hub_port hub_ip
  hub_line="$(get_hub_line "$base_dir")"
  hub_bot=""; hub_port=""; hub_ip=""
  if [[ -n "$hub_line" ]]; then
    hub_bot="$(awk '{print $1}' <<<"$hub_line")"
    hub_port="$(awk '{print $2}' <<<"$hub_line")"
    hub_ip="$(awk '{print $3}' <<<"$hub_line")"
  fi

  ohai "Writing config: $cfg"
  cat > "$cfg" <<EOF
# --- Generated by Sulap Installer ---
set nick "$botname"
set altnick "${botname}-"
set username "$username"
set realname "$realname"

set owner "$owner"
set admin "$owner"

set servers { $irc_server:$irc_port }

loadmodule server
loadmodule channels
loadmodule irc

# Botnet nick must be unique
set botnet-nick "$botname"
set botnet-user "$owner"

# Listen port used for botnet + partyline
listen $listen_port all

channel add $channel {
  chanmode "+nt"
  idle-kick 0
}

source eggdrop.conf

# BlackTools + Relay
source scripts/${SCRIPT_TARGET_NAME}
source scripts/${RELAY_TCL_NAME}
EOF

  if [[ "$make_hub" == "1" ]]; then
    set_hub "$base_dir" "$botname" "$listen_port" "$ip4"
    ohai "Set HUB: $botname @ $ip4:$listen_port"
  fi

  if [[ "$link_to_hub" == "1" && -n "$hub_bot" && "$hub_bot" != "$botname" ]]; then
    cat >> "$cfg" <<EOF

# Auto-link to hub
link "$hub_bot" "$hub_ip" "$hub_port"
EOF
    ohai "Linked to HUB: $hub_bot @ $hub_ip:$hub_port"
  fi

  ohai "Reserved listen port: $listen_port"

  # Firewall open prompt
  if ask_yn "Open firewall for TCP ${listen_port} (eggdrop-${botname})?" "Y"; then
    ensure_sudo
    open_firewall_port "$listen_port" "eggdrop-${botname}"
  else
    warn "Firewall not modified. If linking across servers, open TCP ${listen_port} on the HUB."
  fi

  echo
  ohai "Partyline (if exposed): telnet ${ip4} ${listen_port}"
}

append_loaders_to_existing_config() {
  local cfg="$1"
  [[ -f "$cfg" ]] || die "Config not found: $cfg"
  local bt="source scripts/${SCRIPT_TARGET_NAME}"
  local rl="source scripts/${RELAY_TCL_NAME}"

  if ! grep -Fq "$bt" "$cfg"; then
    printf "\n# BlackTools\n%s\n" "$bt" >> "$cfg"
    ohai "Added BlackTools loader"
  fi
  if ! grep -Fq "$rl" "$cfg"; then
    printf "\n# Sulap Relay\n%s\n" "$rl" >> "$cfg"
    ohai "Added relay loader"
  fi
}

# --------------------------
# Start / rehash
# --------------------------
start_bot() {
  local bot_dir="$1" botname="$2"
  [[ -x "${bot_dir}/eggdrop" ]] || die "eggdrop binary not found in $bot_dir"
  [[ -f "${bot_dir}/${botname}.conf" ]] || die "Config not found: ${bot_dir}/${botname}.conf"

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
    ohai "Rehashing (HUP) PID $pid..."
    kill -HUP "$pid" || warn "Rehash failed"
  else
    warn "Bot not detected running; restart manually."
  fi
}

# --------------------------
# Flows
# --------------------------
install_new() {
  wait_for_user
  detect_system

  if ask_yn "Install prerequisites automatically?" "Y"; then
    install_prereqs
  else
    warn "Skipping prerequisites; build may fail."
  fi

  local base_dir botname server irc_port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Eggdrop base dir" "$DEFAULT_BASE_DIR")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  irc_port="$(prompt_default "IRC port" "$DEFAULT_IRC_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  mkdir -p "$base_dir"
  bot_dir="${base_dir}/${botname}"
  handle_existing_botdir "$bot_dir"
  mkdir -p "$bot_dir"

  # Hub/spoke selection
  local make_hub="0"
  local link_to_hub="0"
  local hub_line
  hub_line="$(get_hub_line "$base_dir")"
  if [[ -z "$hub_line" ]]; then
    if ask_yn "No HUB found. Make this bot the HUB?" "Y"; then
      make_hub="1"
    fi
  else
    if ask_yn "HUB found. Link this bot to HUB automatically?" "Y"; then
      link_to_hub="1"
    fi
  fi

  download_and_build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server" "$irc_port" "$channel" "$realname" "$username" "$owner" "$make_hub" "$link_to_hub"

  ohai "${tty_green}Installation complete!${tty_reset}"
  echo "Start:"
  echo "  cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\""
  echo
  echo "Relay usage in channel:"
  echo "  !relay #channel message..."
}

add_bot() {
  detect_system
  install_prereqs

  local base_dir botname server irc_port channel realname username owner repo bot_dir
  base_dir="$(prompt_default "Existing base dir" "$DEFAULT_BASE_DIR")"
  [[ -d "$base_dir" ]] || die "Base dir not found: $base_dir"

  botname="$(prompt_default "New bot nickname" "sulap_bot2")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  irc_port="$(prompt_default "IRC port" "$DEFAULT_IRC_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  bot_dir="${base_dir}/${botname}"
  handle_existing_botdir "$bot_dir"
  mkdir -p "$bot_dir"

  local make_hub="0"
  local link_to_hub="0"
  if [[ -n "$(get_hub_line "$base_dir")" ]]; then
    link_to_hub="1"
  else
    make_hub="1"
  fi

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  else
    ohai "Eggdrop already present, skipping build."
  fi

  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server" "$irc_port" "$channel" "$realname" "$username" "$owner" "$make_hub" "$link_to_hub"

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
  [[ -d "$bot_dir" ]] || die "Bot directory not found: $bot_dir"
  [[ -f "$cfg" ]] || die "Config not found: $cfg"

  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir"
  append_loaders_to_existing_config "$cfg"

  if ask_yn "Rehash bot now if running?" "Y"; then
    rehash_if_running "$botname"
  fi

  ohai "Done."
}

deploy_from_file() {
  local file="${1:-}"
  local flag="${2:-}"
  [[ -n "$file" ]] || die "Usage: ./install.sh -f <file> [-y]"
  [[ -f "$file" ]] || die "Deploy file not found: $file"

  local launch=0
  [[ "$flag" == "-y" ]] && launch=1

  # shellcheck disable=SC1090
  source "$file"

  : "${botname:?missing botname= in deploy file}"

  local base_dir="${install_dir:-$DEFAULT_BASE_DIR}"
  local server_v="${server:-$DEFAULT_SERVER}"
  local irc_port_v="${irc_port:-$DEFAULT_IRC_PORT}"
  local channel_v="${channel:-$DEFAULT_CHAN}"
  local realname_v="${realname:-$DEFAULT_REALNAME}"
  local username_v="${username:-$(whoami)}"
  local owner_v="${owner:-$(whoami)}"
  local repo_v="${script_repo:-$SCRIPT_REPO_DEFAULT}"
  local make_hub="${make_hub:-0}"
  local link_to_hub="${link_to_hub:-1}"

  detect_system
  install_prereqs

  mkdir -p "$base_dir"
  local bot_dir="${base_dir}/${botname}"
  handle_existing_botdir "$bot_dir"
  mkdir -p "$bot_dir"

  if [[ ! -x "${bot_dir}/eggdrop" ]]; then
    download_and_build_eggdrop "$bot_dir"
  fi

  install_blacktools "$bot_dir" "$repo_v"
  write_relay_tcl "$bot_dir"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server_v" "$irc_port_v" "$channel_v" "$realname_v" "$username_v" "$owner_v" "$make_hub" "$link_to_hub"

  ohai "Deployed: ${tty_green}${botname}${tty_reset} -> ${tty_green}${bot_dir}${tty_reset}"
  if [[ "$launch" -eq 1 ]]; then
    start_bot "$bot_dir" "$botname"
  fi
}

usage() {
  cat <<EOF

${PROJECT_NAME}
Usage:
  ./install.sh -i [--yes]
  ./install.sh -a [--yes]
  ./install.sh -l [--yes]
  ./install.sh -f <file> [-y]
  ./install.sh -h | --help

EOF
  exit 0
}

# --------------------------
# Entry
# --------------------------
case "${1:-}" in
  -h|--help) usage ;;
  -i) install_new ;;
  -a) add_bot ;;
  -l) load_only ;;
  -f)
    [[ $# -ge 2 ]] || die "Usage: ./install.sh -f <file> [-y]"
    deploy_from_file "${2}" "${3:-}"
    ;;
  *) die "Unknown option: ${1:-<none>}. Use -h for help." ;;
esac
