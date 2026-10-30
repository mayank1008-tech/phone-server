#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Stealth Tor v3 Phone Server Setup (Android Termux)
# ==============================================================================
# This script configures a headless, account-free, zero-discovery server on Android
# using Tor v3 Onion Services with Client Authorization (x25519) and OpenSSH (Ed25519).
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
echo "    STEALTH TOR v3 PHONE SERVER SETUP (ANDROID TERMUX)           "
echo "=================================================================="
echo -e "${NC}"

# 1. Environment Verification
if [ -z "$PREFIX" ] || [ ! -d "/data/data/com.termux" ]; then
    echo -e "${RED}[!] Error: This script must be run inside Android Termux!${NC}"
    exit 1
fi

export HOME=/data/data/com.termux/files/home
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH=$PREFIX/bin:$PATH
cd "$HOME"

# 2. Package Installation & Self-Healing Verification
echo -e "${BLUE}[*] Step 1/5: Installing dependencies (tor, openssh, openssl-tool, coreutils, procps, psmisc, termux-tools)...${NC}"
pkg update -y
pkg install -y tor openssh openssl-tool coreutils procps psmisc termux-tools

# Verify every critical binary
for cmd in sshd tor openssl ssh-keygen base32 pgrep killall; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Binary $cmd not found. Attempting repair installation...${NC}"
        pkg install -y tor openssh openssl-tool coreutils procps psmisc termux-tools
        break
    fi
done
echo -e "${GREEN}[+] Dependencies verified: sshd, tor, openssl, ssh-keygen, base32, pgrep, killall.${NC}"

# 3. Android & Samsung Sleep Hardening (via Root if available & granted)
echo -e "${BLUE}[*] Step 2/5: Applying Android & Samsung Keep-Alive Hardening...${NC}"
HAS_ROOT=0
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    HAS_ROOT=1
    echo -e "${GREEN}[+] Root access confirmed. Applying permanent power-management immunity...${NC}"
    su -c "dumpsys deviceidle whitelist +com.termux 2>/dev/null || true"
    su -c "cmd appops set com.termux RUN_IN_BACKGROUND allow 2>/dev/null || true"
    su -c "cmd appops set com.termux RUN_ANY_IN_BACKGROUND allow 2>/dev/null || true"
    su -c "cmd appops set com.termux WAKE_LOCK allow 2>/dev/null || true"
    su -c "settings put global wifi_sleep_policy 2 2>/dev/null || true"
    su -c "settings put global wifi_wakeup_enabled 1 2>/dev/null || true"
    su -c "settings put global stay_on_while_plugged_in 3 2>/dev/null || true"
    su -c "pm disable-user --user 0 com.samsung.android.lool 2>/dev/null || true"
    echo -e "${GREEN}[+] Android OS Doze and Samsung background killers suppressed.${NC}"
else
    echo -e "${YELLOW}[!] Root (su) not available or not granted. Acquiring user-space wakelock...${NC}"
fi

# Acquire Termux wakelock
termux-wake-lock 2>/dev/null || true

# 4. OpenSSH Server Hardening
echo -e "${BLUE}[*] Step 3/5: Hardening OpenSSH Server...${NC}"
mkdir -p "$PREFIX/etc/ssh"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

# Ensure host keys exist (prevents 'no hostkeys available' error on fresh setups)
ssh-keygen -A >/dev/null 2>&1 || true

# Enforce no password auth and key-only in sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$PREFIX/etc/ssh/sshd_config" 2>/dev/null || echo "PasswordAuthentication no" >> "$PREFIX/etc/ssh/sshd_config"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$PREFIX/etc/ssh/sshd_config" 2>/dev/null || echo "PubkeyAuthentication yes" >> "$PREFIX/etc/ssh/sshd_config"
sed -i 's/^#*Port.*/Port 8022/' "$PREFIX/etc/ssh/sshd_config" 2>/dev/null || echo "Port 8022" >> "$PREFIX/etc/ssh/sshd_config"

