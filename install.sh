#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer - Eggdrop + BlackTools + Botnet Hub/Spoke + Relay (FIXED ABS PATH)
# --------------------------------------------------------------------------------------------

set -euo pipefail
shopt -s nocasematch

PROJECT_NAME="Sulap Installer"
EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"

SCRIPT_REPO_DEFAULT="https://github.com/mrprogrammer2938/Black-Tool.git"
SCRIPT_TARGET_NAME="BlackTools.tcl"
RELAY_TCL_NAME="sulap-relay.tcl"

DEFAULT_BASE_DIR="${HOME}/bots"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_IRC_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

START_PORT=42420
END_PORT=42519
PORT_REG_FILE=".sulap-ports.registry"
HUB_FILE=".sulap-hub"

AUTO_YES=0
for a in "${@:-}"; do
  case "$a" in
    -y|--yes) AUTO_YES=1 ;;
  esac
done

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
have_tty() { [[ -r /dev/tty ]]; }

read_line_tty() {
  local __var="$1" line=""
  if have_tty; then IFS= read -r line </dev/tty || true; else line=""; fi
  printf -v "$__var" "%s" "$line"
}

read_key_tty() {
  local __var="$1" c=""
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
  local q="$1" def="$2" ans=""
  if have_tty; then
    printf "%s [%s]: " "$q" "$def" >/dev/tty
    read_line_tty ans
  fi
  [[ -z "$ans" ]] && printf "%s" "$def" || printf "%s" "$ans"
}

ask_yn() {
  local q="$1" def="${2:-Y}"
  [[ "$AUTO_YES" == "1" ]] && return 0
  ! have_tty && return 0
  local c=""
  printf "%s (Y/N) [%s]: " "$q" "$def" >/dev/tty
  read_key_tty c
  printf "\n" >/dev/tty
  [[ -z "$c" ]] && c="$def"
  [[ "$c" == "y" || "$c" == "Y" ]]
}

wait_for_user() {
  echo
  ohai "${tty_green}${PROJECT_NAME}${tty_reset}"
  if [[ "$AUTO_YES" == "1" ]]; then
    ohai "Auto-yes enabled; continuing..."
    return 0
  fi
  if have_tty; then
    echo "Press ENTER to begin, or type anything then ENTER to abort:" >/dev/tty
    local line=""
    read_line_tty line
    [[ -n "$line" ]] && exit 1
  else
    ohai "No TTY detected; continuing without prompt..."
  fi
}

