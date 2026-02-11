#!/usr/bin/env bash
# --------------------------------------------------------------------------------------------
# Sulap Universal Eggdrop Installer (FULL FEATURE VERSION)
# Stable under: curl -fsSL ... | bash -s -- -i
# --------------------------------------------------------------------------------------------

set -euo pipefail
shopt -s nocasematch

PROJECT="Sulap Universal Installer"
VERSION="2.0"
EGG_VER="1.10.1"
EGG_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGG_VER}.tar.gz"

DEFAULT_BASE="$HOME/bots"
DEFAULT_SERVER="irc.dal.net"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"
BLACKTOOLS_REPO="https://github.com/mrprogrammer2938/Black-Tool.git"

PORT_START=42420
PORT_END=42519
PORT_REG=".sulap-ports"
HUB_FILE=".sulap-hub"

AUTO_YES=0
[[ "${@:-}" =~ (--yes|-y) ]] && AUTO_YES=1

# -------------------- COLOR --------------------
if [[ -t 1 ]]; then
  esc(){ printf "\033[%sm" "$1"; }
else
  esc(){ :; }
fi
BLUE="$(esc 1;34)"
GREEN="$(esc 1;32)"
RED="$(esc 1;31)"
RESET="$(esc 0)"

log(){ printf "${BLUE}==>${RESET} %s\n" "$*"; }
die(){ printf "${RED}Error:${RESET} %s\n" "$*"; exit 1; }

# -------------------- INPUT SAFE --------------------
have_tty(){ [[ -r /dev/tty ]]; }

read_line(){
  local __var="$1"
  local v=""
  if have_tty; then
    IFS= read -r v </dev/tty || true
  fi
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  printf -v "$__var" "%s" "$v"
}

prompt(){
  local text="$1" def="$2" out=""
  if [[ "$AUTO_YES" == 1 || ! have_tty ]]; then
    printf "%s" "$def"
    return
  fi
  printf "%s [%s]: " "$text" "$def" >/dev/tty
  read_line out
  [[ -z "$out" ]] && printf "%s" "$def" || printf "%s" "$out"
}

ask_yes(){
  local text="$1" def="Y" ans=""
  if [[ "$AUTO_YES" == 1 || ! have_tty ]]; then
    return 0
  fi
  printf "%s (Y/N) [%s]: " "$text" "$def" >/dev/tty
  read_line ans
  [[ -z "$ans" ]] && ans="$def"
  [[ "$ans" =~ ^[Yy]$ ]]
}

