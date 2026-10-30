#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
# Stealth Tor v3 Phone Server Setup (Android Termux)
# ==============================================================================
# This script configures a headless, account-free, zero-discovery server on Android
# using Tor v3 Onion Services with Client Authorization (x25519) and OpenSSH (Ed25519).
# ==============================================================================

set -e

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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
export PREFIX=/data/data/com.termux/files/usr
export PATH=$PREFIX/bin:$PATH
cd $HOME

# 2. Package Installation
echo -e "${BLUE}[*] Step 1/5: Updating Termux repositories and installing packages...${NC}"
pkg update -y
pkg install -y tor openssh

# 3. Android & Samsung Sleep Hardening (via Root if available)
echo -e "${BLUE}[*] Step 2/5: Applying Android & Samsung Keep-Alive Hardening...${NC}"
if command -v su >/dev/null 2>&1; then
    echo -e "${GREEN}[+] Root access detected. Applying permanent power-management immunity...${NC}"
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
    echo -e "${YELLOW}[!] Root (su) not found or not granted. Acquiring user-space wakelock...${NC}"
fi

# Acquire Termux wakelock
termux-wake-lock 2>/dev/null || true

# 4. OpenSSH Server Hardening
echo -e "${BLUE}[*] Step 3/5: Hardening OpenSSH Server...${NC}"
mkdir -p $PREFIX/etc/ssh
mkdir -p $HOME/.ssh
chmod 700 $HOME/.ssh
touch $HOME/.ssh/authorized_keys
chmod 600 $HOME/.ssh/authorized_keys

# Enforce no password auth in sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' $PREFIX/etc/ssh/sshd_config 2>/dev/null || echo "PasswordAuthentication no" >> $PREFIX/etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' $PREFIX/etc/ssh/sshd_config 2>/dev/null || echo "PubkeyAuthentication yes" >> $PREFIX/etc/ssh/sshd_config
sed -i 's/^#*Port.*/Port 8022/' $PREFIX/etc/ssh/sshd_config 2>/dev/null || echo "Port 8022" >> $PREFIX/etc/ssh/sshd_config

# 5. Tor Stealth Hidden Service Configuration
echo -e "${BLUE}[*] Step 4/5: Configuring Stealth Tor v3 Hidden Service...${NC}"
mkdir -p $PREFIX/etc/tor
mkdir -p $PREFIX/var/lib/tor/hidden_ssh/authorized_clients
chmod 700 $PREFIX/var/lib/tor/hidden_ssh
chmod 700 $PREFIX/var/lib/tor/hidden_ssh/authorized_clients

# Clean up existing hidden_ssh block if re-running
if [ -f $PREFIX/etc/tor/torrc ]; then
    grep -v "hidden_ssh" $PREFIX/etc/tor/torrc > $PREFIX/etc/tor/torrc.bak || true
    mv $PREFIX/etc/tor/torrc.bak $PREFIX/etc/tor/torrc
fi

cat << 'EOF' >> $PREFIX/etc/tor/torrc
# Stealth Tor v3 Onion Service for SSH
HiddenServiceDir /data/data/com.termux/files/usr/var/lib/tor/hidden_ssh/
HiddenServicePort 8022 127.0.0.1:8022
EOF

# 6. Install Server Control Executables into $PREFIX/bin/
echo -e "${BLUE}[*] Step 5/5: Installing Management CLI Tools (start-server, stop-server, status-server)...${NC}"

cat << 'EOF' > $PREFIX/bin/start-server
#!/data/data/com.termux/files/usr/bin/bash
PREFIX=/data/data/com.termux/files/usr
$PREFIX/bin/sshd
nohup $PREFIX/bin/tor > $PREFIX/var/lib/tor/tor.log 2>&1 &
echo "[+] Phone server services started (OpenSSH & Tor)."
EOF

cat << 'EOF' > $PREFIX/bin/stop-server
#!/data/data/com.termux/files/usr/bin/bash
if command -v su >/dev/null 2>&1; then
    su -c 'killall -9 tor sshd sshd-session 2>/dev/null'
fi
killall -9 tor sshd sshd-session 2>/dev/null
echo "[+] Phone server stopped & all active sessions terminated."
EOF

cat << 'EOF' > $PREFIX/bin/status-server
#!/data/data/com.termux/files/usr/bin/bash
PREFIX=/data/data/com.termux/files/usr

if command -v su >/dev/null 2>&1; then
    SSH_PID=$(su -c 'pgrep -x sshd' 2>/dev/null | head -n 1)
    TOR_PID=$(su -c 'pgrep -x tor' 2>/dev/null | head -n 1)
    SESSIONS=$(su -c 'pgrep sshd-session' 2>/dev/null | wc -l)
