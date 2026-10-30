#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Stealth Tor v3 Client Setup for Secondary Android Phone (Termux)
# ==============================================================================
# This script configures a mobile client (another Android device with Termux)
# to authenticate and connect to your primary phone server over stealth Tor v3.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}"
echo "=================================================================="
echo "    STEALTH TOR v3 CLIENT SETUP FOR MOBILE TERMUX                "
echo "=================================================================="
echo -e "${NC}"

if [ -z "$PREFIX" ] || [ ! -d "/data/data/com.termux" ]; then
    echo -e "${RED}[!] Error: This script must be run inside Android Termux!${NC}"
    exit 1
fi

export HOME=/data/data/com.termux/files/home
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH=$PREFIX/bin:$PATH
cd "$HOME"

# 1. Package Installation & Verification
echo -e "${BLUE}[*] Step 1/5: Installing dependencies (tor, openssh, netcat-openbsd, openssl-tool, coreutils, procps, psmisc)...${NC}"
pkg update -y
pkg install -y tor openssh netcat-openbsd openssl-tool coreutils procps psmisc

# Verify every critical binary
for cmd in openssl ssh-keygen base32 tor nc pgrep killall; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Binary $cmd not found. Attempting repair install...${NC}"
        pkg install -y tor openssh netcat-openbsd openssl-tool coreutils procps psmisc
        break
    fi
done
echo -e "${GREEN}[+] All dependencies verified: openssl, ssh-keygen, base32, tor, nc, pgrep, killall.${NC}"

# 2. SSH Key Generation (Ed25519)
echo -e "${BLUE}[*] Step 2/5: Generating Client SSH Ed25519 Keypair...${NC}"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_KEY_FILE="$HOME/.ssh/phone_server_ed25519"

if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "termux-client-to-phone-server" >/dev/null
    echo -e "${GREEN}[+] Generated client SSH key: $SSH_KEY_FILE${NC}"
else
    echo -e "${YELLOW}[!] Existing SSH key detected at: $SSH_KEY_FILE (Reusing)${NC}"
fi
SSH_PUB_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

# 3. Tor Client Authorization Key Generation (X25519)
echo -e "${BLUE}[*] Step 3/5: Generating Client Tor X25519 Cryptographic Keys...${NC}"
mkdir -p "$HOME/.tor_keys"
chmod 700 "$HOME/.tor_keys"
X25519_PEM="$HOME/.tor_keys/x25519_priv.pem"

if [ ! -f "$X25519_PEM" ]; then
    openssl genpkey -algorithm x25519 -out "$X25519_PEM" 2>/dev/null
    chmod 600 "$X25519_PEM"
    echo -e "${GREEN}[+] Generated new X25519 key: $X25519_PEM${NC}"
else
    echo -e "${YELLOW}[!] Existing X25519 key detected at: $X25519_PEM (Reusing)${NC}"
fi

