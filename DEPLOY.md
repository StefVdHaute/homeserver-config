# DEPLOY.md — First-install playbook

Step-by-step procedure to bring both hosts up from nothing, written for an operator with no prior exposure to this repo. Architecture context: [`CLAUDE.md`](CLAUDE.md). Ongoing operations (rolling patches, etc.): each host's `README.md` under `hosts/`.

End-to-end walltime: **~3–4 h** for a first-timer, **~1.5 h** once you've done it before. Most of the wall-clock is nix closure builds (aarch64 cross-build for Pi) and ACME propagation, not operator attention.

---

## 1. Prerequisites

### 1.1 Hardware

- **Main:** dual-Xeon-ish, DDR3, 32–48 GB RAM. 250 GB boot SSD on `/dev/sda`. Four 1 TB spinners on `/dev/sdb..e` (mdadm RAID 10 + btrfs `@data` at `/mnt/data`).
- **Pi:** Raspberry Pi 4 (any RAM variant) with EEPROM bootloader ≥ 2020-10-28 (GPT + USB boot; any board bought 2021+ qualifies — older ones need one boot of the Raspberry Pi Imager "Bootloader → USB Boot" utility SD). ~240 GB SATA SSD in a USB adapter as OS drive (flashed on the workstation, no SD needed). Second external USB SSD/HDD for backup data. Both USB bridges need UAS/SAT SMART passthrough (verify with `sudo smartctl -a -d sat <dev>` once booted — opaque enclosures have no software workaround; replace).
- **Workstation:** Linux with Nix installed, LAN reachable to both targets.

### 1.2 Accounts

- **deSEC** — free dynamic DNS with API for ACME DNS-01. Sign up at <https://desec.io>, register your subdomain (e.g. `home.dedyn.io`), generate API token at <https://desec.io/tokens>.
- **Tailscale** — sign up at <https://tailscale.com>. Generate one **reusable** auth key (untick "Ephemeral", leave "Pre-approved" off so devices wait for manual approval).

---

## 2. Workstation setup (≈ 30 min)

### 2.1 Nix daemon + aarch64 emulation

```bash
sudo systemctl enable --now nix-daemon

# aarch64 emulation for cross-building the Pi closure (Arch package
# names; adapt: Debian/Ubuntu have qemu-user-static + binfmt-support):
sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt.service
sudo tee -a /etc/nix/nix.conf <<< 'extra-platforms = aarch64-linux'
sudo systemctl restart nix-daemon

# Verify binfmt points at the STATIC qemu binary
grep interpreter /proc/sys/fs/binfmt_misc/qemu-aarch64
# expected: interpreter /usr/bin/qemu-aarch64-static
```

### 2.2 Clone the repo

```bash
cd ~ && git clone <repo-url> server_config && cd server_config
```

### 2.3 Operator-managed files in `/etc/nixos/`

Four files, pulled in as flake path inputs (pure eval throughout, content captured into `flake.lock`):

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

# Operator pubkey — into both hosts' `operator` user authorized_keys
sudo cp ~/.ssh/id_ed25519.pub /etc/nixos/operator.pub

# Main's SSH host keypair — private ships at install via --extra-files;
# pubkey is the agenix recipient for main's secrets.
sudo ssh-keygen -t ed25519 -N "" -f /etc/nixos/main-host-key -C "main@homeserver"

# Main's root SSH keypair — for restic SFTP into Pi. Private gets
# encrypted into secrets/main-root-sshkey.age; pubkey is a flake input
# baked into Pi's restic authorized_keys.
sudo ssh-keygen -t ed25519 -N "" -f /etc/nixos/main-root-key -C "main-root@homeserver"
```

### 2.4 Encrypt the four agenix secrets

Each opens `$EDITOR` — paste content on a single line where applicable, save, exit.

```bash
cd ~/server_config/secrets
AGENIX="nix run --extra-experimental-features 'nix-command flakes' github:ryantm/agenix --"

