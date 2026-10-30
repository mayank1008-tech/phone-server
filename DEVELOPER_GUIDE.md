# 🛠️ Stealth Tor v3 Phone Server — Developer & Architecture Deep Dive

Welcome to the **Stealth Tor v3 Phone Server Developer Guide**. This document is designed for developers, systems engineers, and security researchers—from curious newcomers to seasoned Linux hackers—who want to understand every layer of this system in exhaustive technical depth.

Whether you want to contribute, fork, audit the security architecture, or simply learn how advanced Linux networking, asymmetric cryptography, and Android OS internals fit together, this guide walks you through every concept from first principles.

---

## 📑 Table of Contents

1. [High-Level Philosophy & The Threat Model](#1-high-level-philosophy--the-threat-model)
2. [Networking Foundations: Conquering Carrier-Grade NAT](#2-networking-foundations-conquering-carrier-grade-nat)
   - [How Tor Bypasses CGNAT](#how-tor-bypasses-cgnat)
   - [Dynamic IP Churn & Self-Healing Watchdog](#dynamic-ip-churn--self-healing-watchdog)
3. [The Tor v3 Onion Protocol & Client Authorization](#3-the-tor-v3-onion-protocol--client-authorization)
   - [Onion Routing & 6-Hop Encrypted Circuits](#onion-routing--6-hop-encrypted-circuits)
   - [Mathematical Derivation of `.onion` Addresses](#mathematical-derivation-of-onion-addresses)
   - [Standard Hidden Services vs. Stealth Client Authorization (x25519)](#standard-hidden-services-vs-stealth-client-authorization-x25519)
   - [Cryptographic Encodings: RFC 4648 Unpadded Base32](#cryptographic-encodings-rfc-4648-unpadded-base32)
4. [Secure Shell (OpenSSH) Architecture](#4-secure-shell-openssh-architecture)
   - [Why Ed25519?](#why-ed25519)
   - [OpenSSH 9.8+ Process Architecture (`sshd` vs. `sshd-session`)](#openssh-98-process-architecture-sshd-vs-sshd-session)
   - [Pseudo-Terminal (PTY) Allocation & Real Session Counting](#pseudo-terminal-pty-allocation--real-session-counting)
   - [SSH Connection Multiplexing (`ControlMaster`)](#ssh-connection-multiplexing-controlmaster)
5. [Android OS Internals & Termux Subsystem](#5-android-os-internals--termux-subsystem)
   - [The Termux Filesystem & Environment Variables (`$PREFIX`)](#the-termux-filesystem--environment-variables-prefix)
   - [SELinux Process Domain Isolation (`magisk` vs. `untrusted_app`)](#selinux-process-domain-isolation-magisk-vs-untrusted_app)
   - [SELinux Multi-Level Security (MLS) Dynamic Categories](#selinux-multi-level-security-mls-dynamic-categories)
   - [Android OS Doze Mode & Samsung One UI Battery Suppression](#android-os-doze-mode--samsung-one-ui-battery-suppression)
6. [End-to-End Cryptographic Sequence Flow](#6-end-to-end-cryptographic-sequence-flow)
7. [Codebase Architecture & File-by-File Analysis](#7-codebase-architecture--file-by-file-analysis)
   - [`phone-server` (Master CLI & State Machine)](#phone-server-master-cli--state-machine)
   - [`setup-server-termux.sh` (Server Engine)](#setup-server-termuxsh-server-engine)
   - [`setup-client-linux.sh` (Linux Client Engine)](#setup-client-linuxsh-linux-client-engine)
   - [`setup-client-termux.sh` (Mobile Client Engine)](#setup-client-termuxsh-mobile-client-engine)
8. [Debugging & Developer Diagnostics](#8-debugging--developer-diagnostics)

---

## 1. High-Level Philosophy & The Threat Model

Most modern solutions for reaching home devices across the internet (such as Tailscale, ZeroTier, Cloudflare Tunnels, or Ngrok) suffer from three fatal design compromises:

1. **Identity & Centralization**: They require authenticating with a central corporate identity provider (Google, GitHub, Microsoft, or SaaS email logins).
2. **Control-Plane Vulnerability**: Even when data payloads are encrypted end-to-end (like WireGuard in Tailscale), the *control plane* (device discovery, IP allocation, public key distribution) resides on corporate infrastructure subject to subpoenas, telemetry tracking, outages, or sudden policy changes.
3. **Metadata Leakage**: Routing through proprietary relays exposes your device's connection frequency, timestamp patterns, IP addresses, and physical locations.

### The Pure Cryptographic Philosophy
**Stealth Tor v3 Phone Server** operates on a zero-trust, account-free model:
- **Zero Accounts**: No sign-ups, no API tokens, no email addresses, and no domain registrations.
- **Zero Open Router Ports**: Works entirely behind Carrier-Grade NAT (CGNAT), cellular firewalls, airport Wi-Fi, and corporate proxies without Universal Plug and Play (UPnP) or router port forwarding.
- **Asymmetric Cryptographic Authority**: Access is granted purely by possessing mathematical private keys: **Curve25519 (X25519)** for network discovery and **Ed25519** for terminal authentication.

---

## 2. Networking Foundations: Conquering Carrier-Grade NAT

When you plug a computer into a home fiber connection, your home router is often assigned a publicly routable IPv4 address. You could theoretically forward port `22` to your server.

However, **mobile devices on 4G/5G cellular networks are placed behind Carrier-Grade NAT (CGNAT, RFC 6598 - `100.64.0.0/10`)**:

```
[ Phone Server ] (IP: 100.72.14.89 - CGNAT Private)
       │
       ▼
[ Cellular Tower / ISP NAT Gateway ] (Shared Public IP: 203.0.113.5)
       │
       ▼
  [ Internet ] ◄──❌ [ Inbound Packets Blocked by Carrier Firewall ]
```

- In CGNAT, thousands of mobile devices share a single public IPv4 address.
- The carrier firewall **drops all incoming connection attempts**. It only allows outbound connections initiated by the phone.
- Furthermore, cellular IP addresses change frequently as the phone switches cell towers or toggles airplane mode.

### How Tor Bypasses CGNAT
Tor Onion Services completely eliminate the concept of inbound listening ports:
1. The phone server **initiates an outbound connection** to long-lived Tor relays called **Introduction Points**.
2. Because the connection is outbound from the phone to the Tor network, the carrier NAT gateway happily allows the TCP connection and keeps the NAT table state alive.
3. When a client wants to connect, it meets the phone at a third-party relay called a **Rendezvous Point**.
4. Both devices connect **outward** to the rendezvous point. No inbound ports are ever opened on either device!

### Dynamic IP Churn & Self-Healing Watchdog

Mobile phones frequently change IP addresses as they roam between Wi-Fi and 4G/5G, switch cell towers, or renew DHCP leases.

#### The Mobile Dead-Socket Problem
1. When the phone server's IP address changes, the remote Introduction Points have no immediate way of knowing the phone has moved. They continue sending traffic to the old IP, where packets are silently dropped (black-holed).
2. Because the server does not receive an active TCP `RST`, Tor's established TLS circuits to Introduction Points remain stalled in a dead socket state.
3. Left unmanaged, Tor can take several minutes to time out dead circuits (`connection_failed=89`), causing incoming clients to receive `Host unreachable`.

#### The 100% Non-Root Solution: Watchdog & SIGHUP
To solve this permanently without requiring root privileges:
1. **The Watchdog Daemon (`watchdog-server`)**: A lightweight background supervisor runs inside Termux, sampling active network interfaces (`ifconfig`) every 8 seconds.
2. **Instant `SIGHUP` Signal**: The moment `CURRENT_IPS != LAST_IPS`, the watchdog issues a `killall -HUP tor` signal.
3. **Descriptor Invalidation**: `SIGHUP` forces Tor's user-space event loop to immediately close stale socket file descriptors, construct new 3-hop circuits over the active interface, select fresh Introduction Points, and upload an updated descriptor to the HSDir ring within **10 to 15 seconds**.
4. **Process Supervision**: If Android OOM terminates `sshd` or `tor`, the watchdog automatically revives them and re-acquires the Termux wakelock.

---

## 3. The Tor v3 Onion Protocol & Client Authorization

### Onion Routing & 6-Hop Encrypted Circuits

A standard internet connection routes packets directly from Client IP to Server IP. Every router along the path can see who is talking to whom.

In Tor Onion Services, an end-to-end connection uses a **6-hop circuit**:

```
[ Client ] ──> [Guard Relay] ──> [Middle Relay] ──> [Rendezvous Point]
                                                           ▲
                                                           │ (Encrypted Rendezvous)
                                                           ▼
[ Phone Server ] ──> [Guard Relay] ──> [Middle Relay] ─────┘
```

1. **Client Circuit (3 Hops)**: The client builds an encrypted tunnel through a Guard relay and Middle relay to a mutually chosen Rendezvous Point.
2. **Server Circuit (3 Hops)**: The phone server builds an independent encrypted tunnel through its Guard relay and Middle relay to the same Rendezvous Point.
3. **Zero Knowledge**:
   - The Rendezvous Point only connects two cryptographic streams together. It does not know the IP address of the client, nor does it know the IP address of the server.
   - The Client does not know the phone's IP address.
   - The Phone does not know the client's IP address.
   - Intermediate ISPs only see standard encrypted TLS packets to known Tor relays.

---

### Mathematical Derivation of `.onion` Addresses

A Tor v3 onion address (e.g. `examp1e0ni0naddre55v3pubkeyhere777777777777777777777777.onion`) is **not a DNS domain**. It is a cryptographic public key!

The 56-character string is derived mathematically as follows:

$$\text{Address} = \text{Base32}\Big(\text{Public Key (32 bytes)} \,\|\, \text{Checksum (2 bytes)} \,\|\, \text{Version Byte (1 byte: \texttt{0x03})}\Big)$$

1. **Identity Key**: When Tor starts up a hidden service, it generates an **Ed25519 keypair** (`hs_ed25519_secret_key` and `hs_ed25519_public_key`).
2. **Checksum**: A 2-byte SHA3-256 hash of the string `".onion checksum"` concatenated with the 32-byte public key and the version byte `0x03`.
3. **Base32 Encoding**: The resulting 35 bytes (32 + 2 + 1) are encoded using RFC 4648 Base32:
   $$\frac{35 \text{ bytes} \times 8 \text{ bits}}{5 \text{ bits/char}} = 56 \text{ characters}$$
4. Appending `.onion` yields the final address.

Because the address *is* the public key, **DNS spoofing and Man-in-the-Middle (MITM) attacks are mathematically impossible**. If an attacker attempts to impersonate the onion service, their cryptographic proof of identity will fail against the public key embedded in the address.

---

### Standard Hidden Services vs. Stealth Client Authorization (x25519)

#### The Problem with Standard Hidden Services
In a standard Tor hidden service, the server publishes a signed **Hidden Service Descriptor** to Distributed Hash Table (HSDir) directory authorities.
- The descriptor contains the list of Introduction Points and the server's public key.
- **Vulnerability**: Rogue HSDir nodes and botnets actively harvest newly published `.onion` addresses from the distributed directory. Automated crawlers scan these addresses 24/7 for exposed web panels, default SSH logins, and unpatched CVEs.

#### The Stealth Solution: Tor v3 Client Authorization
Tor v3 Client Authorization enforces **Layer 1 stealth encryption**:

```
[ Server Phone ]
  1. Reads client public key: descriptor:x25519:<Client_Pubkey_Base32>
  2. Encrypts the hidden service descriptor using Curve25519 (X25519 ECDH)
  3. Publishes ENCRYPTED descriptor to the Tor HSDir network.
```

When an unauthorized client (a crawler, bot, or malicious ISP) queries the Tor network for your `.onion` address:
1. The HSDir node delivers an encrypted blob that can only be decrypted with the matching private key.
2. Without the client private key, the unauthorized client cannot decrypt the list of Introduction Points.
3. The Tor daemon immediately aborts with:
   ```text
   Connection to UNKNOWN port 65535 timed out
   Host unreachable
   ```
4. **Zero network packets ever reach your phone server.** The phone's radio stays completely idle, saving battery and ensuring absolute cloaking.

---

### Cryptographic Encodings: RFC 4648 Unpadded Base32

Tor v3 Client Authorization keys require a very specific encoding:
- **Algorithm**: Curve25519 Diffie-Hellman (`X25519`).
- **Raw Length**: Exactly 32 bytes (256 bits).
- **Encoding**: RFC 4648 Base32 alphabet (`a-z`, `2-7`) with **all trailing padding (`=`) stripped**.

#### How Keys Are Generated in OpenSSL
Our client setup script (`setup-client-linux.sh` / `setup-client-termux.sh`) uses OpenSSL 3.x/1.1.x:

```bash
# 1. Generate private key in PKCS#8 PEM format
openssl genpkey -algorithm x25519 -out ~/.tor_keys/x25519_priv.pem

# 2. Extract raw 32-byte private key in DER format, grab last 32 bytes, base32 encode, strip padding
TOR_PRIV_KEY=$(openssl pkey -in ~/.tor_keys/x25519_priv.pem -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')

# 3. Extract raw 32-byte public key in DER format, grab last 32 bytes, base32 encode, strip padding
TOR_PUB_KEY=$(openssl pkey -in ~/.tor_keys/x25519_priv.pem -pubout -outform DER | tail -c 32 | base32 | tr -d '=\n\r ')
```

#### On-Disk File Specifications
1. **Server Lock File** (`$PREFIX/var/lib/tor/hidden_ssh/authorized_clients/<client_name>.auth`):
   ```text
   descriptor:x25519:abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv
   ```
   *Permissions must be `600`.*
2. **Client Key File** (`/var/lib/tor/onion_auth/phone.auth_private`):
   ```text
   <56-char-onion-without-dot-onion>:descriptor:x25519:abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv
   ```
   *Permissions must be `600`, owned by the system Tor user.*

---

## 4. Secure Shell (OpenSSH) Architecture

Once a packet clears **Gate 1 (Tor Client Authorization)**, it arrives at loopback port `127.0.0.1:8022`, where it faces **Gate 2 (OpenSSH Authentication)**.

### Why Ed25519?

We strictly mandate **Ed25519** public keys (`ssh-keygen -t ed25519`):
- **Security**: Based on Twisted Edwards Curve Curve25519, offering ~128 bits of security equivalent to 3072-bit RSA.
- **Constant-Time Execution**: Immune to cache-timing attacks and side-channel leakage.
- **Key Size**: Public keys are only 68 characters (`ssh-ed25519 AAAA...`). They can easily be copied, pasted, and reviewed over chat or mobile screens without truncation errors.
- **No Password Authentication**: Passwords are unconditionally disabled in `sshd_config`:
  ```ssh-config
  PasswordAuthentication no
  PubkeyAuthentication yes
  Port 8022
  ```

---

### OpenSSH 9.8+ Process Architecture (`sshd` vs. `sshd-session`)

In OpenSSH 9.8 (released mid-2024 to remediate CVE-2024-6387 "regreSSHion"), the OpenSSH team decoupled the monolithic daemon architecture:

```
[ sshd (PID 9467, Master Listener) ]  <── Binds to port 8022
       │
       ├── Incoming SSH Handshake
       ▼
[ sshd-session (PID 11040, Privilege Separation Monitor) ]
       │
       ▼
[ sshd-session (PID 11042, Authenticated Session Handler) ]
       │
       ▼
[ bash -l (PID 11520, Allocated on /dev/pts/2) ]
```

#### Why Traditional Process Management Fails
If a developer writes a naive stop script:
```bash
# ❌ INCORRECT: Leaves active sessions alive!
pkill sshd
```
Only the master listener (PID 9467) is terminated. The `sshd-session` worker processes and the user shells continue running indefinitely.

#### The Robust Teardown Implementation
Our `stop-server` script guarantees a complete teardown of both daemons and child sessions:
```bash
killall -9 tor sshd sshd-session 2>/dev/null || true
pkill -9 -x tor 2>/dev/null || true
pkill -9 -x sshd 2>/dev/null || true
pkill -9 sshd-session 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true
```

---

### Pseudo-Terminal (PTY) Allocation & Real Session Counting

A subtle bug in server monitoring scripts is how "active users" or "active sessions" are counted:

1. **Why TCP Socket Counting Fails**:
   If you check established sockets (`ss -tn sport = :8022`), running a remote query like `ssh phone-server status-server` creates a TCP socket to execute the command. The script **counts itself as an active user**, reporting `Active Clients: 1` even when no human is connected!
2. **Why `sshd-session` Counting Fails**:
   OpenSSH spawns two `sshd-session` processes per connection (monitor + worker). Checking `pgrep sshd-session | wc -l` yields 2 sessions for 1 client, or 4 sessions for 2 clients.

#### The PTY Detection Solution
When a user opens an interactive shell (`phone-ssh` or `ssh phone-server`), OpenSSH allocates a **pseudo-terminal (`/dev/pts/*`)**.
When a script runs a remote command (`ssh phone-server status-server`), OpenSSH executes it non-interactively without allocating a TTY (`TTY = ?`).

Our optimized `status-server` script inspects process-table terminal assignments:
```bash
SSHD_PIDS=$(su -c "pgrep sshd-session" 2>/dev/null || true)
SHELL_COUNT=0
if [ -n "$SSHD_PIDS" ]; then
    # Aggregate PIDs into a regex: e.g. "11040|11042"
    REGEX=$(echo $SSHD_PIDS | tr '\n ' '||' | sed 's/||*$//')
    # Count children of sshd-session that have an assigned pts/* terminal
    SHELL_COUNT=$(su -c "ps -eo ppid,tty" 2>/dev/null | grep -c -E "^ *($REGEX) +pts/" || true)
fi
SHELL_COUNT=$(echo "$SHELL_COUNT" | tr -dc '0-9')
SHELL_COUNT="${SHELL_COUNT:-0}"
```
- A remote `phone-server status` command executes with `TTY = ?` $\rightarrow$ **Count = 0**.
- A developer working in a terminal shell is attached to `/dev/pts/2` $\rightarrow$ **Count = 1**.
- Completely eliminates false positives!

---

### SSH Connection Multiplexing (`ControlMaster`)

Establishing a new Tor v3 encrypted circuit from scratch involves:
1. Connecting to local SOCKS5 proxy (`127.0.0.1:9050`).
2. SOCKS5 greeting and Tor circuit construction (3 hops to Rendezvous Point).
3. HSDir descriptor decryption and introduction handshake (3 hops to phone).
4. OpenSSH key exchange (`curve25519-sha256`) and Ed25519 signature verification.
- **Total Cold Latency**: **3 to 8 seconds**.

While acceptable for an initial connection, waiting 5 seconds every time you run a status command or open a second terminal tab ruins developer velocity.

#### The Multiplexing Solution (`ControlMaster auto`)
In `~/.ssh/config`:
```ssh-config
Host phone-server
    ControlMaster auto
    ControlPath ~/.ssh/control-%C
    ControlPersist 10m
    ServerAliveInterval 15
    ServerAliveCountMax 3
    Compression yes
    ProxyCommand nc -X 5 -x 127.0.0.1:9050 %h %p
```

- **`ControlMaster auto`**: The first connection creates a persistent UNIX domain socket at `~/.ssh/control-<hash>`.
- **`ControlPath`**: All subsequent SSH calls, `rsync` file transfers, and `phone-server status` commands detect the existing socket and pass their file descriptors directly over the established tunnel.
- **Latency Result**: **Under 100 milliseconds** ($< 0.1\text{s}$) with zero Tor handshake overhead.
- **`ControlPersist 10m`**: Keeps the background circuit alive for 10 minutes after closing your last shell window.

---

## 5. Android OS Internals & Termux Subsystem

Running a 24/7 server on Android requires navigating multiple layers of Android OS security and power management.

```
┌────────────────────────────────────────────────────────┐
│ Android Linux Kernel (Linux 4.14 / 5.x)                 │
├────────────────────────────────────────────────────────┤
│ SELinux Policy Engine (Enforcing Mode)                 │
│   ├── u:r:magisk:s0          (Root Domain)             │
│   └── u:r:untrusted_app:s0   (Termux User Domain)      │
├────────────────────────────────────────────────────────┤
│ Android OS Framework & Battery Management              │
│   ├── Android Doze Engine    (DeviceIdle Controller)   │
│   └── Samsung One UI OOM     (com.samsung.android.lool)│
├────────────────────────────────────────────────────────┤
│ Termux Userspace Environment (/data/data/com.termux)    │
│   ├── $PREFIX/bin            (sshd, tor, bash)         │
│   └── $PREFIX/var/lib/tor    (hidden_ssh/)             │
└────────────────────────────────────────────────────────┘
```

---

### The Termux Filesystem & Environment Variables (`$PREFIX`)

Android is not standard Linux. It does not follow the Filesystem Hierarchy Standard (FHS):
- There is no `/usr/bin/bash` or `/bin/sh` accessible to standard applications.
- Termux resides entirely inside its isolated app data sandbox:
  ```text
  /data/data/com.termux/files/
  ├── home/          ($HOME)
  └── usr/           ($PREFIX)
      ├── bin/       ($PREFIX/bin - standard binaries)
      ├── etc/       ($PREFIX/etc - configuration files)
      ├── lib/       ($PREFIX/lib - shared libraries)
      └── var/       ($PREFIX/var - runtime state & Tor data)
  ```

#### Why Shebang Lines Matter
If a script begins with `#!/bin/bash`, it will crash on Android with `No such file or directory`.
All server scripts in this repository use the explicit Termux shebang:
```bash
#!/data/data/com.termux/files/usr/bin/bash
```
Or resolve `$PREFIX` dynamically:
```bash
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
```

---

### SELinux Process Domain Isolation (`magisk` vs. `untrusted_app`)

Android enforces strict Security-Enhanced Linux (SELinux) Mandatory Access Control (MAC).
- Apps operate in the unprivileged domain: `u:r:untrusted_app:s0` (or `untrusted_app_27` / `untrusted_app_30`).
- Root shells run in the elevated Magisk domain: `u:r:magisk:s0`.

#### The "SELinux Process Blindfold"
By default, SELinux policy prevents an `untrusted_app` process from viewing `/proc/<pid>` entries belonging to `magisk` processes.
If `sshd` or `tor` was started via root `su`:
- Running `pgrep sshd` as the standard Termux user returns **nothing** (empty output).
- A naive status script would report `OpenSSH: STOPPED`, even while connections are actively working!

#### The Dual-Layer Detection Engine
Our `status-server` script circumvents the SELinux blindfold using a two-tier approach:
1. **Tier 1 (Root Process Probe)**: If root `su` is available, execute `su -c "pgrep -x sshd"`.
2. **Tier 2 (Direct TCP Socket Probe Fallback)**:
   ```bash
   if [ -z "$SSH_PID" ]; then
       if (echo > /dev/tcp/127.0.0.1/8022) >/dev/null 2>&1; then
           SSH_PID="ACTIVE (port 8022)"
       fi
   fi
   ```
   Loopback network sockets cannot be hidden by process-table access restrictions. If port `8022` responds to a SYN packet, OpenSSH is verifiably operational!

---

### SELinux Multi-Level Security (MLS) Dynamic Categories

Every Android app is assigned a dynamic MLS sensitivity category at install time (e.g. `s0:c44,c257,c512,c768`).
If a script running as root `su` creates an executable inside `$PREFIX/bin`, the file inherits root security contexts:
`u:object_r:system_file:s0`

When the unprivileged Termux user tries to run this script, the kernel blocks execution with `Permission denied`, even if the file is set to `chmod 777`!

#### Dynamic Context Inheritance
Our installer dynamically samples the exact MLS category of the running Termux environment from `$PREFIX/bin/sh` and propagates it to all installed tools:
```bash
if command -v su >/dev/null 2>&1 && su -c "id" 2>/dev/null | grep -q "uid=0"; then
    TERMUX_CTX=$(ls -ldZ "$PREFIX/bin/sh" 2>/dev/null | grep -o 'u:object_r:app_data_file:[^ ]*' | head -n 1 || true)
    if [ -n "$TERMUX_CTX" ]; then
        su -c "chcon $TERMUX_CTX $PREFIX/bin/*-server $PREFIX/bin/authorize-client $PREFIX/bin/phone-server 2>/dev/null || true"
    fi
fi
```

---

### Android OS Doze Mode & Samsung One UI Battery Suppression

When an Android phone's screen turns off and the device is unplugged, Android engages **Doze Mode**:
1. CPU frequencies drop to minimum.
2. Network access for background apps is suspended.
3. Wake locks are ignored.
4. Timers and alarms are batched into narrow maintenance windows.

On Samsung devices, **Samsung Device Care (`com.samsung.android.lool`)** adds an aggressive proprietary memory-killer that kills long-running background processes regardless of wakelocks.

#### Permanent OS-Level Hardening
`setup-server-termux.sh` executes permanent OS-level adjustments (granted once via Magisk root):

| Command | Technical Action |
| :--- | :--- |
| `dumpsys deviceidle whitelist +com.termux` | Grants Termux permanent exemption from Android Doze deep sleep. |
| `cmd appops set com.termux RUN_IN_BACKGROUND allow` | Permits unrestricted background execution in Android AppOps. |
| `cmd appops set com.termux WAKE_LOCK allow` | Unlocks kernel-level wakelock privileges for the Termux UID. |
| `settings put global wifi_sleep_policy 2` | Configures Wi-Fi radio to `NEVER_SLEEP`, keeping the radio awake 24/7. |
| `settings put global stay_on_while_plugged_in 3` | Prevents CPU sleep while connected to AC power or USB. |
| `pm disable-user --user 0 com.samsung.android.lool` | Permanently disables Samsung Device Care background task killer. |
| `termux-wake-lock` | Acquires userspace partial wake lock (`/sys/power/wake_lock`). |

---

## 6. End-to-End Cryptographic Sequence Flow

The following sequence diagram illustrates the lifecycle of a secure session, from cold start to authenticated terminal:

```
Laptop Client                   Tor Directory (HSDir)              Phone Server (Termux)
     │                                    │                                  │
     │                                    │ 1. setup-server-termux.sh        │
     │                                    │    Generates Ed25519 identity    │
     │                                    │    Reads client X25519 publock   │
     │                                    │ 2. Encrypts v3 descriptor        │
     │                                    │ 3. Publishes descriptor          │
     │                                    │ ───────────────────────────────> │
     │                                    │                                  │
     │ 4. User runs: phone-ssh            │                                  │
     │ 5. Local Tor proxy (127.0.0.1:9050)│                                  │
     │    Fetches encrypted descriptor    │                                  │
     │    <────────────────────────────── │                                  │
     │ 6. Decrypts descriptor using       │                                  │
     │    ~/.tor_keys/x25519_priv.pem     │                                  │
     │                                    │                                  │
     │ 7. Builds 3-hop circuit to Rendezvous Point                           │
     │ ─────────────────────────┐         │                                  │
     │                          ▼         │                                  │
     │                   [Rendezvous Point] <─────────────────────────────── │
     │                          ▲         │    8. Server connects to RP      │
     │                          │         │       via independent 3 hops     │
     │ 9. End-to-end 6-hop encrypted Tor stream established                  │
     │ ═════════════════════════════════════════════════════════════════════ │
     │                                                                       │
     │ 10. OpenSSH Handshake: Port 8022                                      │
     │     Presents ~/.ssh/phone_server_ed25519 signature                    │
     │ ────────────────────────────────────────────────────────────────────> │
     │                                                                       │
     │                                    │ 11. Verifies ~/.ssh/authorized_keys
     │                                    │ 12. Forks sshd-session worker    │
     │                                    │ 13. Allocates /dev/pts/2         │
     │                                    │ 14. Launches bash login shell    │
     │ 15. Interactive Shell Ready (<0.1s multiplexed)                       │
     │ <════════════════════════════════════════════════════════════════════ │
```

---

## 7. Codebase Architecture & File-by-File Analysis

```text
stealth-tor-phone-server/
├── phone-server            # Master unified CLI & interactive dashboard (v1.2.0)
├── setup-server-termux.sh  # Automated Server Installer for Android Termux
├── setup-client-linux.sh   # Automated Client Installer for Linux PCs
├── setup-client-termux.sh  # Automated Client Installer for Android Termux Clients
├── README.md               # User manual & quickstart guide
├── DEVELOPER_GUIDE.md      # This comprehensive technical guide
├── LICENSE                 # MIT License
└── .gitignore              # Protects keys, auth files, sockets, and logs
```

### `phone-server` (Master CLI & State Machine)
- **Role**: Single entry point for both interactive and scriptable operations.
- **Dynamic Context Detection**: Detects whether it is executing on Android Termux (`IS_TERMUX=1`) or a Linux PC (`IS_TERMUX=0`), and checks whether the server hostname file (`$PREFIX/var/lib/tor/hidden_ssh/hostname`) exists.
- **Contextual TUI**: If launched without arguments in an interactive TTY (`[ -t 0 ]`), it routes to `menu_server` on the server phone and `menu_client` on client workstations.
- **Dynamic Script Resolution (`find_script`)**: Resolves companion scripts dynamically across `$SCRIPT_DIR`, `$PWD`, `$HOME/stealth-tor-phone-server`, `$HOME/Downloads`, and `/sdcard/Download`.
- **Active Tor Verification (`ensure_local_tor_active`)**: Non-blocking polling loop (`seq 1 10`) probing `127.0.0.1:9050` before initiating connections.

### `setup-server-termux.sh` (Server Engine)
- **Package Matrix**: Auto-installs and repairs `tor`, `openssh`, `openssl-tool`, `coreutils`, `procps`, `psmisc`, and `termux-tools`.
- **Hardening**: Disables password authentication in `sshd_config`, sets port to `8022`, forces public key authentication, and ensures host keys are generated (`ssh-keygen -A`).
- **Binary Installation**: Writes standalone, POSIX-compliant control scripts into `$PREFIX/bin`:
  - `start-server`: Idempotent port checker and daemon launcher.
  - `stop-server`: Forceful teardown (`killall -9 tor sshd sshd-session`) and wakelock release.
  - `status-server`: Dual-layer process & TCP socket engine with PTY-filtered active shell counting.
  - `restart-server`: Clean stop/start cycle.
  - `authorize-client`: Sanitizes client names and registers new public keys on the fly (`killall -HUP tor`).

### `setup-client-linux.sh` (Linux Client Engine)
- **Multi-Distro Packaging**: Automatically detects and invokes `apt-get`, `dnf`, `pacman`, `zypper`, or `apk`.
- **Tor Daemon User Detection**: Discovers system user (`debian-tor` on Debian/Ubuntu, `toranon` on Fedora/RHEL, `tor` on Arch/openSUSE) and sets ownership of `/var/lib/tor/onion_auth`.
- **ProxyCommand Detection**: Automatically determines whether `netcat-openbsd` (`nc -X 5`) or `nmap-ncat` (`ncat --proxy-type socks5`) is present.
- **SSH Multiplexing**: Writes isolated, tagged configuration block into `~/.ssh/config`.

### `setup-client-termux.sh` (Mobile Client Engine)
- **Phone-to-Phone Management**: Enables an unrooted secondary Android phone running Termux to act as a fully fledged mobile administrative workstation.
- **Key Auto-Export**: Saves public keys to `/sdcard/Download/client_public_keys.txt` for easy copying or QR code transfer.

---

## 8. Debugging & Developer Diagnostics

### 1. Diagnosing Tor Hidden Service State (Server Phone)
```bash
# View live Tor logs
cat $PREFIX/var/lib/tor/tor.log

# Check bootstrap progress (look for 100%: Done)
grep "Bootstrapped" $PREFIX/var/lib/tor/tor.log | tail -n 5

# Check if authorized clients directory is recognized
grep "hidden_ssh" $PREFIX/var/lib/tor/tor.log
```

### 2. Diagnosing Client Tor SOCKS Proxy (Linux PC)
```bash
# Verify systemd service status
systemctl status tor

# Inspect live client Tor logs
journalctl -u tor -n 50 --no-pager

# Test local SOCKS5 proxy manually using curl over Tor
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```

### 3. Verbose SSH Handshake Debugging
To inspect the exact cryptographic exchange and see why a connection might be failing:
```bash
ssh -vvv phone-server
```
- **Look for Gate 1**: Netcat establishing SOCKS5 tunnel through `127.0.0.1:9050`.
- **Look for Gate 2**: OpenSSH offering `~/.ssh/phone_server_ed25519` and server accepting the public key.

### 4. Cold Start Descriptor Publication Latency
When Tor daemons are restarted, Tor establishes three 3-hop circuits to directory authorities and publishes its v3 encrypted descriptor.
- **Expected delay**: **30 to 45 seconds**.
- Connecting within the first 20 seconds will trigger `Connection timed out during banner exchange`.
- Always allow ~30–45s after a daemon restart before testing connections.

---

## 📜 Contributing & Security Auditing

We welcome pull requests, security audits, and enhancements! When submitting code:
1. **Maintain Zero-Account Integrity**: Never introduce dependencies on third-party registration services.
2. **Preserve Compatibility**: Ensure scripts run cleanly on both GNU Linux and Android Termux environments.
3. **Run Syntax Checks**: Verify bash syntax with `bash -n <script>` before committing.
4. **Sanitize Secrets**: Ensure no real `.onion` addresses, private keys, or hostnames are ever committed to git history.
