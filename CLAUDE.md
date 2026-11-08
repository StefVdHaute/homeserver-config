# Home Server Config

Fully reproducible NixOS setup spanning a home server (`homeserver`), a Pi backup target (`backupserver`), and the operator's workstation (`workstation`), versioned in Git. A flake at the repo root pins `main` and `backup` to the same `nixos-26.05` nixpkgs; `workstation` tracks the rolling `nixos-unstable` branch via a separate `nixpkgs-unstable` input.

This file is the single source of truth for architecture, decisions, and the behaviours this repo encodes. Operational setup steps live in each host's `README.md`; the end-to-end install playbook is [`DEPLOY.md`](DEPLOY.md); outstanding work lives in `TODO.md`.

---

## Hosts

### `homeserver` (main)

- **Hardware:** Dell PowerEdge R720 (service tag 9QYZF42), 2× Xeon E5-2620 (Sandy Bridge, 6C each), 32GB DDR3, UEFI boot. iDRAC7 Enterprise on the LAN for out-of-band power and console.
- **Controller:** PERC H710P Mini cross-flashed to IT mode (LSI SAS2308, `mpt3sas`), so Linux sees plain disks. Until the flash is done the disks are invisible to mdadm/btrfs and SMART.
- **Disks:** 4× 1TB Seagate ST1000DM010 (desktop drives, no ERC/TLER) in bays 0–3. No boot SSD; the onboard SATA ports stay free for one later. Addressed by `/dev/disk/by-id/` in `disko.nix`.
- **Layout (per disk, identical):** 512M ESP (`/boot1..4`; GRUB `mirroredBoots` installs to all four, removable path, so any disk boots), 50G member of the mdadm RAID 10 `os` (btrfs `@nixos` at `/`, ~100GB), the rest as a member of a **btrfs RAID 1** (data `raid1`, metadata `raid1c3`, `@data` at `/mnt/data`, ~1.9TB, zstd, noatime). Swap is zram.
- **Why split:** mdadm keeps `/` booting unattended with a dead disk (SSH/Tailscale stay up). btrfs's own RAID lets scrub *repair* bad blocks on `/mnt/data` — under mdadm btrfs could only detect them. Cost: after a reboot with a disk missing, `/mnt/data` doesn't mount until `mount -o degraded` by hand (deliberately not automatic); Docker and the restic jobs have `RequiresMountsFor=/mnt/data` so they never write to the OS array instead. A full data disk also can't fill `/`.
- **Disk alerts:** mdadm `PROGRAM` hook and hourly `btrfs-data-check` (device error counters, missing device, unmounted `/mnt/data`) both post to ntfy `home-smart`; smartd covers SMART. The desktop disks get a 180s SCSI command timeout (udev) so a long bad-sector retry doesn't kick them out of the array. Disk replacement: `hosts/main/README.md` §13.
- **Role:** Runs all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD) behind Caddy; originates restic backups.
- **Config:** `hosts/main/`

### `backupserver` (Pi backup target)

