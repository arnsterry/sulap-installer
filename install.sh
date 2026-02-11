#!/usr/bin/env bash

set -e

PROJECT="Sulap Installer"
VERSION="3.0"
EGG_VER="1.10.1"
EGG_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGG_VER}.tar.gz"
BLACKTOOLS_REPO="https://github.com/mrprogrammer2938/Black-Tool.git"

DEFAULT_BASE="$HOME/bots"
DEFAULT_SERVER="irc.dal.net"
DEFAULT_PORT="6667"
DEFAULT_CHAN="#bislig"
DEFAULT_REALNAME="https://sulapradio.com"

PORT_START=42420
PORT_END=42519
PORT_REG=".sulap-ports"

AUTO_YES=0
for arg in "$@"; do
    if [ "$arg" = "--yes" ] || [ "$arg" = "-y" ]; then
        AUTO_YES=1
    fi
done

log() { echo "==> $*"; }
die() { echo "Error: $*" >&2; exit 1; }

have_tty() { [ -r /dev/tty ]; }

read_line() {
    VAR_NAME="$1"
    VALUE=""
    if have_tty; then
        IFS= read -r VALUE < /dev/tty || true
    fi
    VALUE="${VALUE//$'\r'/}"
    VALUE="${VALUE//$'\n'/}"
    printf -v "$VAR_NAME" "%s" "$VALUE"
}

prompt() {
    TEXT="$1"
    DEFAULT="$2"
    RESULT=""
    if [ "$AUTO_YES" -eq 1 ] || ! have_tty; then
        echo "$DEFAULT"
        return
    fi
    printf "%s [%s]: " "$TEXT" "$DEFAULT" > /dev/tty
    read_line RESULT
    if [ -z "$RESULT" ]; then
        echo "$DEFAULT"
    else
        echo "$RESULT"
    fi
}

ask_yes() {
    TEXT="$1"
    if [ "$AUTO_YES" -eq 1 ] || ! have_tty; then
        return 0
    fi
    printf "%s (Y/N) [Y]: " "$TEXT" > /dev/tty
    ANSWER=""
    read_line ANSWER
    if [ -z "$ANSWER" ] || [ "$ANSWER" = "Y" ] || [ "$ANSWER" = "y" ]; then
        return 0
    fi
    return 1
}

abs_path() {
    P="$1"
    case "$P" in
        /*) echo "$P" ;;
        ~*) echo "${P/#\~/$HOME}" ;;
        *) echo "$HOME/$P" ;;
    esac
}

install_prereqs() {
    log "Installing prerequisites..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        gcc make curl git tar \
        tcl tcl-dev \
        libssl-dev zlib1g-dev pkg-config \
        lsof
    log "Prerequisites installed."
}

reserve_port() {
    BASE="$1"
    BOT="$2"
    REG="$BASE/$PORT_REG"

    mkdir -p "$BASE"
    [ -f "$REG" ] || touch "$REG"

    EXISTING=$(awk -v b="$BOT" '$1==b {print $2}' "$REG")
    if [ -n "$EXISTING" ]; then
        echo "$EXISTING"
        return
    fi

    for P in $(seq $PORT_START $PORT_END); do
        if ! grep -q " $P" "$REG" && ! lsof -i :"$P" >/dev/null 2>&1; then
            echo "$BOT $P" >> "$REG"
            echo "$P"
            return
        fi
    done

    die "No free ports available."
}

open_firewall() {
    PORT="$1"
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow "$PORT/tcp" >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

build_eggdrop() {
    TARGET="$1"
    TAR="eggdrop-${EGG_VER}.tar.gz"
    SRC="eggdrop-${EGG_VER}"

    log "Downloading Eggdrop..."
    [ -f "$TAR" ] || curl -L -o "$TAR" "$EGG_URL"

    rm -rf "$SRC"
    tar -zxf "$TAR"

    cd "$SRC"
    ./configure --prefix="$TARGET"
    make config
    make
    make install
    cd ..

    [ -x "$TARGET/eggdrop" ] || die "Eggdrop build failed."
}

install_blacktools() {
    DIR="$1"
    mkdir -p "$DIR/scripts"
    rm -rf "$DIR/scripts/_bt"
    git clone "$BLACKTOOLS_REPO" "$DIR/scripts/_bt" >/dev/null 2>&1 || true
    TCL=$(find "$DIR/scripts/_bt" -name "*.tcl" | head -n 1)
    [ -n "$TCL" ] || die "No TCL file found in BlackTools repo."
    cp "$TCL" "$DIR/scripts/BlackTools.tcl"
}

write_relay() {
    DIR="$1"
    cat > "$DIR/scripts/sulap-relay.tcl" <<EOF
bind pub m relay sulap_relay
proc sulap_relay {nick uhost hand chan text} {
    set msg [join \$text " "]
    putserv "PRIVMSG \$chan :[RELAY] \$msg"
}
EOF
}

write_config() {
    BASE="$1"
    DIR="$2"
    BOT="$3"
    SERVER="$4"
    PORT="$5"
    CHAN="$6"
    REAL="$7"
    IDENT="$8"
    OWNER="$9"

    LISTEN=$(reserve_port "$BASE" "$BOT")

    cat > "$DIR/$BOT.conf" <<EOF
set nick "$BOT"
set altnick "${BOT}-"
set username "$IDENT"
set realname "$REAL"
set owner "$OWNER"
set servers { $SERVER:$PORT }

loadmodule server
loadmodule channels
loadmodule irc

listen $LISTEN all

channel add $CHAN {
    chanmode "+nt"
}

source eggdrop.conf
source scripts/BlackTools.tcl
source scripts/sulap-relay.tcl
EOF

    log "Bot will listen on port $LISTEN"
    ask_yes "Open firewall for port $LISTEN?" && open_firewall "$LISTEN"
}

install_bot() {
    log "$PROJECT v$VERSION"

    ask_yes "Install prerequisites?" && install_prereqs

    BASE=$(prompt "Eggdrop base dir" "$DEFAULT_BASE")
    BASE=$(abs_path "$BASE")

    BOT=$(prompt "Bot nickname" "sulap_bot")
    SERVER=$(prompt "IRC server" "$DEFAULT_SERVER")
    PORT=$(prompt "IRC port" "$DEFAULT_PORT")
    CHAN=$(prompt "Home channel" "$DEFAULT_CHAN")
    REAL=$(prompt "Realname" "$DEFAULT_REALNAME")
    IDENT=$(prompt "Ident/username" "$(whoami)")
    OWNER=$(prompt "Owner name/handle" "$(whoami)")

    mkdir -p "$BASE"
    DIR="$BASE/$BOT"

    if [ -d "$DIR" ]; then
        ask_yes "Directory exists. Backup?" && mv "$DIR" "$DIR.backup.$(date +%s)"
    fi

    mkdir -p "$DIR"

    build_eggdrop "$DIR"
    install_blacktools "$DIR"
    write_relay "$DIR"
    write_config "$BASE" "$DIR" "$BOT" "$SERVER" "$PORT" "$CHAN" "$REAL" "$IDENT" "$OWNER"

    log "Installation complete."
    echo "Start with:"
    echo "cd $DIR && ./eggdrop -m $BOT.conf"
}

case "$1" in
    -i) install_bot ;;
    *) echo "Usage: $0 -i [--yes]" ;;
esac
