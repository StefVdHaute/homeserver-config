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
- First install is **nixos-anywhere + disko** for both hosts — see each host's README §1. Disk layouts live in `hosts/<host>/disko.nix`; platform stubs in `hosts/<host>/hardware-configuration.nix` are committed hand-authored (not machine-generated).

---

## Architecture Overview

### Reverse Proxy

- **Caddy** — single entry point for all web services (ports 80/443)
- Subdomain-based routing (`seafile.DOMAIN`, `vaultwarden.DOMAIN`, etc.)
- HTTPS via real Let's Encrypt certs (wildcard) issued and renewed by NixOS `security.acme` on the host, using a DNS-01 ACME challenge through the deSEC DNS plugin. Caddy reads `cert.pem`/`key.pem` from `/var/lib/acme/${DOMAIN}/` via a read-only bind mount; a `caddy-reload-certs.service` restarts Caddy after each renewal. See `hosts/main/README.md` §6.

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
| WUD | Container update monitoring (notify-only, no auto-updates); posts to ntfy `home-updates` |
| ntfy | Self-hosted push-notification server for operator alerts (tailnet-only) |
| AdGuard Home | Network-wide DNS + ad/tracker blocking (NixOS `services.adguardhome`, not a container). UI at `adguard.DOMAIN`; DNS on 53 reachable from tailnet + LAN. Upstream: Quad9 + Cloudflare over DoT. |

Restic is not in the table above — it runs as a NixOS service (`services.restic.backups`), not a Docker container. See the Backup & Restore section below.

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
- **Integrity:** fast `restic check` after every backup on main; additionally a `restic-check-deep.timer` runs monthly (first-of-month, 6h randomised delay) with `--read-data-subset=10%` — samples 10% of pack data per run so the whole repo gets verified statistically over ~10 months. Success → silent ntfy ping on `home-backup`; failure → audible via the same `ntfy-backup-failure@` template used for the daily jobs
- **Outcome alerts:** success → silent ntfy ping on `home-backup` (via the module's `backupCleanupCommand`); failure → audible ntfy ping via a templated `ntfy-backup-failure@.service` wired through each unit's `OnFailure`.
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
- **`home-infra`** — Pi-side host-health failures (`nixos-upgrade.service`, `mnt-backups.mount`, `tailscaled.service`). Daemon crashes only — connectivity-level Tailscale monitoring is a follow-up.

Producer → URL:

| Producer | Reaches ntfy via |
|---|---|
| Restic `backupCleanupCommand` (per-job) | `http://127.0.0.1:8085/home-backup` — silent (Priority 1) |
| Restic `OnFailure` via `ntfy-backup-failure@.service` | `http://127.0.0.1:8085/home-backup` — audible (Priority 3) |
| `smartd` on main | `http://127.0.0.1:8085/home-smart` |
| WUD container on main | `http://ntfy:80/home-updates` (Docker proxy network DNS) |
| `smartd` on Pi | `$(cat /etc/ntfy/url)/home-smart` — `/etc/ntfy/url` on the Pi holds the base URL (operator-managed, outside git) |
| Pi `OnFailure` hooks via `ntfy-infra-failure@.service` | `$(cat /etc/ntfy/url)/home-infra` — one templated unit, three wired units (`nixos-upgrade`, `tailscaled`, `mnt-backups.mount`) |
| `tailscale-healthcheck.timer` on main | `http://127.0.0.1:8085/home-infra` — 15-min active check of `tailscale status --json` (`BackendState == Running` + `Self.Online`) |
| `tailscale-healthcheck.timer` on Pi | `$(cat /etc/ntfy/url)/home-infra` — same check as main, complements the daemon-crash `OnFailure` hook |

Caveat for the Pi's USB drive: SMART passthrough depends on the enclosure's UAS/SAT support. Verify once with `sudo smartctl -a -d sat /dev/sda` on first deploy. If the enclosure is opaque, replace it with one that isn't — there's no software workaround.

### Operator-managed files outside git (main)

Site-specific values and secrets that don't belong in Nix source live in operator-managed files. The main host expects:

| File | Purpose | Format |
|---|---|---|
| `/etc/nixos/site.nix` | deSEC subdomain + ACME contact email; read at eval time by `hosts/main/configuration.nix` | Nix attrset: `{ acmeDomain = "..."; acmeEmail = "..."; }` |
| `/etc/acme/credentials.env` | DNS provider API token used by `security.acme` | env file: `DESEC_TOKEN=...` |
| `/etc/restic/env` | Restic repository URL + encryption password | env file: `RESTIC_REPOSITORY=...` / `RESTIC_PASSWORD=...` |
| `hosts/main/.env` | Compose env vars (DOMAIN, service passwords, etc.); `DOMAIN` must match `site.acmeDomain` | env file |

On the Pi, `/etc/ntfy/url` holds the base URL of main's ntfy server (see the Notifications section above).

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
| `modules/alerts.nix` | Shared NixOS module: ntfy helper, smartd wiring, templated failure notifiers. Imported by both hosts. |
| `hosts/main/configuration.nix` | Main host NixOS config (boot, RAID, Docker, SSH, Tailscale, firewall, auto-upgrade) |
| `hosts/main/disko.nix` | Declarative disk layout: boot SSD (ESP + swap + ext4 root) + RAID 10 over 4 spinners |
| `hosts/main/hardware-configuration.nix` | Hand-authored platform stub: initrd modules (incl. raid10/md_mod), kvm-intel, Intel microcode |
| `hosts/main/Caddyfile` | Reverse proxy routes for all main-host services |
| `hosts/main/.env.example` | Main-host environment variable template |
| `hosts/main/compose/*.yml` | Docker Compose files (one per service) |
| `hosts/main/README.md` | Main-host setup guide |
| `hosts/backup/configuration.nix` | Pi backup-host NixOS config (aarch64, btrfs, firewall, heartbeat-gated auto-upgrade) |
| `hosts/backup/disko.nix` | Declarative disk layout: SD (FAT32 firmware + ext4 root) + external USB btrfs with `@homeserver` subvolume |
| `hosts/backup/hardware-configuration.nix` | Hand-authored platform stub: aarch64, USB + MMC initrd modules |
| `hosts/backup/README.md` | Pi backup-host setup guide |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
