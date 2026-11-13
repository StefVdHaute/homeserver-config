# backupserver: operation

First install: [`DEPLOY.md`](../../DEPLOY.md) sections 4 and 5. Loss of the Pi:
[`RECOVERY.md`](../../RECOVERY.md).

The Pi boots from the SATA SSD on USB, without an SD card. `config.txt` and
the firmware on `/boot` come from Nix on each rebuild: do not edit them by hand.

## Files outside git

Both are written at flash time. To change one later:

```bash
sudo tee /etc/ntfy/url <<< 'https://ntfy.<domain>'               # base URL of main's ntfy
sudo tee /etc/tailscale/authkey <<< 'tskey-auth-...' && sudo systemctl restart tailscaled
```

## The data drive

- It is not in `disko.nix`, so no install can format it. `disko-data.nix`
  formats a new drive, by hand (`DEPLOY.md` 5.1).
- `/mnt/backups` is an automount by label (`backup-data`). Without the drive,
  access fails after 30 s and restic on main fails. Nothing lands on the OS SSD.
- smartd monitors only the by-id paths in `alerts.smartd.devices`. Add a new
  drive there.
- Containers must never touch `/mnt/backups`. Docker's data is in
  `/srv/projects/docker` on the OS SSD.

To add a second drive as a mirror, online:

```bash
sudo btrfs device add /dev/sdYn /mnt/backups
sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/backups
```

## Fluidd for the Creality K1C

```bash
cd ~/server_config/hosts/backup
docker compose -f compose/fluidd.yml up -d --build      # again after a change to proxy.py
```

Fluidd is at `http://backupserver:8080` (tailnet) or `http://<pi-lan-ip>:8080`.
The printer's address is in `compose/fluidd.yml`: give the printer a DHCP
reservation.

## Troubleshooting

- **The Pi does not boot from the SSD:** the bootloader is older than
  2020-10-28, or an SD card is in the slot. The serial console is on GPIO
  14/15 at 115200 baud. Firmware messages without U-Boot point to the FAT
  partition; U-Boot without a kernel points to extlinux or the initrd.
- **"Backup drive missing" on `home-infra`:** look at
  `systemctl status mnt-backups.mount` and `lsblk -f`. The label must be
  `backup-data`.
- **The upgrade is skipped ("no restic snapshot newer than 24h"):** the
  backups on main fail. Look at `journalctl -u 'restic-backups-*'` on main.
- **restic on main gets no SSH connection:** check `tailscale status` here and
  `/var/lib/restic/.ssh/authorized_keys`.