# Restic repo URL + encryption password
$AGENIX -i ~/.ssh/id_ed25519 -e restic.env.age
# In editor:
#   RESTIC_REPOSITORY=sftp:restic@backupserver.<your-tailnet>.ts.net:/mnt/backups/homeserver
#   RESTIC_PASSWORD=<openssl rand -hex 32 — SAVE in your password manager OFF-SITE>

# deSEC API token
$AGENIX -i ~/.ssh/id_ed25519 -e acme-credentials.env.age
# In editor:
#   DESEC_TOKEN=<your-desec-token>

# Main's root SSH private (paste BEGIN through END including trailing newline)
sudo cat /etc/nixos/main-root-key
$AGENIX -i ~/.ssh/id_ed25519 -e main-root-sshkey.age

# Tailscale auth key (just the tskey-auth-... string, single line)
$AGENIX -i ~/.ssh/id_ed25519 -e tailscale-authkey.age
```

### 2.5 Lock + verify

```bash
cd ~/server_config && nix flake lock

nix build .#nixosConfigurations.main.config.system.build.toplevel --no-link --dry-run
nix build .#nixosConfigurations.backup.config.system.build.toplevel --no-link --dry-run
# Both should exit 0; "Git tree dirty" warning is fine.
```

---

## 3. Order of operations

**Pi first, main second.** Reasons:

- Main's restic backups push to Pi at 03:00; main's `nixos-upgrade.service` `requires` the restic units, so main needs Pi reachable when its first daily upgrade runs.
- Both configs are now self-contained at install: main's secrets (and root SSH key for SFTP) come via agenix; Pi's `restic` user authorizes main's pubkey via the `mainRootPubkey` flake input. **No paste roundtrip** required after either install.

---

## 4. Pi install (≈ 30–45 min)

The Pi's OS SSD is flashed **directly on the workstation** — plug the drive (in its USB adapter) into the workstation; no throwaway SD, no nixos-anywhere. The Pi 4 boots it via EEPROM USB boot.

### 4.1 Build + flash the OS SSD (≈ 15–25 min)

Confirm the drive's by-id path matches `device =` in `hosts/backup/disko.nix` (with two USB drives on the Pi, `/dev/sdX` is a race — by-id is authoritative):

```bash
ls -l /dev/disk/by-id/ | grep usb
```

Build the closure, then format + install. Disko touches **only** the OS SSD — the backup data drive is deliberately not in `disko.nix`, so reinstalls can never wipe the restic repo:

```bash
cd ~/server_config
nix build .#nixosConfigurations.backup.config.system.build.toplevel -o /tmp/backup-toplevel

sudo nix run --extra-experimental-features 'nix-command flakes' \
  github:nix-community/disko -- --mode destroy,format,mount --flake .#backup

sudo nix shell --extra-experimental-features 'nix-command flakes' \
  nixpkgs#nixos-install-tools -c \
  nixos-install --system "$(readlink -f /tmp/backup-toplevel)" \
  --root /mnt --no-root-passwd --no-channel-copy
```

The install's bootloader step (aarch64, runs under qemu binfmt from §2.1) populates `/boot` with extlinux + kernels **and** the Pi firmware/U-Boot chain — see the `installBootLoader` wrapper in `hosts/backup/hardware-configuration.nix`.

Set the operator password while the disk is still mounted (first-boot SSH is key-only and `sudo` needs a password):

```bash
sudo nix shell --extra-experimental-features 'nix-command flakes' \
  nixpkgs#nixos-install-tools -c \
  nixos-enter --root /mnt -- passwd operator
```

### 4.2 Seed operator files onto the SSD

```bash
sudo install -d -m 0755 /mnt/etc/tailscale /mnt/etc/ntfy

cd ~/server_config/secrets
$AGENIX -i ~/.ssh/id_ed25519 -d tailscale-authkey.age | sudo tee /mnt/etc/tailscale/authkey >/dev/null
sudo chmod 0600 /mnt/etc/tailscale/authkey

sudo tee /mnt/etc/ntfy/url >/dev/null <<< "https://ntfy.<your-domain>"
sudo chmod 0600 /mnt/etc/ntfy/url

