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

# Clean up existing tagged phone-server block atomically if re-running
if [ -f "$PREFIX/etc/tor/torrc" ]; then
    sed -i '/# --- START STEALTH TOR PHONE SERVER CONFIG ---/,/# --- END STEALTH TOR PHONE SERVER CONFIG ---/d' "$PREFIX/etc/tor/torrc" 2>/dev/null || true
    # Also strip legacy untagged entries
    sed -i '/HiddenServiceDir.*hidden_ssh/d; /HiddenServicePort.*8022/d; /KeepalivePeriod/d; /ConnectionPadding/d; /ReducedConnectionPadding/d' "$PREFIX/etc/tor/torrc" 2>/dev/null || true
fi

cat << EOF >> "$PREFIX/etc/tor/torrc"
# --- START STEALTH TOR PHONE SERVER CONFIG ---
# Stealth Tor v3 Onion Service for SSH
HiddenServiceDir $PREFIX/var/lib/tor/hidden_ssh/
HiddenServicePort 8022 127.0.0.1:8022

# Mobile Dynamic IP & NAT Keepalive Tuning
KeepalivePeriod 30
ConnectionPadding 1
ReducedConnectionPadding 0
# --- END STEALTH TOR PHONE SERVER CONFIG ---
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
if (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1 || pidof sshd >/dev/null 2>&1; then
    echo "[*] OpenSSH daemon is already running (port 8022)."
else
    $PREFIX/bin/sshd
    echo "[+] OpenSSH daemon started on port 8022."
fi

# Start Tor if not already listening
if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1 || pidof tor >/dev/null 2>&1; then
    echo "[*] Tor daemon is already running (port 9050)."
else
    if ! $PREFIX/bin/tor --verify-config >/dev/null 2>&1; then
        echo "[!] Error: tor --verify-config reported invalid configuration. Tor was NOT started."
    else
        nohup $PREFIX/bin/tor > "$PREFIX/var/lib/tor/tor.log" 2>&1 &
        echo "[+] Tor daemon started in background."
    fi
fi

# Ensure Termux wakelock is active
termux-wake-lock 2>/dev/null || true

# Start background dynamic IP watchdog & auto-healer
if [ -x "$PREFIX/bin/watchdog-server" ]; then
    if ! pgrep -f "watchdog-server" >/dev/null 2>&1; then
        nohup $PREFIX/bin/watchdog-server >/dev/null 2>&1 &
        echo "[+] Dynamic IP watchdog started in background."
    fi
fi
echo "[+] Phone server is active and protected against Doze."
EOF

# 6b. stop-server (terminates listener, watchdog, and all worker sessions)
cat << 'EOF' > "$PREFIX/bin/stop-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Stop watchdog first so it does not auto-restart killed services
pkill -9 -f "watchdog-server" 2>/dev/null || true
rm -f "$PREFIX/var/run/watchdog-server.pid" 2>/dev/null || true

if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    su -c 'killall -9 tor sshd sshd-session 2>/dev/null || true'
    su -c 'pkill -9 -f watchdog-server 2>/dev/null || true'
fi
killall -9 tor sshd sshd-session 2>/dev/null || true
pkill -9 -x tor 2>/dev/null || true
pkill -9 -x sshd 2>/dev/null || true
pkill -9 sshd-session 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true
echo "[+] Phone server stopped & all active sessions terminated."
EOF

# 6c. status-server (dual-layer detection: root pgrep + local socket probes)
cat << 'EOF' > "$PREFIX/bin/status-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

# Check process IDs
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    SSH_PID=$(su -c "pidof sshd" 2>/dev/null | awk '{print $1}')
    [ -z "$SSH_PID" ] && SSH_PID=$(su -c "pgrep -x sshd" 2>/dev/null | head -n 1)
    TOR_PID=$(su -c "pidof tor" 2>/dev/null | awk '{print $1}')
    [ -z "$TOR_PID" ] && TOR_PID=$(su -c "pgrep -x tor" 2>/dev/null | head -n 1)
    SSHD_PIDS=$(su -c "pgrep sshd-session" 2>/dev/null || true)
    SHELL_COUNT=0
    if [ -n "$SSHD_PIDS" ]; then
        REGEX=$(echo $SSHD_PIDS | tr '\n ' '||' | sed 's/||*$//')
        SHELL_COUNT=$(su -c "ps -eo ppid,tty" 2>/dev/null | grep -c -E "^ *($REGEX) +pts/" || true)
    fi
else
    SSH_PID=$(pidof sshd 2>/dev/null | awk '{print $1}')
    [ -z "$SSH_PID" ] && SSH_PID=$(pgrep -x sshd 2>/dev/null | head -n 1)
    TOR_PID=$(pidof tor 2>/dev/null | awk '{print $1}')
    [ -z "$TOR_PID" ] && TOR_PID=$(pgrep -x tor 2>/dev/null | head -n 1)
    SSHD_PIDS=$(pgrep sshd-session 2>/dev/null || true)
    SHELL_COUNT=0
    if [ -n "$SSHD_PIDS" ]; then
        REGEX=$(echo $SSHD_PIDS | tr '\n ' '||' | sed 's/||*$//')
        SHELL_COUNT=$(ps -eo ppid,tty 2>/dev/null | grep -c -E "^ *($REGEX) +pts/" || true)
    fi
fi
SHELL_COUNT=$(echo "$SHELL_COUNT" | tr -dc '0-9')
SHELL_COUNT="${SHELL_COUNT:-0}"

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
AUTH_CLIENTS=$(find "$PREFIX/var/lib/tor/hidden_ssh/authorized_clients" -name "*.auth" 2>/dev/null | wc -l | tr -dc '0-9')
AUTH_CLIENTS="${AUTH_CLIENTS:-0}"

# Optional battery status
BATTERY=""
if [ -f /sys/class/power_supply/battery/capacity ]; then
    BATTERY=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
fi

echo "=========================================="
echo "        Phone Server Status"
echo "=========================================="
if [ -n "$SSH_PID" ]; then
    if [[ "$SSH_PID" =~ ^[0-9]+$ ]]; then
        echo "  [+] OpenSSH Daemon : RUNNING (PID: $SSH_PID)"
    else
        echo "  [+] OpenSSH Daemon : RUNNING ($SSH_PID)"
    fi
else
    echo "  [-] OpenSSH Daemon : STOPPED"
fi

if [ -n "$TOR_PID" ]; then
    if [[ "$TOR_PID" =~ ^[0-9]+$ ]]; then
        echo "  [+] Tor Daemon     : RUNNING (PID: $TOR_PID)"
    else
        echo "  [+] Tor Daemon     : RUNNING ($TOR_PID)"
    fi
else
    echo "  [-] Tor Daemon     : STOPPED"
fi

if pgrep -f "watchdog-server" >/dev/null 2>&1; then
    WATCHDOG_PID=$(pgrep -f "watchdog-server" | head -n 1)
    echo "  [+] Watchdog       : RUNNING (PID: $WATCHDOG_PID, Auto-heals IP)"
else
    echo "  [-] Watchdog       : STOPPED"
fi

echo "  [*] Active Shells  : $SHELL_COUNT open"
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
# Cycle Tor and SSH daemon cleanly
# When called over an active SSH session, avoid terminating own session before start-server
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ]; then
    pkill -x tor 2>/dev/null || true
    pkill -x sshd 2>/dev/null || true
    sleep 1
    $PREFIX/bin/start-server
