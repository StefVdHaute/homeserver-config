# Main host (`homeserver`) — setup guide

Scope: the dual-Xeon main server running all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD) behind Caddy. For the Raspberry Pi backup target, see [`hosts/backup/README.md`](../backup/README.md).

## Prerequisites

- NixOS 25.11 live USB booted on the server
- 4 storage drives + 1 boot SSD installed
- Raspberry Pi backup host already set up (see [`hosts/backup/README.md`](../backup/README.md)) — needed for step 9
- A [Tailscale account](https://login.tailscale.com)

---

## 1. Install NixOS

### 1.1 Partition and create RAID

From the live installer, confirm your drive layout:

```bash
lsblk
```

Edit `raid-setup.sh` if your device names differ from `/dev/sda–sde`, then run:

```bash
bash raid-setup.sh
```

### 1.2 Mount and install

```bash
mount /dev/disk/by-label/nixos-root /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/nixos-boot /mnt/boot
mkdir -p /mnt/mnt/data
mount /dev/disk/by-label/data /mnt/mnt/data
swapon /dev/disk/by-label/nixos-swap
```

Generate the per-host hardware config (stays local to the installed system, not in git):

```bash
nixos-generate-config --root /mnt --no-filesystems
# Move it into this repo so the flake can find it:
cp /mnt/etc/nixos/hardware-configuration.nix /mnt/root/server_config/hosts/main/
```

Install via the flake and reboot:

```bash
nixos-install --flake /mnt/root/server_config#main
reboot
```

### 1.3 First boot

```bash
# Set your password
passwd stef

# Verify RAID is healthy
cat /proc/mdstat
```

---

## 2. Create data directories

```bash
sudo mkdir -p /mnt/data/{seafile,backups}
sudo chown stef:users /mnt/data/{seafile,backups}
```

---

## 3. Set up Tailscale

```bash
sudo tailscale up
```

Follow the link to authenticate. Your server will be accessible at
`homeserver.<your-tailnet>.ts.net` from any device with Tailscale installed.

To use Tailscale MagicDNS as your domain, update `DOMAIN` in `.env`
(see step 5).

---

## 4. Clone the repo

```bash
cd /home/stef
git clone <your-repo-url> server_config
cd server_config
```

---

## 5. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and fill in all values:

| Variable | What to set |
|---|---|
| `DOMAIN` | Your tailnet hostname (e.g. `homeserver.tail1234.ts.net`) or `homeserver.local` for LAN-only |
| `SEAFILE_MYSQL_ROOT_PASSWORD` | Strong random password |
| `SEAFILE_MYSQL_DB_PASSWORD` | Strong random password (Seafile DB user) |
| `SEAFILE_ADMIN_EMAIL` | Your admin email |
| `SEAFILE_ADMIN_PASSWORD` | Your Seafile admin password |
| `SEAFILE_REDIS_PASSWORD` | Strong random password |
| `JWT_PRIVATE_KEY` | Generate with `pwgen -s 40 1` (min 32 chars) |
| `VAULTWARDEN_ADMIN_TOKEN` | Generate with `openssl rand -hex 32` |
| `JOPLIN_DB_PASSWORD` | Strong random password |

Generate passwords quickly:

```bash
openssl rand -hex 16
```

---

## 6. Create the Docker network

All services share a single network for Caddy to reach them:

```bash
docker network create proxy
```

---

## 7. Deploy services

Start Caddy first, then the rest in any order:

```bash
cd ~/server_config/hosts/main

# Reverse proxy (must be first)
docker compose --env-file .env -f compose/caddy.yml up -d

# Core services
docker compose --env-file .env -f compose/seafile.yml up -d
docker compose --env-file .env -f compose/vaultwarden.yml up -d
docker compose --env-file .env -f compose/joplin.yml up -d
docker compose --env-file .env -f compose/portainer.yml up -d

# Update monitoring
docker compose --env-file .env -f compose/wud.yml up -d

# Push notifications (operator alerts — ntfy)
docker compose --env-file .env -f compose/ntfy.yml up -d
```

---

## 8. Verify services

Open these URLs (replace `DOMAIN` with your value from `.env`):

| Service | URL |
|---|---|
| Seafile | `https://seafile.DOMAIN` |
| Vaultwarden | `https://vaultwarden.DOMAIN` |
| Joplin | `https://joplin.DOMAIN` |
| Portainer | `https://portainer.DOMAIN` |
| WUD | `https://wud.DOMAIN` |
| ntfy | `https://ntfy.DOMAIN` |

If using `homeserver.local`, your browser will warn about Caddy's
internal CA certificate on first visit — this is expected. Accept
the certificate to proceed.

---

## 9. Set up backups

Prerequisite: the `backupserver` Pi is already running and reachable
via Tailscale (see [`hosts/backup/README.md`](../backup/README.md)).

### 9.1 Write the env file

One file holds both the repository URL and the password, read by the
restic systemd service at runtime:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/restic/env
sudo tee /etc/restic/env >/dev/null <<EOF
RESTIC_REPOSITORY=sftp:restic@backupserver.<your-tailnet>.ts.net:/mnt/backups/homeserver
RESTIC_PASSWORD=$(openssl rand -hex 32)
EOF
```

Save the `RESTIC_PASSWORD` value somewhere safe (e.g. Vaultwarden) —
restores need it. `cat /etc/restic/env` to recover it once.

### 9.2 Give root an SSH key for the Pi

The backup runs as root, so root needs an SSH key the Pi accepts:

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
sudo cat /root/.ssh/id_ed25519.pub
# paste this pubkey into hosts/backup/configuration.nix under
# users.users.restic.openssh.authorizedKeys.keys, then rebuild the Pi
```

### 9.3 Apply

```bash
sudo nixos-rebuild switch --flake ~/server_config#main
```

The two timers — `restic-backups-docker-volumes.timer` and
`restic-backups-seafile-data.timer` — fire daily at 03:00. Verify:

```bash
systemctl list-timers 'restic-backups-*'

# Run once manually to initialise the repo and confirm end-to-end
sudo systemctl start restic-backups-docker-volumes.service
sudo journalctl -u restic-backups-docker-volumes.service -f
```

---

## 10. Connect your devices

### Seafile desktop sync

1. Install the [Seafile desktop client](https://www.seafile.com/en/download/)
2. Server URL: `https://seafile.DOMAIN`
3. Log in with your admin credentials
4. Choose libraries to sync

### Vaultwarden

1. Install Bitwarden on your devices
2. Before logging in, tap the gear icon and set the server URL to
   `https://vaultwarden.DOMAIN`
3. Create an account or log in

### Joplin

1. In Joplin, go to Settings > Synchronisation
2. Set target to "Joplin Server"
3. Server URL: `https://joplin.DOMAIN`
4. Default admin login: `admin@localhost` / `admin` (change immediately)

### Seafile server-only files

Files uploaded via the web UI are stored on the server without
syncing to your desktop. Create a library and don't sync it to
any client — use this for large archives, media, or anything
you don't need locally.

### ntfy (push notifications for operator alerts)

1. Install the ntfy app ([iOS](https://apps.apple.com/us/app/ntfy/id1625396347) / [Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy)).
2. Add your server in the app: tap the "+" button → "Subscribe to topic",
   enter the topic name (e.g. `home-backup`), then use the three-dot menu
   to set the server to `https://ntfy.DOMAIN`.
3. Subscribe to all three operator topics:
   - `home-backup` — restic backup success (silent) and failure (audible).
   - `home-smart` — SMART disk alerts from both hosts.
   - `home-updates` — WUD container-update notifications.
   Each topic can be muted independently in the app.
4. No login or token is required — the ntfy server is reachable only
   over Tailscale, so tailnet membership is the authentication.

---

## 11. Updates

### How updates work

- **Docker containers:** WUD (What's Up Docker) monitors all containers and
  shows available updates in its dashboard at `https://wud.DOMAIN`. It does
  not auto-update — you decide when to pull new images.
- **NixOS:** Auto-upgrades run daily at 04:30, but only after a successful
  Restic backup. If the backup fails, the upgrade is skipped.
- **Major versions:** All images are pinned to their current major version
  (e.g. `joplin/server:3`). Patch updates are safe to pull. Major version
  bumps (e.g. 3 -> 4) require changing the tag in the compose file after
  checking release notes.

### Daily schedule

```text
03:00  Restic backup
04:30  NixOS upgrade (only if backup succeeded)
```

### Manually updating a container

After WUD shows an update is available:

```bash
cd ~/server_config/hosts/main
docker compose --env-file .env -f compose/<service>.yml pull
docker compose --env-file .env -f compose/<service>.yml up -d
```

### Rolling back NixOS

If an upgrade causes issues, boot into a previous generation from the
bootloader, or run:

```bash
sudo nixos-rebuild switch --rollback
```