cd ~/server_config && sudo umount -R /mnt
```

Tailscale auth keys expire after ≤ 90 days. If the one in `secrets/tailscale-authkey.age` is stale, generate a fresh reusable key in the [Tailscale admin](https://login.tailscale.com/admin/settings/keys), re-encrypt it (`$AGENIX -e tailscale-authkey.age`), and re-run the seed step.

### 4.3 Boot the Pi from USB

Unplug the SSD from the workstation, plug both drives into the Pi's USB 3 (blue) ports, **no SD card inserted**, power on. The EEPROM's default boot order falls through to USB when no SD is present.

- Board older than ~2021: flash the Raspberry Pi Imager "Misc utility images → Bootloader → USB Boot" image to any SD, boot it once (steady green LED = done), then retry.
- Optional hardening: set `BOOT_ORDER=0xf14` (USB first) so a forgotten SD can never shadow the SSD.

### 4.4 Approve on tailnet, SSH (≈ 5 min)

The Pi tailscaled reads the seeded auth key on first boot and registers itself. Approve `backupserver` in the [Tailscale admin](https://login.tailscale.com/admin/machines), then:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net
```

### 4.5 Provision the backup data drive (first install only)

The data drive is formatted **manually, on the Pi** — never as part of an OS install:

```bash
# On the Pi:
git clone <your-repo-url> server_config && cd server_config/hosts/backup
ls -l /dev/disk/by-id/ | grep usb        # find the data drive; set device= in disko-data.nix
sudo nix run --extra-experimental-features 'nix-command flakes' \
  github:nix-community/disko -- --mode destroy,format,mount ./disko-data.nix
sudo systemd-tmpfiles --create           # creates /mnt/backups/homeserver for restic
```

The runtime mount is by-label (`backup-data`) via `fileSystems` in `configuration.nix`, so this is a one-time step per drive.

### 4.6 Verify SMART passthrough on both USB bridges

```bash
for d in /dev/disk/by-id/usb-*0:0; do echo "== $d"; sudo smartctl -a -d sat "$d" | head -40; done
```

If the "Vendor Specific SMART Attributes" table appears for both, the `home-smart` alert path works. If not, replace the offending enclosure — opaque ones have no software workaround.

---

## 5. Main install (≈ 60–90 min)

### 5.1 Boot throwaway Linux on main (≈ 5 min)

Same as 4.1 — any image with root SSH. Verify the disk layout matches disko:

```bash
lsblk
# /dev/sda    — 250 GB (boot SSD)
# /dev/sdb..e — 1 TB each (RAID 10 spinners)
```

If device names differ, edit `hosts/main/disko.nix` on the workstation before installing. Disko wipes every disk listed.

### 5.2 Stage main's host SSH key for shipping

```bash
mkdir -p /tmp/main-extra/etc/ssh
sudo install -m 0600 -o root -g root /etc/nixos/main-host-key /tmp/main-extra/etc/ssh/ssh_host_ed25519_key
sudo install -m 0644 -o root -g root /etc/nixos/main-host-key.pub /tmp/main-extra/etc/ssh/ssh_host_ed25519_key.pub
```

This pre-deploys main's SSH host key so on first boot the on-disk key matches the agenix recipient — agenix can decrypt the secrets immediately.

### 5.3 Run nixos-anywhere (≈ 15–20 min)

```bash
nix run --extra-experimental-features 'nix-command flakes' \
  github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#main \
  --target-host root@<main-lan-ip> \
  --extra-files /tmp/main-extra

rm -rf /tmp/main-extra
```

### 5.4 Approve on tailnet, SSH, passwd

```bash
# Approve homeserver in the Tailscale admin first.
ssh operator@homeserver.<your-tailnet>.ts.net
sudo passwd operator
cat /proc/mdstat              # verify RAID 10 healthy + resync clean
ls /run/agenix/               # restic-env, acme-credentials, main-root-sshkey, tailscale-authkey
```

### 5.5 Clone the repo on main

The flake auto-upgrade pulls from GitHub, but the Compose stack needs the repo locally for `.env` + compose YAMLs:

