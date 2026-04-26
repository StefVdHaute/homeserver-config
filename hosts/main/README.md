# Main host (`homeserver`) — setup guide

Scope: the dual-Xeon main server running all user-facing services (Seafile, Vaultwarden, Joplin, Portainer, WUD, ntfy) behind Caddy. For the Raspberry Pi backup target, see [`hosts/backup/README.md`](../backup/README.md).

## Prerequisites

- Any Linux with SSH-as-root booted on the target (Ubuntu live USB, NixOS installer ISO, minimal cloud image — nixos-anywhere kexecs into the NixOS installer from whatever's running)
- 4 storage drives + 1 boot SSD installed
- A workstation with Nix installed, holding this repo clone
- Raspberry Pi backup host already set up (see [`hosts/backup/README.md`](../backup/README.md)) — needed for §10 (verify backups)
- A [Tailscale account](https://login.tailscale.com)

---

## 1. Install NixOS via nixos-anywhere + disko

Disk layout (GPT on `/dev/sda` + mdadm RAID 10 across `/dev/sdb..e`) is declared in [`hosts/main/disko.nix`](./disko.nix); the platform stub in [`hosts/main/hardware-configuration.nix`](./hardware-configuration.nix) is committed. Install is a single command from your workstation, plus a one-time setup of operator-managed files + agenix-encrypted secrets.

### 1.1 Workstation prep — operator-managed files

These four files live outside git and are pulled in as flake path inputs (pure eval throughout). Create once per workstation:

```bash
sudo install -d -m 0755 /etc/nixos

# Per-site values (domain + ACME email)
sudo install -m 0644 -o root -g root /dev/null /etc/nixos/site.nix
sudo tee /etc/nixos/site.nix >/dev/null <<'EOF'
{
  acmeDomain = "home.dedyn.io";       # your deSEC subdomain
  acmeEmail  = "you@example.com";     # Let's Encrypt contact
}
EOF

# Operator pubkey — baked into both hosts' `operator` user authorized_keys
sudo cp ~/.ssh/id_ed25519.pub /etc/nixos/operator.pub

# Main's SSH host keypair — private gets shipped at install via
# nixos-anywhere --extra-files; pubkey is the agenix recipient for
# main's secrets.
sudo ssh-keygen -t ed25519 -N "" -f /etc/nixos/main-host-key -C "main@homeserver"

# Main's root SSH keypair — for restic SFTP into Pi. Private is
# encrypted into secrets/main-root-sshkey.age; pubkey is a flake input
# baked into Pi's restic authorized_keys.
sudo ssh-keygen -t ed25519 -N "" -f /etc/nixos/main-root-key -C "main-root@homeserver"
```

### 1.2 Encrypt the agenix secrets

Generate a deSEC API token at <https://desec.io/tokens> and a reusable Tailscale auth key in the Tailscale admin (untick "Ephemeral", leave "Pre-approved" unticked so devices wait for manual approval). Then encrypt four secrets — each opens `$EDITOR`; type/paste content, save, exit.

```bash
cd ~/server_config/secrets
AGENIX="nix run --extra-experimental-features 'nix-command flakes' github:ryantm/agenix --"

# Restic repo URL + encryption password
$AGENIX -i ~/.ssh/id_ed25519 -e restic.env.age
# In editor:
#   RESTIC_REPOSITORY=sftp:restic@backupserver.<your-tailnet>.ts.net:/mnt/backups/homeserver
#   RESTIC_PASSWORD=<openssl rand -hex 32 — SAVE in your password manager off-site>

# deSEC API token
$AGENIX -i ~/.ssh/id_ed25519 -e acme-credentials.env.age
# In editor:
#   DESEC_TOKEN=<your-desec-token>

# Main's root SSH private key (paste the whole file including BEGIN/END)
sudo cat /etc/nixos/main-root-key
$AGENIX -i ~/.ssh/id_ed25519 -e main-root-sshkey.age

# Tailscale auth key (just the tskey-auth-... string)
$AGENIX -i ~/.ssh/id_ed25519 -e tailscale-authkey.age
```

Lock the new path inputs into `flake.lock`:

```bash
cd ~/server_config && nix flake lock
```

### 1.3 Target prep — boot SSH-capable image

Boot any Linux with SSH-as-root on the target. Verify disko's expected disk layout (`/dev/sda` boot SSD, `/dev/sdb..sde` RAID spinners) — disko will WIPE every disk listed:

```bash
lsblk
```

If device names differ, edit `hosts/main/disko.nix` on the workstation before installing.

### 1.4 Stage main's host key for shipping

agenix on main decrypts using `/etc/ssh/ssh_host_ed25519_key`. Ship the pre-generated key so the on-disk key matches the agenix recipient:

```bash
mkdir -p /tmp/main-extra/etc/ssh
sudo install -m 0600 -o root -g root /etc/nixos/main-host-key /tmp/main-extra/etc/ssh/ssh_host_ed25519_key
sudo install -m 0644 -o root -g root /etc/nixos/main-host-key.pub /tmp/main-extra/etc/ssh/ssh_host_ed25519_key.pub
```

### 1.5 Run nixos-anywhere

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#main \
  --target-host root@<main-lan-ip> \
  --extra-files /tmp/main-extra

rm -rf /tmp/main-extra        # cleanup post-install
```

Nixos-anywhere kexecs into the NixOS installer, runs disko to partition + format, installs the flake closure with main's pre-generated host key in place, and reboots. Expect ~15–20 minutes depending on network.

### 1.6 First boot

```bash
ssh operator@<main-lan-ip>
sudo passwd operator
cat /proc/mdstat              # verify RAID 10 assembled healthy
ls /run/agenix/               # restic-env, acme-credentials, main-root-sshkey, tailscale-authkey
```

Tailscale registers itself on first boot (via the agenix-decrypted auth key) and waits in the Tailscale admin for your manual approval click.

---

## 2. Approve main on the tailnet

Visit the [Tailscale admin](https://login.tailscale.com/admin/machines), find `homeserver` waiting for approval (because the auth key is reusable but not pre-approved), click approve. Subsequent SSH:

```bash
ssh operator@homeserver.<your-tailnet>.ts.net
```

`/mnt/data/{seafile,backups}` are pre-created with `operator:users` ownership by `systemd.tmpfiles`.

---

## 3. Clone the repo on main

The flake auto-upgrade pulls from GitHub directly, but the Compose stack needs the repo locally for the `.env` file + compose YAMLs:

```bash
cd ~ && git clone <your-repo-url> server_config && cd server_config
```

---

## 4. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and fill in all values:

| Variable | What to set |
|---|---|
| `DOMAIN` | Your deSEC subdomain (e.g. `home.dedyn.io`). MUST match `site.acmeDomain` in `/etc/nixos/site.nix` (§1.1). `homeserver.local` still works for LAN-only testing with internal CA certs. |
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

## 5. TLS certs via deSEC + ACME DNS-01

NixOS `security.acme` issues + renews a wildcard cert for `*.${DOMAIN}`. The DNS-01 challenge runs through deSEC's API; the token is already encrypted in `secrets/acme-credentials.env.age` (decrypted at activation by agenix), so no file creation is needed on main.

### 5.1 deSEC account + DNS records

1. Create a free account at <https://desec.io>, confirm the email.
2. Under "DNS" → "My domains" → "Create new": register the subdomain matching `site.acmeDomain` (e.g. `home.dedyn.io`).
3. Add a wildcard A record pointing at `homeserver`'s Tailscale IP:
   - Subname: `*`, Type: `A`, Value: `tailscale ip` output on main, TTL: 3600.

### 5.2 Verify ACME issuance

The first cert issuance triggered automatically when nixos-rebuild ran in §1.5; deSEC propagation + Let's Encrypt validation takes 2–5 min. Verify:

```bash
sudo journalctl -u acme-$(sudo nix eval --raw -f /etc/nixos/site.nix acmeDomain).service -f
ls /var/lib/acme/<your-domain>/      # cert.pem, key.pem, fullchain.pem, chain.pem
```

Caddy picks up the cert files when started in §6. `caddy-reload-certs.service` restarts Caddy on each renewal — first nixos-rebuild logged it failed because Caddy isn't up yet; that resolves after §6.

---

## 6. Create the Docker network

All services share a single network for Caddy to reach them:

```bash
docker network create proxy
```

---

## 7. Deploy services

Caddy first (other services depend on the `proxy` network it uses), then re-run nixos-rebuild so `caddy-reload-certs.service` finds the container, then the rest:

```bash
cd ~/server_config/hosts/main

# Caddy first
docker compose --env-file .env -f compose/caddy.yml up -d

# Re-rebuild so caddy-reload-certs stops failing
sudo nixos-rebuild switch --flake ~/server_config#main

# Rest of the stack (joplin-init runs once after joplin's healthcheck
# passes and rotates admin/admin → JOPLIN_ADMIN_PASSWORD).
for svc in seafile vaultwarden joplin portainer ntfy wud; do
  docker compose --env-file .env -f compose/$svc.yml up -d
done
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

With the deSEC ACME setup from §5, certs are real Let's Encrypt ones and no browser warning appears. If you're on the `homeserver.local` LAN-only fallback, browsers will warn about Caddy's internal CA on first visit — accept the cert.

---

## 9. AdGuard Home (network-wide DNS + ad-blocking)

AdGuard Home runs as a NixOS service (already enabled by §1.5's nixos-rebuild). DNS on `0.0.0.0:53` (tailnet + LAN reachable), forwards to Quad9 + Cloudflare over DoT.

### 9.1 Initial setup wizard

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

### 9.2 Point devices at AdGuard

Two complementary paths:

**Tailnet clients (phones/laptops on Tailscale):** open the Tailscale
admin console → **DNS** → set *Global nameservers* to
`homeserver`'s Tailscale IP (from `tailscale ip` on the server). All
tailnet peers will use AdGuard automatically.

**LAN devices (smart TV, guest phones, IoT not on the tailnet):** in
your router's DHCP config, hand out `homeserver`'s LAN IP as the
primary DNS server. Devices will pick it up on DHCP renewal.

### 9.3 Verify

On a device using AdGuard:

```bash
# Should show AdGuard as the resolver, and a blocked domain as 0.0.0.0
dig doubleclick.net @<homeserver-ip>
```

The AdGuard UI's **Query log** shows every query in real-time; great
for debugging when a site breaks ("what did it try to reach?").

### 9.4 Troubleshooting

- **AdGuard won't start / port 53 conflict** — another service on main
  is bound to 53. Unlikely with our config (NetworkManager doesn't
  listen on 53 by default), but check `sudo ss -tulpn | grep :53`.
- **A site stops working after enabling a filter** — check the AdGuard
  query log for blocked domains on that site; whitelist via the UI.
- **Tailscale peers still using old DNS** — they cache the config.
  Toggle Tailscale off/on once; or run `tailscale set --accept-dns=true`.

---

## 10. Verify backups

Prerequisite: the `backupserver` Pi is already running and reachable via Tailscale (see [`hosts/backup/README.md`](../backup/README.md)). All backup wiring (restic env, main's root SSH key, ACME credentials) is already in place via agenix from §1.2.

The three jobs (`restic-backups-docker-volumes.timer`, `restic-backups-seafile-data.timer`, `restic-backups-adguard-state.timer`) fire daily at 03:00 + 30m randomized delay. Trigger the first run manually:

```bash
systemctl list-timers 'restic-backups-*'

sudo systemctl start restic-backups-docker-volumes.service
sudo journalctl -u restic-backups-docker-volumes.service -f
# Initial seeding takes ~30–60 min over SFTP/Tailscale
```

Verify the snapshot landed on the Pi:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net \
  ls /mnt/backups/homeserver/snapshots
```

Then trigger the other two jobs:

```bash
sudo systemctl start restic-backups-seafile-data.service
sudo systemctl start restic-backups-adguard-state.service
```

On success each job sends a **silent** ntfy ping (Priority 1) to `home-backup`. On failure, the templated `ntfy-backup-failure@.service` fires via `OnFailure` with an **audible** alert; `journalctl -u restic-backups-<tag>.service` for details.

**Off-site key escrow:** when you generated `RESTIC_PASSWORD` in §1.2, you saved it to your password manager. Verify that's still true now — without it, a complete loss of both main and your workstation = unrecoverable backups. See `CLAUDE.md` § Disaster recovery.

---

## 11. Connect your devices

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
4. Admin login: `admin@localhost` + the `JOPLIN_ADMIN_PASSWORD` you set in `.env` (the `joplin-init` container rotated the upstream default at first compose-up).

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

## 12. Updates

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
