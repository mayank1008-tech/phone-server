#!/bin/bash
# ==============================================================================
# Stealth Tor v3 Client Setup for Linux PC
# ==============================================================================
# This script configures a Linux computer to authenticate and connect to your
# stealth Tor v3 Android server using x25519 Client Authorization and Ed25519 SSH.
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
echo "      STEALTH TOR v3 CLIENT SETUP FOR LINUX                      "
echo "=================================================================="
echo -e "${NC}"

# Helper for privileged commands
run_sudo() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# 1. Package Installation & Self-Healing Verification
echo -e "${BLUE}[*] Step 1/5: Checking dependencies (tor, netcat, openssl, base32)...${NC}"
install_needed=0
for cmd in tor openssl ssh-keygen base32; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        install_needed=1
        break
    fi
done

# Check for a working SOCKS5 proxy command (nc or ncat)
if ! command -v nc >/dev/null 2>&1 && ! command -v ncat >/dev/null 2>&1; then
    install_needed=1
fi

if [ "$install_needed" -eq 1 ]; then
    echo -e "${YELLOW}[*] Installing missing dependencies...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        run_sudo apt-get update -y
        run_sudo apt-get install -y tor netcat-openbsd openssl coreutils openssh-client
    elif command -v dnf >/dev/null 2>&1; then
        run_sudo dnf install -y tor nmap-ncat openssl coreutils openssh-clients
    elif command -v pacman >/dev/null 2>&1; then
        run_sudo pacman -Sy --noconfirm tor openbsd-netcat openssl coreutils openssh
    elif command -v zypper >/dev/null 2>&1; then
        run_sudo zypper install -y tor netcat-openbsd openssl coreutils openssh
    elif command -v apk >/dev/null 2>&1; then
        run_sudo apk add tor netcat-openbsd openssl coreutils openssh-client
    else
        echo -e "${RED}[!] Unsupported package manager. Please install tor, netcat, and openssl manually.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[+] Dependencies verified: tor, nc/ncat, openssl, ssh-keygen, base32.${NC}"

# Detect ProxyCommand syntax based on available tools
PROXY_CMD="nc -X 5 -x 127.0.0.1:9050 %h %p"
if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- "-X"; then
    PROXY_CMD="nc -X 5 -x 127.0.0.1:9050 %h %p"
elif command -v ncat >/dev/null 2>&1; then
    PROXY_CMD="ncat --proxy-type socks5 --proxy 127.0.0.1:9050 %h %p"
fi

# 2. SSH Key Generation (Ed25519)
echo -e "${BLUE}[*] Step 2/5: Generating SSH Ed25519 Keypair...${NC}"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
SSH_KEY_FILE="$HOME/.ssh/phone_server_ed25519"

if [ ! -f "$SSH_KEY_FILE" ]; then
    ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "linux-client-to-phone-server" >/dev/null
    echo -e "${GREEN}[+] Generated new SSH key: $SSH_KEY_FILE${NC}"
else
    echo -e "${YELLOW}[!] Existing SSH key detected at: $SSH_KEY_FILE (Reusing)${NC}"
fi
SSH_PUB_CONTENT=$(cat "${SSH_KEY_FILE}.pub")

# 3. Tor Client Authorization Key Generation (X25519)
echo -e "${BLUE}[*] Step 3/5: Generating Tor X25519 Cryptographic Authorization Keys...${NC}"
mkdir -p "$HOME/.tor_keys"
chmod 700 "$HOME/.tor_keys"
X25519_PEM="$HOME/.tor_keys/x25519_priv.pem"

if [ ! -f "$X25519_PEM" ]; then
    openssl genpkey -algorithm x25519 -out "$X25519_PEM" 2>/dev/null
    chmod 600 "$X25519_PEM"
    echo -e "${GREEN}[+] Generated new X25519 private key: $X25519_PEM${NC}"
else
    echo -e "${YELLOW}[!] Existing X25519 key detected at: $X25519_PEM (Reusing)${NC}"
fi

