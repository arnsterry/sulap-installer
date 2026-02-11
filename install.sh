#!/usr/bin/env bash

set -e

EGG_VERSION="1.10.1"
EGG_URL="https://ftp.eggheads.org/pub/eggdrop/source/1.10/eggdrop-${EGG_VERSION}.tar.gz"
SULAP_REPO_ZIP="https://github.com/arnsterry/sulap-installer/archive/refs/heads/main.zip"

echo
echo "==> Sulap Installer"
echo

read -p "Install prerequisites automatically? (Y/N) [Y]: " AUTO
AUTO=${AUTO:-Y}

if [[ "$AUTO" =~ ^[Yy]$ ]]; then
    echo "==> Installing prerequisites..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        build-essential \
        gcc \
        make \
        curl \
        git \
        unzip \
        tcl \
        tcl-dev \
        libssl-dev \
        openssl \
        pkg-config \
        >/dev/null
    echo "==> Done."
fi

read -p "Eggdrop base dir [$HOME/bots]: " BASEDIR
BASEDIR=${BASEDIR:-$HOME/bots}
BASEDIR=$(realpath -m "$BASEDIR")

read -p "Bot nickname [sulap_bot]: " BOTNAME
BOTNAME=${BOTNAME:-sulap_bot}

read -p "IRC server [irc.dal.net]: " SERVER
SERVER=${SERVER:-irc.dal.net}

read -p "IRC port [6667]: " PORT
PORT=${PORT:-6667}

read -p "Home channel [#bislig]: " CHANNEL
CHANNEL=${CHANNEL:-#bislig}

read -p "Realname [https://sulapradio.com]: " REALNAME
REALNAME=${REALNAME:-https://sulapradio.com}

read -p "Ident/username [$USER]: " IDENT
IDENT=${IDENT:-$USER}

read -p "Owner name [$USER]: " OWNER
OWNER=${OWNER:-$USER}

INSTALL_DIR="$BASEDIR/$BOTNAME"
mkdir -p "$BASEDIR"

echo
echo "==> Preparing Eggdrop ${EGG_VERSION}..."

cd "$BASEDIR"

if [ ! -f "eggdrop-${EGG_VERSION}.tar.gz" ]; then
    echo "==> Downloading Eggdrop..."
    curl -L "$EGG_URL" -o "eggdrop-${EGG_VERSION}.tar.gz"
fi

if [ -d "eggdrop-${EGG_VERSION}" ]; then
    rm -rf "eggdrop-${EGG_VERSION}"
fi

tar -xzf "eggdrop-${EGG_VERSION}.tar.gz"

cd "eggdrop-${EGG_VERSION}"

./configure --prefix="$INSTALL_DIR"
make config
make -j$(nproc)
make install

echo "==> Eggdrop installed to $INSTALL_DIR"

echo
echo "==> Installing BlackTools..."

mkdir -p "$INSTALL_DIR/scripts"
cd "$INSTALL_DIR/scripts"

curl -L "$SULAP_REPO_ZIP" -o sulaprepo.zip
unzip -oq sulaprepo.zip -d tmprepo

BT_FOLDER=$(find tmprepo -type d -name "BLACKTOOLS NO CONFIG" | head -n 1)

if [ -z "$BT_FOLDER" ]; then
    echo "ERROR: BLACKTOOLS NO CONFIG folder not found."
    exit 1
fi

TCL_FILE=$(find "$BT_FOLDER" -name "*.tcl" | head -n 1)

if [ -z "$TCL_FILE" ]; then
    echo "ERROR: No .tcl file found inside BlackTools folder."
    exit 1
fi

cp "$TCL_FILE" "$INSTALL_DIR/scripts/BlackTools.tcl"

rm -rf tmprepo sulaprepo.zip

echo "==> BlackTools installed."

echo
echo "==> Creating configuration..."

cat > "$INSTALL_DIR/$BOTNAME.conf" <<EOF
set nick "$BOTNAME"
set altnick "${BOTNAME}-"
set realname "$REALNAME"
set username "$IDENT"
set owner "$OWNER"
set servers { $SERVER:$PORT }

loadmodule channels
loadmodule server
loadmodule irc

channel add $CHANNEL {
  chanmode "+nt"
  idle-kick 0
}

source scripts/BlackTools.tcl
EOF

echo
echo "========================================="
echo "Installation completed successfully."
echo
echo "Start your bot with:"
echo "cd $INSTALL_DIR"
echo "./eggdrop -m $BOTNAME.conf"
echo "========================================="