else
    SSH_PID=$(pgrep -x sshd 2>/dev/null | head -n 1)
    TOR_PID=$(pgrep -x tor 2>/dev/null | head -n 1)
    SESSIONS=$(pgrep sshd-session 2>/dev/null | wc -l)
fi

# Fallback to direct TCP socket probes
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

ONION=$(cat $PREFIX/var/lib/tor/hidden_ssh/hostname 2>/dev/null)

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

echo "  [*] Active Sessions: $SESSIONS"
if [ -n "$ONION" ]; then
    echo "  [*] Onion Address  : $ONION"
fi
echo "=========================================="
EOF

cat << 'EOF' > $PREFIX/bin/restart-server
#!/data/data/com.termux/files/usr/bin/bash
$PREFIX/bin/stop-server
sleep 1
$PREFIX/bin/start-server
EOF

chmod 755 $PREFIX/bin/start-server
chmod 755 $PREFIX/bin/stop-server
chmod 755 $PREFIX/bin/status-server
chmod 755 $PREFIX/bin/restart-server

# Set proper SELinux MLS context if on Android root
if command -v su >/dev/null 2>&1; then
    su -c 'chcon u:object_r:app_data_file:s0:c44,c257,c512,c768 /data/data/com.termux/files/usr/bin/*-server 2>/dev/null || true'
fi

# 7. Interactive Client Authorization Setup
echo ""
echo -e "${YELLOW}${BOLD}--- CLIENT AUTHORIZATION REGISTRATION ---${NC}"
echo "To grant your PC or mobile device access to this server, paste its generated keys."
echo ""

read -p "Enter a label for this client device [default: laptop]: " CLIENT_NAME
CLIENT_NAME=${CLIENT_NAME:-laptop}

read -p "Paste Client Tor Public Key (52 chars base32 or descriptor:x25519:...): " TOR_PUB
if [ -n "$TOR_PUB" ]; then
    # Strip descriptor:x25519: prefix if user pasted it
    CLEAN_PUB=$(echo "$TOR_PUB" | sed 's/descriptor:x25519://')
    echo "descriptor:x25519:$CLEAN_PUB" > $PREFIX/var/lib/tor/hidden_ssh/authorized_clients/${CLIENT_NAME}.auth
    chmod 600 $PREFIX/var/lib/tor/hidden_ssh/authorized_clients/${CLIENT_NAME}.auth
    echo -e "${GREEN}[+] Tor authorization key saved for client: ${CLIENT_NAME}${NC}"
fi

read -p "Paste Client SSH Public Key (ssh-ed25519 AAAA...): " SSH_PUB
if [ -n "$SSH_PUB" ]; then
    echo "$SSH_PUB" >> $HOME/.ssh/authorized_keys
    chmod 600 $HOME/.ssh/authorized_keys
    echo -e "${GREEN}[+] SSH Public Key authorized.${NC}"
fi

# 8. Start Services and Obtain Onion Hostname
echo ""
echo -e "${BLUE}[*] Starting services and establishing Tor circuits...${NC}"
stop-server >/dev/null 2>&1 || true
sleep 1
start-server >/dev/null

echo -e "${YELLOW}[*] Waiting for Tor to publish service descriptor and generate .onion address...${NC}"
ONION_ADDR=""
for i in $(seq 1 40); do
    if [ -f $PREFIX/var/lib/tor/hidden_ssh/hostname ]; then
        ONION_ADDR=$(cat $PREFIX/var/lib/tor/hidden_ssh/hostname)
        break
    fi
    sleep 1
done

echo ""
echo -e "${GREEN}${BOLD}=================================================================="
echo "                   SETUP COMPLETE & SERVER ACTIVE!                "
echo "==================================================================${NC}"
if [ -n "$ONION_ADDR" ]; then
    echo -e "${CYAN}${BOLD}YOUR ONION ADDRESS:${NC}"
    echo -e "${YELLOW}${BOLD}  $ONION_ADDR${NC}"
    echo ""
    echo "Copy this onion address into your client setup script."
else
    echo -e "${RED}[!] Tor is still bootstrapping. Check 'cat $PREFIX/var/lib/tor/tor.log' in a moment.${NC}"
fi
echo ""
echo -e "${BOLD}Management commands installed:${NC}"
echo "  • start-server   : Start background services"
echo "  • stop-server    : Terminate all listeners and active sessions"
echo "  • status-server  : Display active PIDs and onion domain"
echo "  • restart-server : Cleanly cycle the server"
echo "=================================================================="