```bash
cd ~ && git clone <your-repo-url> server_config && cd server_config/hosts/main
```

### 5.6 Configure compose env file (≈ 5 min)

```bash
cp .env.example .env
vim .env       # fill in DOMAIN + all passwords (see hosts/main/README.md §4 for the variable table)
```

Generate strong passwords with `openssl rand -hex 32`. For `PORTAINER_ADMIN_PASSWORD_HASH`, run on the workstation:

```bash
docker run --rm httpd:alpine htpasswd -nbB admin '<your-portainer-password>' | cut -d: -f2
# Save the plaintext password in your password manager; paste the hash output into .env
```

### 5.7 Wait for ACME (≈ 2–5 min)

The ACME service was triggered automatically by §5.3's nixos-rebuild. deSEC propagation + Let's Encrypt validation takes a few minutes:

```bash
sudo journalctl -u acme-$(sudo nix eval --raw -f /etc/nixos/site.nix acmeDomain).service -f
# Wait for "Obtained certificate" / "acme finished"
ls /var/lib/acme/<your-domain>/      # cert.pem, key.pem, fullchain.pem, chain.pem
```

`caddy-reload-certs.service` will have logged a failure on first run because the Caddy container doesn't exist yet — expected, resolves after §5.8.

### 5.8 Bring up Docker services (≈ 10 min)

```bash
docker network create proxy

# Caddy first (other services route via the proxy network through it)
docker compose --env-file .env -f compose/caddy.yml up -d

# Re-rebuild so caddy-reload-certs stops failing
sudo nixos-rebuild switch --flake ~/server_config#main

# Rest of the stack — joplin-init runs once after joplin's healthcheck
# passes and rotates admin/admin → JOPLIN_ADMIN_PASSWORD.
for svc in seafile vaultwarden joplin portainer ntfy wud; do
  docker compose --env-file .env -f compose/$svc.yml up -d
done
```

---

## 6. Post-install smoke tests (≈ 30 min)

### 6.1 HTTPS on every service

```bash
for svc in seafile vaultwarden joplin portainer wud ntfy adguard; do
  printf '%-12s ' "$svc"
  curl -fsSI "https://${svc}.<your-domain>/" | head -1
done
# Each prints 200 / 302 / 401 — not a TLS error.
```

### 6.2 Joplin admin rotated

```bash
docker logs joplin-init
# Expect: "logged in with default creds; rotating admin password..." → "admin password rotated"
```

Log in to `https://joplin.<your-domain>` with `admin@localhost` + your `JOPLIN_ADMIN_PASSWORD`.

### 6.3 Portainer admin pre-set

Visit `https://portainer.<your-domain>`, log in with `admin` + your chosen Portainer password (the bcrypt hash you put in `.env` was generated from this).

### 6.4 AdGuard wizard

Visit `https://adguard.<your-domain>` and complete the first-run wizard:
- Admin interface: leave defaults.
- DNS listener: port 53 on all interfaces.
- Auth: create admin user + password.
- Filters → DNS blocklists: pick a starter set (AdGuard DNS filter, AdAway).

Then point devices at AdGuard (see `hosts/main/README.md` §9.2).

### 6.5 First restic backup

```bash
sudo systemctl start restic-backups-docker-volumes.service
sudo journalctl -u restic-backups-docker-volumes.service -f
# Initial seeding takes ~30–60 min over SFTP/Tailscale
```

Verify on Pi:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net \
  ls /mnt/backups/homeserver/snapshots
```

Trigger the other two:

```bash
sudo systemctl start restic-backups-seafile-data.service
sudo systemctl start restic-backups-adguard-state.service
```

### 6.6 Tailscale healthcheck (both hosts)

```bash
sudo systemctl start tailscale-healthcheck.service
sudo journalctl -u tailscale-healthcheck.service | tail

ssh operator@backupserver.<your-tailnet>.ts.net \
  'sudo systemctl start tailscale-healthcheck.service && sudo journalctl -u tailscale-healthcheck.service | tail'