else
    $PREFIX/bin/stop-server
    sleep 1
    $PREFIX/bin/start-server
fi
EOF

# 6e. authorize-client (Allows registering additional client devices anytime)
cat << 'EOF' > "$PREFIX/bin/authorize-client"
#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Authorize or Revoke a Client Device (Phone Server)
# ==============================================================================
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME=/data/data/com.termux/files/home
AUTH_DIR="$PREFIX/var/lib/tor/hidden_ssh/authorized_clients"
mkdir -p "$AUTH_DIR" "$HOME/.ssh" 2>/dev/null || true

# Handle Client Revocation
if [ "$1" == "--revoke" ] || [ "$1" == "revoke" ] || [ "$1" == "-r" ]; then
    REVOKE_NAME="$2"
    if [ -z "$REVOKE_NAME" ]; then
        read -p "Enter label of client to revoke: " REVOKE_NAME
    fi
    REVOKE_NAME=$(echo "$REVOKE_NAME" | tr -cd 'a-zA-Z0-9_-')
    if [ -z "$REVOKE_NAME" ]; then
        echo "[!] Error: Invalid client name for revocation."
        exit 1
    fi
    TARGET_AUTH="$AUTH_DIR/${REVOKE_NAME}.auth"
    if [ -f "$TARGET_AUTH" ]; then
        rm -f "$TARGET_AUTH"
        if [ -x "$PREFIX/bin/tor" ] && ! "$PREFIX/bin/tor" --verify-config >/dev/null 2>&1; then
            echo "[!] Warning: tor --verify-config failed after removing authorization file."
        fi
        pkill -HUP -x tor 2>/dev/null || killall -HUP tor 2>/dev/null || true
        echo "[+] Client '$REVOKE_NAME' authorization file removed and Tor reloaded."
    else
        echo "[-] Client authorization '$TARGET_AUTH' not found."
    fi
    exit 0
