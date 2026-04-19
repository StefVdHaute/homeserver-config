# Backup host (`backupserver`) — setup guide

Scope: the Raspberry Pi 4 that receives restic backups from `homeserver` over SFTP via Tailscale. For the main server, see [`hosts/main/README.md`](../main/README.md).

## Prerequisites

- Raspberry Pi 4 (any RAM variant)
- microSD card, 16GB or larger
- External USB SSD/HDD — capacity ≥ ~2× the main server's live data; oversize if you plan to host edge-replicated services later
- Tailnet already set up and reachable from `homeserver`

---

## 1. Flash the SD card

Download the community NixOS aarch64 SD image from https://hydra.nixos.org/job/nixos/release-25.11/nixos.sd_image.aarch64-linux (pick the latest build). On any machine with `dd`:

```bash
zstd -d nixos-sd-image-*.img.zst
sudo dd if=nixos-sd-image-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with your SD-card device (check `lsblk` first).

---

## 2. First boot + network

Insert the SD, attach keyboard + HDMI, power on. Once at the prompt:

```bash
# NixOS SD image lands you as `nixos` with no password.
sudo passwd nixos           # optional — set a temporary password
sudo -i
tailscale up
```

Follow the link to authorise the Pi on your tailnet. The Pi is now reachable from `homeserver` as `backupserver.<tailnet>.ts.net`.

---

## 3. Clone the repo

```bash
mkdir -p /home/stef && cd /home/stef
# Use https until you have your SSH key on the Pi.
git clone https://github.com/StefVdHaute/homeserver-config.git server_config
```

(Or `scp` it from main if the repo is private and you want to skip setting up a GitHub token on the Pi.)

---

## 4. Prepare the external USB drive

Plug in the USB SSD/HDD. Identify the device (`lsblk`), then run the setup script:

```bash
cd /home/stef/server_config
sudo bash hosts/backup/disk-setup.sh /dev/sda      # replace /dev/sda with yours
```

Creates one GPT partition, a btrfs filesystem labelled `backup-data`, and the `@homeserver` subvolume.

---

## 5. Wire up SSH keys before first switch

Edit `hosts/backup/configuration.nix` and paste two public keys:

- **Your workstation's key** (for `stef`) — lets you SSH into the Pi for ops.
- **`homeserver`'s key** (for `restic`) — lets main push restic backups over SFTP. On main: `cat ~/.ssh/id_ed25519.pub`.

Commit locally (you can clean up before pushing later), then continue.

---

## 6. Point SMART alerts at main's ntfy

The Pi's `smartd` posts disk-health alerts to the ntfy server running on main.
Write the base URL once, outside Nix:

```bash
sudo install -m 600 -o root -g root /dev/null /etc/ntfy/url
sudo tee /etc/ntfy/url <<< 'https://ntfy.<your-tailnet-DOMAIN>'
```

The script `/run/current-system/sw/bin/smartd-ntfy` appends `/home-smart` at runtime.

---

## 7. Generate hardware config and apply

```bash
sudo nixos-generate-config --root / --dir /home/stef/server_config/hosts/backup/ --no-filesystems
sudo nixos-rebuild switch --flake /home/stef/server_config#backup
```

The `--no-filesystems` flag keeps the generated file minimal — the fstab for `/mnt/backups` is already declared in `configuration.nix`.

After this, the Pi:
- has `stef` and `restic` users with authorized keys
- has `/mnt/backups` mounted from the USB drive
- SSH is only reachable via the tailnet
- `services.smartd` posts disk alerts to main's ntfy topic `home-smart`
- `nixos-upgrade` runs daily at 05:30 but only when a restic snapshot has landed in the last 24h
- posts `home-infra` alerts to ntfy on `nixos-upgrade`, `tailscaled`, or `mnt-backups.mount` failure (via the shared `ntfy-infra-failure@.service` template)

### 7.1 Verify SMART passthrough on the USB drive

Not every USB-SATA bridge exposes SMART. Check:

```bash
sudo smartctl -a -d sat /dev/sda | head -30
```

If SMART attributes come through (look for the "Vendor Specific SMART Attributes" table), the alert path works. If not, this drive's enclosure is opaque to SMART and you'll need to replace it with one that supports UAS/SAT passthrough — notify your future self accordingly.

---

## 8. First backup from main

Follow `hosts/main/README.md` §9 to create `/etc/restic/env` on main and
trigger the first backup:

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