# 5. Tor Stealth Hidden Service Configuration
echo -e "${BLUE}[*] Step 4/5: Configuring Stealth Tor v3 Hidden Service...${NC}"
mkdir -p "$PREFIX/etc/tor"
mkdir -p "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients"
chmod 700 "$PREFIX/var/lib/tor/hidden_ssh"
chmod 700 "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients"

# Clean up existing hidden_ssh block if re-running
if [ -f "$PREFIX/etc/tor/torrc" ]; then
    grep -v "hidden_ssh" "$PREFIX/etc/tor/torrc" > "$PREFIX/etc/tor/torrc.bak" || true
    mv "$PREFIX/etc/tor/torrc.bak" "$PREFIX/etc/tor/torrc"
fi

cat << EOF >> "$PREFIX/etc/tor/torrc"
# Stealth Tor v3 Onion Service for SSH
HiddenServiceDir $PREFIX/var/lib/tor/hidden_ssh/
HiddenServicePort 8022 127.0.0.1:8022
EOF

# 6. Install Server Control Executables into $PREFIX/bin/
echo -e "${BLUE}[*] Step 5/5: Installing Management CLI Tools into $PREFIX/bin/...${NC}"

# Clean up any legacy shell functions or aliases in ~/.bashrc that would shadow $PREFIX/bin binaries
if [ -f "$HOME/.bashrc" ]; then
    sed -i '/# --- Headless Phone Server Management ---/,/Display active PIDs/d' "$HOME/.bashrc" 2>/dev/null || true
    sed -i '/alias start-server=/d; /alias stop-server=/d; /alias status-server=/d; /alias restart-server=/d' "$HOME/.bashrc" 2>/dev/null || true
fi

# 6a. start-server (idempotent, checks ports before binding)
cat << 'EOF' > "$PREFIX/bin/start-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Ensure host keys exist
ssh-keygen -A >/dev/null 2>&1 || true

