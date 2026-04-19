# Home Server Config

Fully reproducible two-host home setup using NixOS + Docker Compose, versioned in Git. A flake at the repo root ties both hosts to the same pinned nixpkgs.

This file is the single source of truth for architecture, decisions, and the behaviours this repo encodes. Operational setup steps live in each host's `README.md`; outstanding work lives in `TODO.md`.

---

## Hosts

### `homeserver` (main)

- **Hardware:** Dual Xeon, DDR3, 32–48GB RAM
- **Boot drive:** 250GB SSD
- **Storage:** 4× 1TB spinning drives in RAID 10 (2TB usable), mounted at `/mnt/data`
- **Role:** Runs all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD) behind Caddy; originates restic backups.
- **Config:** `hosts/main/`

### `backupserver` (Pi backup target)

- **Hardware:** Raspberry Pi 4, SD boot, external USB SSD on btrfs (single drive now; btrfs RAID 1 conversion path reserved for when a second drive is added)
- **Role:** Receives restic backups from `homeserver` over SSH/SFTP via Tailscale. Does not hold the restic password (encryption keys stay on main so a Pi compromise cannot decrypt backups).
- **Future flex:** can host Docker containers for edge-replicated services at the Pi's location (slow uplink at that site — edge replicas avoid re-pulling over the link).
- **Config:** `hosts/backup/`

---

## Base OS: NixOS 25.11

- Declarative, fully reproducible
- Everything versioned in Git
- Tailscale for secure remote access
- Auto-upgrades daily (only after successful backup)

---

## Architecture Overview

### Reverse Proxy

- **Caddy** — single entry point for all web services (ports 80/443)
- Subdomain-based routing (`seafile.DOMAIN`, `vaultwarden.DOMAIN`, etc.)
- Automatic HTTPS via built-in internal CA (or Let's Encrypt with public domain)

### Remote Access

- **Tailscale** — mesh VPN, all services accessible from anywhere via tailnet hostname
- Firewall trusts `tailscale0` interface

### Containerisation

- Docker + Docker Compose
- Docker data root: `/mnt/data/docker` (on RAID, not boot SSD)
- Separate compose files per service
- All images pinned to major versions

### Services (all as Docker containers)

| Service | Purpose |
|---|---|
| Seafile | File storage + desktop sync for up to 5 desktops with version history. MariaDB + Redis for performance. |
| Vaultwarden | Self-hosted Bitwarden-compatible password manager |
| Joplin Server | Self-hosted note sync (PostgreSQL backend) |
| Caddy | Reverse proxy with automatic HTTPS |
| Portainer | Container management web UI |
| WUD | Container update monitoring dashboard (notify-only, no auto-updates) |
| ntfy | Self-hosted push-notification server for operator alerts (tailnet-only) |
| Restic | Scheduled backups to Raspberry Pi over SSH |

### Storage layout on RAID (`/mnt/data`)

```text
/mnt/data/
├── docker/          # Docker data root
├── seafile/         # Seafile data
└── backups/         # Local backup staging
```

### Backup & Restore

- **Tool:** Restic, declared via NixOS `services.restic.backups.<name>` in `hosts/main/configuration.nix`. Two jobs share a `resticCommon` record: `docker-volumes` and `seafile-data`.
- **Target:** `backupserver` (Pi) over SFTP via Tailscale.
- **Config:** `/etc/restic/env` on main holds `RESTIC_REPOSITORY=` and `RESTIC_PASSWORD=` — operator-managed, mode 0600, outside git. Wired via the module's `environmentFile` option.
- **Schedule:** `restic-backups-docker-volumes.timer` and `restic-backups-seafile-data.timer` both fire daily at 03:00 (30m randomised delay) on `homeserver`.
- **Scope:** Docker volumes (`/mnt/data/docker/volumes`, tagged `docker-volumes`, excludes `*.tmp`/`*.log`) + Seafile data (`/mnt/data/seafile`, tagged `seafile-data`).
- **Retention:** 7 daily, 4 weekly, 6 monthly snapshots. The module runs `restic forget --prune` after each backup via `pruneOpts`.
- **Integrity:** fast `restic check` after every backup on main; monthly deep `--read-data-subset` planned as follow-up
- **Security:** restic password only lives on `homeserver`; a compromise of the Pi cannot decrypt backups
- **Aliveness signal:** the Pi's `nixos-upgrade` has an `ExecCondition` that looks for any file under `/mnt/backups/homeserver/snapshots/` newer than 24h. Restic's own snapshot file layout doubles as proof that main is alive and the backup pipeline is working — no extra SSH round-trip from main is needed to write a heartbeat file.
- **Goal:** full restore possible from Pi in case of main-server failure

### Updates

- **Docker containers:** WUD monitors for available updates, user pulls manually
- **NixOS:** Auto-upgrades daily at 04:30, only after successful backup
- **Major versions:** Pinned in compose files, require manual tag change

### Notifications

Operator alerts go to a self-hosted [ntfy](https://ntfy.sh) server running on `homeserver` as a Docker container on the `proxy` network, fronted by Caddy at `ntfy.<DOMAIN>`. Tailnet-only reachability; no auth (tailnet membership is the authentication).

Topics, subscribed by the operator's phone:

- **`home-backup`** — restic success pings (Priority 1 / silent) and failures (default priority / audible).
- **`home-smart`** — `smartd` alerts from both hosts (main's RAID drives + the Pi's external USB SSD).
- **`home-updates`** — WUD container-update notifications.

Producer → URL:

| Producer | Reaches ntfy via |
|---|---|
| Restic hooks on main | `http://127.0.0.1:8085/home-backup` (host-mapped port) |
| `smartd` on main | `http://127.0.0.1:8085/home-smart` |
| WUD container on main | `http://ntfy:80/home-updates` (Docker proxy network DNS) |
| `smartd` on Pi | `$(cat /etc/ntfy/url)/home-smart` — `/etc/ntfy/url` on the Pi holds the base URL (operator-managed, outside git) |

---

## Key Requirements

- **Reproducible:** Everything defined as code, versioned in Git
- **Restorable:** Full restore from Raspberry Pi backup must be straightforward
- **Lightweight:** Usage is light, but Seafile is tuned with Redis caching
- **Secure:** Tailscale for remote access, no services exposed to the public internet

---

## Files in this repo

| File | Purpose |
|---|---|
| `flake.nix` | Pinned nixpkgs + `nixosConfigurations.main` / `.backup` |
| `README.md` | Top-level index for both hosts |
| `CLAUDE.md` | This file — architecture + decisions |
| `TODO.md` | Outstanding tasks |
| `hosts/main/configuration.nix` | Main host NixOS config (boot, RAID, Docker, SSH, Tailscale, firewall, auto-upgrade) |
| `hosts/main/raid-setup.sh` | RAID 10 setup script for live installer |
| `hosts/main/Caddyfile` | Reverse proxy routes for all main-host services |
| `hosts/main/.env.example` | Main-host environment variable template |
| `hosts/main/compose/*.yml` | Docker Compose files (one per service) |
| `hosts/main/README.md` | Main-host setup guide |
| `hosts/backup/configuration.nix` | Pi backup-host NixOS config (aarch64, btrfs, firewall, heartbeat-gated auto-upgrade) |
| `hosts/backup/disk-setup.sh` | btrfs format script for the external USB drive |
| `hosts/backup/README.md` | Pi backup-host setup guide |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
