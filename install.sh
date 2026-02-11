#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Installer (stable) - Eggdrop + BlackTools + Port registry + Optional firewall
# Works reliably with: curl -fsSL https://install.sulapradio.com/install.sh | bash -s -- -i
# --------------------------------------------------------------------------------------------

set -euo pipefail
shopt -s nocasematch

PROJECT_NAME="Sulap Installer"
EGGDROP_VER="1.10.1"
EGGDROP_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGGDROP_VER}.tar.gz"

BLACKTOOLS_DEFAULT_REPO="https://github.com/mrprogrammer2938/Black-Tool.git"
BLACKTOOLS_TARGET_NAME="BlackTools.tcl"

DEFAULT_BASE_DIR="$HOME/bots"
DEFAULT_BOTNAME="sulap_bot"
DEFAULT_SERVER="vancouver.bc.ca.undernet.org"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

PORT_START=42420
PORT_END=42519
PORT_REG_FILE=".sulap-ports.registry"
HUB_FILE=".sulap-hub"   # stores: hub_bot hub_ip hub_port

AUTO_YES=0

# ------------------ pretty output ------------------
if [[ -t 1 ]]; then
  esc(){ printf "\033[%sm" "$1"; }
else
  esc(){ :; }
fi
BOLD="$(esc "1;39")"
BLUE="$(esc "1;34")"
YELLOW="$(esc "1;33")"
RED="$(esc "1;31")"
RESET="$(esc "0")"

ohai(){ printf "${BLUE}==>${BOLD} %s${RESET}\n" "$*"; }
warn(){ printf "${YELLOW}Warning${RESET}: %s\n" "$*" >&2; }
die(){ printf "${RED}Error${RESET}: %s\n" "$*" >&2; exit 1; }

# ------------------ args ------------------
usage(){
  cat <<EOF

${PROJECT_NAME}
Usage:
  ./install.sh -i [--yes]
  ./install.sh -h|--help

Examples:
  curl -fsSL https://install.sulapradio.com/install.sh | bash -s -- -i
  curl -fsSL https://install.sulapradio.com/install.sh | bash -s -- -i --yes

EOF
}

for a in "${@:-}"; do
  case "$a" in
    --yes|-y) AUTO_YES=1 ;;
  esac
done

# ------------------ reliable input (works under curl|bash) ------------------
have_tty(){ [[ -r /dev/tty ]]; }

# Read a full line from /dev/tty and strip CR/LF
read_line(){
  local __var="$1"
  local line=""
  if have_tty; then
    IFS= read -r line </dev/tty 2>/dev/null || true
  else
    line=""
  fi
  # strip CR/LF to avoid your exact issue
  line="${line//$'\r'/}"
  line="${line//$'\n'/}"
  printf -v "$__var" "%s" "$line"
}

prompt_default(){
  local q="$1" def="$2" out=""
  if [[ "$AUTO_YES" == "1" || ! "$(have_tty; echo $?)" == "0" ]]; then
    printf "%s" "$def"
    return 0
  fi
  printf "%s [%s]: " "$q" "$def" >/dev/tty
  read_line out
  [[ -z "$out" ]] && printf "%s" "$def" || printf "%s" "$out"
}