# Start sshd if not already listening
if (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1; then
    echo "[*] OpenSSH daemon is already running (port 8022)."
else
    $PREFIX/bin/sshd
    echo "[+] OpenSSH daemon started on port 8022."
fi

# Start Tor if not already listening
if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
    echo "[*] Tor daemon is already running (port 9050)."
else
    nohup $PREFIX/bin/tor > "$PREFIX/var/lib/tor/tor.log" 2>&1 &
    echo "[+] Tor daemon started in background."
fi

# Ensure Termux wakelock is active
termux-wake-lock 2>/dev/null || true
echo "[+] Phone server is active and protected against Doze."
EOF

# 6b. stop-server (terminates listener and all worker sessions)
cat << 'EOF' > "$PREFIX/bin/stop-server"
#!/data/data/com.termux/files/usr/bin/bash
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    su -c 'killall -9 tor sshd sshd-session 2>/dev/null || true'
fi
killall -9 tor sshd sshd-session 2>/dev/null || true
pkill -9 -x tor 2>/dev/null || true
pkill -9 -x sshd 2>/dev/null || true
pkill -9 sshd-session 2>/dev/null || true
echo "[+] Phone server stopped & all active sessions terminated."
EOF

# 6c. status-server (dual-layer detection: root pgrep + local socket probes)
cat << 'EOF' > "$PREFIX/bin/status-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Check process IDs (dual-layer: root su if available, fallback to user space)
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    SSH_PID=$(su -c 'pgrep -x sshd' 2>/dev/null | head -n 1)
    TOR_PID=$(su -c 'pgrep -x tor' 2>/dev/null | head -n 1)
    CONN_COUNT=$(su -c 'ss -tn state established sport = :8022 2>/dev/null' | grep -v Recv-Q | grep -c 8022 || echo 0)
    if [ "$CONN_COUNT" -gt 0 ] 2>/dev/null; then
        SESSIONS=$CONN_COUNT
    else
        RAW_WORKERS=$(su -c 'pgrep sshd-session' 2>/dev/null | wc -l)
        SESSIONS=$(( ${RAW_WORKERS:-0} / 2 ))
    fi
else
    SSH_PID=$(pgrep -x sshd 2>/dev/null | head -n 1)
    TOR_PID=$(pgrep -x tor 2>/dev/null | head -n 1)
    RAW_WORKERS=$(pgrep sshd-session 2>/dev/null | wc -l)
    SESSIONS=$(( ${RAW_WORKERS:-0} / 2 ))
fi

# Fallback to direct TCP socket probes (bypasses SELinux process hiding)
if [ -z "$SSH_PID" ]; then
    if (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1; then
        SSH_PID="ACTIVE (port 8022)"
    fi
fi

if [ -z "$TOR_PID" ]; then
    if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
        TOR_PID="ACTIVE (port 9050)"
    fi
fi

ONION=$(cat "$PREFIX/var/lib/tor/hidden_ssh/hostname" 2>/dev/null || true)
AUTH_CLIENTS=$(find "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients" -name "*.auth" 2>/dev/null | wc -l || echo 0)

# Optional battery status
BATTERY=""
if [ -f /sys/class/power_supply/battery/capacity ]; then
    BATTERY=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
fi

echo "=========================================="
echo "        Phone Server Status"
echo "=========================================="
if [ -n "$SSH_PID" ]; then
    echo "  [+] OpenSSH Daemon : RUNNING (PID: $SSH_PID)"
else
    echo "  [-] OpenSSH Daemon : STOPPED"
fi

if [ -n "$TOR_PID" ]; then
    echo "  [+] Tor Daemon     : RUNNING (PID: $TOR_PID)"
else
    echo "  [-] Tor Daemon     : STOPPED"
fi

echo "  [*] Active Clients : $SESSIONS connected"
echo "  [*] Auth Clients   : $AUTH_CLIENTS registered"

if [ -n "$BATTERY" ]; then
    echo "  [*] Battery Level  : ${BATTERY}%"
fi

if [ -n "$ONION" ]; then
    echo "  [*] Onion Address  : $ONION"
fi
echo "=========================================="
EOF

# 6d. restart-server
cat << 'EOF' > "$PREFIX/bin/restart-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
$PREFIX/bin/stop-server
sleep 1
$PREFIX/bin/start-server
EOF

# 6e. authorize-client (Allows registering additional client devices anytime)
cat << 'EOF' > "$PREFIX/bin/authorize-client"
#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Authorize a New Client Device (Phone Server)
# ==============================================================================
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME=/data/data/com.termux/files/home

CLIENT_NAME="$1"
TOR_PUB="$2"
SSH_PUB="$3"

if [ -z "$CLIENT_NAME" ]; then
    read -p "Enter a label for this client device [default: client]: " CLIENT_NAME
    CLIENT_NAME=${CLIENT_NAME:-client}
fi

# Sanitize client name for safe filenames (alphanumeric, underscore, dash)
CLIENT_NAME=$(echo "$CLIENT_NAME" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
CLIENT_NAME=${CLIENT_NAME:-client}

if [ -z "$TOR_PUB" ]; then
    read -p "Paste Client Tor Public Key (descriptor:x25519:...): " TOR_PUB
fi

if [ -z "$SSH_PUB" ]; then
    read -p "Paste Client SSH Public Key (ssh-ed25519 AAAA...): " SSH_PUB
fi

CLEAN_PUB=$(echo "$TOR_PUB" | sed 's/descriptor:x25519://' | tr -d ' \t\n\r')
CLEAN_SSH=$(echo "$SSH_PUB" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

KEYS_ADDED=0

if [ -n "$CLEAN_PUB" ]; then
    mkdir -p "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients"
    echo "descriptor:x25519:$CLEAN_PUB" > "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients/${CLIENT_NAME}.auth"
    chmod 600 "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients/${CLIENT_NAME}.auth"
    echo "[+] Tor authorization registered: ${CLIENT_NAME}.auth"
    KEYS_ADDED=1
fi

if [ -n "$CLEAN_SSH" ]; then
    mkdir -p "$HOME/.ssh"
    if ! grep -qF "$CLEAN_SSH" "$HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "$CLEAN_SSH" >> "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        echo "[+] SSH Public Key authorized in ~/.ssh/authorized_keys"
    else
        echo "[*] SSH Public Key is already present in ~/.ssh/authorized_keys"
    fi
    KEYS_ADDED=1
fi

if [ "$KEYS_ADDED" -eq 1 ]; then
    # Signal Tor to reload authorization descriptors without dropping circuits
    if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
        su -c 'killall -HUP tor 2>/dev/null || pkill -HUP -x tor 2>/dev/null' || true
    else
        killall -HUP tor 2>/dev/null || pkill -HUP -x tor 2>/dev/null || true
    fi
    echo "[+] Tor reloaded. Client '$CLIENT_NAME' is authorized!"
else
    echo "[!] No keys provided. Skipped authorization. Run 'authorize-client' anytime when ready."
fi
EOF

chmod 755 "$PREFIX/bin/start-server" "$PREFIX/bin/stop-server" "$PREFIX/bin/status-server" "$PREFIX/bin/restart-server" "$PREFIX/bin/authorize-client"

# 6f. Autostart on boot (Termux:Boot support)
mkdir -p "$HOME/.termux/boot"
cat << 'EOF' > "$HOME/.termux/boot/start-phone-server.sh"
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock 2>/dev/null || true
$PREFIX/bin/start-server
EOF
chmod 755 "$HOME/.termux/boot/start-phone-server.sh"

# Dynamically apply exact SELinux MLS context if on Android root
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    TERMUX_CTX=$(ls -ldZ "$PREFIX/bin/sh" 2>/dev/null | grep -o 'u:object_r:app_data_file:[^ ]*' | head -n 1 || true)
    if [ -n "$TERMUX_CTX" ]; then
        su -c "chcon $TERMUX_CTX $PREFIX/bin/*-server $PREFIX/bin/authorize-client 2>/dev/null || true"
    fi
fi

# 7. Interactive Client Authorization Setup
echo ""
echo -e "${YELLOW}${BOLD}--- CLIENT AUTHORIZATION REGISTRATION ---${NC}"
echo "To grant your PC or mobile device access to this server, register its generated keys."
echo "If you haven't generated client keys yet, you can press Enter to skip and run 'authorize-client' later."
echo ""

"$PREFIX/bin/authorize-client"

# 8. Start Services and Obtain Onion Hostname
echo ""
echo -e "${BLUE}[*] Starting services and establishing Tor circuits...${NC}"
"$PREFIX/bin/stop-server" >/dev/null 2>&1 || true
sleep 1
"$PREFIX/bin/start-server" >/dev/null

echo -e "${YELLOW}[*] Waiting for Tor to publish service descriptor and generate .onion address...${NC}"
ONION_ADDR=""
for i in $(seq 1 40); do
    if [ -f "$PREFIX/var/lib/tor/hidden_ssh/hostname" ]; then
        ONION_ADDR=$(cat "$PREFIX/var/lib/tor/hidden_ssh/hostname")
        break
    fi
    sleep 1
done

CURRENT_USER=$(whoami)

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "                   SETUP COMPLETE & SERVER ACTIVE!                "
echo "==================================================================${NC}"
if [ -n "$ONION_ADDR" ]; then
    echo -e "${CYAN}${BOLD}YOUR ONION ADDRESS:${NC}"
    echo -e "${YELLOW}${BOLD}  $ONION_ADDR${NC}"
    echo ""
    echo -e "${CYAN}${BOLD}SERVER TERMUX USERNAME:${NC}"
    echo -e "${YELLOW}${BOLD}  $CURRENT_USER${NC}"
    echo ""
    echo "Provide this Onion Address and Username to your client setup scripts."
else
    echo -e "${RED}[!] Tor is still bootstrapping. Check 'cat $PREFIX/var/lib/tor/tor.log' in a moment.${NC}"
fi
echo ""
echo -e "${BOLD}Management commands installed:${NC}"
echo "  • start-server     : Start background services (OpenSSH & Tor)"
echo "  • stop-server      : Force terminate all listeners and active sessions"
echo "  • status-server    : Display active PIDs, sockets, clients, and onion address"
echo "  • restart-server   : Cleanly cycle the server"
echo "  • authorize-client : Register additional client devices anytime"
echo "=================================================================="
