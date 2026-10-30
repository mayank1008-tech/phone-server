# 🛡️ Stealth Tor v3 Phone Server

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Android](https://img.shields.io/badge/Platform-Android%20Termux-green.svg)](https://termux.dev)
[![Client: Linux & Android](https://img.shields.io/badge/Client-Linux%20%7C%20Android-orange.svg)]()
[![Security: Zero Accounts](https://img.shields.io/badge/Security-Zero%20Accounts%20%7C%20Pure%20Crypto-red.svg)]()

Turn any spare or rooted Android phone into a **headless, 24/7 Linux home server** accessible from anywhere globally with **dual-layer cryptographic authorization**, zero open router ports, zero DNS leaks, and **zero accounts or third-party sign-ups** (No Tailscale, No Cloudflare, No Ngrok).

---

## 🔒 Threat Model & Architecture

Standard Tor hidden services publish their addresses to public directory nodes where port scanners and web crawlers can discover them. 

This project implements **Tor v3 Client Authorization (Stealth Mode)** combined with **Ed25519 Public-Key SSH**:

```
[ Client (Laptop / Second Phone) ]                         [ Android Phone Server (Termux) ]
  • SSH Priv: ~/.ssh/phone_server_ed25519                   • SSH Auth: ~/.ssh/authorized_keys
  • Tor Priv: onion_auth/phone.auth_private                 • Tor Lock: authorized_clients/laptop.auth
        │                                                                │
        └───> [Local Tor Proxy] ──(6-Hop Encrypted Circuit)──> [Tor Hidden Service] ──> [sshd:8022]
              (127.0.0.1:9050)                                 (Descriptor decrypted    (Passphrase-less,
                                                               with x25519 pubkey)      passwords disabled)
```

### The Two Cryptographic Gates:
1. **Gate 1: Stealth Tor v3 Layer (`X25519`)**
   * The phone's hidden service descriptor is **encrypted with your client's X25519 public key**.
   * Any random scanner, crawler, or unauthorized user attempting to access the `.onion` address receives an immediate `Host unreachable` error at the Tor directory level. **Zero bytes ever reach your phone.**
2. **Gate 2: Fortified SSH Layer (`Ed25519`)**
   * Password authentication is strictly disabled (`PasswordAuthentication no`).
   * Only your client's Ed25519 private key can authenticate.
3. **Isolated Client Routing**:
   * **Only the connection to the phone routes through Tor**. Your regular browsing, gaming, and downloads continue directly through your standard ISP/Wi-Fi connection.

---

## 📁 Repository Structure

| File | Purpose |
| :--- | :--- |
| **`setup-server-termux.sh`** | Run on the **Server Phone** (Termux). Configures Tor, hardens SSH, disables Android sleep/doze killers, and creates management CLI tools. |
| **`setup-client-linux.sh`** | Run on your **Linux PC**. Generates X25519/Ed25519 keys, configures Tor client auth, installs companion controls, and sets up `~/.ssh/config`. |
| **`setup-client-termux.sh`** | Run on a **Secondary Mobile Phone** (Termux). Allows seamless mobile-to-mobile server administration over Tor. |

---

## 🚀 Quickstart Guide

### Step 1: Run the Client Script on Your Laptop
On your Linux machine, clone this repository and run the client setup script:

```bash
git clone https://github.com/your-username/stealth-tor-phone-server.git
cd stealth-tor-phone-server
chmod +x setup-client-linux.sh
./setup-client-linux.sh
```

**What happens:**
* Generates your **SSH Ed25519** and **Tor X25519** cryptographic keys.
* Displays your **Public Keys** in a formatted box on your screen.
* Leaves the prompt open waiting for your phone's `.onion` address.

---

### Step 2: Run the Server Script on Your Phone
Open **Termux** on your Android phone and execute:

```bash
curl -sL https://raw.githubusercontent.com/your-username/stealth-tor-phone-server/main/setup-server-termux.sh -o setup-server-termux.sh
chmod +x setup-server-termux.sh
./setup-server-termux.sh
```

**During execution:**
1. When prompted, **paste the Client Tor Public Key** displayed on your laptop screen.
2. When prompted, **paste the Client SSH Public Key** displayed on your laptop screen.
3. The script configures the services, applies Android Doze suppression, starts the server, and prints your **56-character `.onion` address**.

---

### Step 3: Complete the Client Setup
Paste the `.onion` address printed by your phone into the waiting prompt on your laptop terminal.

---

## 💻 Daily Operations

### Connecting from Your PC
To connect from anywhere in the world (home, coffee shop, mobile hotspot, or abroad):

```bash
ssh phone-server
```
*(Or use the installed companion shortcut: `phone-ssh`)*

### Checking Server Status
From your PC terminal:
```bash
status-server
```
* **If USB is plugged in**: Instantly queries via ADB (<0.05 seconds).
* **If wireless/remote**: Queries securely over Tor SSH.

Output:
```text
==========================================
        Phone Server Status
==========================================
  [+] OpenSSH Daemon : RUNNING (PID: 31584)
  [+] Tor Daemon     : RUNNING (PID: 3445)
  [*] Active Sessions: 0
  [*] Onion Address  : <your-56-char-onion-address>.onion
==========================================
```

### Server Management on the Phone (Inside Termux)
The server script installs native CLI binaries directly into `$PREFIX/bin`:

```bash
start-server    # Starts Tor and OpenSSH quietly in background
stop-server     # Force-kills all listeners and active sessions immediately
restart-server  # Clean restart of both daemons
status-server   # Displays running process IDs and active socket states
```

---

## ⚡ Android & Samsung 24/7 Keep-Alive Hardening

Android devices (especially Samsung One UI) aggressively kill background processes and put Wi-Fi chips to sleep when the screen turns off. 

`setup-server-termux.sh` automatically executes the following root-level mitigations:

1. **Suppresses Samsung Device Care**: Disables `com.samsung.android.lool` background task killer.
2. **Wi-Fi Sleep Immunity**: Sets `wifi_sleep_policy = 2` (never sleep Wi-Fi).
3. **Kernel Doze Whitelisting**: Adds Termux to the Linux kernel `deviceidle` whitelist.
4. **AppOps Background Rights**: Grants unrestricted `RUN_IN_BACKGROUND` and `WAKE_LOCK`.
5. **Always-On Power Policy**: Configures `stay_on_while_plugged_in = 3` (AC + USB).

> [!TIP]
> Keep the phone connected to power (charger). Pull down the Android notification shade, locate the Termux notification, and tap **"Acquire Wakelock"**.

---

## 🔄 Key Rotation & Multi-Device Management

### Authorizing a Second Device (e.g. Work Laptop or Secondary Phone)
You can authorize multiple devices without altering existing keys:

1. Run `setup-client-linux.sh` (or `setup-client-termux.sh`) on the new device to obtain its public keys.
2. On the Phone Server (Termux), add the new authorization lock:
   ```bash
   echo "descriptor:x25519:<NEW_DEVICE_TOR_PUB>" > $PREFIX/var/lib/tor/hidden_ssh/authorized_clients/device2.auth
   chmod 600 $PREFIX/var/lib/tor/hidden_ssh/authorized_clients/device2.auth
   ```
3. Append its SSH public key:
   ```bash
   echo "<NEW_DEVICE_SSH_PUB>" >> ~/.ssh/authorized_keys
   ```
4. Reload Tor: `killall -HUP tor`.

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.
