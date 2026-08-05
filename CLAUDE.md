# Home Server Config

Fully reproducible NixOS setup spanning a home server (`homeserver`), a Pi backup target (`backupserver`), and the operator's workstation (`workstation`), versioned in Git. A flake at the repo root pins `main` and `backup` to the same `nixos-26.05` nixpkgs; `workstation` tracks the rolling `nixos-unstable` branch via a separate `nixpkgs-unstable` input.

This file is the single source of truth for architecture, decisions, and the behaviours this repo encodes. Operational setup steps live in each host's `README.md`; the end-to-end install playbook is [`DEPLOY.md`](DEPLOY.md); outstanding work lives in `TODO.md`.

---

## Hosts

### `homeserver` (main)

- **Hardware:** Dual Xeon, DDR3, 32–48GB RAM
- **Boot drive:** 250GB SSD
- **Storage:** 4× 1TB spinning drives in mdadm RAID 10 (2TB usable), btrfs on top with the `@data` subvolume mounted at `/mnt/data` (zstd compression, noatime). Mdadm handles redundancy; btrfs handles checksumming + snapshots-if-needed.
- **Role:** Runs all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD) behind Caddy; originates restic backups.
- **Config:** `hosts/main/`

### `backupserver` (Pi backup target)

- **Hardware:** Raspberry Pi 4, no SD card — boots from a ~240GB SATA SSD in a USB adapter via EEPROM USB boot (GPT; needs bootloader ≥ 2020-10-28). OS SSD carries btrfs `@nixos` at `/` plus `@projects` at `/srv/projects` for side projects, and a 1G FAT32 `/boot` holding the whole boot chain (Pi firmware + U-Boot + extlinux + kernels — U-Boot can't read into btrfs subvolumes). Second external USB SSD on btrfs holds backup data (single drive now; btrfs RAID 1 conversion path reserved for when a second drive is added). The data drive is excluded from disko so no reinstall can format the restic repo.
- **Role:** Receives restic backups from `homeserver` over SSH/SFTP via Tailscale. Does not hold the restic password (encryption keys stay on main so a Pi compromise cannot decrypt backups).
- **Edge services:** Docker is enabled (data root `/srv/projects/docker` on the `@projects` subvolume — the data drive stays restic-only) for edge-replicated services at the Pi's location (slow uplink at that site — edge replicas avoid re-pulling over the link). No compose files yet.
- **Config:** `hosts/backup/`

### `workstation` (operator's daily driver)

- **Hardware:** Framework 16 with Ryzen 7000-series, 32GB RAM. Single NVMe (`/dev/nvme1n1`) — installed alongside an existing OS on a separate drive (dual-boot via UEFI menu, separate ESPs, no shared bootloader).
- **Storage:** LUKS-encrypted btrfs `@nixos` subvolume at `/`. Boot SSD has its own ESP partition.
- **Role:** Daily driver for the operator. Runs Hyprland (Wayland tiling compositor), Tailscale leaf, no service-hosting role. Holds the workstation-side operator key + host keys for managing main/Pi.
- **Out of scope here:** user dotfiles (Hyprland config, shell rc, etc.) — those stay under GNU Stow at `~/.dotfiles`, not Nix-managed.
- **Config:** `hosts/workstation/`

---

## Base OS: NixOS 26.05 (main + backup); nixos-unstable (workstation)

- `main` and `backup` pin `nixos-26.05`; `workstation` is rolling on `nixos-unstable` — the Hydra-built channel branch, so updates substitute from cache and rarely compile. Roll it forward with `nix flake update nixpkgs-unstable` then `nixos-rebuild switch`. Dry-run first (`nix build --dry-run .#nixosConfigurations.workstation.config.system.build.toplevel`): if a heavy package isn't cached yet, skip the update a day or two rather than compiling it; if a build lands broken, roll back a generation. Occasionally the channel HEAD ships a broken/uncached non-blocking package (Hyprland did on 2026-08-04) — the lock can sit a few evals behind HEAD until it clears. `stateVersion` stays at its install value regardless of channel.
- Declarative, fully reproducible
- Everything versioned in Git
- Tailscale for secure remote access
- Auto-upgrades daily (only after successful backup)
- First install is **nixos-anywhere + disko** for main and workstation; the Pi's OS SSD is flashed **directly on the workstation** (disko + `nixos-install --system`, aarch64 via binfmt) and then moved to the Pi — see [`DEPLOY.md`](DEPLOY.md). Disk layouts live in `hosts/<host>/disko.nix`; platform stubs in `hosts/<host>/hardware-configuration.nix` are committed hand-authored (not machine-generated).

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
- Images pinned to major versions where upstream publishes major tags (`caddy:2-alpine`, `ntfy:v2`, `postgres:16-alpine`, …); exact `x.y.z` where they don't (vaultwarden, portainer, joplin publish no major-only tags — WUD flags when the exact pins fall behind)

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
- **Config:** `RESTIC_REPOSITORY=` and `RESTIC_PASSWORD=` live in `secrets/restic.env.age` (agenix). Decrypted at activation to `/run/agenix/restic-env`, threaded in via the module's `environmentFile` option.
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
- **Versions:** Pinned in compose files, require manual tag change

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

### Operator-managed files outside git

Two categories:

**(1) Workstation-side files** — live under `/etc/nixos/` on the operator's workstation. Only `site.nix` is still a flake path input; note `flake.lock` merely *verifies* path inputs (narHash) — it cannot supply their content, so the file must exist on any machine that evaluates the main host (main materializes it onto its own disk via `environment.etc` so auto-upgrades keep working). SSH **public** keys live in the repo under `keys/` — they used to be path inputs, which broke every on-device rebuild.

| File | Purpose |
|---|---|
| `/etc/nixos/site.nix` | deSEC subdomain + ACME contact email. Nix attrset: `{ acmeDomain = "..."; acmeEmail = "..."; }`. Threaded in as `siteConfig` via specialArgs; kept out of git deliberately. |
| `/etc/nixos/main-host-key` + `.pub` | Pre-generated SSH host keypair for main. Private gets shipped at install time via `nixos-anywhere --extra-files`; pubkey is the agenix recipient for main's secrets (referenced by `secrets/secrets.nix`). |
| `keys/operator.pub` (in repo) | Operator's SSH pubkey, baked into the `operator` user's `authorized_keys` on both hosts. Forks replace it with their own. |
| `keys/main-root.pub` (in repo) | Pubkey of main's root SSH key (for restic SFTP to Pi); ends up in Pi's `users.users.restic.openssh.authorizedKeys.keyFiles`. Matching private is encrypted in `secrets/main-root-sshkey.age`. |

**(2) Encrypted secrets in repo** — `secrets/*.age`, decrypted by agenix at activation time using main's SSH host key (and editable on the workstation by the operator using their own SSH key).

| Secret | Decrypted to | Used by |
|---|---|---|
| `secrets/restic.env.age` | `/run/agenix/restic-env` | restic services + monthly deep check |
| `secrets/acme-credentials.env.age` | `/run/agenix/acme-credentials` (owner `acme`) | `security.acme` for deSEC DNS-01 |
| `secrets/main-root-sshkey.age` | `/root/.ssh/id_ed25519` (symlink → `/run/agenix/main-root-sshkey`) | restic SFTP client identity |

**(3) Compose-side runtime config** — operator-managed, **not** agenix:

| File | Purpose |
|---|---|
| `hosts/main/.env` | Compose env vars (DOMAIN, service passwords). DOMAIN must match `site.acmeDomain`. Operator-managed because Docker Compose reads it at `up` time, not via the Nix activation pipeline. |
| `/etc/ntfy/url` (Pi only) | Main's ntfy base URL on the tailnet. Single-line file. Read at runtime by the alerts module. |
| `/etc/tailscale/authkey` (Pi only) | Tailscale auth key, one-line. Seeded onto the OS SSD at flash time (decrypted from `secrets/tailscale-authkey.age`); tailscaled reads on first boot to register. Main side uses agenix instead. |

---

## Key Requirements

- **Reproducible:** Everything defined as code, versioned in Git
- **Restorable:** Full restore from Raspberry Pi backup must be straightforward
- **Lightweight:** Usage is light, but Seafile is tuned with Redis caching
- **Secure:** Tailscale for remote access, no services exposed to the public internet

---

## Disaster recovery

`secrets/restic.env.age` (and every other `.age` file) is encrypted to **two recipients**: main's SSH host pubkey, and the operator's workstation pubkey (read from `/etc/nixos/operator.pub`). Either private key is sufficient to decrypt — survival of one means survival of the backup.

### Main loss (Pi + workstation intact)

Most common scenario: main's drives die, fire, theft. Pi still holds the encrypted restic repo.

1. From any machine with the operator's `~/.ssh/id_ed25519` and a clone of the repo, decrypt the repo URL + password:
   ```bash
   nix run github:ryantm/agenix -- -i ~/.ssh/id_ed25519 -d secrets/restic.env.age
   ```
2. Restic can now restore from the Pi via SFTP — anywhere with `restic` installed.
3. To bring main back online: pre-generate a new `/etc/nixos/main-host-key`, `nix flake lock`, run `agenix -r` from `secrets/` to rekey every secret to the new host pubkey + operator, then nixos-anywhere a fresh main with the new host private shipped via `--extra-files`.

### Pi loss (main + workstation intact)

Main keeps running; backup target is gone. If only the Pi's OS SSD died, the data drive (and all snapshots) survives — re-flash the OS SSD per DEPLOY.md §4 and reattach; nothing in the install path can format the data drive. If the data drive itself is lost:

1. Replace the hardware. Re-flash the OS SSD on the workstation, provision the new data drive via `disko-data.nix` (DEPLOY.md §4).
2. Main's next 03:00 restic timer re-initializes a fresh repo on the new drive (`initialize = true`) and seeds it.
3. Snapshot history before the loss is gone; current state is preserved (still on main).

### Catastrophic loss (main + workstation BOTH gone)

Encrypted secrets in the repo are unreadable — neither private key remains. Pi's repo is unrecoverable.

To survive this scenario, keep **at least one** off-site / offline:

- **Workstation `~/.ssh/id_ed25519`** copied to an offline medium (USB in a safe, etc.). Cheapest, recovers everything.
- **OR `RESTIC_PASSWORD` plaintext** in a cloud password manager (Bitwarden cloud, 1Password, Proton Pass). Only recovers the restic repo — secrets/acme-credentials.env.age stays unreadable, but those are easier to regenerate (re-issue deSEC token).
- **OR a paper backup of the password.** Same scope as the password manager option.

The deploy playbook's secrets-inventory section calls this out at install time — when you generate the `RESTIC_PASSWORD`, save it to your password manager *immediately*. The encrypted-only-in-repo posture is only safe if the recovery key has a redundant home.

---

## Files in this repo

| File | Purpose |
|---|---|
| `flake.nix` | Pinned `nixos-26.05` nixpkgs (main/backup) + rolling `nixpkgs-unstable` (workstation); `nixosConfigurations.main` / `.backup` / `.workstation` |
| `keys/*.pub` | Public keys distributed via git: operator SSH key + main's root key (restic SFTP identity) |
| `README.md` | Top-level index for both hosts |
| `CLAUDE.md` | This file — architecture + decisions |
| `DEPLOY.md` | First-install playbook (workstation prep → Pi → main → smoke tests) |
| `TODO.md` | Outstanding tasks |
| `modules/common.nix` | Shared baseline package set (git, vim, htop, curl, wget, usbutils). Imported by all three hosts. |
| `modules/alerts.nix` | Shared NixOS module: ntfy helper, smartd wiring, templated failure notifiers. Imported by both hosts. |
| `hosts/main/configuration.nix` | Main host NixOS config (boot, RAID, Docker, SSH, Tailscale, firewall, auto-upgrade) |
| `hosts/main/disko.nix` | Declarative disk layout: boot SSD (ESP + swap + btrfs `@nixos` at `/`) + mdadm RAID 10 over 4 spinners with btrfs `@data` at `/mnt/data` |
| `hosts/main/hardware-configuration.nix` | Hand-authored platform stub: initrd modules (incl. raid10/md_mod), kvm-intel, Intel microcode |
| `hosts/main/Caddyfile` | Reverse proxy routes for all main-host services |
| `hosts/main/.env.example` | Main-host environment variable template |
| `hosts/main/compose/*.yml` | Docker Compose files (one per service) |
| `hosts/main/README.md` | Main-host setup guide |
| `hosts/backup/configuration.nix` | Pi backup-host NixOS config (aarch64, btrfs, firewall, heartbeat-gated auto-upgrade, by-label `/mnt/backups` mount) |
| `hosts/backup/disko.nix` | Declarative disk layout, OS SSD only: 1G FAT32 `/boot` + btrfs `@nixos` at `/` and `@projects` at `/srv/projects`. Data drive intentionally absent. |
| `hosts/backup/disko-data.nix` | Standalone layout for the backup data drive (btrfs `backup-data`, `@homeserver` subvolume). Not flake-imported — manual disko run when provisioning a fresh drive only. |
| `hosts/backup/hardware-configuration.nix` | Hand-authored platform stub: USB-root initrd modules (xhci/uas/sd), mainline kernel pin (channel-cached — no kernel compiles on Pi or workstation), serial consoles, `installBootLoader` wrapper syncing Pi firmware + U-Boot into `/boot` |
| `hosts/backup/README.md` | Pi backup-host setup guide |
| `hosts/workstation/configuration.nix` | Workstation NixOS config (Hyprland, PipeWire, greetd/tuigreet, Tailscale leaf, no service-hosting) |
| `hosts/workstation/disko.nix` | Declarative disk layout: ESP + LUKS-encrypted btrfs `@nixos` on `/dev/nvme1n1` |
| `hosts/workstation/hardware-configuration.nix` | Hand-authored platform stub: AMD CPU + NVMe initrd modules; Framework 16-specific bits come from `nixos-hardware.nixosModules.framework-16-7040-amd` |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