ask_yn(){
  # returns 0 yes, 1 no
  local q="$1" def="${2:-Y}" ans=""
  if [[ "$AUTO_YES" == "1" || ! "$(have_tty; echo $?)" == "0" ]]; then
    return 0
  fi
  printf "%s (Y/N) [%s]: " "$q" "$def" >/dev/tty
  read_line ans
  [[ -z "$ans" ]] && ans="$def"
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# IMPORTANT: remove the “Press ENTER to begin” gate entirely (it caused your failures).
banner(){
  echo
  ohai "$PROJECT_NAME"
  echo
}

# ------------------ sudo keepalive ------------------
SUDO="sudo"
KEEPALIVE_PID=""

ensure_sudo(){
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  ohai "Requesting sudo (you may be prompted once)..."
  sudo -v || die "sudo auth failed."
  ( while true; do sudo -n true 2>/dev/null || true; sleep 30; done ) &
  KEEPALIVE_PID=$!
  trap '[[ -n "${KEEPALIVE_PID}" ]] && kill "${KEEPALIVE_PID}" 2>/dev/null || true' EXIT
}

# ------------------ absolute path normalization ------------------
to_abs_path(){
  # If user enters "Sulapas" -> "/home/user/Sulapas"
  local p="$1"
  [[ -z "$p" ]] && { printf "%s" ""; return 0; }

  if [[ "$p" == "~"* ]]; then
    p="${p/#\~/$HOME}"
  fi

  if [[ "$p" == /* ]]; then
    printf "%s" "$p"
    return 0
  fi

  # Prefer HOME for relative user entries (less confusing than $PWD)
  printf "%s/%s" "$HOME" "$p"
}

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

# ------------------ system prereqs ------------------
detect_pkgmgr(){
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo ""
  fi
}

install_prereqs(){
  ensure_sudo
  local pm; pm="$(detect_pkgmgr)"
  [[ -n "$pm" ]] || die "No supported package manager (apt/dnf/yum)."

  if [[ "$pm" == "apt" ]]; then
    ohai "Detected Debian/Ubuntu. Installing prerequisites..."
    ${SUDO} apt-get update -qq
    ${SUDO} apt-get install -y -qq \
      gcc make curl git tar ca-certificates \
      tcl tcl-dev \
      libssl-dev pkg-config zlib1g-dev \
      lsof
  elif [[ "$pm" == "dnf" ]]; then
    ohai "Detected Fedora/RHEL. Installing prerequisites..."
    ${SUDO} dnf install -y \
      gcc make curl git tar ca-certificates \
      tcl tcl-devel \
      openssl-devel zlib-devel pkgconf-pkg-config \
      lsof
  else
    ohai "Detected CentOS/RHEL. Installing prerequisites..."
    ${SUDO} yum install -y \
      gcc make curl git tar ca-certificates \
      tcl tcl-devel \
      openssl-devel zlib-devel pkgconfig \
      lsof
  fi
  ohai "Done."
}

# ------------------ networking helpers ------------------
get_ipv4(){
  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1 || true
  else
    hostname -I 2>/dev/null | awk '{print $1}' || true
  fi
}

port_in_use(){
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  else
    netstat -an 2>/dev/null | grep -E "LISTEN.*\.$port" >/dev/null 2>&1
  fi
}

reserve_port(){
  local base_dir="$1" botname="$2"
  local reg="${base_dir}/${PORT_REG_FILE}"
  mkdir -p "$base_dir"
  [[ -f "$reg" ]] || : > "$reg"

  # reuse if already assigned
  local existing=""
  existing="$(awk -v b="$botname" '$1==b {print $2}' "$reg" | head -n 1 || true)"
  if [[ -n "$existing" ]]; then
    printf "%s" "$existing"
    return 0
  fi

  local p
  for ((p=PORT_START; p<=PORT_END; p++)); do
    # already reserved?
    if awk -v pp="$p" '$2==pp{f=1} END{exit f?0:1}' "$reg"; then
      continue
    fi
    # currently listening?
    if port_in_use "$p"; then
      continue
    fi
    printf "%s %s\n" "$botname" "$p" >> "$reg"
    printf "%s" "$p"
    return 0
  done

  die "No free port in range ${PORT_START}-${PORT_END}"
}

open_firewall(){
  local port="$1"
  ensure_sudo

  if command -v ufw >/dev/null 2>&1; then
    ohai "Opening UFW: allow ${port}/tcp"
    ${SUDO} ufw allow "${port}/tcp" >/dev/null 2>&1 || warn "ufw failed"
    return 0
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    ohai "Opening firewalld: add-port ${port}/tcp"
    ${SUDO} firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || warn "firewalld add-port failed"
    ${SUDO} firewall-cmd --reload >/dev/null 2>&1 || warn "firewalld reload failed"
    return 0
  fi

  warn "No ufw/firewalld detected. Open TCP ${port} manually if needed."
}

# ------------------ eggdrop build ------------------
build_eggdrop(){
  local install_dir="$1"
  need_cmd curl; need_cmd tar; need_cmd make; need_cmd gcc

  [[ "$install_dir" == /* ]] || die "Internal: install_dir must be absolute: $install_dir"

  local tarball="eggdrop-${EGGDROP_VER}.tar.gz"
  local srcdir="eggdrop-${EGGDROP_VER}"

  ohai "Preparing Eggdrop ${EGGDROP_VER}..."

  if [[ ! -f "$tarball" ]]; then
    ohai "Downloading ${EGGDROP_URL}"
    curl -L --progress-bar -o "$tarball" "$EGGDROP_URL"
  else
    ohai "Using existing tarball: $tarball"
  fi

  # Always rebuild clean to avoid stale configure junk
  rm -rf "$srcdir" 2>/dev/null || true
  tar -zxf "$tarball"

  ohai "Building + installing to: $install_dir"
  pushd "$srcdir" >/dev/null

  ./configure --prefix="$install_dir"
  make config
  make -j"$(nproc 2>/dev/null || echo 1)"
  make install

  popd >/dev/null

  [[ -x "${install_dir}/eggdrop" ]] || die "Eggdrop install failed: ${install_dir}/eggdrop missing"
  ohai "Eggdrop installed."
}

# ------------------ blacktools ------------------
install_blacktools(){
  local bot_dir="$1" repo="$2"
  need_cmd git
  mkdir -p "${bot_dir}/scripts"

  if [[ -d "${bot_dir}/scripts/_blacktools/.git" ]]; then
    ohai "Updating BlackTools..."
    git -C "${bot_dir}/scripts/_blacktools" pull --ff-only >/dev/null || die "git pull failed"
  else
    rm -rf "${bot_dir}/scripts/_blacktools" 2>/dev/null || true
    ohai "Cloning BlackTools..."
    git clone "$repo" "${bot_dir}/scripts/_blacktools" >/dev/null || die "git clone failed"
  fi

  # pick first .tcl found
  local tcl=""
  tcl="$(find "${bot_dir}/scripts/_blacktools" -maxdepth 8 -type f -name "*.tcl" | head -n 1 || true)"
  [[ -n "$tcl" ]] || die "No .tcl found inside repo: $repo"

  cp -f "$tcl" "${bot_dir}/scripts/${BLACKTOOLS_TARGET_NAME}"
  ohai "Installed: scripts/${BLACKTOOLS_TARGET_NAME}"
}

# ------------------ config ------------------
write_config(){
  local base_dir="$1" bot_dir="$2" botname="$3" server="$4" port="$5" chan="$6" realname="$7" ident="$8" owner="$9"

  local cfg="${bot_dir}/${botname}.conf"
  local listen_port; listen_port="$(reserve_port "$base_dir" "$botname")"
  local ip4; ip4="$(get_ipv4)"; [[ -n "$ip4" ]] || ip4="127.0.0.1"

  ohai "Writing config: $cfg"
  cat > "$cfg" <<EOF
# Generated by ${PROJECT_NAME}
set nick "$botname"
set altnick "${botname}-"
set username "$ident"
set realname "$realname"

set owner "$owner"
set admin "$owner"

set servers { $server:$port }

loadmodule server
loadmodule channels
loadmodule irc

set botnet-nick "$botname"
set botnet-user "$owner"

listen $listen_port all

channel add $chan {
  chanmode "+nt"
  idle-kick 0
}

source eggdrop.conf
source scripts/${BLACKTOOLS_TARGET_NAME}
EOF

  ohai "Listen port: ${listen_port}"
  if ask_yn "Open firewall for TCP ${listen_port}?" "Y"; then
    open_firewall "$listen_port"
  fi

  echo
  ohai "Partyline (local IP shown): telnet ${ip4} ${listen_port}"
}

# ------------------ dirs handling ------------------
handle_existing_dir(){
  local dir="$1"
  [[ -d "$dir" ]] || return 0

  warn "Directory exists: $dir"
  if [[ "$AUTO_YES" == "1" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    mv "$dir" "${dir}-backup-${ts}"
    ohai "Auto-yes: backed up to ${dir}-backup-${ts}"
    return 0
  fi

  if ! have_tty; then
    die "Dir exists and no TTY to ask. Re-run with --yes or rename/delete: $dir"
  fi

  echo "Choose: (B)ackup  (D)elete  (E)xit" >/dev/tty
  local choice=""; read_line choice
  case "$choice" in
    b|B|"")
      local ts; ts="$(date +%Y%m%d-%H%M%S)"
      mv "$dir" "${dir}-backup-${ts}"
      ohai "Backed up to ${dir}-backup-${ts}"
      ;;
    d|D) rm -rf "$dir" ;;
    *) die "Aborted." ;;
  esac
}

# ------------------ main install ------------------
install_flow(){
  banner

  if ask_yn "Install prerequisites automatically?" "Y"; then
    install_prereqs
  else
    warn "Skipping prereqs. Build may fail."
  fi

  local base_in botname server ircport chan realname ident owner repo
  base_in="$(prompt_default "Eggdrop base dir" "$DEFAULT_BASE_DIR")"
  botname="$(prompt_default "Bot nickname" "$DEFAULT_BOTNAME")"
  server="$(prompt_default "IRC server" "$DEFAULT_SERVER")"
  ircport="$(prompt_default "IRC port" "$DEFAULT_PORT")"
  chan="$(prompt_default "Home channel" "$DEFAULT_CHAN")"
  realname="$(prompt_default "Realname" "$DEFAULT_REALNAME")"
  ident="$(prompt_default "Ident/username" "$(whoami)")"
  owner="$(prompt_default "Owner name/handle" "$(whoami)")"
  repo="$(prompt_default "BlackTools repo URL" "$BLACKTOOLS_DEFAULT_REPO")"

  [[ -n "$botname" ]] || die "Bot nickname cannot be empty."
  [[ -n "$server" ]] || die "IRC server cannot be empty."

  local base_dir; base_dir="$(to_abs_path "$base_in")"
  [[ -n "$base_dir" ]] || die "Base dir cannot be empty."
  [[ "$base_dir" == /* ]] || die "Base dir must be absolute after normalization: $base_dir"

  local bot_dir="${base_dir}/${botname}"

  ohai "Resolved paths:"
  echo "  Base dir: $base_dir"
  echo "  Bot dir : $bot_dir"

  mkdir -p "$base_dir"
  handle_existing_dir "$bot_dir"
  mkdir -p "$bot_dir"

  build_eggdrop "$bot_dir"
  install_blacktools "$bot_dir" "$repo"
  write_config "$base_dir" "$bot_dir" "$botname" "$server" "$ircport" "$chan" "$realname" "$ident" "$owner"

  echo
  ohai "DONE."
  echo "Start the bot:"
  echo "  cd \"$bot_dir\" && ./eggdrop -m \"$botname.conf\""
  echo
}

# ------------------ entry ------------------
case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  -i) install_flow ;;
  *) die "Unknown option: ${1}. Use -h for help." ;;
esac