```

Both exit cleanly (BackendState=Running + Self.Online=true).

### 6.7 ntfy phone hookup

Install the ntfy app ([iOS](https://apps.apple.com/us/app/ntfy/id1625396347) / [Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy)). Add server `https://ntfy.<your-domain>`, subscribe to all four topics: `home-backup`, `home-smart`, `home-updates`, `home-infra`.

Trigger test alerts:

```bash
# main
curl -H "Priority: 3" -d "main → infra test" "http://127.0.0.1:8085/home-infra"

# Pi
ssh operator@backupserver.<your-tailnet>.ts.net \
  'curl -H "Priority: 3" -d "pi → infra test" "$(tr -d "\n" < /etc/ntfy/url)/home-infra"'
```

Both should buzz the phone.

### 6.8 mdadm alert path

```bash
sudo mdadm --monitor --scan --test --oneshot
# Fires mdadm-alert → ntfy home-smart → phone.
```

---

## 7. Known gotchas

- **`caddy-reload-certs.service` fails on first nixos-rebuild.** Expected: Caddy container doesn't exist yet. Bring Caddy up via compose, re-run rebuild, it succeeds. Real post-deploy failures here mean certs silently stop rotating (no `OnFailure` wired yet) — flag if seen.

- **ACME DNS-01 propagation delay.** First cert issuance takes 2–5 min as deSEC publishes the TXT record and Let's Encrypt verifies. `sudo journalctl -u acme-<domain>.service -f` shows progress.

- **AdGuard `DynamicUser` state dir empty on first restic-adguard-state run.** Restic snapshot may capture an empty `/var/lib/AdGuardHome` if the wizard hasn't been completed yet. Do §6.4 before the next 03:00, otherwise the first snapshot is unusable for restore.

- **First aarch64 Pi build is mostly cache hits.** The kernel is pinned to nixpkgs' `linuxPackages_rpi4` (Hydra-cached) precisely so the workstation never compiles a kernel under qemu; what remains (initrd assembly, systemd units) builds in minutes via binfmt + qemu-user-static.

- **Pi 4 EEPROM older than 2020-10-28 can't boot the SSD.** GPT + USB-boot support landed in that release. One boot of the Raspberry Pi Imager "Bootloader → USB Boot" utility SD fixes it permanently.

- **Two SSDs share the Pi 4's ~1.2 A USB power budget.** Fine on the official 3 A PSU; USB resets in `dmesg` mean the data drive needs a powered hub.

- **Caddy must be up before any other compose service is meaningful.** Services start without Caddy but are unreachable via HTTPS until Caddy's running.

- **MagicDNS resolution for `backupserver`.** Main's nixos-upgrade gates on restic-to-Pi success; restic resolves `backupserver.<tailnet>.ts.net` via Tailscale MagicDNS. NixOS's Tailscale module sets `--accept-dns=true` by default.

- **First-boot SSH is key-only.** `PasswordAuthentication = false` is live from first boot. If `/etc/nixos/operator.pub` on the install workstation is wrong or stale, you can't SSH in. Physical console is the fallback.

- **Tailscale device awaits manual approval.** Both hosts try to register on first boot using the auth key but the key is not pre-approved — they sit in the admin console until you click "approve". Forgetting this looks like "tailscaled isn't working" but the device just isn't on the tailnet yet.

- **Restic first-run is slow.** Initial seeding transfers full working set over SFTP/Tailscale. Expect 30–60 min for several GB. Subsequent daily runs are incremental and quick.

- **agenix recipients tied to host SSH key.** If main's `/etc/ssh/ssh_host_ed25519_key` is regenerated (rebuild without `--extra-files`, or host reinstall), agenix can't decrypt and every secret-using service fails. The `--extra-files` step in §5.2 prevents this on first install. To rotate later: regenerate `/etc/nixos/main-host-key`, `nix flake lock`, run `agenix -r` from `secrets/` to re-encrypt to the new pubkey, ship the new private to main.

---

## 8. Rollback playbook

### During install

