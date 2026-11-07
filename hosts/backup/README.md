# Backup host (`backupserver`) — setup guide

Scope: the Raspberry Pi 4 that receives restic backups from `homeserver` over SFTP via Tailscale. For the main server, see [`hosts/main/README.md`](../main/README.md).

The Pi boots from a SATA SSD in a USB adapter (EEPROM USB boot) — there is no SD card in the running system. The OS SSD is flashed directly on the workstation; the backup data drive is provisioned once, on the Pi, and is deliberately excluded from every automated install path.

## Prerequisites

- Raspberry Pi 4 (any RAM variant), EEPROM bootloader ≥ 2020-10-28 (GPT + USB boot; boards bought 2021+ qualify)
- ~240 GB SATA SSD in a USB adapter — OS + side projects (`/srv/projects`)
- External USB SSD/HDD for backup data — capacity ≥ ~2× the main server's live data; oversize if you plan to host edge-replicated services later
- Both USB bridges must pass SMART through (`-d sat`); verify in §5
- Tailnet already set up and reachable from `homeserver`
- A workstation with Nix, aarch64 binfmt (DEPLOY.md §2.1), and this repo clone — the SSD is flashed there, so it must be plugged into the workstation
- Workstation prep per DEPLOY.md §2.3: the repo's `keys/operator.pub` is baked into the Pi's `operator` user, `keys/main-root.pub` into the Pi's `restic` user authorized_keys. No manual paste step on the Pi side, and no `/etc/nixos` files needed on the Pi.

---

## 1. Flash the OS SSD on the workstation

Plug the SSD (in its USB adapter) into the workstation. Confirm its by-id path matches `device =` in `disko.nix` — with two USB drives on the Pi, `/dev/sdX` is a race, so by-id is the only identifier that matters:

```bash
ls -l /dev/disk/by-id/ | grep usb
```

Then build + flash (full commands: DEPLOY.md §4.1–4.2). In short:

```bash
nix build .#nixosConfigurations.backup.config.system.build.toplevel -o /tmp/backup-toplevel
sudo disko --mode destroy,format,mount --flake .#backup     # wipes ONLY the OS SSD
sudo nixos-install --system "$(readlink -f /tmp/backup-toplevel)" --root /mnt --no-root-passwd
sudo nixos-enter --root /mnt -- passwd operator             # sudo on the Pi needs this
# seed /mnt/etc/tailscale/authkey + /mnt/etc/ntfy/url, then umount -R /mnt
```

The bootloader step populates `/boot` with extlinux + kernels **and** the Pi firmware/U-Boot chain — the `installBootLoader` wrapper in `hardware-configuration.nix` re-syncs those files on every rebuild, so firmware updates flow in with normal upgrades. `config.txt` is Nix-owned; hand edits get clobbered on the next switch.

---

## 2. Boot the Pi from USB

Move the SSD (keep the same USB adapter — the by-id path encodes it) to one of the Pi's USB 3 (blue) ports, plug in the data drive, no SD card, power on. The EEPROM's default boot order falls through to USB when no SD is present.

- EEPROM too old? Flash the Raspberry Pi Imager "Misc utility images → Bootloader → USB Boot" image to any SD, boot it once (steady green LED = done).
- Optional: set `BOOT_ORDER=0xf14` (USB first) so a forgotten SD can never shadow the SSD.

---

## 3. Approve on tailnet, SSH