- **Hardware:** Raspberry Pi 4, no SD card — boots from a ~240GB SATA SSD in a USB adapter via EEPROM USB boot (GPT; needs bootloader ≥ 2020-10-28). OS SSD carries btrfs `@nixos` at `/` plus `@projects` at `/srv/projects` for side projects, and a 1G FAT32 `/boot` holding the whole boot chain (Pi firmware + U-Boot + extlinux + kernels — U-Boot can't read into btrfs subvolumes). Second external USB SSD on btrfs holds backup data (single drive now; btrfs RAID 1 conversion path reserved for when a second drive is added). The data drive is excluded from disko so no reinstall can format the restic repo.
- **Role:** Receives restic backups from `homeserver` over SSH/SFTP via Tailscale. Does not hold the restic password (encryption keys stay on main so a Pi compromise cannot decrypt backups).
- **Edge services:** Docker is enabled (data root `/srv/projects/docker` on the `@projects` subvolume — the data drive stays restic-only) for edge-replicated services at the Pi's location (slow uplink at that site — edge replicas avoid re-pulling over the link). Compose files live in `hosts/backup/compose/` (Fluidd for the Creality K1C printer).
- **Firewall:** trusts `tailscale0`, the IPv4 LAN (`192.168.128.0/23`) and IPv6 link-local (`fe80::/10`) on `end0`; drops everything else. The LAN rules match source addresses, not the interface, because `end0` also carries public IPv6. The link-local rule is limited to `end0` because Docker bridges also have link-local addresses.
- **Config:** `hosts/backup/`

### `workstation` (operator's daily driver)

- **Hardware:** Framework 16 with Ryzen 7000-series, 32GB RAM. NixOS has its own 2TB NVMe (addressed by `/dev/disk/by-id/`); Arch stays on the other NVMe. Separate ESPs: Limine on the NixOS ESP lists both systems and chainloads Arch's signed UKI, with Secure Boot on Arch's existing sbctl keys.
- **Storage:** LUKS-encrypted btrfs with `@nixos` at `/`, `@home`, `@log` at `/var/log`, `@games` at `/home/stef/Games`, and `@swap` holding the 40G hibernate swapfile.
- **Role:** Daily driver for the operator. Runs Hyprland (Wayland tiling compositor), Tailscale leaf, no service-hosting role. Holds the workstation-side operator key + host keys for managing main/Pi.
- **Out of scope here:** user dotfiles (Hyprland config, shell rc, etc.) — those stay under GNU Stow at `~/.dotfiles`. The exception is the dotfiles flake's `home/` modules (fonts, git, ssh, tmux, user session variables): the `dotfiles` input's `homeModules.default`, applied for `stef` by the Home Manager NixOS module. See `hosts/workstation/DOTFILES.md`.
- **Config:** `hosts/workstation/`

---

## Base OS: NixOS 26.05 (main + backup); nixos-unstable (workstation)

- `main` and `backup` pin `nixos-26.05`; `workstation` is rolling on `nixos-unstable` — the Hydra-built channel branch, so updates substitute from cache and rarely compile. Roll it forward with `nix flake update nixpkgs-unstable` then `nixos-rebuild switch`. Dry-run first (`nix build --dry-run .#nixosConfigurations.workstation.config.system.build.toplevel`): if a heavy package isn't cached yet, skip the update a day or two rather than compiling it; if a build lands broken, roll back a generation. Occasionally the channel HEAD ships a broken/uncached non-blocking package (Hyprland did on 2026-08-04) — the lock can sit a few evals behind HEAD until it clears. `stateVersion` stays at its install value regardless of channel. The spotify-adblock shim is pinned by version + hashes, not a flake input, so `nix flake update` never moves it — bump it separately with `nix-update --flake spotify-adblock --version=stable` (reads upstream's GitHub releases feed, rewrites the hashes).
- Declarative, fully reproducible
- Everything versioned in Git
- Tailscale for secure remote access
- Auto-upgrades daily (only after successful backup)
- First install is **nixos-anywhere + disko** for main and workstation; the Pi's OS SSD is flashed **directly on the workstation** (disko + `nixos-install --system`, aarch64 via binfmt) and then moved to the Pi — see [`DEPLOY.md`](DEPLOY.md). Disk layouts live in `hosts/<host>/disko.nix`; platform stubs in `hosts/<host>/hardware-configuration.nix` are committed hand-authored (not machine-generated).

---

## Architecture Overview

### Reverse Proxy

- **Caddy** — single entry point for all web services (ports 80/443)
- Subdomain-based routing (`seafile.DOMAIN`, `vaultwarden.DOMAIN`, etc.); `home.DOMAIN` is a static page linking to all of them
- HTTPS via real Let's Encrypt certs (wildcard) issued and renewed by NixOS `security.acme` on the host, using a DNS-01 ACME challenge through the deSEC DNS plugin. Caddy reads `cert.pem`/`key.pem` from `/var/lib/acme/${DOMAIN}/` via a read-only bind mount; a `caddy-reload-certs.service` restarts Caddy after each renewal. See `hosts/main/README.md` §6.

### Remote Access

- **Tailscale** — mesh VPN, all services accessible from anywhere via tailnet hostname
- Firewall trusts `tailscale0` interface

### Containerisation

- Docker + Docker Compose
- Docker data root: `/mnt/data/docker` (on the btrfs RAID 1 data array, not the OS array)
- Separate compose files per service
- Images pinned to exact versions (`caddy:2.11.9-alpine`, `postgres:18.6-alpine`, `seafile-mc:14.0.9`, …), never floating tags, so WUD compares real versions. Each service has a `wud.tag.include` label limiting WUD to that image's release format (e.g. `^\d+\.\d+\.\d+$$`), because unfiltered it picks up `-rc`, `.dev`, Windows and branch tags as "updates". Major bumps stay manual: Postgres needs a dump/restore (or `pg_upgrade`), Seafile a config check against its upgrade notes.