- **nixos-anywhere fails partway through disko/install (main).** Target is in an indeterminate state. Cleanest: reboot into the original live medium and re-run nixos-anywhere — disko is destructive and re-runs are safe.
- **Pi flash fails partway.** Re-run §4.1 from the workstation — the OS SSD gets re-wiped, and the data drive is untouchable by construction (not in `disko.nix`).
- **nixos-rebuild switch fails post-install.** NixOS keeps the previous generation active. Fall back with `sudo nixos-rebuild switch --rollback`.

### Post-install

- **Docker compose pulled a broken image tag.** `docker compose -f compose/<svc>.yml down`, edit the tag back to the previous version, `up -d`.
- **Bad commit auto-upgraded both hosts.** Main upgraded at 04:30, failed cleanly (NixOS rolls back). Pi at 05:30 is gated by the ntfy-reachability check — if main's upgrade bricked ntfy, Pi gates out. If the bad commit builds but breaks runtime, both follow. Mitigation: `git revert` on `main`, push — next upgrade cycle fixes itself.
- **Restic repo corruption.** `restic check` flags it. Recovery needs another good copy. Currently the Pi is the only copy — flagged in TODO.md as the off-site-backup gap.
- **agenix can't decrypt after host-key change.** Symptom: services fail because `/run/agenix/<name>` is missing. Fetch the new pubkey from main into `/etc/nixos/main-host-key.pub`, `nix flake update mainHostKey` (or full `nix flake lock`), then from `secrets/`: `agenix -i ~/.ssh/id_ed25519 -r` to rekey all `.age` files. Commit + push + rebuild.

---

## 9. Secrets inventory

| File | Lives on | Purpose | Loss impact |
|---|---|---|---|
| `/etc/nixos/site.nix` | Workstation | Domain + ACME email; flake input | Low — recreate from known values |
| `/etc/nixos/operator.pub` | Workstation | Operator SSH pubkey, baked into both hosts' authorized_keys | Low — re-copy from `~/.ssh/id_ed25519.pub` |
| `/etc/nixos/main-host-key{,.pub}` | Workstation | Main's SSH host keypair. Private ships at install via `--extra-files`; pubkey is the agenix recipient. | **High — lose the private and you can't decrypt main's secrets without rekeying via the operator key.** |
| `/etc/nixos/main-root-key{,.pub}` | Workstation | Main's root SSH keypair. Private encrypted into agenix; pubkey is a flake input → Pi's restic authorized_keys. | Medium — regenerate, re-encrypt, re-push Pi config. |
| `secrets/restic.env.age` | Repo (encrypted) | Restic repo URL + encryption password | **CATASTROPHIC** — `RESTIC_PASSWORD` loss = backups unrecoverable forever. |
| `secrets/acme-credentials.env.age` | Repo (encrypted) | deSEC API token | Medium — revoke in deSEC dashboard, issue new, re-encrypt. |
| `secrets/main-root-sshkey.age` | Repo (encrypted) | Main's root SSH private (for restic SFTP) | Medium — regenerate keypair, re-encrypt this file, update `/etc/nixos/main-root-key.pub` so Pi re-bakes the new pubkey. |
| `secrets/tailscale-authkey.age` | Repo (encrypted) | Reusable Tailscale auth key | Low — generate a new one in the Tailscale admin, re-encrypt. |
| `hosts/main/.env` | Main (gitignored, in repo clone) | Compose env: DOMAIN + service passwords + Portainer hash + Joplin admin password | Medium — recreate from password manager. |
| `/etc/ntfy/url` | Pi | Main's ntfy base URL | Low — recreate from known value. |
| `/etc/tailscale/authkey` | Pi (seeded onto the SSD at flash time) | Tailscale auth key (one-line) | Low — generate a new one (they expire ≤ 90 days), re-encrypt, re-seed. |

**Off-site escrow priority:** save the **plaintext `RESTIC_PASSWORD`** to a password manager that's not hosted on main (Bitwarden cloud, 1Password, Proton Pass) when you generate it in §2.4. Without it, a complete loss of *both* main and your workstation = unrecoverable backups. See [`CLAUDE.md`](CLAUDE.md) § Disaster recovery for the full posture and recovery procedure.
