# Main host (`homeserver`) — setup guide

Scope: the dual-Xeon main server running all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD, ntfy) behind Caddy. For the Raspberry Pi backup target, see [`hosts/backup/README.md`](../backup/README.md).

## Prerequisites

- Any Linux with SSH-as-root booted on the target (Ubuntu live USB, NixOS installer ISO, minimal cloud image — nixos-anywhere kexecs into the NixOS installer from whatever's running)
- 4 storage drives + 1 boot SSD installed
- A workstation with Nix installed, holding this repo clone
- Raspberry Pi backup host already set up (see [`hosts/backup/README.md`](../backup/README.md)) — needed for step 11
- A [Tailscale account](https://login.tailscale.com)

---

## 1. Install NixOS via nixos-anywhere + disko

Disk layout (GPT on `/dev/sda` + mdadm RAID 10 across `/dev/sdb..e`) is declared in [`hosts/main/disko.nix`](./disko.nix); the platform stub in [`hosts/main/hardware-configuration.nix`](./hardware-configuration.nix) is committed. Install is a single command from your workstation.

### 1.1 On the workstation: create `/etc/nixos/site.nix` and `/etc/nixos/operator.pub`

Two operator-managed files stay outside git but are pulled in by `flake.nix` as path inputs (so eval is pure — no `--impure` needed). Create both once per workstation that'll run `nixos-anywhere`:

```bash
# Per-site values (domain + ACME email)
sudo install -m 600 -o root -g root /dev/null /etc/nixos/site.nix
sudo tee /etc/nixos/site.nix >/dev/null <<'EOF'
{
  acmeDomain = "home.dedyn.io";       # your deSEC subdomain
  acmeEmail  = "you@example.com";     # Let's Encrypt contact
}
EOF

# SSH pubkey baked into operator's authorized_keys on both hosts
sudo cp ~/.ssh/id_ed25519.pub /etc/nixos/operator.pub
```

After creating or changing either file, run `nix flake lock` in the repo so `flake.lock` captures the updated narHash. (The lock change is part of your branch and commits normally.)

### 1.2 On the target: boot & confirm SSH

Boot the live medium, enable SSH-as-root if the image doesn't already, and note the IP (`ip a`). Verify drive enumeration matches disko.nix (`/dev/sda` boot SSD, `/dev/sdb..sde` RAID spinners):

```bash
lsblk
```

If device names differ, edit `hosts/main/disko.nix` on the workstation before installing. Disko wipes the listed disks — double-check.

### 1.3 On the workstation: run nixos-anywhere

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#main \
  --target-host root@<target-ip>
```

Nixos-anywhere kexecs into the NixOS installer, runs disko to partition + format, installs the flake closure, and reboots the target into NixOS. Expect ~10–20 minutes depending on network.

**Optional — ship operator-managed files at install time** with `--extra-files`:

```bash
mkdir -p /tmp/extra/etc/{acme,restic,nixos}
sudo cp /etc/acme/credentials.env /tmp/extra/etc/acme/    # if you already have one
# ...same for /etc/restic/env
nix run github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#main \
  --target-host root@<target-ip> \
  --extra-files /tmp/extra
```

(Note: `site.nix` and `operator.pub` are already baked into the flake closure via path inputs, so they don't need shipping separately.)

Otherwise, create these files on the target post-install (see §6.3, §11.1).

### 1.4 First boot

SSH back in via the tailnet hostname (once Tailscale is up — §3) or the LAN IP:

```bash
passwd operator            # set a real password
cat /proc/mdstat       # verify RAID 10 assembled healthy
```

---

## 2. Create data directories

```bash
sudo mkdir -p /mnt/data/{seafile,backups}
sudo chown operator:users /mnt/data/{seafile,backups}
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
cd ~
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
| `DOMAIN` | Your deSEC subdomain (e.g. `home.dedyn.io`). MUST match `site.acmeDomain` in `/etc/nixos/site.nix` (step 6). `homeserver.local` still works for LAN-only testing with internal CA certs. |
| `SEAFILE_MYSQL_ROOT_PASSWORD` | Strong random password |
| `SEAFILE_MYSQL_DB_PASSWORD` | Strong random password (Seafile DB user) |
| `SEAFILE_ADMIN_EMAIL` | Your admin email |
| `SEAFILE_ADMIN_PASSWORD` | Your Seafile admin password |
| `SEAFILE_REDIS_PASSWORD` | Strong random password |
| `JWT_PRIVATE_KEY` | Generate with `pwgen -s 40 1` (min 32 chars) |
| `VAULTWARDEN_ADMIN_TOKEN` | Generate with `openssl rand -hex 32` |
| `JOPLIN_DB_PASSWORD` | Strong random password |
| `JOPLIN_ADMIN_PASSWORD` | Joplin admin password the `joplin-init` container will set on first startup, replacing the upstream default `admin`. Save in your password manager — login at `https://joplin.${DOMAIN}` afterwards is `admin@localhost` + this. |
| `PORTAINER_ADMIN_PASSWORD_HASH` | **bcrypt hash** of your chosen Portainer admin password — Portainer reads it via `--admin-password` and skips the first-run init wizard. Generate once with `docker run --rm httpd:alpine htpasswd -nbB admin '<password>' \| cut -d: -f2`, save the plaintext in your password manager, paste the hash here. |

Generate passwords quickly:

```bash
openssl rand -hex 16
```

---

## 6. Set up real TLS certs via deSEC + ACME DNS-01

This gives every service a trusted Let's Encrypt cert (no "accept
this certificate?" prompts on devices). Issuance and renewal are
handled on the host by NixOS `security.acme`; Caddy just reads the
resulting cert files.

### 6.1 Sign up at deSEC

1. Create a free account at <https://desec.io>, confirm the email.
2. Under "DNS" → "My domains" → "Create new": register the subdomain
   you used as `DOMAIN` (e.g. `home.dedyn.io`).
3. Add a wildcard A record for your Tailscale IP:
   - Subname: `*`
   - Type: `A`
   - Value: `homeserver`'s Tailscale IP (from `tailscale ip` on the
     server).
   - TTL: 3600 is fine.

### 6.2 Generate a DNS API token

1. Go to <https://desec.io/tokens> → "Create new token".
2. Scope: restrict to "manage tokens" = off, "manage account" = off,
   perm tokens for DNS = yes. (The default "DNS write" scope is fine.)
3. Copy the token string — it's shown once.

### 6.3 Write the operator-managed files on main

Two files live outside Nix (not in git). Create them as root:

```bash
# Site-specific values read at nixos-rebuild time by configuration.nix
sudo install -m 600 -o root -g root /dev/null /etc/nixos/site.nix
sudo tee /etc/nixos/site.nix >/dev/null <<'EOF'
{
  acmeDomain = "home.dedyn.io";       # MUST match DOMAIN in hosts/main/.env
  acmeEmail  = "you@example.com";     # for Let's Encrypt expiry reminders
}
EOF

# DNS provider credentials read by the acme service at runtime
sudo mkdir -p /etc/acme
sudo install -m 600 -o root -g root /dev/null /etc/acme/credentials.env
sudo tee /etc/acme/credentials.env >/dev/null <<'EOF'
DESEC_TOKEN=<paste-your-desec-token-here>
EOF
```

### 6.4 Apply

```bash
sudo nixos-rebuild switch --flake ~/server_config#main
```

First request may take a minute (deSEC propagation + Let's Encrypt
validation). Verify:

```bash
systemctl status acme-<your-domain>.service      # should be "inactive (dead)" after success
ls /var/lib/acme/<your-domain>/                   # cert.pem, key.pem, fullchain.pem, chain.pem
```

Once the files exist, the Caddy container on the next compose-up (or
after the `caddy-reload-certs.service` fires on renewal) will serve
real certs.

---

## 7. Create the Docker network

All services share a single network for Caddy to reach them:

```bash
docker network create proxy
```

---

## 8. Deploy services

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

# Push notifications (operator alerts — ntfy). Bring this up BEFORE WUD
# so WUD's first notifications have somewhere to land.
docker compose --env-file .env -f compose/ntfy.yml up -d

# Update monitoring (posts container-update notifications to ntfy)
docker compose --env-file .env -f compose/wud.yml up -d
```

---

## 9. Verify services

Open these URLs (replace `DOMAIN` with your value from `.env`):

| Service | URL |
|---|---|
| Seafile | `https://seafile.DOMAIN` |
| Vaultwarden | `https://vaultwarden.DOMAIN` |
| Joplin | `https://joplin.DOMAIN` |
| Portainer | `https://portainer.DOMAIN` |
| WUD | `https://wud.DOMAIN` |
| ntfy | `https://ntfy.DOMAIN` |

With the deSEC ACME setup from step 6, certs are real Let's Encrypt
ones and no warning should appear. If you're on the `homeserver.local`
fallback instead, your browser will warn about Caddy's internal CA
on first visit — accept the cert to proceed.

---

## 10. Set up AdGuard Home (network-wide DNS + ad-blocking)

AdGuard Home runs as a NixOS service (enabled by the rebuild in step 6,
not a Docker container). It listens for DNS on port 53 across the
tailnet and LAN, and forwards non-blocked queries to Quad9 primary +
Cloudflare secondary over DoT.

### 10.1 Initial setup wizard

1. Visit `https://adguard.DOMAIN` (proxied by Caddy to the host's UI
   on `127.0.0.1:3000`).
2. Walk through the setup wizard:
   - **Admin interface**: leave defaults (already bound correctly by Nix).
   - **DNS listener**: leave at port 53 on all interfaces.
   - **Authentication**: create an admin username + password (the
     wizard stores them in AdGuard's state file; declared as
     `mutableSettings = true` so the UI owns user management).
3. Under **Filters → DNS blocklists**, pick a reasonable starting set
   — the AdGuard DNS filter is a fine default; add AdAway + EasyList
   for more aggressive blocking.

### 10.2 Point devices at AdGuard

Two complementary paths:

**Tailnet clients (phones/laptops on Tailscale):** open the Tailscale
admin console → **DNS** → set *Global nameservers* to
`homeserver`'s Tailscale IP (from `tailscale ip` on the server). All
tailnet peers will use AdGuard automatically.

**LAN devices (smart TV, guest phones, IoT not on the tailnet):** in
your router's DHCP config, hand out `homeserver`'s LAN IP as the
primary DNS server. Devices will pick it up on DHCP renewal.

### 10.3 Verify

On a device using AdGuard:

```bash
# Should show AdGuard as the resolver, and a blocked domain as 0.0.0.0
dig doubleclick.net @<homeserver-ip>
```

The AdGuard UI's **Query log** shows every query in real-time; great
for debugging when a site breaks ("what did it try to reach?").

### 10.4 Troubleshooting

- **AdGuard won't start / port 53 conflict** — another service on main
  is bound to 53. Unlikely with our config (NetworkManager doesn't
  listen on 53 by default), but check `sudo ss -tulpn | grep :53`.
- **A site stops working after enabling a filter** — check the AdGuard
  query log for blocked domains on that site; whitelist via the UI.
- **Tailscale peers still using old DNS** — they cache the config.
  Toggle Tailscale off/on once; or run `tailscale set --accept-dns=true`.

---

## 11. Set up backups

Prerequisite: the `backupserver` Pi is already running and reachable
via Tailscale (see [`hosts/backup/README.md`](../backup/README.md)).

### 11.1 Write the env file

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

### 11.2 Give root an SSH key for the Pi

The backup runs as root, so root needs an SSH key the Pi accepts:

```bash
sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""
sudo cat /root/.ssh/id_ed25519.pub
# paste this pubkey into hosts/backup/configuration.nix under
# users.users.restic.openssh.authorizedKeys.keys, then rebuild the Pi
```

### 11.3 Apply

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

On success each job sends a **silent** ntfy notification (Priority 1) to
the `home-backup` topic. On failure, a templated `ntfy-backup-failure@`
service fires via `OnFailure` and sends an **audible** alert with the
unit name, so you can `journalctl -u restic-backups-<tag>.service` for
details.

---

## 12. Connect your devices

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
3. Subscribe to all four operator topics:
   - `home-backup` — restic backup success (silent) and failure (audible).
   - `home-smart` — SMART disk alerts from both hosts.
   - `home-updates` — WUD container-update notifications.
   - `home-infra` — Pi host-health alerts (nixos-upgrade / mount / tailscaled failures).
   Each topic can be muted independently in the app.
4. No login or token is required — the ntfy server is reachable only
   over Tailscale, so tailnet membership is the authentication.

---

## 13. Updates

### How updates work

- **Docker containers:** WUD (What's Up Docker) monitors all containers and
  shows available updates in its dashboard at `https://wud.DOMAIN`. New
  updates also push a notification to ntfy's `home-updates` topic so you
  don't have to keep the dashboard open. WUD does not auto-update — you
  decide when to pull new images.
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
