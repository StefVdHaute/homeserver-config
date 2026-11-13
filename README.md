# homeserver-config

NixOS flake for a home server, its backup target and the operator's laptop.

| Host | Flake output | Role | Hardware |
|---|---|---|---|
| `homeserver` | `main` | All services behind Caddy; runs the restic backups | Dell R720, 4x 1 TB: mdadm RAID 10 for `/`, btrfs RAID 1 for `/mnt/data` |
| `backupserver` | `backup` | Restic target over SFTP; Fluidd for the 3D printer | Raspberry Pi 4, USB SSD for the OS, USB drive for the backups |
| `workstation` | `workstation` | Daily driver (Hyprland) | Framework 16, LUKS btrfs |

## How it fits together

- **Access:** Tailscale only. Nothing is open to the internet. Caddy on main
  serves `<service>.DOMAIN` with a wildcard Let's Encrypt certificate (deSEC
  DNS-01, `security.acme`).
- **Services:** Seafile, Vaultwarden, Joplin, Home Assistant, Portainer, WUD
  and ntfy run in Docker Compose (`hosts/main/compose/`). AdGuard Home,
  Grafana with Prometheus, and tsidp (single sign-on) are NixOS services.
- **Backups:** restic on main pushes to the Pi each night at 03:00. The
  password stays on main, so the Pi cannot read the backups.
- **Upgrades:** main upgrades itself from GitHub at 04:30, after the backups
  succeed. The Pi follows at 05:30 if a fresh snapshot arrived. Containers
  are pinned; WUD reports new versions and the operator bumps the tags.
- **Alerts:** all go to ntfy on main (`hosts/main/README.md` has the topics).
- **Secrets:** agenix files in `secrets/`. A few files stay outside git
  (`RECOVERY.md` lists them).

## Rebuild

    nixh                 # picker: check, switch, boot, gens, roll, gc, bump
    sudo nixos-rebuild switch --flake .#<main|backup|workstation>

The clone is `~/server_config` on the servers.

## Docs

| File | Topic |
|---|---|
| [`DEPLOY.md`](DEPLOY.md) | First install of the Pi and main |
| [`RECOVERY.md`](RECOVERY.md) | Loss of a host, rollback, what is outside git |
| [`hosts/main/README.md`](hosts/main/README.md) | Operation of main: updates, backups, alerts, disk replacement |
| [`hosts/backup/README.md`](hosts/backup/README.md) | Operation of the Pi |
| [`hosts/workstation/DOTFILES.md`](hosts/workstation/DOTFILES.md) | What the workstation provides for the dotfiles |
| [`TODO.md`](TODO.md) | Open work |
| [`AGENTS.md`](AGENTS.md) | Rules for coding agents |