# Extract raw 32-byte public key and private key in unpadded RFC 4648 Base32
TOR_PUB_KEY=$(openssl pkey -in "$X25519_PEM" -pubout -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')
TOR_PRIV_KEY=$(openssl pkey -in "$X25519_PEM" -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')

# 4. Display Keys for Server Registration
echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "          COPY THESE KEYS TO YOUR PHONE (SERVER SETUP)           "
echo "==================================================================${NC}"
echo -e "${CYAN}${BOLD}1. CLIENT TOR PUBLIC KEY (Paste into phone's Tor Auth):${NC}"
echo -e "${YELLOW}${BOLD}descriptor:x25519:$TOR_PUB_KEY${NC}"
echo ""
echo -e "${CYAN}${BOLD}2. CLIENT SSH PUBLIC KEY (Paste into phone's SSH Auth):${NC}"
echo -e "${YELLOW}${BOLD}$SSH_PUB_CONTENT${NC}"
echo -e "${GREEN}==================================================================${NC}"
echo ""

# 5. Configure Tor Client Authorization Directory
echo -e "${BLUE}[*] Step 4/5: Configuring Local Tor Client Authorization...${NC}"
run_sudo mkdir -p /var/lib/tor/onion_auth
run_sudo chmod 700 /var/lib/tor/onion_auth

# Ensure ClientOnionAuthDir is enabled in torrc
if ! run_sudo grep -q "ClientOnionAuthDir" /etc/tor/torrc 2>/dev/null; then
    echo "ClientOnionAuthDir /var/lib/tor/onion_auth" | run_sudo tee -a /etc/tor/torrc >/dev/null
fi

# 6. Prompt for Onion Address and Username (supports arguments $1 and $2)
INPUT_ONION="${1:-}"
SERVER_USER="${2:-}"

if [ -z "$INPUT_ONION" ]; then
    echo -e "${YELLOW}Please enter the 56-character .onion address from your Phone Server:${NC}"
    read -p "Server Onion Address (e.g. abcdef...onion): " INPUT_ONION
fi

if [ -z "$SERVER_USER" ]; then
    read -p "Server Termux Username (run 'whoami' on phone) [default: u0_a300]: " SERVER_USER
    SERVER_USER=${SERVER_USER:-u0_a300}
fi

CLEAN_ONION=$(echo "$INPUT_ONION" | sed 's/\.onion//' | tr -d ' \n\r')

if [ -n "$CLEAN_ONION" ]; then
    AUTH_FILE_CONTENT="${CLEAN_ONION}:descriptor:x25519:${TOR_PRIV_KEY}"
    echo "$AUTH_FILE_CONTENT" | run_sudo tee /var/lib/tor/onion_auth/phone.auth_private >/dev/null
    run_sudo chmod 600 /var/lib/tor/onion_auth/phone.auth_private
    
    # Auto-detect Tor daemon system user across Linux distributions
    TOR_USER="debian-tor"
    if id toranon >/dev/null 2>&1; then
        TOR_USER="toranon"
    elif id tor >/dev/null 2>&1; then
        TOR_USER="tor"
    elif id debian-tor >/dev/null 2>&1; then
        TOR_USER="debian-tor"
    fi
    run_sudo chown -R ${TOR_USER}:${TOR_USER} /var/lib/tor/onion_auth 2>/dev/null || true
    echo -e "${GREEN}[+] Saved private authorization key to /var/lib/tor/onion_auth/phone.auth_private (Owner: $TOR_USER)${NC}"
    
    # Enable and restart Tor service
    echo -e "${BLUE}[*] Restarting system Tor service...${NC}"
    run_sudo systemctl enable tor tor@default 2>/dev/null || true
    run_sudo systemctl restart tor tor@default 2>/dev/null || run_sudo service tor restart 2>/dev/null || true
else
    echo -e "${YELLOW}[!] Skipped onion address mapping. You can add it later to /var/lib/tor/onion_auth/phone.auth_private${NC}"
fi

# 7. Configure ~/.ssh/config (Clean & Idempotent with boundary markers)
echo -e "${BLUE}[*] Step 5/5: Configuring ~/.ssh/config for instantaneous multiplexed connection...${NC}"
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
    ProxyCommand $PROXY_CMD
# --- END STEALTH TOR PHONE SERVER CONFIG ---
EOF

# 8. Install Local PC Management Scripts into ~/.local/bin/
mkdir -p "$HOME/.local/bin"

# 8a. status-server
cat << 'EOF' > "$HOME/.local/bin/status-server"
#!/bin/bash
# Verify local Tor SOCKS proxy is active
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[!] Local Tor proxy (127.0.0.1:9050) is not listening. Starting Tor..."
    sudo systemctl start tor tor@default 2>/dev/null || sudo service tor start 2>/dev/null || true
    sleep 2
fi

if [ "$1" == "--adb" ]; then
    echo "[*] Querying Phone Server status directly via ADB..."
    adb shell '/data/data/com.termux/files/usr/bin/status-server'
    exit $?
fi

echo "[*] Connecting to Phone Server over Tor..."
if ! ssh -o ConnectTimeout=20 phone-server status-server; then
    echo ""
    echo "[!] Could not reach Phone Server over Tor."
    echo "    Troubleshooting tips:"
    echo "    1. Ensure phone server is powered on and connected to charger."
    echo "    2. Ensure phone has an active Wi-Fi or mobile data connection."
    echo "    3. Ensure Termux wakelock is acquired on the server."
fi
EOF

# 8b. stop-server (catches server-side socket close cleanly)
cat << 'EOF' > "$HOME/.local/bin/stop-server"
#!/bin/bash
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[!] Local Tor proxy (127.0.0.1:9050) is not listening. Starting Tor..."
    sudo systemctl start tor tor@default 2>/dev/null || sudo service tor start 2>/dev/null || true
    sleep 2
fi

if [ "$1" == "--adb" ]; then
    echo "[*] Stopping Phone Server directly via ADB..."
    adb shell '/data/data/com.termux/files/usr/bin/stop-server'
    exit $?
fi

echo "[*] Sending stop signal to Phone Server over Tor..."
ssh -o ConnectTimeout=20 phone-server stop-server 2>/dev/null || true
echo "[+] Phone server daemons terminated successfully."
EOF

# 8c. restart-server
cat << 'EOF' > "$HOME/.local/bin/restart-server"
#!/bin/bash
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[!] Local Tor proxy (127.0.0.1:9050) is not listening. Starting Tor..."
    sudo systemctl start tor tor@default 2>/dev/null || sudo service tor start 2>/dev/null || true
    sleep 2
fi

if [ "$1" == "--adb" ]; then
    echo "[*] Restarting Phone Server directly via ADB..."
    adb shell '/data/data/com.termux/files/usr/bin/restart-server'
    exit $?
fi

echo "[*] Restarting Phone Server over Tor..."
ssh -o ConnectTimeout=20 phone-server restart-server
EOF

# 8d. phone-ssh
cat << 'EOF' > "$HOME/.local/bin/phone-ssh"
#!/bin/bash
if ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[!] Local Tor proxy (127.0.0.1:9050) is not listening. Starting Tor..."
    sudo systemctl start tor tor@default 2>/dev/null || sudo service tor start 2>/dev/null || true
    sleep 2
fi
ssh phone-server "$@"
EOF

chmod +x "$HOME/.local/bin/status-server" "$HOME/.local/bin/stop-server" "$HOME/.local/bin/restart-server" "$HOME/.local/bin/phone-ssh"

# Ensure ~/.local/bin is in PATH in ~/.bashrc and ~/.zshrc if they exist
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if [ -f "$rc" ]; then
        if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$rc" 2>/dev/null; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        fi
    fi
done

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "                   LINUX CLIENT CONFIGURATION COMPLETE!           "
echo "==================================================================${NC}"
echo -e "You can now connect to your phone server from anywhere in the world:"
echo -e "${YELLOW}${BOLD}  ssh phone-server${NC}  or  ${YELLOW}${BOLD}phone-ssh${NC}"
echo ""
echo "Companion commands available:"
echo "  • phone-ssh      : Quick alias for ssh phone-server"
echo "  • status-server  : Query phone server status over Tor (or pass --adb)"
echo "  • stop-server    : Force terminate phone server daemons remotely"
echo "  • restart-server : Cleanly cycle the server daemons remotely"
echo "=================================================================="