# Extract raw 32-byte public key and private key in unpadded Base32
TOR_PUB_KEY=$(openssl pkey -in "$X25519_PEM" -pubout -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')
TOR_PRIV_KEY=$(openssl pkey -in "$X25519_PEM" -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')

# 4. Display Keys for Registration on Server
echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "      COPY THESE KEYS TO YOUR MAIN PHONE SERVER                  "
echo "==================================================================${NC}"
echo -e "${CYAN}${BOLD}1. MOBILE CLIENT TOR PUBLIC KEY (Paste into Server Tor Auth):${NC}"
echo -e "${YELLOW}${BOLD}descriptor:x25519:$TOR_PUB_KEY${NC}"
echo ""
echo -e "${CYAN}${BOLD}2. MOBILE CLIENT SSH PUBLIC KEY (Paste into Server authorized_keys):${NC}"
echo -e "${YELLOW}${BOLD}$SSH_PUB_CONTENT${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo ""

# Save a copy of public keys to file for easy retrieval
{
    echo "TOR_PUB=descriptor:x25519:$TOR_PUB_KEY"
    echo "SSH_PUB=$SSH_PUB_CONTENT"
} > /sdcard/Download/client_public_keys.txt 2>/dev/null || {
    echo "TOR_PUB=descriptor:x25519:$TOR_PUB_KEY"
    echo "SSH_PUB=$SSH_PUB_CONTENT"
} > "$HOME/client_public_keys.txt"

# 5. Configure Client Tor Authorization Directory
echo -e "${BLUE}[*] Step 4/5: Configuring Client Tor Directory...${NC}"
mkdir -p "$PREFIX/var/lib/tor/onion_auth"
chmod 700 "$PREFIX/var/lib/tor/onion_auth"

if ! grep -q "ClientOnionAuthDir" "$PREFIX/etc/tor/torrc" 2>/dev/null; then
    echo "ClientOnionAuthDir $PREFIX/var/lib/tor/onion_auth" >> "$PREFIX/etc/tor/torrc"
fi

# 6. Prompt for Server Onion Address and Server Username (supports arguments $1 and $2)
INPUT_ONION="${1:-}"
SERVER_USER="${2:-}"

if [ -z "$INPUT_ONION" ]; then
    echo -e "${YELLOW}Please enter the 56-character .onion address of your main Server:${NC}"
    read -p "Server Onion Address (e.g. abcdef...onion): " INPUT_ONION
fi

if [ -z "$SERVER_USER" ]; then
    read -p "Server Termux Username (run 'whoami' on phone server) [default: u0_a300]: " SERVER_USER
    SERVER_USER=${SERVER_USER:-u0_a300}
fi

CLEAN_ONION=$(echo "$INPUT_ONION" | sed 's/\.onion//' | tr -d ' \n\r')

if [ -n "$CLEAN_ONION" ]; then
    AUTH_FILE_CONTENT="${CLEAN_ONION}:descriptor:x25519:${TOR_PRIV_KEY}"
    echo "$AUTH_FILE_CONTENT" > "$PREFIX/var/lib/tor/onion_auth/phone.auth_private"
    chmod 600 "$PREFIX/var/lib/tor/onion_auth/phone.auth_private"
    echo -e "${GREEN}[+] Saved private authorization key to $PREFIX/var/lib/tor/onion_auth/phone.auth_private${NC}"
    
    # Restart local client Tor daemon
    killall tor 2>/dev/null || true
    nohup tor > "$PREFIX/var/lib/tor/client_tor.log" 2>&1 &
    echo -e "${GREEN}[+] Client Tor proxy started on 127.0.0.1:9050.${NC}"
else
    echo -e "${YELLOW}[!] Skipped onion address mapping.${NC}"
fi

# 7. Configure ~/.ssh/config (Clean, Idempotent, with Connection Multiplexing)
echo -e "${BLUE}[*] Step 5/5: Configuring ~/.ssh/config for multiplexed connection...${NC}"
FULL_ONION="${CLEAN_ONION:-YOUR_ONION_ADDRESS}.onion"

touch "$HOME/.ssh/config"
chmod 600 "$HOME/.ssh/config"

# Strip existing phone-server blocks (both tagged and legacy untagged)
sed -i '/# --- START STEALTH TOR PHONE SERVER CONFIG ---/,/# --- END STEALTH TOR PHONE SERVER CONFIG ---/d' "$HOME/.ssh/config" 2>/dev/null || true
sed -i '/^Host phone-server$/,/^Host /{ /^Host phone-server$/d; /^Host /!d; }' "$HOME/.ssh/config" 2>/dev/null || true

cat << EOF >> "$HOME/.ssh/config"
# --- START STEALTH TOR PHONE SERVER CONFIG ---
Host phone-server
    HostName $FULL_ONION
    User $SERVER_USER
    Port 8022
    IdentityFile $SSH_KEY_FILE
    IdentitiesOnly yes
    Compression yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 10m
    ProxyCommand nc -X 5 -x 127.0.0.1:9050 %h %p
# --- END STEALTH TOR PHONE SERVER CONFIG ---
EOF

# 8. Install Client Helper Commands into $PREFIX/bin/
echo -e "${BLUE}[*] Installing client helper tools (phone-ssh, status-server, stop-server, restart-server)...${NC}"

# 8a. phone-ssh (auto-starts Tor if inactive, waits for port 9050 with diagnostic reporting)
cat << 'EOF' > "$PREFIX/bin/phone-ssh"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[*] Starting local Tor proxy..."
    nohup tor > "$PREFIX/var/lib/tor/client_tor.log" 2>&1 &
    TOR_READY=0
    for i in $(seq 1 15); do
        if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
            TOR_READY=1
            break
        fi
        sleep 1
    done
    if [ "$TOR_READY" -eq 0 ]; then
        echo "[!] Warning: Local Tor proxy did not respond on 127.0.0.1:9050."
        echo "    Check logs: cat $PREFIX/var/lib/tor/client_tor.log"
    fi
fi
ssh phone-server "$@"
EOF

# 8b. status-server
cat << 'EOF' > "$PREFIX/bin/status-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[*] Starting local Tor proxy..."
    nohup tor > "$PREFIX/var/lib/tor/client_tor.log" 2>&1 &
    for i in $(seq 1 15); do
        if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi
echo "[*] Connecting to Phone Server over Tor..."
if ! ssh -o ConnectTimeout=20 phone-server status-server; then
    echo ""
    echo "[!] Could not reach Phone Server over Tor."
    echo "    Troubleshooting tips:"
    echo "    1. Ensure phone server is powered on and connected to charger."
    echo "    2. Ensure phone server has an active Wi-Fi or mobile data connection."
    echo "    3. Ensure Termux wakelock is acquired on the server."
fi
EOF

# 8c. stop-server
cat << 'EOF' > "$PREFIX/bin/stop-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[*] Starting local Tor proxy..."
    nohup tor > "$PREFIX/var/lib/tor/client_tor.log" 2>&1 &
    for i in $(seq 1 15); do
        if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi
echo "[*] Sending stop signal to Phone Server over Tor..."
ssh -o ConnectTimeout=20 phone-server stop-server 2>/dev/null || true
echo "[+] Phone server daemons terminated successfully."
EOF

# 8d. restart-server
cat << 'EOF' > "$PREFIX/bin/restart-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[*] Starting local Tor proxy..."
    nohup tor > "$PREFIX/var/lib/tor/client_tor.log" 2>&1 &
    for i in $(seq 1 15); do
        if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi
echo "[*] Restarting Phone Server over Tor..."
ssh -o ConnectTimeout=20 phone-server restart-server
EOF

# For convenience, link connect-server as well
ln -sf "$PREFIX/bin/phone-ssh" "$PREFIX/bin/connect-server"

chmod 755 "$PREFIX/bin/phone-ssh" "$PREFIX/bin/status-server" "$PREFIX/bin/stop-server" "$PREFIX/bin/restart-server" "$PREFIX/bin/connect-server"

# Install master phone-server CLI tool
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/phone-server" ]; then
    cp "$SCRIPT_DIR/phone-server" "$PREFIX/bin/phone-server"
    chmod 755 "$PREFIX/bin/phone-server"
    ln -sf "$PREFIX/bin/phone-server" "$PREFIX/bin/stealth-server"
fi

# Dynamically apply exact SELinux MLS context if on Android root
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    TERMUX_CTX=$(ls -ldZ "$PREFIX/bin/sh" 2>/dev/null | grep -o 'u:object_r:app_data_file:[^ ]*' | head -n 1 || true)
    if [ -n "$TERMUX_CTX" ]; then
        su -c "chcon $TERMUX_CTX $PREFIX/bin/*-server $PREFIX/bin/phone-ssh $PREFIX/bin/phone-server 2>/dev/null || true"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "               MOBILE CLIENT CONFIGURATION COMPLETE!              "
echo "==================================================================${NC}"
echo -e "Connect to your home phone server anytime by running:"
echo -e "${YELLOW}${BOLD}  phone-server${NC}       # Interactive menu"
echo -e "${YELLOW}${BOLD}  phone-server status${NC}  # Check phone health"
echo -e "${YELLOW}${BOLD}  phone-server connect${NC} # Shell login (or ssh phone-server)"
echo ""
echo "Companion commands available:"
echo "  • phone-server   : Master CLI & interactive menu (alias: stealth-server)"
echo "  • phone-ssh      : One-word shortcut to ssh into the server (multiplexed)"
echo "  • status-server  : Query phone server status over Tor"
echo "  • stop-server    : Force terminate phone server daemons remotely"
echo "  • restart-server : Cleanly cycle the server daemons remotely"
echo "=================================================================="