The Pi registers on the tailnet automatically using the seeded auth key. Approve `backupserver` in the [Tailscale admin](https://login.tailscale.com/admin/machines), then:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net
```

State after first boot:
- `operator` and `restic` users exist with authorized keys (from flake inputs)
- SSH reachable over the tailnet and the LAN (IPv4 `192.168.128.0/23`, IPv6 link-local); the firewall drops all other traffic
- `services.smartd` posts disk alerts to main's ntfy topic `home-smart`
- `nixos-upgrade` runs daily 05:30 but only when a restic snapshot has landed in the last 24h **and** main's ntfy responds
- `OnFailure` hooks post `home-infra` alerts to ntfy for `nixos-upgrade`, `tailscaled`, or `mnt-backups.mount` failures
- `backup-drive-check.timer` posts a `home-infra` alert every 3h while the data drive isn't mounted

---

## 4. Provision the backup data drive (first install only)

The data drive is intentionally **not** in `disko.nix` — no OS install or reinstall may ever format the restic repo. Format a brand-new drive manually, on the Pi:

```bash
git clone <your-repo-url> server_config && cd server_config/hosts/backup
ls -l /dev/disk/by-id/ | grep usb        # find the data drive; set device= in disko-data.nix
sudo nix run --extra-experimental-features 'nix-command flakes' \
  github:nix-community/disko -- --mode destroy,format,mount ./disko-data.nix
sudo install -d -m700 -o restic -g restic /mnt/backups/homeserver   # restic repo dir, on the drive
```

The runtime mount is by-label (`backup-data`, subvol `@homeserver`) via `fileSystems` in `configuration.nix` — enumeration never matters again after formatting. The repo directory is created on the drive itself, never by the config: with the drive absent, `/mnt/backups` is an automount that errors out over a `root:root 0000` directory, so restic fails loudly instead of writing a fresh repo to the OS SSD.

---

## 5. Verify SMART passthrough on both USB bridges

Not every USB-SATA bridge exposes SMART, and *both* drives feed `home-smart` alerts. Check:

```bash
for d in /dev/disk/by-id/usb-*0:0; do echo "== $d"; sudo smartctl -a -d sat "$d" | head -30; done
```

If SMART attributes come through (look for the "Vendor Specific SMART Attributes" table), the alert path works. If not, that enclosure is opaque to SMART — replace it; there's no software workaround.

Monitored devices are listed **explicitly by by-id path** in `alerts.smartd.devices` (`configuration.nix`) — smartd's `DEVICESCAN` finds nothing when combined with `-d sat`, since sat is a pass-through protocol rather than a scannable class. When provisioning the data drive, add its by-id path to that list.

---

## 6. `/etc/ntfy/url`

Seeded onto the SSD at flash time (base URL of main's ntfy, e.g. `https://ntfy.<your-domain>`). To change it later:

```bash
sudo tee /etc/ntfy/url <<< 'https://ntfy.<your-domain>'
```

The helper `/run/current-system/sw/bin/smartd-ntfy` appends the topic at runtime.

---

## 7. First backup from main

Follow [`hosts/main/README.md`](../main/README.md) §10 to trigger the first restic run from main. Verify on the Pi:

```bash
ssh operator@backupserver.<your-tailnet>.ts.net \
  ls /mnt/backups/homeserver/snapshots
```

---

## 8. Fluidd for the Creality K1C

`compose/fluidd.yml` runs Fluidd, `k1c-proxy` (see `k1c-proxy/proxy.py`) and go2rtc. go2rtc turns the WebRTC camera into MJPEG at `/webcam/stream.mjpeg`, so web views without WebRTC (OrcaSlicer on Linux) show it too. The Fluidd camera is an `iframe` on `/webcam/`, a page that shows the stream in an `<img>`.

```bash
cd ~ && git clone <your-repo-url> server_config && cd server_config/hosts/backup
docker compose -f compose/fluidd.yml up -d --build
```

Open `http://<pi-lan-ip>:8080` (LAN) or `http://backupserver:8080` (tailnet). The printer address is in `compose/fluidd.yml`; give the printer a DHCP reservation. After a change to `proxy.py`, run `up -d --build` again.

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

- **Pi doesn't boot from the SSD** — in EEPROM order: (1) bootloader too old for GPT/USB (< 2020-10-28) → run the Imager "USB Boot" utility SD once; (2) an inserted SD is shadowing the SSD → remove it or set `BOOT_ORDER=0xf14`; (3) watch the boot on serial (`enable_uart=1` is set in config.txt, 115200 baud on GPIO 14/15) — firmware messages but no U-Boot means a broken FAT partition, U-Boot but no kernel means extlinux/initrd trouble.
- **`/mnt/backups` didn't mount** ("Backup drive missing" on `home-infra`) — it's an automount (`x-systemd.automount`, 30s device timeout), so the Pi boots without the drive and accesses fail instead of hitting the OS SSD. Check `systemctl status mnt-backups.mount` and `lsblk -f` (label must be `backup-data`). `ls -ld /mnt/backups` shows `d---------` only when nothing is mounted at all; that's the intended fallback.
- **SSH refused from main** — confirm `tailscale status` on the Pi shows it as online, and that `homeserver`'s pubkey is in `authorized_keys` for `restic`. `sudo cat /var/lib/restic/.ssh/authorized_keys` on the Pi.
- **nixos-upgrade skipped with "no restic snapshot newer than 24h"** — expected if backups are failing on main. Check `journalctl -u restic-backups-docker-volumes.service` and `journalctl -u restic-backups-seafile-data.service` on main first.
- **Tailscale never registers on first boot** — the seeded auth key was probably expired (they live ≤ 90 days). Generate a fresh reusable key, then on the Pi: `sudo tee /etc/tailscale/authkey <<< 'tskey-auth-...'` and `sudo systemctl restart tailscaled`.
- **Running Docker containers here** — Docker is enabled with its data root at `/srv/projects/docker` (the `@projects` subvolume on the OS SSD; the backup data drive stays dedicated to restic). `operator` is in the `docker` group; compose files live in `hosts/backup/compose/` (one per service, see section 8). Containers must never touch `/mnt/backups`.
