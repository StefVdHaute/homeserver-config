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
| Restic | Scheduled backups to Raspberry Pi over SSH |

### Storage layout on RAID (`/mnt/data`)

```text
/mnt/data/
├── docker/          # Docker data root
├── seafile/         # Seafile data
└── backups/         # Local backup staging
```

### Backup & Restore

- **Tool:** Restic
- **Target:** `backupserver` (Pi) over SFTP via Tailscale (`sftp:restic@backupserver.<tailnet>.ts.net:/mnt/backups/homeserver`)
- **Schedule:** Daily at 03:00 via systemd timer on `homeserver`
- **Scope:** Docker volumes (`/mnt/data/docker/volumes`) + Seafile data (`/mnt/data/seafile`)
- **Retention:** 7 daily, 4 weekly, 6 monthly snapshots (`restic forget --prune` runs from main)
- **Integrity:** fast `restic check` after every backup on main; monthly deep `--read-data-subset` planned as follow-up
- **Security:** restic password only lives on `homeserver`; a compromise of the Pi cannot decrypt backups
- **Aliveness signal:** the Pi's `nixos-upgrade` has an `ExecCondition` that looks for any file under `/mnt/backups/homeserver/snapshots/` newer than 24h. Restic's own snapshot file layout doubles as proof that main is alive and the backup pipeline is working — no extra SSH round-trip from main is needed to write a heartbeat file.
- **Goal:** full restore possible from Pi in case of main-server failure

### Updates

- **Docker containers:** WUD monitors for available updates, user pulls manually
- **NixOS:** Auto-upgrades daily at 04:30, only after successful backup
- **Major versions:** Pinned in compose files, require manual tag change

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
| `hosts/main/restic/restic-backup.sh` | Main-host backup script |
| `hosts/main/restic/restic-backup.service` | Systemd service for backup |
| `hosts/main/restic/restic-backup.timer` | Systemd timer (daily 03:00) |
| `hosts/main/restic/restic-env.example` | Restic credentials template |
| `hosts/main/README.md` | Main-host setup guide |
| `hosts/backup/configuration.nix` | Pi backup-host NixOS config (aarch64, btrfs, firewall, heartbeat-gated auto-upgrade) |
| `hosts/backup/disk-setup.sh` | btrfs format script for the external USB drive |
| `hosts/backup/README.md` | Pi backup-host setup guide |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