# -------------------- PATH FIX --------------------
abs_path(){
  local p="$1"
  [[ "$p" == /* ]] && echo "$p" && return
  [[ "$p" == "~"* ]] && p="${p/#\~/$HOME}"
  echo "$HOME/$p"
}

# -------------------- PREREQS --------------------
install_prereqs(){
  log "Installing prerequisites..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    gcc make curl git tar \
    tcl tcl-dev \
    libssl-dev zlib1g-dev pkg-config \
    lsof
  log "Done."
}

# -------------------- PORT MGMT --------------------
reserve_port(){
  local base="$1" bot="$2"
  local reg="$base/$PORT_REG"
  mkdir -p "$base"
  [[ -f "$reg" ]] || touch "$reg"

  local existing
  existing="$(awk -v b="$bot" '$1==b{print $2}' "$reg" || true)"
  [[ -n "$existing" ]] && { echo "$existing"; return; }

  for p in $(seq $PORT_START $PORT_END); do
    if ! grep -q " $p" "$reg" && ! lsof -i:$p >/dev/null 2>&1; then
      echo "$bot $p" >> "$reg"
      echo "$p"
      return
    fi
  done
  die "No free ports."
}

# -------------------- FIREWALL --------------------
open_firewall(){
  local port="$1"
  if command -v ufw >/dev/null; then
    sudo ufw allow "$port/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null; then
    sudo firewall-cmd --permanent --add-port="$port/tcp" >/dev/null 2>&1 || true
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# -------------------- BUILD EGGDROP --------------------
build_egg(){
  local dir="$1"
  local tar="eggdrop-${EGG_VER}.tar.gz"
  local src="eggdrop-${EGG_VER}"

  log "Preparing Eggdrop..."
  [[ -f "$tar" ]] || curl -L -o "$tar" "$EGG_URL"

  rm -rf "$src"
  tar -zxf "$tar"

  pushd "$src" >/dev/null
  ./configure --prefix="$dir"
  make config
  make -j"$(nproc)"
  make install
  popd >/dev/null

  [[ -x "$dir/eggdrop" ]] || die "Eggdrop failed."
}

# -------------------- BLACKTOOLS --------------------
install_blacktools(){
  local dir="$1"
  mkdir -p "$dir/scripts"
  git clone "$BLACKTOOLS_REPO" "$dir/scripts/_bt" >/dev/null 2>&1 || true
  local tcl
  tcl="$(find "$dir/scripts/_bt" -name "*.tcl" | head -n1)"
  cp "$tcl" "$dir/scripts/BlackTools.tcl"
}

# -------------------- RELAY TCL --------------------
write_relay(){
  local dir="$1"
  cat > "$dir/scripts/sulap-relay.tcl" <<EOF
bind pub m relay sulap_relay
proc sulap_relay {nick uhost hand chan text} {
  set msg [join \$text " "]
  putserv "PRIVMSG \$chan :[format {[RELAY] %s} \$msg]"
}
EOF
}

# -------------------- CONFIG --------------------
write_config(){
  local base="$1" dir="$2" bot="$3" server="$4" port="$5" chan="$6" real="$7" ident="$8" owner="$9"

  local listen
  listen="$(reserve_port "$base" "$bot")"

  cat > "$dir/$bot.conf" <<EOF
set nick "$bot"
set altnick "${bot}-"
set username "$ident"
set realname "$real"
set owner "$owner"
set servers { $server:$port }

loadmodule server
loadmodule channels
loadmodule irc

listen $listen all

channel add $chan {
  chanmode "+nt"
}

source eggdrop.conf
source scripts/BlackTools.tcl
source scripts/sulap-relay.tcl
EOF

  log "Bot listening on port $listen"
  ask_yes "Open firewall for $listen?" && open_firewall "$listen"
}

# -------------------- INSTALL FLOW --------------------
install_bot(){
  log "$PROJECT v$VERSION"

  ask_yes "Install prerequisites?" && install_prereqs

  local base bot server port chan real ident owner
  base="$(prompt "Eggdrop base dir" "$DEFAULT_BASE")"
  base="$(abs_path "$base")"

  bot="$(prompt "Bot nickname" "sulap_bot")"
  server="$(prompt "IRC server" "$DEFAULT_SERVER")"
  port="$(prompt "IRC port" "$DEFAULT_PORT")"
  chan="$(prompt "Home channel" "$DEFAULT_CHAN")"
  real="$(prompt "Realname" "$DEFAULT_REALNAME")"
  ident="$(prompt "Ident/username" "$(whoami)")"
  owner="$(prompt "Owner name/handle" "$(whoami)")"

  mkdir -p "$base"
  local dir="$base/$bot"

  if [[ -d "$dir" ]]; then
    ask_yes "Directory exists. Backup?" && mv "$dir" "$dir.backup.$(date +%s)"
  fi

  mkdir -p "$dir"

  build_egg "$dir"
  install_blacktools "$dir"
  write_relay "$dir"
  write_config "$base" "$dir" "$bot" "$server" "$port" "$chan" "$real" "$ident" "$owner"

  log "Installation complete."
  echo "Start with:"
  echo "cd $dir && ./eggdrop -m $bot.conf"
}

# -------------------- ENTRY --------------------
case "${1:-}" in
  -i) install_bot ;;
  *) echo "Use -i to install." ;;
esac
