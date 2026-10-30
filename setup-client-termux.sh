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
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:$PATH
cd $HOME

# 1. Package Installation
echo -e "${BLUE}[*] Step 1/5: Installing dependencies (tor, openssh, netcat-openbsd)...${NC}"
pkg update -y
pkg install -y tor openssh netcat-openbsd openssl coreutils

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
    openssl genpkey -algorithm x25519 -out "$X25519_PEM"
    chmod 600 "$X25519_PEM"
    echo -e "${GREEN}[+] Generated new X25519 key: $X25519_PEM${NC}"
else
    echo -e "${YELLOW}[!] Existing X25519 key detected at: $X25519_PEM (Reusing)${NC}"
fi

# Extract raw 32-byte public key and private key in unpadded Base32
TOR_PUB_KEY=$(openssl pkey -in "$X25519_PEM" -pubout -outform DER | tail -c 32 | base32 | tr -d '=')
TOR_PRIV_KEY=$(openssl pkey -in "$X25519_PEM" -outform DER | tail -c 32 | base32 | tr -d '=')

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
cat << KEYSEOF > /sdcard/Download/client_public_keys.txt 2>/dev/null || cat << KEYSEOF > "$HOME/client_public_keys.txt"
TOR_PUB=descriptor:x25519:$TOR_PUB_KEY
SSH_PUB=$SSH_PUB_CONTENT
KEYSEOF

# 5. Configure Client Tor Authorization Directory
echo -e "${BLUE}[*] Step 4/5: Configuring Client Tor Directory...${NC}"
mkdir -p "$PREFIX/var/lib/tor/onion_auth"
chmod 700 "$PREFIX/var/lib/tor/onion_auth"

if ! grep -q "ClientOnionAuthDir" "$PREFIX/etc/tor/torrc" 2>/dev/null; then
    echo "ClientOnionAuthDir $PREFIX/var/lib/tor/onion_auth" >> "$PREFIX/etc/tor/torrc"
fi

# 6. Prompt for Server Onion Address (accepts $1 argument or prompts)
INPUT_ONION="${1:-}"
if [ -z "$INPUT_ONION" ]; then
    echo -e "${YELLOW}Please enter the 56-character .onion address of your main Server:${NC}"
    read -p "Server Onion Address (e.g. abcdef...onion): " INPUT_ONION
fi

CLEAN_ONION=$(echo "$INPUT_ONION" | sed 's/\.onion//' | tr -d ' ')

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

# 7. Configure ~/.ssh/config
echo -e "${BLUE}[*] Step 5/5: Configuring ~/.ssh/config...${NC}"
FULL_ONION="${CLEAN_ONION:-YOUR_ONION_ADDRESS}.onion"

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
    ProxyCommand nc -X 5 -x 127.0.0.1:9050 %h %p
EOF
chmod 600 "$HOME/.ssh/config"

# 8. Create quick connect alias
cat << 'EOF' > "$PREFIX/bin/connect-server"
#!/data/data/com.termux/files/usr/bin/bash
# Ensure client tor is running
pgrep -x tor >/dev/null || nohup tor >/dev/null 2>&1 &
ssh phone-server
EOF
chmod 755 "$PREFIX/bin/connect-server"

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "               MOBILE CLIENT CONFIGURATION COMPLETE!              "
echo "==================================================================${NC}"
echo -e "Connect to your home phone server anytime by running:"
echo -e "${YELLOW}${BOLD}  connect-server${NC}"
echo "=================================================================="