fi

CLIENT_NAME="$1"
TOR_PUB="$2"
SSH_PUB="$3"

if [ -z "$CLIENT_NAME" ]; then
    read -p "Enter a label for this client device [default: client]: " CLIENT_NAME
    CLIENT_NAME=${CLIENT_NAME:-client}
fi

# Sanitize client name for safe filenames (alphanumeric, underscore, dash only)
CLIENT_NAME=$(echo "$CLIENT_NAME" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_-')
CLIENT_NAME=${CLIENT_NAME:-client}

if [ -z "$TOR_PUB" ]; then
    read -p "Paste Client Tor Public Key (descriptor:x25519:...): " TOR_PUB
fi

if [ -z "$SSH_PUB" ]; then
    read -p "Paste Client SSH Public Key (ssh-ed25519 AAAA...): " SSH_PUB
fi

CLEAN_PUB=$(echo "$TOR_PUB" | sed 's/descriptor:x25519://' | tr -d ' \t\n\r"'"'")
CLEAN_SSH=$(echo "$SSH_PUB" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')

KEYS_ADDED=0

if [ -n "$CLEAN_PUB" ]; then
    # Strict validation: RFC 4648 unpadded Base32 (32-byte key is 52 or 56 chars of A-Z, 2-7)
    if ! echo "$CLEAN_PUB" | grep -E -q '^[a-zA-Z2-7]{52,56}$'; then
        echo "[!] Error: Invalid Tor X25519 public key format. Expected 52-56 Base32 characters [a-z, 2-7]."
        exit 1
    fi
    # Atomic file write via temporary file
    TMP_AUTH="$AUTH_DIR/${CLIENT_NAME}.auth.tmp"
    echo "descriptor:x25519:$CLEAN_PUB" > "$TMP_AUTH"
    chmod 600 "$TMP_AUTH"
    mv -f "$TMP_AUTH" "$AUTH_DIR/${CLIENT_NAME}.auth"
    echo "[+] Tor authorization registered: ${CLIENT_NAME}.auth"
    KEYS_ADDED=1
fi

if [ -n "$CLEAN_SSH" ]; then
    # Strict validation: Ed25519 public key format check
    if ! echo "$CLEAN_SSH" | grep -E -q '^ssh-ed25519 +[A-Za-z0-9+/=]+'; then
        echo "[!] Error: Invalid SSH public key format. Expected 'ssh-ed25519 AAAA...'."
        exit 1
    fi
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
    # Verify Tor configuration before signaling daemon
    if [ -x "$PREFIX/bin/tor" ] && ! "$PREFIX/bin/tor" --verify-config >/dev/null 2>&1; then
        echo "[!] Error: tor --verify-config failed after adding authorization! Reverting..."
        [ -n "$CLEAN_PUB" ] && rm -f "$AUTH_DIR/${CLIENT_NAME}.auth"
        exit 1
    fi
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

# 6e. watchdog-server (Background dynamic IP monitor & auto-healer)
cat << 'EOF' > "$PREFIX/bin/watchdog-server"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

WATCHDOG_PID_FILE="$PREFIX/var/run/watchdog-server.pid"
mkdir -p "$PREFIX/var/run" "$PREFIX/var/lib/tor" 2>/dev/null || true

if [ -f "$WATCHDOG_PID_FILE" ]; then
    OLD_PID=$(cat "$WATCHDOG_PID_FILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$WATCHDOG_PID_FILE"

get_current_ips() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | sort | tr '\n' ' '
    else
        ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | sort | tr '\n' ' '
    fi
}

LAST_IPS=$(get_current_ips)
LAST_SIGHUP=0

while true; do
    sleep 8

    # 1. Process supervision: ensure sshd is listening
    if ! pidof sshd >/dev/null 2>&1 && ! (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1; then
        $PREFIX/bin/sshd >/dev/null 2>&1 || true
    fi

    # 2. Process supervision: ensure tor is running (dual-check: pidof + socket check)
    if ! pidof tor >/dev/null 2>&1 && ! (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1; then
        nohup $PREFIX/bin/tor > "$PREFIX/var/lib/tor/tor.log" 2>&1 &
        LAST_IPS=$(get_current_ips)
        termux-wake-lock 2>/dev/null || true
        continue
    fi

    # 3. Dynamic IP / Network Interface Change Detection (Wi-Fi <-> Cellular / DHCP renew)
    CURRENT_IPS=$(get_current_ips)
    if [ -n "$CURRENT_IPS" ] && [ "$CURRENT_IPS" != "$LAST_IPS" ]; then
        NOW=$(date +%s)
        # Bounded debounce: Do not signal SIGHUP more frequently than once every 20 seconds
        if [ $((NOW - LAST_SIGHUP)) -ge 20 ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network change detected ($LAST_IPS -> $CURRENT_IPS). Signaling Tor SIGHUP..." >> "$PREFIX/var/lib/tor/watchdog.log" 2>&1
            LAST_IPS="$CURRENT_IPS"
            LAST_SIGHUP="$NOW"
            pkill -HUP -x tor 2>/dev/null || killall -HUP tor 2>/dev/null || true
            termux-wake-lock 2>/dev/null || true
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Network shift flapping detected, debouncing SIGHUP ($((NOW - LAST_SIGHUP))s since last reload)..." >> "$PREFIX/var/lib/tor/watchdog.log" 2>&1
            LAST_IPS="$CURRENT_IPS"
        fi
    fi
done
EOF

# 6f. reset-tor-state (Manual diagnostic recovery tool for Tor descriptor upload lockouts)
cat << 'EOF' > "$PREFIX/bin/reset-tor-state"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
echo "[*] Manual Tor State Recovery Tool"
echo "[!] Caution: Resetting Tor state file clears descriptor rate limits but forces Tor to choose fresh Entry Guards."
pkill -x tor 2>/dev/null || true
rm -f "$PREFIX/var/lib/tor/state" "$PREFIX/tmp/state" 2>/dev/null || true
sleep 1
$PREFIX/bin/start-server
echo "[+] Tor state purged and daemon restarted with fresh circuit state."
EOF

chmod 755 "$PREFIX/bin/start-server" "$PREFIX/bin/stop-server" "$PREFIX/bin/status-server" "$PREFIX/bin/restart-server" "$PREFIX/bin/authorize-client" "$PREFIX/bin/watchdog-server" "$PREFIX/bin/reset-tor-state"

# 6f. Install master phone-server CLI tool
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CLI="$SCRIPT_DIR/phone-server"
if [ ! -f "$SOURCE_CLI" ] && [ -f "$HOME/stealth-tor-phone-server/phone-server" ]; then
    SOURCE_CLI="$HOME/stealth-tor-phone-server/phone-server"
elif [ ! -f "$SOURCE_CLI" ] && [ -f "/sdcard/Download/phone-server" ]; then
    SOURCE_CLI="/sdcard/Download/phone-server"
elif [ ! -f "$SOURCE_CLI" ] && [ -f "$HOME/phone-server" ]; then
    SOURCE_CLI="$HOME/phone-server"
fi

if [ -f "$SOURCE_CLI" ]; then
    cp "$SOURCE_CLI" "$PREFIX/bin/phone-server"
    chmod 755 "$PREFIX/bin/phone-server"
    ln -sf "$PREFIX/bin/phone-server" "$PREFIX/bin/stealth-server"
fi

# 6g. Autostart on boot (Termux:Boot support)
mkdir -p "$HOME/.termux/boot"
cat << 'EOF' > "$HOME/.termux/boot/start-phone-server.sh"
#!/data/data/com.termux/files/usr/bin/bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PREFIX
export PATH="$PREFIX/bin:$PATH"
termux-wake-lock 2>/dev/null || true
$PREFIX/bin/start-server
EOF
chmod 755 "$HOME/.termux/boot/start-phone-server.sh"

# Dynamically apply exact SELinux MLS context if on Android root
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    TERMUX_CTX=$(ls -ldZ "$PREFIX/bin/sh" 2>/dev/null | grep -o 'u:object_r:app_data_file:[^ ]*' | head -n 1 || true)
    if [ -n "$TERMUX_CTX" ]; then
        su -c "chcon $TERMUX_CTX $PREFIX/bin/*-server $PREFIX/bin/authorize-client $PREFIX/bin/phone-server 2>/dev/null || true"
    fi
fi

# 7. Interactive Client Authorization Setup
if [ "${NON_INTERACTIVE:-0}" -ne 1 ]; then
    echo ""
    echo -e "${YELLOW}${BOLD}--- CLIENT AUTHORIZATION REGISTRATION ---${NC}"
    echo "To grant your PC or mobile device access to this server, register its generated keys."
    echo "If you haven't generated client keys yet, you can press Enter to skip and run 'authorize-client' later."
    echo ""

    "$PREFIX/bin/authorize-client"
fi

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
echo "  • watchdog-server  : Dynamic IP auto-healer & process supervisor"
echo "  • authorize-client : Register additional client devices anytime"
echo "=================================================================="
