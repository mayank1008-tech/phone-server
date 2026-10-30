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

# Helper for sudo commands
run_sudo() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# 1. Package Installation
echo -e "${BLUE}[*] Step 1/5: Checking dependencies (tor, netcat, openssl)...${NC}"
if ! command -v tor >/dev/null 2>&1 || ! command -v nc >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Installing Tor and Netcat...${NC}"
    if command -v apt-get >/dev/null 2>&1; then
        run_sudo apt-get update -y
        run_sudo apt-get install -y tor netcat-openbsd openssl
    elif command -v dnf >/dev/null 2>&1; then
        run_sudo dnf install -y tor nmap-ncat openssl
    elif command -v pacman >/dev/null 2>&1; then
        run_sudo pacman -Sy --noconfirm tor openbsd-netcat openssl
    else
        echo -e "${RED}[!] Unsupported package manager. Please install tor and netcat manually.${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}[+] Dependencies verified.${NC}"

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
TOR_PUB_KEY=$(openssl pkey -in "$X25519_PEM" -pubout -outform DER | tail -c 32 | base32 | tr -d '=')
TOR_PRIV_KEY=$(openssl pkey -in "$X25519_PEM" -outform DER | tail -c 32 | base32 | tr -d '=')

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

# 6. Prompt for Onion Address
echo -e "${YELLOW}Please enter the 56-character .onion address from your Phone Server:${NC}"
read -p "Server Onion Address (e.g. abcdef...onion): " INPUT_ONION

CLEAN_ONION=$(echo "$INPUT_ONION" | sed 's/\.onion//' | tr -d ' ')

if [ -n "$CLEAN_ONION" ]; then
    AUTH_FILE_CONTENT="${CLEAN_ONION}:descriptor:x25519:${TOR_PRIV_KEY}"
    echo "$AUTH_FILE_CONTENT" | run_sudo tee /var/lib/tor/onion_auth/phone.auth_private >/dev/null
    run_sudo chmod 600 /var/lib/tor/onion_auth/phone.auth_private
    run_sudo chown -R debian-tor:debian-tor /var/lib/tor/onion_auth 2>/dev/null || true
    echo -e "${GREEN}[+] Saved private authorization key to /var/lib/tor/onion_auth/phone.auth_private${NC}"
    
    # Restart Tor service
    echo -e "${BLUE}[*] Restarting system Tor service...${NC}"
    run_sudo systemctl restart tor || run_sudo service tor restart || true
else
    echo -e "${YELLOW}[!] Skipped onion address mapping. You can add it later to /var/lib/tor/onion_auth/phone.auth_private${NC}"
fi

# 7. Configure ~/.ssh/config
echo -e "${BLUE}[*] Step 5/5: Configuring ~/.ssh/config for instantaneous multiplexed connection...${NC}"
FULL_ONION="${CLEAN_ONION:-YOUR_ONION_ADDRESS}.onion"

# Remove old phone-server block if present
if [ -f "$HOME/.ssh/config" ]; then
    sed -i '/^Host phone-server$/,/^Host /{ /^Host phone-server$/d; /^Host /!d; }' "$HOME/.ssh/config" 2>/dev/null || true
fi

cat << EOF >> "$HOME/.ssh/config"
Host phone-server
    HostName $FULL_ONION
    User u0_a300
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
EOF
chmod 600 "$HOME/.ssh/config"

# 8. Install Local PC Management Scripts into ~/.local/bin/
mkdir -p "$HOME/.local/bin"

cat << 'EOF' > "$HOME/.local/bin/status-server"
#!/bin/bash
if adb devices 2>/dev/null | grep -q "device$"; then
    adb shell su -g 10300 -G 3003 10300 -c '/data/data/com.termux/files/usr/bin/status-server' 2>/dev/null || \
    adb shell '/data/data/com.termux/files/usr/bin/status-server'
else
    echo "[*] Connecting to phone server over Tor..."
    ssh -o ConnectTimeout=15 phone-server status-server
fi
EOF

cat << 'EOF' > "$HOME/.local/bin/stop-server"
#!/bin/bash
if adb devices 2>/dev/null | grep -q "device$"; then
    adb shell su -g 10300 -G 3003 10300 -c '/data/data/com.termux/files/usr/bin/stop-server' 2>/dev/null || \
    adb shell '/data/data/com.termux/files/usr/bin/stop-server'
else
    ssh -o ConnectTimeout=15 phone-server stop-server
fi
EOF

cat << 'EOF' > "$HOME/.local/bin/phone-ssh"
#!/bin/bash
ssh phone-server "$@"
EOF

chmod +x "$HOME/.local/bin/status-server"
chmod +x "$HOME/.local/bin/stop-server"
chmod +x "$HOME/.local/bin/phone-ssh"

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "                   LINUX CLIENT CONFIGURATION COMPLETE!           "
echo "==================================================================${NC}"
echo -e "You can now connect to your phone server from anywhere in the world:"
echo -e "${YELLOW}${BOLD}  ssh phone-server${NC}"
echo ""
echo "Convenience commands available:"
echo "  • status-server : Inspect phone server status (via ADB if wired, or Tor if wireless)"
echo "  • stop-server   : Terminate phone server daemons remotely"
echo "  • phone-ssh     : Quick alias for ssh phone-server"
echo "=================================================================="
