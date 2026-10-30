# 🛡️ Stealth Tor v3 Phone Server

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Android](https://img.shields.io/badge/Platform-Android%20Termux-green.svg)](https://termux.dev)
[![Clients: Linux & Android](https://img.shields.io/badge/Clients-Linux%20%7C%20Android-orange.svg)]()
[![Security: Zero Accounts](https://img.shields.io/badge/Security-Zero%20Accounts%20%7C%20Pure%20Crypto-red.svg)]()
[![Encryption: x25519 + Ed25519](https://img.shields.io/badge/Encryption-x25519%20%2B%20Ed25519-purple.svg)]()

Convert any spare or rooted Android phone into a **headless, 24/7 Linux home server** accessible from anywhere globally with **dual-layer cryptographic authorization**, zero open router ports, zero DNS leaks, and **zero accounts or third-party sign-ups** (No Tailscale, No Cloudflare, No Ngrok).

---

## 📑 Table of Contents

- [Security Architecture & Threat Model](#-security-architecture--threat-model)
  - [Why Not Tailscale, Ngrok, or Cloudflare?](#why-not-tailscale-ngrok-or-cloudflare)
  - [Tor v3 Stealth Mode vs. Public Hidden Services](#tor-v3-stealth-mode-vs-public-hidden-services)
  - [The Two Cryptographic Gates](#the-two-cryptographic-gates)
  - [Isolated Client Routing](#isolated-client-routing)
- [Prerequisites & Requirements Matrix](#-prerequisites--requirements-matrix)
- [Repository Structure](#-repository-structure)
- [Quickstart Guide](#-quickstart-guide)
  - [Phase 1: Setup Client (Linux PC or Secondary Phone)](#phase-1-setup-client-linux-pc-or-secondary-phone)
  - [Phase 2: Setup Server (Android Phone)](#phase-2-setup-server-android-phone)
  - [Phase 3: Connect & Verify](#phase-3-connect--verify)
  - [Phase 4: Adding Multiple Clients (Work Laptop, Second Phone)](#phase-4-adding-multiple-clients)
- [Daily Operations & CLI Tools](#-daily-operations--cli-tools)
- [Deep Dive: Internal Mechanics & Process Architecture](#-deep-dive-internal-mechanics--process-architecture)
  - [OpenSSH 9.8+ Process Splitting (`sshd` vs. `sshd-session`)](#openssh-98-process-splitting-sshd-vs-sshd-session)
  - [Tor Circuit Teardown & Linger (`ShutdownWaitLength 30`)](#tor-circuit-teardown--linger-shutdownwaitlength-30)
  - [Android SELinux Domain Process Isolation](#android-selinux-domain-process-isolation)
  - [Android SELinux MLS Dynamic Contexts](#android-selinux-mls-dynamic-contexts)
  - [Android OS Power Management & Samsung One UI Sleep Suppression](#android-os-power-management--samsung-one-ui-sleep-suppression)
  - [SSH Multiplexing & Connection Warmth](#ssh-multiplexing--connection-warmth)
- [Manual Administration & Diagnostic Cheat Sheet](#-manual-administration--diagnostic-cheat-sheet)
- [Battle-Tested Troubleshooting Guide](#-battle-tested-troubleshooting-guide)
- [Security Best Practices & Revocation](#-security-best-practices--revocation)
- [License](#-license)

---

## 🔒 Security Architecture & Threat Model

### Why Not Tailscale, Ngrok, or Cloudflare?

Most modern remote-access solutions rely on third-party SaaS infrastructure:
* **Tailscale / ZeroTier**: Require logging in with Google, Microsoft, or GitHub SSO. Your device control plane and node metadata reside on corporate servers.
* **Cloudflare Tunnels**: Require a domain name registered with Cloudflare, account credentials, and Cloudflare holds TLS termination keys.
* **Ngrok**: Rate-limited, requires credit card verification or accounts, and proxies all unencrypted payloads through shared servers.

**Stealth Tor v3 Phone Server uses zero accounts, zero registrations, zero proprietary relays, and zero email addresses.** Communication is anchored strictly in mathematics and asymmetric cryptography: **Curve25519 (X25519)** and **Ed25519**.

---

### Tor v3 Stealth Mode vs. Public Hidden Services

Standard Tor onion services publish unencrypted descriptors to Tor Distributed Hash Table (HSDir) directory nodes. Malicious directory authorities and port scanners routinely harvest public onion addresses from the DHT and bombard them with automated exploit scripts.

This project enforces **Tor v3 Client Authorization (Stealth Mode)**:

```
[ Client (Laptop / Second Phone) ]                         [ Android Phone Server (Termux) ]
  • SSH Priv: ~/.ssh/phone_server_ed25519                   • SSH Auth: ~/.ssh/authorized_keys
  • Tor Priv: onion_auth/phone.auth_private                 • Tor Lock: authorized_clients/laptop.auth
        │                                                                │
        └───> [Local Tor Proxy] ──(6-Hop Encrypted Circuit)──> [Tor Hidden Service] ──> [sshd:8022]
              (127.0.0.1:9050)                                 (Descriptor decrypted    (Key auth only,
                                                               with x25519 pubkey)      passwords disabled)
```

1. When the server publishes its hidden service descriptor to the Tor network, the descriptor is **strongly encrypted using the client's X25519 public key**.
2. Any unauthorized crawler, bot, or ISP attempting to query or connect to your `.onion` address receives an instant `Host unreachable` error at the Tor DHT level.
3. **Zero packets ever reach your phone.** Your phone server is completely invisible to anyone without the private authorization key.

---

### The Two Cryptographic Gates

To execute a command or open a shell on your phone server, a packet must clear two independent cryptographic challenges:

| Gate | Protocol | Algorithm | Mechanism |
| :--- | :--- | :--- | :--- |
| **Gate 1** | Tor v3 Onion Protocol | **X25519** (Curve25519 ECDH) | Encrypts Tor descriptor. Prevents discovery, network scanning, and circuit establishment by unauthorized parties. |
| **Gate 2** | OpenSSH | **Ed25519** (Edwards-curve DSA) | Authenticates terminal session. Passwords strictly disabled (`PasswordAuthentication no`). |

---

### Isolated Client Routing

Only packets destined for your phone server (`*.onion`) route through your local Tor SOCKS5 proxy (`127.0.0.1:9050`). All other traffic on your laptop or mobile client (web browsing, streaming, gaming, package updates) continues at native ISP speed through standard network interfaces.

---

## 📦 Prerequisites & Requirements Matrix

The setup scripts feature **self-healing dependency resolution**. When launched, they check for required binaries and automatically install any missing packages using the system's native package manager (`apt`, `dnf`, `pacman`, `zypper`, or Termux `pkg`).

| Device Role | Component | Required Binaries | Package Dependencies | Why It Is Strictly Needed |
| :--- | :--- | :--- | :--- | :--- |
| **Phone Server** (Android) | Headless Server | `sshd`, `tor`, `openssl`, `ssh-keygen`, `base32`, `pgrep`, `killall`, `termux-wake-lock` | `tor openssh openssl-tool coreutils procps psmisc termux-tools` | • `openssl-tool`: Provides the OpenSSL CLI (standard `openssl` in Termux is only headers/libs).<br>• `coreutils`: Provides GNU `base32` (Toybox base32 is incompatible).<br>• `psmisc` & `procps`: Provide `killall` and `pgrep` for process lifecycle management.<br>• `termux-tools`: Provides Android wake lock management. |
| **PC Client** (Linux) | Workstation Client | `tor`, `nc`, `openssl`, `ssh-keygen`, `base32`, `ssh` | `tor netcat-openbsd openssl coreutils openssh-client` | • `tor`: Runs local SOCKS5 proxy (`127.0.0.1:9050`) with `ClientOnionAuthDir`.<br>• `netcat-openbsd` / `nmap-ncat`: Provides `nc -X 5` for SSH SOCKS5 ProxyCommand.<br>• `openssl` & `coreutils`: Generates X25519 client keypairs in RFC 4648 unpadded base32. |
| **Mobile Client** (Android) | Secondary Phone | `tor`, `nc`, `openssl`, `ssh-keygen`, `base32`, `ssh`, `pgrep`, `killall` | `tor openssh netcat-openbsd openssl-tool coreutils procps psmisc` | • Mirrors PC client capabilities directly inside mobile Termux for seamless phone-to-phone management. |

---

## 📁 Repository Structure

```text
stealth-tor-phone-server/
├── phone-server            # Master unified CLI & interactive dropdown menu
├── setup-server-termux.sh  # Automated Server Installer for Android Termux
├── setup-client-linux.sh   # Automated Client Installer for Linux PCs (Debian/Ubuntu/Fedora/Arch)
├── setup-client-termux.sh  # Automated Client Installer for Android Termux Mobile Clients
├── LICENSE                 # MIT Open Source License
├── README.md               # Complete architecture, operations, and troubleshooting manual
└── .gitignore              # Ignores generated keys (*.pem, *.auth, id_*), sockets, logs
```

---

## 🕹️ Master CLI & Interactive Dashboards (`phone-server`)

The project features a unified master CLI tool: **`phone-server`** (with global alias **`stealth-server`**).

Running `phone-server` with no arguments automatically detects your environment and launches the appropriate interactive dashboard:

#### 💻 Client Dashboard (Linux PC or Secondary Phone)
```text
==================================================================
      🛡️  STEALTH TOR v3 PHONE SERVER CLI (v1.2.0)            
==================================================================
Active Dashboard: [CLIENT MODE]
Target Server   : <your-56-char-onion-address>.onion (via 127.0.0.1:9050)
------------------------------------------------------------------
CLIENT OPERATIONS:
  1) ⚡ Connect / Open Shell          (phone-ssh)
  2) 📊 Query Server Status           (Check PIDs, clients, battery)
  3) 🔄 Restart Server Remotely       (Clean cycle over Tor)
  4) 🛑 Stop Server Remotely          (Shutdown server over Tor)

CLIENT CONFIGURATION:
  5) 💻 Configure Linux PC Client     (setup-client-linux)
  6) 📲 Configure Mobile Phone Client (setup-client-termux)

SWITCH & ADVANCED:
  s) 📱 Switch to Server Management Menu
  i) ⚙️  Install 'phone-server' to PATH
  h) ❓ Show Help & CLI Syntax
  0) 🚪 Exit
------------------------------------------------------------------
Select an option [1-6, s, i, h, 0]: 
```

#### 📱 Server Dashboard (Termux Server Phone)
```text
==================================================================
      🛡️  STEALTH TOR v3 PHONE SERVER CLI (v1.2.0)            
==================================================================
Active Dashboard: [SERVER MODE]
Server Onion    : <your-56-char-onion-address>.onion
Server User     : u0_a300
------------------------------------------------------------------
SERVER OPERATIONS:
  1) 📊 Check Local Server Status     (PIDs, sockets, clients, battery)
  2) ▶️  Start Server Daemons          (Launch OpenSSH & Tor quietly)
  3) 🔄 Restart Server Daemons        (Clean cycle)
  4) 🛑 Stop Server Daemons           (Kill all listeners & sessions)
  5) 🔑 Authorize a New Client Device (Register laptop or mobile keys)

SERVER CONFIGURATION:
  6) 📱 Run Server Setup / Reinstall  (setup-server-termux)

SWITCH & ADVANCED:
  c) 💻 Switch to Client Mode Menu
  i) ⚙️  Install 'phone-server' to PATH
  h) ❓ Show Help & CLI Syntax
  0) 🚪 Exit
------------------------------------------------------------------
Select an option [1-6, c, i, h, 0]: 
```

### CLI Command-Line Syntax & Subcommands

For terminal automation, cron jobs, and quick one-liners, `phone-server` provides complete subcommands:

```bash
phone-server --help
```

| Scope | Command | Description |
| :--- | :--- | :--- |
| **Global** | `phone-server` | Launches contextual interactive dashboard (Client or Server). |
| **Global** | `phone-server client` | Opens Client Dashboard explicitly. |
| **Global** | `phone-server server` | Opens Server Dashboard explicitly. |
| **Global** | `phone-server install` | Installs `phone-server` and `stealth-server` globally into PATH. |
| **Global** | `phone-server -h` / `--help` | Displays command syntax, examples, and flags. |
| **Global** | `phone-server -v` / `--version` | Displays CLI version (`v1.2.0`). |
| **Client** | `phone-server connect [ssh-args]` | Opens SSH shell into phone server (alias: `phone-server ssh`). |
| **Client** | `phone-server status [--adb]` | Queries remote phone server health over Tor (or via USB ADB). |
| **Client** | `phone-server stop [--adb]` | Sends remote stop signal to terminate daemons over Tor. |
| **Client** | `phone-server restart [--adb]` | Sends remote restart signal to cycle daemons over Tor. |
| **Client** | `phone-server setup client-linux` | Installs Linux client dependencies & generates keys. |
| **Client** | `phone-server setup client-termux` | Installs mobile Termux client dependencies & generates keys. |
| **Server** | `phone-server start` | Launches OpenSSH and Tor daemons locally on phone. |
| **Server** | `phone-server stop` | Terminates listeners and active worker sessions on phone. |
| **Server** | `phone-server restart` | Cleanly terminates and relaunches daemons on phone. |
| **Server** | `phone-server status` | Queries local PIDs, sockets, active shells, and battery. |
| **Server** | `phone-server authorize [name]` | Registers a new client device on server. |
| **Server** | `phone-server setup server` | Runs full server installer on Android Termux. |

---

## 🚀 Quickstart Guide

### Phase 1: Setup Client (Linux PC or Secondary Phone)

#### Option A: Linux PC Client
On your Linux machine (Ubuntu, Debian, Fedora, Arch, etc.):

```bash
git clone https://github.com/your-username/stealth-tor-phone-server.git
cd stealth-tor-phone-server
chmod +x setup-client-linux.sh
./setup-client-linux.sh
```

#### Option B: Secondary Mobile Phone Client (Android Termux)
Inside Termux on your secondary client phone:

```bash
pkg update && pkg install -y git
git clone https://github.com/your-username/stealth-tor-phone-server.git
cd stealth-tor-phone-server
chmod +x setup-client-termux.sh
./setup-client-termux.sh
```

**What the client script does:**
1. Installs all missing dependencies (`tor`, `netcat`, `openssl`, `coreutils`).
2. Generates an **Ed25519 SSH keypair** (`~/.ssh/phone_server_ed25519`).
3. Generates an **X25519 Tor Client Authorization keypair** (`~/.tor_keys/x25519_priv.pem`).
4. Prints your **Public Keys** in a formatted block on your screen:
   ```text
   ==================================================================
             COPY THESE KEYS TO YOUR PHONE (SERVER SETUP)
   ==================================================================
   1. CLIENT TOR PUBLIC KEY:
   descriptor:x25519:<CLIENT_TOR_X25519_PUBLIC_KEY>

   2. CLIENT SSH PUBLIC KEY:
   ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... client-to-phone-server
   ==================================================================
   ```
5. Leaves the prompt open waiting for your phone server's `.onion` address and username.

---

### Phase 2: Setup Server (Android Phone)

Open **Termux** on the phone intended to be your 24/7 server.

> [!IMPORTANT]
> Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/) or [GitHub Releases](https://github.com/termux/termux-app/releases). **Do NOT use the Google Play Store version**, which has been permanently deprecated since 2020.

Clone and run the server installer:

```bash
pkg update && pkg install -y git
git clone https://github.com/your-username/stealth-tor-phone-server.git
cd stealth-tor-phone-server
chmod +x setup-server-termux.sh
./setup-server-termux.sh
```

**What the server script does:**
1. Automatically installs `tor`, `openssh`, `openssl-tool`, `coreutils`, `procps`, `psmisc`, and `termux-tools`.
2. Applies **Android OS Doze and Samsung Device Care immunity** (if rooted via Magisk/KernelSU) and acquires user-space wake locks.
3. Hardens OpenSSH to port `8022` and strictly disables password authentication.
4. Configures a Tor hidden service directory at `$PREFIX/var/lib/tor/hidden_ssh/`.
5. Prompts you to paste the **Client Tor Public Key** and **Client SSH Public Key** displayed by your client script.
6. Installs native CLI management tools (`start-server`, `stop-server`, `status-server`, `restart-server`, `authorize-client`).
7. Starts the services, waits for Tor circuit generation, and displays your server credentials:
   ```text
   ==================================================================
                      SETUP COMPLETE & SERVER ACTIVE!
   ==================================================================
   YOUR ONION ADDRESS:
     <your-56-character-onion-address>.onion

   SERVER TERMUX USERNAME:
     u0_a300
   ==================================================================
   ```

---

### Phase 3: Connect & Verify

1. Return to your client terminal (Linux PC or second phone).
2. Enter the **56-character `.onion` address** and **Server Username** (`u0_a300`) into the waiting prompt.
3. The script configures `/var/lib/tor/onion_auth/phone.auth_private`, restarts the local Tor proxy, and configures `~/.ssh/config`.
4. Connect to your phone server from anywhere:
   ```bash
   phone-ssh
   ```
   *(Or natively: `ssh phone-server`)*

---

### Phase 4: Adding Multiple Clients

To authorize an additional client (e.g., your laptop and your mobile phone simultaneously) without restarting existing sessions:

1. Run the client installer on the new device (`setup-client-linux.sh` or `setup-client-termux.sh`) to obtain its public keys.
2. On your phone server, run the built-in authorization command:
   ```bash
   authorize-client
   ```
3. Enter a label for the device (e.g. `work-laptop` or `mobile-client`), paste its **Tor Public Key**, and paste its **SSH Public Key**.
4. The server automatically writes `authorized_clients/<name>.auth`, appends to `~/.ssh/authorized_keys`, and reloads Tor (`killall -HUP tor`) without dropping active connections.

---

## 💻 Daily Operations & CLI Tools

### Client Companion Commands (Linux PC & Mobile Client)

Both Linux PC and mobile Termux clients share an identical, standardized toolset:

| Command | Usage | Description |
| :--- | :--- | :--- |
| **`phone-ssh [args]`** | `phone-ssh` | One-word shortcut to log into your phone server. Automatically verifies that the local Tor proxy is running before connecting. |
| **`status-server`** | `status-server` | Queries your phone server over Tor and prints live daemon status, active sessions, registered clients, and battery percentage. *(On Linux, pass `--adb` for USB query)*. |
| **`stop-server`** | `stop-server` | Sends a remote shutdown command over Tor to terminate all listeners and active sessions. |
| **`restart-server`** | `restart-server` | Cleanly cycles the server daemons remotely over Tor. |
| **`ssh phone-server`** | `ssh phone-server` | Standard OpenSSH command supported anywhere on your system via `~/.ssh/config`. |

#### Example Status Output:
```text
$ status-server
[*] Connecting to Phone Server over Tor...
==========================================
        Phone Server Status
==========================================
  [+] OpenSSH Daemon : RUNNING (PID: 4291)
  [+] Tor Daemon     : RUNNING (PID: 4292)
  [*] Active Shells  : 1 open
  [*] Auth Clients   : 2 registered
  [*] Battery Level  : 84%
  [*] Onion Address  : <your-56-char-onion-address>.onion
==========================================
```

### Server Management Commands (Inside Phone Termux)

The server script installs native executables directly into `$PREFIX/bin`:

| Command | Description |
| :--- | :--- |
| **`start-server`** | Checks if ports `8022` and `9050` are already listening, starts `sshd` and `tor` quietly in the background, and acquires Android wakelock. |
| **`stop-server`** | Executes an immediate, force-kill teardown (`killall -9 tor sshd sshd-session`), terminating all listening daemons and active remote shells. |
| **`status-server`** | Uses dual-layer detection (root process query + TCP socket verification) to accurately report service health even under Android SELinux isolation. |
| **`restart-server`** | Cleanly terminates and relaunches both daemons. |
| **`authorize-client`** | Registers a new client device interactively or via arguments (`authorize-client <label> <tor_pub> <ssh_pub>`). |

---

## 🔬 Deep Dive: Internal Mechanics & Process Architecture

### OpenSSH 9.8+ Process Splitting (`sshd` vs. `sshd-session`)

In OpenSSH 9.8 and newer, OpenSSH split its process architecture to mitigate race conditions and security vulnerabilities:
1. **Master Listener (`sshd`)**: Binds to port `8022` and listens for incoming connections.
2. **Worker Session (`sshd-session`)**: Spawned whenever a client logs in. Each authenticated client terminal runs inside its own isolated `sshd-session` child process.

> [!WARNING]
> Running `pkill sshd` or `kill $(pgrep sshd)` on Linux only kills the master listener. It leaves all `sshd-session` worker processes completely untouched! Active client shells remain connected.
> 
> Our `stop-server` implementation guarantees a complete teardown by terminating both listeners and sessions:
> ```bash
> killall -9 tor sshd sshd-session 2>/dev/null
> ```

---

### Tor Circuit Teardown & Linger (`ShutdownWaitLength 30`)

By default, the Tor daemon enforces a 30-second graceful socket draining period (`ShutdownWaitLength 30`) when receiving a `SIGTERM` or `SIGINT` signal. During this interval, Tor stops accepting new circuits but remains resident in memory while sockets drain.

Attempting to restart Tor during this 30-second window causes port-binding collisions on `127.0.0.1:9050` and lock-file contention in `$PREFIX/var/lib/tor/lock`. Our `stop-server` script sends `SIGKILL` (`killall -9 tor`) to immediately release socket bindings and file locks.

---

### Android SELinux Domain Process Isolation

On rooted Android devices (Magisk / KernelSU), processes launched via root `su` run in the privileged SELinux domain:
* Root Context: `u:r:magisk:s0`
* Termux Unprivileged App Context: `u:r:untrusted_app:s0` (or `u:r:untrusted_app_30:s0`)

By design, Android SELinux domain isolation prevents an `untrusted_app` from inspecting the `/proc/<pid>` directories of processes residing in the `magisk` domain. If `sshd` or `tor` was started with elevated permissions, running standard `pgrep sshd` inside the Termux app returns **0 processes found ("STOPPED")**, even though the server is fully running and accepting SSH connections!

#### The Dual-Layer Detection Solution:
`status-server` implements a dual-layer verification strategy:
1. **Layer 1 (Process Query)**: Executes `su -c 'pgrep -x sshd'` if root is available, otherwise unprivileged `pgrep`.
2. **Layer 2 (Socket Probe Fallback)**: If process querying fails or is blocked by SELinux, the script probes loopback TCP sockets directly using native Bash file descriptors:
   ```bash
   if (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1; then
       SSH_PID="ACTIVE (port 8022)"
   fi
   ```
   Socket binding states cannot be hidden by process-table SELinux restrictions, ensuring accurate status reporting under all conditions.

---

### Android SELinux MLS Dynamic Contexts

Android assigns dynamic Multi-Level Security (MLS) category pairs to every installed application (e.g., `u:object_r:app_data_file:s0:c44,c257,c512,c768`). 

If a root script creates executable files inside `$PREFIX/bin` without inheriting the application's unique MLS category pair, the unprivileged Termux user receives `Permission denied` errors when trying to execute them.

Our installer dynamically samples the running environment's exact SELinux context from `$PREFIX/bin/sh` and propagates it to all installed CLI utilities:
```bash
TERMUX_CTX=$(ls -ldZ "$PREFIX/bin/sh" 2>/dev/null | grep -o 'u:object_r:app_data_file:[^ ]*' | head -n 1)
su -c "chcon $TERMUX_CTX $PREFIX/bin/*-server $PREFIX/bin/authorize-client"
```

---

### Android OS Power Management & Samsung One UI Sleep Suppression

Modern Android aggressively suspends background processes when the screen turns off. On Samsung devices running One UI, the proprietary Samsung Device Care service (`com.samsung.android.lool`) contains an aggressive out-of-memory (OOM) killer that evicts long-running daemons regardless of standard Android settings.

`setup-server-termux.sh` applies the following permanent OS-level mitigations:

1. **Suppresses Samsung Device Care**: Disables the background killer package:
   ```bash
   su -c "pm disable-user --user 0 com.samsung.android.lool"
   ```
2. **Linux Kernel Doze Whitelisting**: Grants Termux permanent exemption from Android Doze power budgeting:
   ```bash
   su -c "dumpsys deviceidle whitelist +com.termux"
   ```
3. **AppOps Execution Rights**: Unlocks unrestricted background processing:
   ```bash
   su -c "cmd appops set com.termux RUN_IN_BACKGROUND allow"
   su -c "cmd appops set com.termux RUN_ANY_IN_BACKGROUND allow"
   su -c "cmd appops set com.termux WAKE_LOCK allow"
   ```
4. **Wi-Fi Chip Sleep Immunity**: Forces the Wi-Fi radio to stay awake 24/7 even during deep sleep:
   ```bash
   su -c "settings put global wifi_sleep_policy 2"
   su -c "settings put global wifi_wakeup_enabled 1"
   ```
5. **Continuous AC Power Mode**: Keeps the CPU at baseline frequency while plugged in:
   ```bash
   su -c "settings put global stay_on_while_plugged_in 3"
   ```
6. **Userspace Wakelock**: Automatically engages `termux-wake-lock`.

---

### SSH Multiplexing & Connection Warmth

Negotiating a new 6-hop Tor v3 encrypted circuit from scratch takes between 3 to 8 seconds. To make daily terminal usage feel like a local LAN connection, `setup-client-linux.sh` configures OpenSSH connection multiplexing in `~/.ssh/config`:

```ssh-config
Host phone-server
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 10m
    ServerAliveInterval 15
    ServerAliveCountMax 3
    Compression yes
```

* **`ControlMaster auto` & `ControlPath`**: The first connection establishes the Tor circuit and authenticates. Subsequent terminals, file transfers (`rsync` / `scp`), or `status-server` commands reuse the active master socket.
* **Result**: Subsequent commands execute **instantaneously (< 0.1 seconds)** with zero handshake latency.
* **`ControlPersist 10m`**: Keeps the underlying encrypted socket warm for 10 minutes after you close your last terminal window.

---

## 🛠️ Manual Administration & Diagnostic Cheat Sheet

For power users managing their server manually, here is a quick-reference cheat sheet of essential commands:

### Process Management
```bash
# Check if daemons are running
pgrep -af sshd
pgrep -af tor

# Check full process hierarchy
ps aux | grep -E 'sshd|tor'

# View live worker sessions
pgrep -a sshd-session

# Graceful Tor descriptor reload (re-reads authorized_clients without dropping circuits)
killall -HUP tor

# Hard termination of all server daemons and active shells
killall -9 tor sshd sshd-session
```

### Network & Port Inspection
```bash
# Inspect listening sockets (OpenSSH on 8022, Tor on 9050)
ss -tulpn | grep -E '8022|9050'

# Check active socket using netstat (if installed)
netstat -tuln | grep -E '8022|9050'

# Pure Bash socket probe (works with zero third-party tools installed)
(echo > /dev/tcp/127.0.0.1/8022) && echo "SSH is listening" || echo "SSH is down"
(echo > /dev/tcp/127.0.0.1/9050) && echo "Tor is listening" || echo "Tor is down"
```

### Log File Inspection
```bash
# Server Tor logs (inside phone Termux)
cat $PREFIX/var/lib/tor/tor.log
tail -f $PREFIX/var/lib/tor/tor.log

# Linux Client Tor logs (systemd)
journalctl -u tor -n 50 --no-pager
journalctl -u tor -f

# Mobile Client Tor logs (inside secondary phone Termux)
cat $PREFIX/var/lib/tor/client_tor.log
```

---

## 🩺 Battle-Tested Troubleshooting Guide

### 1. `openssl: command not found` or `base32: command not found` in Termux
* **Cause**: On Termux, the `openssl` package provides only C libraries (`libssl.so`). The CLI binary `openssl` is packaged under `openssl-tool`. Furthermore, Toybox does not supply `base32`.
* **Fix**: Install the missing packages:
  ```bash
  pkg install -y openssl-tool coreutils
  ```

---

### 2. `Connection timed out during banner exchange` / Port 65535 timeout
* **Cause 1 (Cold Start Latency)**: If the server or Tor was started or restarted within the last 30-45 seconds, Tor is still bootstrapping circuits and publishing its encrypted v3 hidden service descriptor to HSDir directory authorities.
* **Fix 1**: Wait 30-45 seconds and retry. Once the descriptor is published, connection is established.
* **Cause 2 (Android Sleep / Doze)**: The server phone has entered deep sleep (Doze mode) or the Wi-Fi chip went into power-saving mode.
* **Fix 2**:
  1. Ensure the phone is connected to a wall charger.
  2. Pull down the Android notification shade, locate the Termux notification, and tap **"Acquire Wakelock"**.
  3. On rooted phones, verify that sleep suppression is active:
     ```bash
     su -c "dumpsys deviceidle whitelist | grep termux"
     ```

---

### 3. `Permission denied` when running scripts on Android
* **Cause**: File created via root `su` lacks Termux user permissions or has an incompatible SELinux MLS category.
* **Fix**: Restore Termux ownership and security contexts:
  ```bash
  chown -R $(whoami):$(whoami) $PREFIX/bin/*-server
  chmod 755 $PREFIX/bin/*-server
  ```

---

### 4. `INJECT_EVENTS` / MIUI & HyperOS Security Exception (Xiaomi/POCO)
* **Cause**: Xiaomi devices running MIUI/HyperOS block automated inputs over ADB unless "USB debugging (Security settings)" is enabled with an active SIM card.
* **Fix**: Run commands directly inside the Termux app on the phone screen instead of pushing them via ADB.

---

### 5. Tor bootstrapping stuck at 5% or 10%
* **Cause**: The local network is blocking Tor directory authorities or system clock skew exceeds 60 seconds.
* **Fix**:
  1. Check device date and time (`date`). Ensure automatic network time synchronization is enabled.
  2. Inspect the log for specific errors:
     ```bash
     cat $PREFIX/var/lib/tor/tor.log
     ```
  3. Cycle the Tor daemon:
     ```bash
     restart-server
     ```

---

### 6. `Permission denied (publickey)` during SSH
* **Cause**: File permissions on `~/.ssh/authorized_keys` or the private key are too permissive, causing OpenSSH to reject them.
* **Fix**:
  * On Phone Server:
    ```bash
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys
    ```
  * On Client:
    ```bash
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/phone_server_ed25519
    ```

---

### 7. Client Tor Authorization Not Working (`Host unreachable`)
* **Cause**: Syntax error in `/var/lib/tor/onion_auth/phone.auth_private` or the auth file on the server.
* **Fix**:
  * **On Client**: The private key auth file must follow this exact format:
    ```text
    <56-char-onion-without-dot-onion>:descriptor:x25519:<32-byte-unpadded-base32-private-key>
    ```
    *Ensure the file ends with a trailing newline and contains no spaces.*
  * **On Server**: The public key auth file at `$PREFIX/var/lib/tor/hidden_ssh/authorized_clients/<client>.auth` must follow this exact format:
    ```text
    descriptor:x25519:<32-byte-unpadded-base32-public-key>
    ```
    *Ensure file permission is `600` and reload Tor (`killall -HUP tor`).*

---

## 🛡️ Security Best Practices & Revocation

### Revoking a Compromised or Lost Client Device

If your laptop or secondary phone is lost or stolen, you can instantly revoke its access without rebuilding the server:

1. Open Termux on your phone server.
2. Remove the client's Tor descriptor lock:
   ```bash
   rm $PREFIX/var/lib/tor/hidden_ssh/authorized_clients/<client_name>.auth
   ```
3. Remove the client's public key from `~/.ssh/authorized_keys`.
4. Reload the Tor daemon:
   ```bash
   killall -HUP tor
   ```
5. Terminate any active sessions:
   ```bash
   stop-server && start-server
   ```
The revoked device will instantly receive `Host unreachable` at the Tor DHT layer and can never connect again.

---

### Backing Up Server Identity Keys

Your phone server's `.onion` address is mathematically derived from its private Ed25519 identity key located at:
`$PREFIX/var/lib/tor/hidden_ssh/hs_ed25519_secret_key`

To backup or migrate your server to another phone without changing your `.onion` address:
```bash
# Backup key to external storage or encrypted USB
cp $PREFIX/var/lib/tor/hidden_ssh/hs_ed25519_secret_key /sdcard/Download/
```

---

## 📜 License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for complete terms and copyright notices.
