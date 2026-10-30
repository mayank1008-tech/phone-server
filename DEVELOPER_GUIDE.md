# 🛠️ Stealth Tor v3 Phone Server — Developer & Architecture Deep Dive

Welcome to the **Stealth Tor v3 Phone Server Developer Guide**. 

This document explains **everything** about how this system works—from high-level, layman-friendly concepts to deep Linux and Android OS internals. Whether you are a curious beginner writing your first bash script or an experienced systems developer, this guide will walk you through the design choices, what happens on each device, the real-world bugs we encountered and defeated, and how to extend this project in the future.

---

## 📑 Table of Contents

1. [The Big Picture (Explain Like I'm 5)](#1-the-big-picture-explain-like-im-5)
   - [What is this project?](#what-is-this-project)
   - [The VIP Vault Analogy](#the-vip-vault-analogy)
2. [Client vs. Server: What Runs Where?](#2-client-vs-server-what-runs-where)
   - [Side-by-Side Architectural Matrix](#side-by-side-architectural-matrix)
   - [What Happens on the Client Device?](#what-happens-on-the-client-device)
   - [What Happens on the Phone Server?](#what-happens-on-the-phone-server)
   - [The End-to-End Handshake Flow](#the-end-to-end-handshake-flow)
3. [Why We Chose This Architecture](#3-why-we-chose-this-architecture)
   - [Why Not Port Forwarding / Dynamic DNS?](#why-not-port-forwarding--dynamic-dns)
   - [Why Not Tailscale, Cloudflare Tunnels, or Ngrok?](#why-not-tailscale-cloudflare-tunnels-or-ngrok)
   - [Why Tor v3 Stealth Mode Instead of Public Onion Services?](#why-tor-v3-stealth-mode-instead-of-public-onion-services)
   - [Why Ed25519 SSH + X25519 Tor Keys?](#why-ed25519-ssh--x25519-tor-keys)
   - [Why 100% Non-Root Android (Standard Termux)?](#why-100-non-root-android-standard-termux)
4. [The Real-World Bugs We Faced & How We Solved Them](#4-the-real-world-bugs-we-faced--how-we-solved-them)
   - [War Story 1: The Dynamic IP / Wi-Fi Roaming Black Hole](#war-story-1-the-dynamic-ip--wi-fi-roaming-black-hole)
   - [War Story 2: The Tor Descriptor Upload Rate-Limit Lockout (`state` file)](#war-story-2-the-tor-descriptor-upload-rate-limit-lockout-state-file)
   - [War Story 3: The Android Toybox `pgrep` Trap](#war-story-3-the-android-toybox-pgrep-trap)
   - [War Story 4: The Remote SSH Session Suicide](#war-story-4-the-remote-ssh-session-suicide)
   - [War Story 5: The 30–45s Global DHT Propagation Delay](#war-story-5-the-3045s-global-dht-propagation-delay)
5. [Future Flexibility & Extensibility](#5-future-flexibility--extensibility)
   - [Adding Multiple Devices Seamlessly](#adding-multiple-devices-seamlessly)
   - [Hosting Any Service (Web Servers, APIs, Databases, Git)](#hosting-any-service-web-servers-apis-databases-git)
   - [Global Network Agnosticism](#global-network-agnosticism)
6. [Codebase Deep Dive: File-by-File Analysis](#6-codebase-deep-dive-file-by-file-analysis)
   - [`phone-server` (Unified CLI & TUI Dashboard)](#phone-server-unified-cli--tui-dashboard)
   - [`setup-server-termux.sh` (Server Engine)](#setup-server-termuxsh-server-engine)
   - [`setup-client-linux.sh` (Linux Client Engine)](#setup-client-linuxsh-linux-client-engine)
   - [`setup-client-termux.sh` (Mobile Client Engine)](#setup-client-termuxsh-mobile-client-engine)
7. [Developer Diagnostics & Troubleshooting Toolkit](#7-developer-diagnostics--troubleshooting-toolkit)

---

## 1. The Big Picture (Explain Like I'm 5)

### What is this project?
Imagine you have an old Android phone lying in a drawer. Normally, if you want to turn a computer into a server that you can control from anywhere, you have to:
- Open ports on your home Wi-Fi router (which is dangerous and exposes you to hackers).
- Buy a public domain name and configure Dynamic DNS (DDNS).
- Or sign up for a cloud service like Tailscale, Cloudflare, or Ngrok that requires creating an account, giving away your email, and trusting a private company with your traffic.

Furthermore, if your phone is on **mobile data (4G/5G)**, your cellular provider blocks all incoming connections from the outside world completely (Carrier-Grade NAT).

**Stealth Tor v3 Phone Server solves all of this without accounts, without router changes, without public IPs, and without root access.** It turns your Android phone into an invisible, 24/7 Linux server that only **you** can see and access from your laptop or another phone, anywhere in the world.

---

### The VIP Vault Analogy

To understand how our two-layer security works, imagine a secret VIP underground vault:

```text
+-------------------------------------------------------------------------------+
|                               THE VIP VAULT ANALOGY                           |
|                                                                               |
|   1. The Invisible Safe (Server):                                             |
|      - Buried underground with NO doors or signs on the street.               |
|      - Only posts an encrypted note in a public locker (Tor DHT) that can     |
|        ONLY be deciphered if you have a special cryptographic lens.           |
|                                                                               |
|   2. The Client (Laptop / Second Phone):                                      |
|      - Gate 1: You use your Lens (X25519 Tor Key) to read the secret note     |
|        and find where the secret tunnel meets (Rendezvous Point).             |
|        * Anyone without this lens cannot even see that the vault exists!      |
|      - Gate 2: Once inside the tunnel, you insert your Physical Keycard       |
|        (Ed25519 SSH Key) to unlock the command terminal.                      |
+-------------------------------------------------------------------------------+
```

If a hacker, botnet, or government agency tries to probe your phone's onion address without your **Gate 1** key, Tor immediately replies `Host unreachable`. Zero network packets ever reach your phone!

---

## 2. Client vs. Server: What Runs Where?

A common question beginners have is: *"Which parts run on my laptop, and which parts run on my phone?"*

Here is the complete breakdown:

### Side-by-Side Architectural Matrix

| Feature / Responsibility | Client Device (Laptop or 2nd Phone) | Server Device (Primary Android Phone) |
| :--- | :--- | :--- |
| **Operating Environment** | Standard Linux (Ubuntu/Fedora/Arch) or Termux | Android Termux (100% root-free user space) |
| **Primary Daemons** | Local Tor SOCKS5 proxy (`127.0.0.1:9050`) | Tor Onion Service daemon + OpenSSH (`sshd:8022`) |
| **Supervisor Daemon** | None needed (on-demand CLI) | `watchdog-server` (monitors IP changes every 8s) |
| **Gate 1 (Tor Stealth Auth)** | Holds **Private Key** (`~/.tor_keys/x25519_priv.pem`) | Holds **Public Lock** (`authorized_clients/*.auth`) |
| **Gate 2 (SSH Terminal Auth)**| Holds **Private SSH Key** (`~/.ssh/phone_server_ed25519`)| Holds **Authorized Public Key** (`~/.ssh/authorized_keys`)|
| **Network Traffic Handling** | SOCKS5 proxy routes ONLY `*.onion` traffic | Accepts incoming 6-hop rendezvous tunnel |
| **Power Management** | OS default | `termux-wake-lock` + Android battery exemption |

---

### What Happens on the Client Device?

Your client device (e.g., your laptop or your secondary phone) is your **control workstation**.

```
[ Laptop / Client Phone ]
  ├── 1. Generates Keys:
  │      - SSH Keypair: ~/.ssh/phone_server_ed25519 (Private) + .pub (Public)
  │      - Tor Keypair: ~/.tor_keys/x25519_priv.pem (Private) + x25519 (Public)
  ├── 2. Runs Local Tor Proxy:
  │      - Listens on 127.0.0.1:9050
  │      - Configured with ClientOnionAuthDir pointing to phone.auth_private
  └── 3. Runs SSH Client:
         - Uses ~/.ssh/config to automatically proxy through 127.0.0.1:9050
         - Keeps persistent connection alive via ControlMaster (<0.1s latency)
```

1. **Local Tor Proxy (`127.0.0.1:9050`)**: You don't route your whole laptop through Tor. Only traffic specifically going to `phone-server` (your `.onion` address) goes through Tor. Your web browsing, Netflix, and gaming remain completely normal at full ISP speed!
2. **Decryption of Server Location**: When you run `ssh phone-server`, your local Tor daemon reads `phone.auth_private`, decrypts the phone server's descriptor from the Tor network, and learns where to meet the phone.
3. **Connection Multiplexing (`ControlMaster`)**: The first SSH connection takes ~3 to 5 seconds to build the encrypted Tor circuit. Once established, SSH keeps a local socket open (`~/.ssh/control-*`). Any new terminal tab or command you run connects in **under 100 milliseconds**!

---

### What Happens on the Phone Server?

Your server device is a dedicated Android phone running Termux.

```
[ Android Phone Server (Termux) ]
  ├── 1. Runs OpenSSH Server (sshd):
  │      - Listens exclusively on local port 8022
  │      - Passwords DISABLED (PasswordAuthentication no)
  │      - Only accepts client Ed25519 keys in ~/.ssh/authorized_keys
  ├── 2. Runs Tor Hidden Service:
  │      - Listens internally on port 9050
  │      - Forwards hidden service port 8022 -> 127.0.0.1:8022
  │      - Publishes ENCRYPTED descriptors using client X25519 public keys
  ├── 3. Runs Watchdog Daemon (watchdog-server):
  │      - Loops in background every 8 seconds
  │      - If Wi-Fi or mobile IP changes -> sends SIGHUP to Tor for instant recovery
  │      - If sshd or tor dies -> auto-restarts them immediately
  └── 4. Prevents Android Sleep:
         - Holds termux-wake-lock so Android does not put the CPU to sleep
```

1. **Zero Open Public Ports**: The phone never listens to the external internet. It makes an **outbound** connection into the Tor network to connect to Introduction Points. This is why it works behind cellular networks and firewalls!
2. **Encrypted Descriptor Publication**: Tor publishes its hidden service descriptor to the Tor Distributed Hash Table (HSDir). But because client authorization is enabled, the descriptor is encrypted with your client's public key. To everyone else on the internet, it looks like random noise.
3. **Dynamic IP Auto-Healing**: When you walk out of your house and your phone switches from Wi-Fi to 4G cellular, the phone's IP address changes. The background `watchdog-server` notices this change in seconds and re-establishes the Tor circuits automatically.

---

### The End-to-End Handshake Flow

Here is what happens when you type `phone-server connect` on your laptop:

```mermaid
sequenceDiagram
    autonumber
    actor User as Developer (Laptop)
    participant SSH as OpenSSH Client
    participant LTor as Client Tor Proxy (127.0.0.1:9050)
    participant DHT as Tor Global DHT (HSDir Nodes)
    participant RP as Tor Rendezvous Point
    participant STor as Phone Tor Daemon
    participant SSHD as Phone OpenSSH (Port 8022)

    User->>SSH: Run "phone-server connect" (or "ssh phone-server")
    SSH->>LTor: ProxyCommand: Route to *.onion via SOCKS5:9050
    LTor->>DHT: Request Hidden Service Descriptor for *.onion
    DHT-->>LTor: Return ENCRYPTED descriptor
    Note over LTor: Decrypts descriptor using client's private X25519 key.<br/>Discovers Introduction Points!
    LTor->>RP: Client builds 3-hop circuit to Rendezvous Point
    LTor->>STor: Send rendezvous request via Introduction Point
    STor->>RP: Phone builds independent 3-hop circuit to Rendezvous Point
    Note over RP: Rendezvous Point connects both circuits together!<br/>A private 6-hop encrypted tunnel is formed.
    SSH->>SSHD: Send OpenSSH Handshake + Ed25519 Signature
    SSHD->>SSHD: Verify signature against ~/.ssh/authorized_keys
    SSHD-->>SSH: Authentication Successful! Spawn bash shell.
    SSH-->>User: Open Interactive Terminal Shell (/dev/pts/*)
```

---

## 3. Why We Chose This Architecture

Every technology in this project was selected after analyzing alternatives, failure modes, and long-term security.

### Why Not Port Forwarding / Dynamic DNS?
- **Carrier-Grade NAT (CGNAT)**: Cellular carriers (and many modern fiber ISPs) put phones behind CGNAT (`100.64.0.0/10`). There is no public IPv4 address assigned to your phone. Inbound port forwarding is physically impossible at the router level.
- **Port Scanners & Attacks**: Opening port 22 on a public IP attracts thousands of automated brute-force attacks from Chinese, Russian, and American botnets every single day.
- **Dynamic DNS Delays**: Dynamic DNS takes 5 to 15 minutes to update DNS caches across the world whenever an IP changes.

### Why Not Tailscale, Cloudflare Tunnels, or Ngrok?
| Consideration | Tailscale / ZeroTier | Cloudflare Tunnels | Ngrok | **Stealth Tor v3 (This Project)** |
| :--- | :--- | :--- | :--- | :--- |
| **Accounts Required?** | Yes (Google/GitHub SSO) | Yes (Cloudflare Account) | Yes (Ngrok Account) | **NONE (100% Math-Based)** |
| **Domain Needed?** | Assigned by SaaS | Must own a domain | Assigned by SaaS | **NONE (Derived from Public Key)**|
| **Control Plane** | Proprietary Company Servers | Proprietary Company Servers| Company Servers | **Decentralized Tor Network** |
| **Metadata Privacy** | Company knows your node IPs | Cloudflare terminates TLS | Company sees all packets | **Zero Knowledge (6-Hop Onion)** |
| **Cost** | Free tier / Paid subscription| Credit card verification | Free tier / Bandwidth limits| **100% Free & Open Source Forever**|

### Why Tor v3 Stealth Mode Instead of Public Onion Services?
In a standard Tor hidden service, the `.onion` address is listed unencrypted in the public Tor directory. Automated scrapers routinely crawl the Tor DHT and port-scan every single discovered `.onion` service.

By turning on **Tor v3 Client Authorization (Stealth Mode)**:
- The descriptor is encrypted using the client's **X25519** public key before it leaves the phone.
- Only clients possessing the corresponding **X25519** private key can decrypt it.
- To port scanners and random crawlers, your server literally does not exist.

### Why Ed25519 SSH + X25519 Tor Keys?
- **Ed25519** offers 128-bit security (comparable to 3072-bit RSA) in a tiny 68-character key. It is immune to cache-timing attacks and side-channel leakage.
- **X25519** is the ECDH (Elliptic-curve Diffie–Hellman) counterpart optimized for ultra-fast, highly secure key exchange.
- Combining both gives you **Two Independent Cryptographic Gates**: Even if an attacker compromised your Tor keys, they would still face an impenetrable Ed25519 SSH wall.

### Why 100% Non-Root Android (Standard Termux)?
Early iterations explored using Magisk root privileges to run `sysctl` commands and bind to low-numbered privileged ports. However:
1. **User Accessibility**: 95%+ of Android users do not root their phones because it trips SafetyNet/Play Integrity and voids warranties.
2. **Portability**: By designing the architecture to run entirely within standard Termux userspace (using port 8022 and standard user permissions), **any user with any Android phone can run this project in 5 minutes**.

---

## 4. The Real-World Bugs We Faced & How We Solved Them

Building a production-ready server on mobile hardware presents unique challenges that do not exist on regular Linux servers. Below are the 5 major real-world engineering bugs we discovered, analyzed, and permanently resolved.

---

### War Story 1: The Dynamic IP / Wi-Fi Roaming Black Hole

#### The Problem:
When you run a server on a laptop or desktop, the IP address rarely changes. But on an Android phone:
- You disconnect from home Wi-Fi and switch to 4G/5G mobile data.
- The phone roams from one cell tower to another.
- The local DHCP lease expires and your home router assigns a new local IP.

When the phone's IP address changes, the remote Tor Introduction Points still expect packets from the old IP. The socket enters a "dead socket" state. Packets sent to the old IP are silently dropped (black-holed). Incoming connection attempts fail with:
```text
nc: connection failed, SOCKSv5 error: Host unreachable
```

#### The Permanent Fix:
We engineered **`watchdog-server`** ([`setup-server-termux.sh`](file:///home/mayank-jain/stealth-tor-phone-server/setup-server-termux.sh#L366-L415)):
1. Every 8 seconds, it samples all active network interfaces:
   ```bash
   get_current_ips() {
       ifconfig 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | sort | tr '\n' ' '
   }
   ```
2. The instant `CURRENT_IPS != LAST_IPS`, it immediately signals Tor:
   ```bash
   pkill -HUP -x tor 2>/dev/null || killall -HUP tor 2>/dev/null || true
   ```
3. `SIGHUP` forces Tor to tear down the dead introduction point circuits and establish fresh ones on the new network interface without terminating active SSH sessions or restarting the process. Recovery takes just 10–15 seconds!

---

### War Story 2: The Tor Descriptor Upload Rate-Limit Lockout (`state` file)

#### The Problem:
During testing, if a user stopped and restarted the server multiple times within a few minutes, Tor's internal rate-limiter kicked in:
```text
[warn] log_cant_upload_desc(): Service [3k75wh...] can't upload its descriptor: 
Upload is rate-limited! (Next upload allowed at 2026-10-30 20:25:00)
```
Tor's hidden service subsystem (`hs_service.c`) implements an exponential backoff penalty to prevent DHT spam. Crucially, **Tor saves this rate-limit timestamp to disk** in its persistent state file (`$PREFIX/var/lib/tor/state`). Even if you killed Tor and restarted it, Tor read the state file, saw the lockout timestamp, and refused to upload the descriptor for up to **90 minutes**!

#### The Permanent Fix:
We added automated state purging into `start-server` and `restart-server`:
```bash
rm -f "$PREFIX/var/lib/tor/state" "$PREFIX/tmp/state" 2>/dev/null || true
```
Clearing the transient state file on server startup resets Tor's upload backoff timer to 0, allowing Tor to immediately publish its hidden service descriptor to all 6 global HSDir nodes without delay.

---

### War Story 3: The Android Toybox `pgrep` Trap

#### The Problem:
On standard GNU Linux, `pgrep -x tor` searches for processes whose executable name matches `tor`. 

However, Android uses **Toybox** instead of standard GNU `procps`. In Android's Toybox:
- Running `pgrep -x tor` often fails and returns exit code 1 because Toybox matches against the full binary path (`/data/data/com.termux/files/usr/bin/tor`) rather than the command name.
- When `watchdog-server` ran `if ! pgrep -x tor; then start tor; fi`, it believed Tor was dead every 8 seconds, spawning dozens of duplicate Tor processes that collided on port 9050:
  ```text
  Could not bind to 127.0.0.1:9050: Address already in use
  ```

#### The Permanent Fix:
We refactored all process detection across [`setup-server-termux.sh`](file:///home/mayank-jain/stealth-tor-phone-server/setup-server-termux.sh#L134-L148) to use **`pidof`** backed by **direct TCP socket probing**:
```bash
# Start Tor if not already listening
if (echo > /dev/tcp/127.0.0.1/9050) >/dev/null 2>&1 || pidof tor >/dev/null 2>&1; then
    echo "[*] Tor daemon is already running (port 9050)."
else
    nohup $PREFIX/bin/tor > "$PREFIX/var/lib/tor/tor.log" 2>&1 &
fi
```
`pidof` works consistently across Toybox and GNU Linux, and testing `/dev/tcp/127.0.0.1/9050` probes the real listener directly, making process detection 100% immune to Toybox quirks.

---

### War Story 4: The Remote SSH Session Suicide

#### The Problem:
When you are connected to the phone server over SSH and you run `restart-server`, the restart script previously executed:
```bash
killall -9 sshd sshd-session 2>/dev/null || true
```
`sshd-session` was the parent process of your remote terminal! The moment the script executed that line, **it instantly killed its own connection before `start-server` could be called**. The server was left in a dead, stopped state, and you had to physically go to the phone to restart it.

#### The Permanent Fix:
We made `restart-server` aware of its execution context:
```bash
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_CLIENT" ]; then
    # Over remote SSH: kill the listener but DO NOT kill active worker sessions
    pkill -x tor 2>/dev/null || true
    pkill -x sshd 2>/dev/null || true
    rm -f "$PREFIX/var/lib/tor/state" "$PREFIX/tmp/state" 2>/dev/null || true
    sleep 1
    $PREFIX/bin/start-server
else
    # Local execution (Termux app): safe to do a full teardown
    $PREFIX/bin/stop-server
    rm -f "$PREFIX/var/lib/tor/state" "$PREFIX/tmp/state" 2>/dev/null || true
    sleep 1
    $PREFIX/bin/start-server
fi
```
If you invoke `restart-server` over SSH, it cleanly cycles the master listener and Tor daemon while keeping your shell session alive until the new daemon is up.

---

### War Story 5: The 30–45s Global DHT Propagation Delay

#### The Problem:
When Tor first starts up or uploads a new descriptor, it has to contact 6 directory authority nodes distributed around the world (Germany, Netherlands, USA, etc.). 

If a user tries to connect within the first 10 seconds of starting the server, the rendezvous circuit fails with:
```text
Connection timed out during banner exchange
```
Beginners often assumed the server was broken and started killing processes, which only restarted the backoff cycle.

#### The Permanent Fix:
1. We documented the **30–45 second propagation window** clearly in all status and connection tools.
2. In `phone-server status` and `phone-server connect`, we added helpful diagnostic messages:
   ```text
   [*] Connecting to Phone Server over Tor...
   [!] If the server was recently restarted, Tor takes ~30-45 seconds
       to publish hidden service descriptors. Please wait a moment and retry.
   ```
3. Added `ServerAliveInterval 15` and `ServerAliveCountMax 3` in SSH configurations to keep the rendezvous tunnel active.

---

## 5. Future Flexibility & Extensibility

This architecture is built for long-term flexibility. Here is how it scales:

### Adding Multiple Devices Seamlessly
You don't need to reconfigure the server when you get a new laptop or want to give access to a trusted collaborator:
1. Run `setup-client-linux.sh` (or `setup-client-termux.sh`) on the new device.
2. It generates a new client keypair and gives you two lines of text:
   - Tor Public Key: `descriptor:x25519:...`
   - SSH Public Key: `ssh-ed25519 AAAA...`
3. On your phone server, run:
   ```bash
   authorize-client "work-laptop" "<TOR_PUB>" "<SSH_PUB>"
   ```
4. Tor reloads its authorization list instantly with `killall -HUP tor`. The new device has immediate access, and existing devices are not interrupted.

### Hosting Any Service (Web Servers, APIs, Databases, Git)
Because you have a full Linux shell inside Termux, your phone server can host almost anything:
- **Git Repositories**: Run a private, self-hosted Git server accessible over Tor (`git clone phone-server:repos/project.git`).
- **REST APIs & Python Scripts**: Run FastAPI, Flask, or Node.js microservices.
- **SQLite / PostgreSQL**: Host lightweight databases for automated workflows.
- **File Synchronization (`rsync` / `sftp`)**: Sync photos and backups securely from anywhere in the world.

To expose a web server or database over Tor, simply add one line to `$PREFIX/etc/tor/torrc`:
```torrc
HiddenServicePort 80 127.0.0.1:8080
```
Tor will automatically route HTTP traffic through the same stealth tunnel!

### Global Network Agnosticism
Because Tor Onion Services rely on outbound rendezvous circuits:
- The server phone can be on a home Wi-Fi network in Tokyo, on a mobile 5G connection in New York, or on an airport Wi-Fi in London.
- The client laptop can be on hotel Wi-Fi or tethered to a cellular hotspot.
- **Both devices will connect seamlessly without any manual reconfiguration.**

---

## 6. Codebase Deep Dive: File-by-File Analysis

### `phone-server` (Unified CLI & TUI Dashboard)
- **Language**: Bash (`#!/bin/bash`).
- **Purpose**: Single binary that provides both an interactive terminal menu and a scriptable CLI.
- **Context Awareness**: Checks whether it is running on the server phone or on a client machine by inspecting `$PREFIX/var/lib/tor/hidden_ssh/hostname`.
- **Auto-Tor Starting**: Checks `/dev/tcp/127.0.0.1/9050` before every operation and starts local Tor automatically if it is inactive.

### `setup-server-termux.sh` (Server Engine)
- **Installs Packages**: `tor`, `openssh`, `openssl-tool`, `coreutils`, `procps`, `psmisc`, `termux-tools`.
- **Generates Daemons**: Installs `start-server`, `stop-server`, `status-server`, `restart-server`, `watchdog-server`, and `authorize-client` into `$PREFIX/bin/`.
- **Hardens SSH**: Modifies `sshd_config` to disable passwords and restrict authentication strictly to Ed25519 keys.
- **Wakelock Integration**: Configures `termux-wake-lock` and optional Android Doze exemptions.

### `setup-client-linux.sh` (Linux Client Engine)
- **Multi-Distro Package Detection**: Automatically detects `apt-get`, `dnf`, `pacman`, `zypper`, or `apk`.
- **Cryptographic Key Generation**: Generates `phone_server_ed25519` (SSH) and uses OpenSSL to generate unpadded Base32 `x25519` keys for Tor client authorization.
- **SSH Configuration**: Appends an isolated, tagged configuration block to `~/.ssh/config` featuring `ControlMaster auto` for sub-second subsequent connections.

### `setup-client-termux.sh` (Mobile Client Engine)
- **Phone-to-Phone Administration**: Enables a secondary Android phone to act as an on-the-go admin workstation.
- **Auto-Exports Keys**: Copies public keys to `/sdcard/Download/client_public_keys.txt` so you can easily share them with the server phone.

---

## 7. Developer Diagnostics & Troubleshooting Toolkit

Use these commands whenever you want to inspect what is happening under the hood:

### 1. Check Live Tor Status & Logs (Server Phone)
```bash
# View last 50 lines of Tor daemon logs
cat $PREFIX/var/lib/tor/tor.log | tail -n 50

# Check if Tor has completed bootstrapping (look for 100%: Done)
grep "Bootstrapped 100%" $PREFIX/var/lib/tor/tor.log

# Check dynamic IP watchdog activity
cat $PREFIX/var/lib/tor/watchdog.log 2>/dev/null || echo "No network shifts yet"
```

### 2. Verify Active Listeners & PIDs (Server Phone)
```bash
# Check if SSH daemon is listening on port 8022
(echo > /dev/tcp/127.0.0.1/8022) && echo "SSHD is LISTENING" || echo "SSHD is DOWN"

# Check if Tor is listening on port 9050
(echo > /dev/tcp/127.0.0.1/9050) && echo "Tor is LISTENING" || echo "Tor is DOWN"

# View running PIDs
pidof sshd tor
```

### 3. Test Local SOCKS5 Proxy (Client Laptop)
```bash
# Verify client Tor proxy is resolving web traffic
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

### 4. Deep SSH Handshake Tracing (Client Laptop)
To see every single byte and packet exchanged during connection:
```bash
ssh -vvv phone-server
```
- **Gate 1 Check**: Look for `ProxyCommand` executing `nc -X 5 -x 127.0.0.1:9050`.
- **Gate 2 Check**: Look for `Offering public key: .../phone_server_ed25519 ED25519` followed by `Server accepts key`.

---

## 📜 Contributing & Code Guidelines

1. **Pure User Space**: Never add hard dependencies on `su` or root. The project must always work on standard, unrooted Android.
2. **Android Toybox Compatibility**: Avoid GNU-specific `pgrep`/`sed` flags that break on Android's Toybox. Always test socket probes with `/dev/tcp/`.
3. **Zero Sensitive Leaks**: Never commit real `.onion` addresses, IP addresses, or private keys to git history.