### Services (all as Docker containers)

| Service | Purpose |
|---|---|
| Seafile | File storage + desktop sync for up to 5 desktops with version history. MariaDB + Redis for performance. |
| Vaultwarden | Self-hosted Bitwarden-compatible password manager |
| Joplin Server | Self-hosted note sync (PostgreSQL backend) |
| Caddy | Reverse proxy with automatic HTTPS |
| Portainer | Container management web UI |
| WUD | Container update monitoring (notify-only, no auto-updates); built-in ntfy trigger to `home-updates`. WUD 9: login required (`admin` / `WUD_ADMIN_PASSWORD` from `.env`, bootstrapped on first start), SQLite store in the `wud_store` volume. |
| Home Assistant | Home automation at `homeassistant.DOMAIN`. Bridge network behind Caddy (no host networking), so LAN auto-discovery (mDNS/SSDP) doesn't work and integrations are added by IP. A one-shot `homeassistant-init` container (runs on each `compose up`) seeds `configuration.yaml` and writes Caddy trust (`use_x_forwarded_for`, `172.16.0.0/12`) into the **stable** slot of `/config/.storage/http`; without it HA answers 400 behind the proxy. Not via an `http:` block in `configuration.yaml`: since 2026.11 HA migrates that once into a *pending* config that must be confirmed in the UI within 5 minutes, else it reverts and restarts, and afterwards ignores the YAML. Config in the `homeassistant_config` volume, so the restic `docker-volumes` job covers it. |
| tsidp | Tailscale's OIDC identity provider, NixOS `services.tsidp` in `hosts/main/tsidp.nix` with the package from nixos-unstable (26.05's 0.0.12 is too old). Joins the tailnet itself as `idp.<tailnet>.ts.net` via tsnet with its own cert, not behind Caddy. Apps log in with Tailscale identities; every app keeps its local admin login as fallback. Needs `tag:tsidp` in the policy's `tagOwners` and a grant with app `tailscale.com/cap/tsidp` (`allow_admin_ui`, `allow_dcr`) for `autogroup:member`. State (node identity, signing key, registered OIDC clients) in `/var/lib/private/tsidp`, backed up by restic `tsidp-state`. Clients are registered once via `/register`; their secrets go into agenix. Grafana is the first client (`auth.generic_oauth` in `monitoring.nix`). |
| ntfy | Self-hosted push-notification server for operator alerts (tailnet-only) |
| Grafana (in-band iDRAC view) | NixOS services in `hosts/main/monitoring.nix`, not containers. No Cockpit (removed 2026-11-08): it duplicated SSH + Grafana, added a password login on the web, and its service/storage/user changes drift from the NixOS config. OS tasks go over SSH; the BMC event log lands in `journalctl -u ipmiseld`. `grafana.DOMAIN`: "Server health (R720)" home dashboard (iDRAC summary: power, temps, fans, PSUs, sensor states, SEL, ECC, SMART, mdadm/btrfs) + "Node Exporter Full". Prometheus (9092, 90d) scrapes node, ipmi (local `/dev/ipmi0`, runs as root for freeipmi) and smartctl exporters; alerts go Alertmanager → alertmanager-ntfy → ntfy topic from the rule's `topic` label (`home-infra`/`home-smart`). Power-on and console while the OS is down stay iDRAC-only. |
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
- **Wrong-target guard:** on the Pi `/mnt/backups` is an automount (30s device timeout) over a `root:root 0000` directory, and the repo dir `homeserver` exists only on the data drive. With the drive absent restic's SFTP access fails, so `initialize = true` can't create a repo on the OS SSD. `backup-drive-check.timer` alerts `home-infra` every 3h while it's unmounted (a never-appearing device leaves the mount unit inactive, so its `OnFailure` doesn't fire). Main's "Backup OK" ping is gated on `$SERVICE_RESULT` because `backupCleanupCommand` is ExecStopPost and also runs after failures.
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
- **`home-smart`** — `smartd` alerts from both hosts (main's RAID drives + the Pi's OS SSD; the Pi's data NVMe is not monitored yet, see TODO).
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
| `/etc/nixos/site.nix` | deSEC subdomain, ACME contact email and tailnet name. Nix attrset: `{ acmeDomain = "..."; acmeEmail = "..."; tailnet = "<name>.ts.net"; }`. Must be byte-identical on the workstation and main (`flake.lock` pins its hash). The backupserver doesn't read it. Threaded in as `siteConfig` via specialArgs; kept out of git deliberately. |
| `/etc/nixos/main-host-key` + `.pub` | Pre-generated SSH host keypair for main. Private gets shipped at install time via `nixos-anywhere --extra-files`; pubkey is the agenix recipient for main's secrets (referenced by `secrets/secrets.nix`). |
| `keys/operator.pub` (in repo) | Operator's SSH pubkey, baked into the `operator` user's `authorized_keys` on both hosts. Forks replace it with their own. |
| `keys/main-root.pub` (in repo) | Pubkey of main's root SSH key (for restic SFTP to Pi); ends up in Pi's `users.users.restic.openssh.authorizedKeys.keyFiles`. Matching private is encrypted in `secrets/main-root-sshkey.age`. |

**(2) Encrypted secrets in repo** — `secrets/*.age`, decrypted by agenix at activation time using main's SSH host key (and editable on the workstation by the operator using their own SSH key).

| Secret | Decrypted to | Used by |
|---|---|---|
| `secrets/restic.env.age` | `/run/agenix/restic-env` | restic services + monthly deep check |
| `secrets/acme-credentials.env.age` | `/run/agenix/acme-credentials` (owner `acme`) | `security.acme` for deSEC DNS-01 |
| `secrets/main-root-sshkey.age` | `/root/.ssh/id_ed25519` (symlink → `/run/agenix/main-root-sshkey`) | restic SFTP client identity |
| `secrets/tailscale-authkey.age` | `/run/agenix/tailscale-authkey` | `services.tailscale.authKeyFile` (first registration) |
| `secrets/grafana-secret-key.age` | `/run/agenix/grafana-secret-key` (owner `grafana`) | Grafana `security.secret_key` (encrypts its DB secrets) |
| `secrets/grafana-admin-password.age` | `/run/agenix/grafana-admin-password` (owner `grafana`) | Grafana `admin` login at `grafana.DOMAIN` |
| `secrets/operator-password.age` | `/run/agenix/operator-password` | `operator`'s `hashedPasswordFile` — sudo password (SSH stays key-only, root login off). `users.mutableUsers` stays `true`, so NixOS only applies it when the account is **created** (fresh install). On an existing host change it with `passwd`; re-encrypting the secret does nothing there. The 2026-11-07 mount-mode reinstall kept the old locked account, so it was set once by hand from the secret on 2026-11-08. |

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

`secrets/restic.env.age` (and every other `.age` file) is encrypted to **two recipients**: main's SSH host pubkey, and the operator's workstation pubkey (`keys/operator.pub`). Either private key is sufficient to decrypt — survival of one means survival of the backup.

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
| `flake.nix` | Pinned `nixos-26.05` nixpkgs (main/backup) + rolling `nixpkgs-unstable`, `home-manager` and `dotfiles` (workstation); `nixosConfigurations.main` / `.backup` / `.workstation` |
| `keys/*.pub` | Public keys distributed via git: operator SSH key + main's root key (restic SFTP identity) |
| `README.md` | Top-level index for both hosts |
| `CLAUDE.md` | This file — architecture + decisions |
| `DEPLOY.md` | First-install playbook (workstation prep → Pi → main → smoke tests) |
| `TODO.md` | Outstanding tasks |
| `modules/common.nix` | Shared baseline package set (git, vim, htop, curl, wget, usbutils). Imported by all three hosts. |
| `modules/alerts.nix` | Shared NixOS module: ntfy helper, smartd wiring, templated failure notifiers. Imported by both hosts. |
| `modules/spotify-adblock/package.nix` | Source build of the spotify-adblock LD_PRELOAD shim (not in nixpkgs). The workstation consumes it via `callPackage`; the flake exposes it as `packages.x86_64-linux.spotify-adblock` so `nix-update --flake spotify-adblock --version=stable` can bump it against upstream's GitHub releases. |
| `modules/blender-mcp/package.nix` | Official Blender Lab MCP server (not in nixpkgs), built from the upstream git tag. Flake output `packages.x86_64-linux.blender-mcp` for `nix-update`. Also ships the matching Blender add-on, which the workstation exposes as a System extension via `BLENDER_SYSTEM_EXTENSIONS`. |
| `hosts/main/configuration.nix` | Main host NixOS config (boot, RAID, Docker, SSH, Tailscale, firewall, auto-upgrade) |
| `hosts/main/disko.nix` | Declarative disk layout over the 4 disks (by-id): per disk an ESP, a member of the mdadm RAID 10 `os` (btrfs `@nixos` at `/`), and a member of the btrfs RAID 1 (`@data` at `/mnt/data`) |
| `hosts/main/monitoring.nix` | Prometheus + exporters (node, ipmi, smartctl), Alertmanager → ntfy, Grafana with provisioned dashboards, `ipmiseld`; firewall opens Grafana/AdGuard to Caddy on the `br-proxy` bridge only |
| `hosts/main/dashboards/server-health.nix` | The "Server health (R720)" Grafana dashboard as Nix, rendered to JSON by `monitoring.nix` |
| `hosts/main/tsidp.nix` | tsidp OIDC provider (`services.tsidp`, unstable package via the `pkgsUnstable` specialArg) |
| `hosts/main/storage.nix` | Boot and disk plumbing for that layout: GRUB `mirroredBoots` over the four ESPs, mdadm + btrfs RAID alerts, `RequiresMountsFor` gates, scrub, desktop-disk timeouts, zram |
| `hosts/main/hardware-configuration.nix` | Hand-authored platform stub for the R720: initrd modules (mpt3sas, raid10/md_mod, btrfs), kvm-intel, IPMI modules, Intel microcode |
| `hosts/main/Caddyfile` | Reverse proxy routes for all main-host services, plus the static homepage at `home.DOMAIN` |
| `hosts/main/homepage/index.html` | Static homepage linking to every service; Caddy's `templates` fills the domain in from `DOMAIN` |
| `hosts/main/.env.example` | Main-host environment variable template |
| `hosts/main/compose/*.yml` | Docker Compose files (one per service) |
| `hosts/main/README.md` | Main-host setup guide |
| `hosts/backup/configuration.nix` | Pi backup-host NixOS config (aarch64, btrfs, firewall, heartbeat-gated auto-upgrade, by-label `/mnt/backups` mount) |
| `hosts/backup/disko.nix` | Declarative disk layout, OS SSD only: 1G FAT32 `/boot` + btrfs `@nixos` at `/` and `@projects` at `/srv/projects`. Data drive intentionally absent. |
| `hosts/backup/disko-data.nix` | Standalone layout for the backup data drive (btrfs `backup-data`, `@homeserver` subvolume). Not flake-imported — manual disko run when provisioning a fresh drive only. |
| `hosts/backup/hardware-configuration.nix` | Hand-authored platform stub: USB-root initrd modules (xhci/uas/sd), mainline kernel pin (channel-cached — no kernel compiles on Pi or workstation), serial consoles, `installBootLoader` wrapper syncing Pi firmware + U-Boot into `/boot` |
| `hosts/backup/compose/fluidd.yml` | Fluidd (port 8080) + `k1c-proxy` (port 7125) + go2rtc (camera as MJPEG) for the Creality K1C |
| `hosts/backup/compose/k1c-proxy/` | Moonraker proxy that adds what the K1C stock API lacks (webcams, `server.database.list`); also relays the camera's WebRTC offer and corrects the answer for go2rtc |
| `hosts/backup/compose/go2rtc.yaml` | go2rtc stream `k1c`: WebRTC through `k1c-proxy`, transcoded to 720p MJPEG |
| `hosts/backup/compose/fluidd-nginx.conf.template` | Fluidd's nginx template plus the `/webcam/` page for the Fluidd iframe camera, and `/webcam/stream.mjpeg` and `/webcam/snapshot.jpg` to go2rtc (the rest of the go2rtc API stays closed) |
| `hosts/backup/README.md` | Pi backup-host setup guide |
| `hosts/workstation/configuration.nix` | Workstation NixOS config (Hyprland, PipeWire, greetd/tuigreet, Tailscale leaf, no service-hosting) |
| `hosts/workstation/disko.nix` | Declarative disk layout: ESP + LUKS-encrypted btrfs subvolumes on the NixOS NVMe, addressed by `/dev/disk/by-id/` |
| `hosts/workstation/hardware-configuration.nix` | Hand-authored platform stub: AMD CPU + NVMe initrd modules; Framework 16-specific bits come from `nixos-hardware.nixosModules.framework-16-7040-amd` |

---

## Outstanding work

See [TODO.md](TODO.md) for the full task list.
