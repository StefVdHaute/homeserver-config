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

```bash
# on the Pi, once booted
sudo systemctl enable --now ssh    # or equivalent for your image
ip a                               # note the LAN IP
```

Plug in the external USB drive. Disko WIPES both `/dev/mmcblk0` (SD) and `/dev/sda` (USB) — verify `lsblk` first.

Workstation prep (per main README §1.1, all four `/etc/nixos/*` files): `operator.pub` baked into the Pi's `operator` user, `main-root-key.pub` baked into the Pi's `restic` user authorized_keys via flake input. No manual paste step on the Pi side.

---

## 2. Stage the Tailscale auth key for shipping

Pi's `services.tailscale.authKeyFile` reads `/etc/tailscale/authkey` on first boot. The same reusable auth key from main's install (Tailscale admin: untick "Ephemeral", leave "Pre-approved" off) works here. Stage it for `nixos-anywhere --extra-files`:

```bash
mkdir -p /tmp/pi-extra/etc/tailscale
echo 'tskey-auth-...' > /tmp/pi-extra/etc/tailscale/authkey
chmod 0600 /tmp/pi-extra/etc/tailscale/authkey
```

---

## 3. Run nixos-anywhere

From the workstation (or main, which has aarch64 binfmt):

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake ~/server_config#backup \
  --target-host root@<pi-lan-ip> \
  --extra-files /tmp/pi-extra

rm -rf /tmp/pi-extra        # cleanup post-install
```

Disko: SD → 512MB FAT32 firmware + btrfs `@nixos` root; USB → btrfs `backup-data` with `@homeserver` subvolume mounted at `/mnt/backups`. Then flake closure, then reboot.

---

## 4. Approve on tailnet, SSH, passwd

Pi registers on the tailnet automatically using the auth key. Approve `backupserver` in the [Tailscale admin](https://login.tailscale.com/admin/machines), then:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net
sudo passwd operator
```

State after first boot:
- `operator` and `restic` users exist with authorized keys (from flake inputs)
- `/mnt/backups` mounted from the external USB btrfs via disko
- SSH only reachable over the tailnet (firewall blocks WAN/LAN)
- `services.smartd` posts disk alerts to main's ntfy topic `home-smart`
- `nixos-upgrade` runs Mondays 05:30 but only when a restic snapshot has landed in the last 24h **and** main's ntfy responds
- `OnFailure` hooks post `home-infra` alerts to ntfy for `nixos-upgrade`, `tailscaled`, or `mnt-backups.mount` failures

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

Follow [`hosts/main/README.md`](../main/README.md) §10 to trigger the first restic run from main. Verify on the Pi:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net \
  ls /mnt/backups/homeserver/snapshots
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
- **Future: running Docker containers here** — flip `virtualisation.docker.enable = true;` in `hosts/backup/configuration.nix`, add `operator` to `extraGroups = [ "wheel" "docker" ]`, and add compose files under a new `hosts/backup/compose/` directory.
