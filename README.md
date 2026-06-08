<h1 align="center">Phormal Tunnel</h1>

<p align="center">
  <em>A fast, resilient tunneling layer for bridging two servers across hostile networks.</em>
</p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-1.0.0-7aa2f7">
  <img alt="platform" src="https://img.shields.io/badge/platform-Linux-78dba9">
  <img alt="shell" src="https://img.shields.io/badge/made%20with-Bash-f7768e">
  <img alt="license" src="https://img.shields.io/badge/license-GPL--3.0-c0caf5">
</p>

---

## Overview

**Phormal** bonds two servers — an **exit node** (a clean, foreign uplink) and an
**entry node** (a local, restricted uplink) — into a single private transport,
then publishes your service ports across it. Clients connect to the entry node
as usual; Phormal carries the traffic to the exit node and back.

It is designed for one job and to do it well: keep a stable link up between two
boxes when the path between them is unreliable or interfered with, and expose
arbitrary TCP / UDP / gRPC ports over that link with minimal fuss.

## Features

- **One command, two roles.** The same script configures both the exit and entry
  nodes; it asks which one it is and does the right thing.
- **Self-healing Core link.** The transport is brought up at boot and watched by
  a guardian process that keeps it warm, so it survives reboots and idle reaping.
- **Single *and* ranged ports together.** Publish `7171,6161` and `2000-2100`
  in the same run — no need to choose one style.
- **TCP / UDP / gRPC** transports for the forwarder.
- **Massive port counts.** Ports are sharded across worker units automatically.
- **Ops built in.** BBR toggle, scheduled auto-refresh, live status, clean uninstall.
- **A real CLI.** After the first run, just type `phormal`.

## Requirements

- Two Linux servers (Debian/Ubuntu recommended) with root access.
- Each server's public IPv4 address.
- Outbound connectivity between the two public IPv4 addresses.

## Install

Run on **both** servers:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Schmi7zz/Phormal/main/phormal.sh)
```

After the first run the script installs itself, so from then on you can simply use:

```bash
sudo phormal
```

## Quick start

1. **Exit node (foreign server).** Run Phormal → **Quick deploy** → choose
   **Exit node** → enter both public IPv4s → accept the suggested **Core key**
   (write it down — you need the same key on the other side).
2. **Entry node (local server).** Run Phormal → **Quick deploy** → choose
   **Entry node** → enter both public IPv4s → paste the **same Core key**.
   When prompted, configure the forwarder: pick a transport and enter your ports.
3. Point your clients at the **entry node's public IP** on the published ports.

> The **Core key** is what links the two nodes. It must be identical on both ends.

## Menu reference

| Option | Action |
| ------ | ------ |
| Quick deploy | Provision the Core link, then (on the entry node) the forwarder |
| Core link only | Build or attach the transport between the two nodes |
| Forwarder only | Publish ports through an existing Core link (entry node) |
| Add / publish more ports | Re-run the forwarder to add ports |
| Status | Show Core link health and forwarder workers |
| Enable BBR | Turn on BBR congestion control for better throughput |
| Auto-refresh schedule | Periodically restart workers to keep things fresh |
| Uninstall | Remove everything Phormal created |

## Port syntax

When configuring the forwarder you'll be asked for two things; fill in either or both:

- **Single ports** — a comma list, e.g. `443,8080,7171`
- **Port ranges** — a comma list of ranges, e.g. `2000-2100,9000-9100`

They are merged and de-duplicated into one published set.

## How it fits together

```
  ┌────────────┐        Phormal Core link        ┌────────────┐
  │ ENTRY node │  ◄────────────────────────────► │ EXIT node  │
  │  (local)   │     published ports forwarded    │ (foreign)  │
  └─────┬──────┘                                  └──────┬─────┘
        │ clients connect here                          │ real service runs here
        ▼                                               ▼
     users                                          upstream
```

## Uninstall

```bash
sudo phormal   # → Uninstall
```

## Notes & limitations

- The transport relies on a protocol that some networks filter. If a fresh Core
  link never reaches its peer, use **Core link → Attach to an existing link** and
  point Phormal at a transport you already have working.
- Match the forwarder transport to your service: a TCP service needs `tcp`; a
  UDP service (e.g. QUIC-based protocols) needs `udp`.
- Logs are written to `/var/log/phormal.log`.

## License

Released under the **GPL-3.0** license. See [LICENSE](LICENSE).

---

<p align="center">
  Made by <a href="https://github.com/Schmi7zz">Schmi7z</a> •
  Telegram channel <a href="https://t.me/SchmitzWS">@SchmitzWS</a> •
  Contact <a href="https://t.me/Schmi7zz">@Schmi7zz</a>
</p>
