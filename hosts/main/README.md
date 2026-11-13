# homeserver: operation

First install: [`DEPLOY.md`](../../DEPLOY.md). Loss and rollback:
[`RECOVERY.md`](../../RECOVERY.md). The clone on this host is `~/server_config`.

## Services

`https://home.DOMAIN` links to all of them: `seafile`, `vaultwarden`,
`joplin`, `homeassistant`, `portainer`, `wud`, `ntfy`, `grafana` and `adguard`,
each at `<name>.DOMAIN`. tsidp is its own tailnet device at
`https://idp.<tailnet>.ts.net`.

Each app with "Sign in with Tailscale" keeps a local admin login as a
fallback. Joplin's admin is `admin@localhost` with `JOPLIN_ADMIN_PASSWORD`.

## Daily schedule

| Time | Job |
|---|---|
| 03:00 | The four restic jobs (`restic-backups-*.timer`) |
| 04:30 | `nixos-upgrade`, only after `docker-volumes` and `seafile-data` succeed |
| Monthly | `restic-check-deep`: reads 10% of the repository |

## Update a container

WUD reports a new version on `home-updates`. Change the tag in
`compose/<service>.yml`, commit and push. Then, on main:

```bash
cd ~/server_config && git pull --ff-only && cd hosts/main
docker compose --env-file .env -f compose/<service>.yml pull
docker compose --env-file .env -f compose/<service>.yml up -d
```

Never run `down` or add `--remove-orphans`: all stacks share the Compose
project `compose`, so the other stacks count as orphans.

Read the release notes before a major version. Postgres cannot open the data
of an older major (dump and restore). Seafile majors change the configuration.

## Backups

```bash
systemctl list-timers 'restic-backups-*'
sudo systemctl start restic-backups-<job>.service
sudo journalctl -u restic-backups-<job>.service
```

The jobs are `docker-volumes`, `seafile-data`, `adguard-state` and
`tsidp-state`. Retention is 7 daily, 4 weekly and 6 monthly snapshots.

## Alerts

All alerts go to ntfy at `https://ntfy.DOMAIN`. There is no login: the server
is reachable from the tailnet only. Subscribe the phone to these topics:

| Topic | Source |
|---|---|
| `home-backup` | restic: success (silent), failure, monthly check |
| `home-smart` | smartd on both hosts, mdadm, `btrfs-data-check`, Prometheus disk rules |
| `home-updates` | WUD |
| `home-infra` | Prometheus rules, `tailscale-healthcheck` on both hosts, and the Pi's upgrade, mount and drive checks |

Local services post to `http://127.0.0.1:8085`. The Pi reads the base URL
from its `/etc/ntfy/url`.

## DNS (AdGuard Home)

- **Tailnet devices:** in the Tailscale admin console, under DNS, set the
  global nameserver to the address from `tailscale ip -4` on main.
- **LAN devices:** let the router's DHCP give out main's LAN address as DNS.

Check with `dig doubleclick.net @<main-ip>`: the answer is `0.0.0.0`. If a
site breaks, the AdGuard query log shows the blocked name.

## sudo rejects the password

`users.mutableUsers` is on, so `operator-password.age` applies only when the
account is created. If `passwd -S operator` shows `L`, set the password once
from the secret (operator is in the `docker` group):

```bash
docker run --rm --privileged --pid=host alpine:3 nsenter -t 1 -m -u -i -n \
  /run/current-system/sw/bin/sh -c 'export PATH=/run/current-system/sw/bin;
  usermod -p "$(cat /run/agenix/operator-password)" operator'
```

Change it later with `passwd`.

## Replacing a disk

With one dead disk:

- `/` continues degraded, and mdadm alerts on `home-smart`.
- `/mnt/data` continues degraded until the next reboot. After a reboot it
  does not mount, so Docker and the backups stay down. SSH and Tailscale
  still work.

Put the new disk in the same bay. `sdX` is the new disk and `N` is its bay
number plus 1:

```bash
# 1. If /mnt/data is not mounted, mount it degraded for the rebuild
sudo mount -o degraded,compress=zstd:3,noatime,subvol=@data /dev/disk/by-label/data /mnt/data

# 2. Copy the partition table from a healthy disk, give it new GUIDs
sudo sgdisk --replicate=/dev/sdX /dev/sdHEALTHY && sudo sgdisk -G /dev/sdX
sudo sgdisk -c 1:bootN -c 2:osN -c 3:dataN /dev/sdX

# 3. ESP
sudo mkfs.vfat -F 32 /dev/disk/by-partlabel/bootN

# 4. OS array
sudo mdadm /dev/md/os --add /dev/disk/by-partlabel/osN

# 5. Data array (devid of the missing disk: `btrfs filesystem show /mnt/data`)
sudo btrfs replace start -B <missing-devid> /dev/disk/by-partlabel/dataN /mnt/data
# Fold back the single-copy chunks written while degraded
sudo btrfs balance start -dconvert=raid1,soft -mconvert=raid1c3,soft /mnt/data

# 6. Put the new by-id path into diskIds in disko.nix, commit, and rebuild.
#    The rebuild installs GRUB on the new ESP.
sudo nixos-rebuild switch --flake .#main
```
