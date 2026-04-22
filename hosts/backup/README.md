# Backup host (`backupserver`) — setup guide

Scope: the Raspberry Pi 4 that receives restic backups from `homeserver` over SFTP via Tailscale. For the main server, see [`hosts/main/README.md`](../main/README.md).

## Prerequisites

- Raspberry Pi 4 (any RAM variant)
- microSD card, 16GB or larger
- External USB SSD/HDD — capacity ≥ ~2× the main server's live data; oversize if you plan to host edge-replicated services later
- Tailnet already set up and reachable from `homeserver`
- A workstation with Nix holding this repo clone. For fastest installs, run the install from `homeserver` itself — main has `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]` so the aarch64 closure builds natively. From an x86_64 workstation without binfmt, pass `--build-on-remote` (the Pi builds its own closure — takes hours) or add `aarch64-linux` to your workstation's `boot.binfmt.emulatedSystems` first.

---

## 1. Flash a throwaway Linux to the SD

Any Linux-with-SSH-as-root works as a starting point — nixos-anywhere kexecs into the NixOS installer from whatever's running. Raspberry Pi OS Lite, Ubuntu Server for Pi, or the NixOS aarch64 SD image are all fine.

Flash your chosen image, boot the Pi, enable SSH-as-root, and note the IP:

```bash
# on the Pi, once booted
sudo systemctl enable --now ssh    # or equivalent for your image
ip a                               # note the LAN IP
```

Plug in the external USB drive. Disko will wipe both `/dev/mmcblk0` (SD) and `/dev/sda` (USB) — double-check `lsblk` if your enumeration differs.

---

## 2. Paste SSH pubkeys into `hosts/backup/configuration.nix`

Two keys, pasted into `users.users.<name>.openssh.authorizedKeys.keys` on the workstation before installing:

- **Your workstation's key** under `users.users.stef` — lets you SSH into the Pi for ops.
- **`homeserver`'s root key** under `users.users.restic` — lets main push restic backups over SFTP. On main: `sudo cat /root/.ssh/id_ed25519.pub` (generate first with `sudo ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""` if missing).

---

## 3. Install via nixos-anywhere

From the workstation (or main):

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#backup \
  --target-host root@<pi-ip>
```

Nixos-anywhere kexecs into the NixOS installer, runs disko (SD gets GPT with FAT32 firmware + ext4 root; USB gets GPT with btrfs `backup-data` + `@homeserver` subvolume), installs the flake closure, and reboots the Pi into NixOS.

**Path B — Nix-native SD image** (alternative, skips the throwaway Linux step): build the SD image with `nix build .#nixosConfigurations.backup.config.system.build.sdImage`, flash the result, boot. You'll still need the disko step for the external USB drive on first boot (`sudo disko --mode destroy,format,mount hosts/backup/disko.nix`, or just declare USB-only disko and skip SD partitioning). Currently the backup config doesn't import an sd-image module, so this path needs a small config change first — flagged as a follow-up.

---

## 4. First boot + Tailscale

SSH in as `stef` on the LAN IP (keypair from §2 authorises you), then join the tailnet:

```bash
ssh stef@<pi-ip>
sudo passwd stef                   # set a real password
sudo tailscale up                  # follow the auth link
```

The Pi is now reachable as `backupserver.<tailnet>.ts.net` from any tailnet peer; subsequent steps can all be done over that hostname. State at this point:

- `stef` and `restic` users exist with authorised keys
- `/mnt/backups` mounted from the external USB btrfs via disko
- SSH only reachable over the tailnet (firewall blocks WAN/LAN)
- `services.smartd` posts disk alerts to main's ntfy topic `home-smart`
- `nixos-upgrade` runs daily at 05:30 but only when a restic snapshot has landed in the last 24h
- `OnFailure` hooks post `home-infra` alerts to ntfy for `nixos-upgrade`, `tailscaled`, or `mnt-backups.mount` failures (via the shared `ntfy-infra-failure@.service` template)

---

## 5. Verify SMART passthrough on the USB drive

Not every USB-SATA bridge exposes SMART. Check:

```bash
sudo smartctl -a -d sat /dev/sda | head -30
```

If SMART attributes come through (look for the "Vendor Specific SMART Attributes" table), the alert path works. If not, this drive's enclosure is opaque to SMART and you'll need to replace it with one that supports UAS/SAT passthrough — notify your future self accordingly.

---

## 6. Point SMART alerts at main's ntfy

The Pi's `smartd` posts disk-health alerts to the ntfy server running on main. Write the base URL once, outside Nix (tailnet hostname is site-specific, not committed):

```bash
sudo install -m 600 -o root -g root -d /etc/ntfy
sudo install -m 600 -o root -g root /dev/null /etc/ntfy/url
sudo tee /etc/ntfy/url <<< 'https://ntfy.<your-tailnet-DOMAIN>'
```

The helper `/run/current-system/sw/bin/smartd-ntfy` appends `/home-smart` at runtime.

---

## 7. First backup from main

Follow [`hosts/main/README.md`](../main/README.md) §11 to create `/etc/restic/env` on main and trigger the first backup:

```bash
sudo systemctl start restic-backups-docker-volumes.service
sudo journalctl -u restic-backups-docker-volumes.service -f
```

Verify the snapshot landed on the Pi:

```bash
ssh restic@backupserver.<tailnet>.ts.net ls /mnt/backups/homeserver/snapshots
```

---

## Future: convert to btrfs RAID 1

When you add a second USB drive for redundancy:

```bash
sudo btrfs device add /dev/sdYn /mnt/backups
sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/backups
```

Online; no downtime. btrfs rebalances data + metadata to mirror across both devices. (Avoid btrfs RAID 5/6 — write-hole issue still flagged unstable.)

---

## Troubleshooting

- **`/mnt/backups` didn't mount after boot** — check `systemctl status mnt-backups.mount`. `nofail` in the fs options means the Pi boots anyway; the mount may have failed because the drive wasn't plugged in or the label doesn't match `backup-data`. Run `lsblk -f` to confirm the label.
- **SSH refused from main** — confirm `tailscale status` on the Pi shows it as online, and that `homeserver`'s pubkey is in `authorized_keys` for `restic`. `sudo cat /var/lib/restic/.ssh/authorized_keys` on the Pi.
- **nixos-upgrade skipped with "no restic snapshot newer than 24h"** — expected if backups are failing on main. Check `journalctl -u restic-backups-docker-volumes.service` and `journalctl -u restic-backups-seafile-data.service` on main first.
- **Future: running Docker containers here** — flip `virtualisation.docker.enable = true;` in `hosts/backup/configuration.nix`, add `stef` to `extraGroups = [ "wheel" "docker" ]`, and add compose files under a new `hosts/backup/compose/` directory.
