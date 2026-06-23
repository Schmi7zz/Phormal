<div align="center">

```
██████  ██   ██  ████  ██████  ███    ███  ████  ██
██   ██ ██   ██ ██  ██ ██   ██ ████  ████ ██  ██ ██
██████  ███████ ██  ██ ██████  ██ ████ ██ ██████ ██
██      ██   ██ ██  ██ ██   ██ ██  ██  ██ ██  ██ ██
██      ██   ██  ████  ██   ██ ██      ██ ██  ██ ███████
                     T   U   N   N   E   L
```

# Phormal Tunnel

**A fast, resilient tunneling layer for bridging two servers across hostile networks.**

[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Version](https://img.shields.io/badge/version-5.6.0-brightgreen.svg)](https://github.com/Schmi7zz/Phormal)
[![Platform](https://img.shields.io/badge/platform-Linux-lightgrey.svg)](#requirements)

[Telegram Channel](https://t.me/SchmitzWS) • [Contact](https://t.me/Schmi7zz) • [GitHub](https://github.com/Schmi7zz/Phormal)

</div>

---

## What is Phormal?

Phormal is an all-in-one, menu-driven tunnel manager that links **two servers** — typically one inside Iran and one abroad — and keeps the link alive even on filtered, throttled, or hostile network paths.

Different paths break in different ways: some drop UDP, some only let TCP out, some barely pass anything but ICMP. Instead of betting on a single method, Phormal ships **six independent tunnel products**, tests every one of them against your actual path, and tells you which to use. You pick the winner and you're done.

Every product is fully self-contained under the Phormal brand — one installer, one command, one consistent workflow.

---

## Highlights

- **Six tunnel products** under one roof — pick whatever survives your path.
- **Path Auto-Test** — one command probes every product end-to-end between the two servers and recommends the best one, with a confidence rating.
- **Role-aware setup** — each product has a clean *exit* (abroad) and *entry* (Iran) side; the menu guides you through both.
- **Self-healing** — optional auto-refresh schedule keeps tunnels warm and healthy.
- **Built-in speedtest** for the main products.
- **Network tuning** — queue-discipline and buffer tuning applied with one option.
- **Clean install / clean uninstall** — everything lives under `/etc/phormal`, and removal is a single menu entry.

---

## Installation

Run this on **both** servers (Iran side and abroad side):

```bash
curl -fsSL https://raw.githubusercontent.com/Schmi7zz/Phormal/main/phormal.sh -o phormal.sh && sed -i 's/\r$//' phormal.sh && chmod +x phormal.sh && sudo ./phormal.sh
```

After the first run, Phormal installs a global command, so next time you can simply launch it with:

```bash
sudo phormal
# or
phormal
```

---

## Quick Start

1. Install Phormal on **both** servers (command above).
2. On one server, open the menu and run **option 1 — Path Auto-Test**. Enter the peer's SSH details once; Phormal probes every product across the real path.
3. Read the results table. Phormal marks each product **PASS / FAIL** with a confidence level and prints a **BEST CHOICE**.
4. Set up the recommended product: add the **exit** on the abroad server and the **entry** on the Iran server, using the menu options listed next to that product.
5. (Optional) Enable the **auto-refresh schedule** to keep the link healthy automatically.

> **Tip:** Re-run the Path Auto-Test whenever you add a new peer or the network behavior changes — then just follow the BEST CHOICE.

---

## Products & Menu Map

| Menu | Section | Purpose |
|------|---------|---------|
| **1** | **Phormal Path Test** | Auto-probe every product between the two servers and recommend the best one |
| **2–5** | **Phormal Bridge** | Add exit link · Add entry link · Manage links · Speedtest |
| **6–9** | **Phormal Relay** | Add exit tunnel · Add entry tunnel · Manage tunnels · Speedtest |
| **10–12** | **Phormal Reverse** | Add exit tunnel · Add entry tunnel · Manage tunnels |
| **13–15** | **Phormal GRE** | Add exit tunnel · Add entry tunnel · Manage tunnels |
| **16–18** | **Phormal Echo** | Add exit tunnel · Add entry tunnel · Manage tunnels |
| **19–21** | **Phormal Raw** | Add exit tunnel · Add entry tunnel · Manage tunnels |
| **22** | Manage | Status — overview of all links/tunnels and service health |
| **23** | Manage | Phormal tuning — apply network/queue/buffer tuning |
| **24** | Manage | Auto-refresh schedule — keep tunnels warm automatically |
| **25** | Manage | Uninstall — clean, complete removal |
| **0** | — | Exit |

---

## Choosing a Product

You don't have to memorize this — the **Path Auto-Test (option 1)** decides for you. But here's what each product is built for:

| Product | Best for | Notes |
|---------|----------|-------|
| **Phormal Bridge** | A solid general-purpose default on clean paths | Stable point-to-point link with a private internal address space between the two servers |
| **Phormal Relay** | Maximum throughput when the path is open | High-speed, obfuscated relay with port-hopping; *Iran = entry, abroad = exit* |
| **Phormal Reverse** | Paths where only outbound TCP survives | The abroad side accepts the connection; the Iran side dials out |
| **Phormal GRE** | Low-latency, low-overhead links on friendly paths | Lightweight kernel-level point-to-point tunnel |
| **Phormal Echo** | Heavily restricted paths | Carries the link over basic echo traffic when little else passes |
| **Phormal Raw** | UDP-hostile filtering | Shapes the link to slip past filters that punish raw UDP |

**Roles in one line:** every product has an **exit** side (set up on the **abroad / kharej** server) and an **entry** side (set up on the **Iran** server). Add the exit first, then the entry.

---

## Requirements

- A Linux server on each side (Debian/Ubuntu family recommended).
- **root** / `sudo` access on both servers.
- **Two servers** — typically one in Iran and one abroad.
- For the Path Auto-Test: outbound **SSH** from the server you run the test on, to the peer (one direction only — Phormal never opens SSH back from the peer).

---

## Uninstall

Open the menu and choose **option 25 — Uninstall**. Phormal removes its services, binaries, and files cleanly. Everything Phormal creates lives under `/etc/phormal`, so nothing is left scattered across the system.

---

## License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**.
See the [LICENSE](LICENSE) file for the full text.

```
Copyright (C) 2026 Schmi7z — github.com/Schmi7zz
```

---

## Links & Contact

- **Telegram Channel:** [@SchmitzWS](https://t.me/SchmitzWS)
- **Contact:** [@Schmi7zz](https://t.me/Schmi7zz)
- **GitHub:** [github.com/Schmi7zz/Phormal](https://github.com/Schmi7zz/Phormal)

<div align="center">

**Phormal Tunnel** — pick the mode that fits your path.

</div>
