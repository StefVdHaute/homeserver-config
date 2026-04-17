# Home Server Setup — Project Briefing

## Context

This is a fully reproducible home server setup using NixOS, Docker, and
Docker Compose, versioned in Git.

---

## Hardware

- **Server:** Dual Xeon, DDR3, 32–48GB RAM
- **Boot drive:** 250GB SSD
- **Storage:** 4x 1TB spinning drives in RAID 10 (2TB usable), mounted at `/mnt/data`
- **Remote backup:** Raspberry Pi at a separate location

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
- **Target:** Raspberry Pi over SSH
- **Schedule:** Daily at 03:00 via systemd timer
- **Scope:** Docker volumes + Seafile data
- **Retention:** 7 daily, 4 weekly, 6 monthly snapshots
- **Goal:** Full restore possible from Pi in case of server failure

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
| `configuration.nix` | NixOS config (boot, RAID, Docker, SSH, Tailscale, firewall, auto-upgrade) |
| `raid-setup.sh` | RAID 10 setup script for live installer |
| `Caddyfile` | Reverse proxy routes for all services |
| `.env.example` | Environment variable template |
| `compose/*.yml` | Docker Compose files (one per service) |
| `backup/restic-backup.sh` | Backup script |
| `backup/restic-backup.service` | Systemd service for backup |
| `backup/restic-backup.timer` | Systemd timer (daily 03:00) |
| `backup/restic-env.example` | Restic credentials template |
| `README.md` | Step-by-step first setup guide |
| `TODO.md` | Outstanding tasks |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