# ---------- PATH NORMALIZATION (THE FIX) ----------
to_abs_path() {
  # Converts relative path to absolute using $PWD, and expands ~
  local p="$1"
  # expand ~
  if [[ "$p" == "~"* ]]; then
    p="${p/#\~/$HOME}"
  fi
  # if already absolute
  if [[ "$p" == /* ]]; then
    printf "%s" "$p"
    return 0
  fi
  # if empty -> default later
  if [[ -z "$p" ]]; then
    printf "%s" "$p"
    return 0
  fi
  printf "%s/%s" "$PWD" "$p"
}

validate_server() {
  local s="$1"
  # very light sanity: must contain a dot and no spaces
  if [[ "$s" != *.* || "$s" == *" "* ]]; then
    warn "IRC server looks invalid: '$s' (example: irc.dal.net)"
  fi
}

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

SYSTEM=""
PKGMGR=""
PKGMGR_ARGS=""
PACKAGES=()

detect_system() {
  [[ "$(uname -s)" == "Linux" ]] || die "Linux only."
  if command -v apt-get >/dev/null 2>&1; then
    SYSTEM="Debian/Ubuntu"
    PKGMGR="apt-get"
    PKGMGR_ARGS="install -y -qq"
    PACKAGES=(gcc make curl git tar ca-certificates tcl tcl-dev libssl-dev pkg-config zlib1g-dev lsof)
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
    die "No supported package manager found."
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
  local base_dir="$1" botname="$2"
  local reg; reg="$(registry_path "$base_dir")"
  mkdir -p "$base_dir"
  [[ -f "$reg" ]] || : > "$reg"

  local existing=""
  existing="$(awk -v b="$botname" '$1==b {print $2}' "$reg" | head -n 1 || true)"
  [[ -n "$existing" ]] && { printf "%s" "$existing"; return 0; }

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

open_firewall_port() {
  local port="$1" label="$2"
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
  ! have_tty && die "Existing dir but no TTY; re-run with --yes or rename/delete: $bot_dir"
  echo "Choose: (D)elete  (B)ackup  (E)xit" >/dev/tty
  local c=""; read_key_tty c; echo >/dev/tty
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

download_and_build_eggdrop() {
  need_cmd curl; need_cmd tar; need_cmd make; need_cmd gcc
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

  if [[ -d "$srcdir" ]]; then
    warn "Source dir exists: $srcdir — cleaning for a fresh build."
    rm -rf "$srcdir"
  fi

  ohai "Extracting..."
  tar -zxf "$tarball"

  ohai "Building + installing to: ${install_dir}"
  pushd "$srcdir" >/dev/null
  ./configure --prefix="$install_dir"
  make config
  make -j"$(nproc 2>/dev/null || echo 1)"
  make install
  popd >/dev/null

  [[ -x "${install_dir}/eggdrop" ]] || die "Eggdrop build failed: ${install_dir}/eggdrop not found."
  ohai "Eggdrop installed."
}

install_blacktools() {
  local bot_dir="$1" repo_url="$2"
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

write_relay_tcl() {
  local bot_dir="$1"
  mkdir -p "${bot_dir}/scripts"
  cat > "${bot_dir}/scripts/${RELAY_TCL_NAME}" <<'EOF'
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
  foreach b [bots] { putbot $b "SULAP_RELAY $tgt $nick $msg" }
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

set_hub() {
  local base_dir="$1" hub_bot="$2" hub_port="$3" hub_ip="$4"
  printf "%s %s %s\n" "$hub_bot" "$hub_port" "$hub_ip" > "$(hub_path "$base_dir")"
}

get_hub_line() {
  local f; f="$(hub_path "$1")"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

write_bot_config() {
  local base_dir="$1" bot_dir="$2" botname="$3" irc_server="$4" irc_port="$5"
  local channel="$6" realname="$7" username="$8" owner="$9" make_hub="${10}" link_to_hub="${11}"

  local cfg="${bot_dir}/${botname}.conf"
  local listen_port; listen_port="$(reserve_port "$base_dir" "$botname")"
  local ip4; ip4="$(getIPv4 || true)"; [[ -n "$ip4" ]] || ip4="127.0.0.1"

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

set botnet-nick "$botname"
set botnet-user "$owner"
listen $listen_port all

channel add $channel {
  chanmode "+nt"
  idle-kick 0
}

source eggdrop.conf
source scripts/${SCRIPT_TARGET_NAME}
source scripts/${RELAY_TCL_NAME}
EOF

  if [[ "$make_hub" == "1" ]]; then
    set_hub "$base_dir" "$botname" "$listen_port" "$ip4"
    ohai "Set HUB: $botname @ $ip4:$listen_port"
  fi

  if [[ "$link_to_hub" == "1" && -n "$hub_bot" && "$hub_bot" != "$botname" ]]; then
    cat >> "$cfg" <<EOF

link "$hub_bot" "$hub_ip" "$hub_port"
EOF
    ohai "Linked to HUB: $hub_bot @ $hub_ip:$hub_port"
  fi

  ohai "Reserved listen port: $listen_port"
  if ask_yn "Open firewall for TCP ${listen_port} (eggdrop-${botname})?" "Y"; then
    ensure_sudo
    open_firewall_port "$listen_port" "eggdrop-${botname}"
  else
    warn "Firewall not modified."
  fi

  echo
  ohai "Partyline: telnet ${ip4} ${listen_port}"
}

install_new() {
  wait_for_user
  detect_system

  if ask_yn "Install prerequisites automatically?" "Y"; then
    install_prereqs
  else
    warn "Skipping prerequisites; build may fail."
  fi

  local base_dir_in botname server irc_port channel realname username owner repo
  base_dir_in="$(prompt_default "Eggdrop base dir" "$DEFAULT_BASE_DIR")"
  botname="$(prompt_default "Bot nickname" "sulap_bot")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  irc_port="$(prompt_default "IRC port" "$DEFAULT_IRC_PORT")"
  channel="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  username="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$SCRIPT_REPO_DEFAULT")"

  validate_server "$server"

  # FIX: normalize base_dir to absolute
  local base_dir
  base_dir="$(to_abs_path "$base_dir_in")"
  [[ -n "$base_dir" ]] || die "Base dir cannot be empty."

  mkdir -p "$base_dir"

  # bot_dir absolute
  local bot_dir="${base_dir}/${botname}"

  # Guard: user accidentally typed botname as base dir
  if [[ "$(basename "$base_dir")" == "$botname" ]]; then
    warn "Your base dir ends with the same name as the bot ($botname). This can be confusing."
    warn "Base dir: $base_dir"
    warn "Bot dir : $bot_dir"
  fi

  ohai "Resolved paths:"
  echo "  Base dir: ${base_dir}"
  echo "  Bot dir : ${bot_dir}"

  handle_existing_botdir "$bot_dir"
  mkdir -p "$bot_dir"

  local make_hub="0" link_to_hub="0"
  local hub_line; hub_line="$(get_hub_line "$base_dir")"
  if [[ -z "$hub_line" ]]; then
    ask_yn "No HUB found. Make this bot the HUB?" "Y" && make_hub="1"
  else
    ask_yn "HUB found. Link this bot to HUB automatically?" "Y" && link_to_hub="1"
  fi

  download_and_build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_relay_tcl "$bot_dir"
  write_bot_config "$base_dir" "$bot_dir" "$botname" "$server" "$irc_port" "$channel" "$realname" "$username" "$owner" "$make_hub" "$link_to_hub"

  ohai "${tty_green}Installation complete!${tty_reset}"
  echo "Start:"
  echo "  cd \"$bot_dir\" && ./eggdrop -m \"${botname}.conf\""
}

usage() {
  echo
  echo "${PROJECT_NAME}"
  echo "Usage:"
  echo "  ./install.sh -i [--yes]"
  echo "  ./install.sh -h | --help"
  echo
  exit 0
}

case "${1:-}" in
  -h|--help) usage ;;
  -i) install_new ;;
  *) die "Unknown option: ${1:-<none>}. Use -h for help." ;;
esac
