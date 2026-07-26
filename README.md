# server_config

Reproducible NixOS + Docker config for a three-host home setup.

| Host | Role | Hardware | Guide |
|---|---|---|---|
| `homeserver` (`hosts/main/`) | Main server — all user-facing services behind Caddy | Dual Xeon, 32–48GB DDR3, 250GB SSD boot + 4×1TB RAID 10 | [`hosts/main/README.md`](hosts/main/README.md) |
| `backupserver` (`hosts/backup/`) | Restic backup target + room for future edge services | Raspberry Pi 4, USB-boot from SATA SSD (OS) + external USB SSD (backup data, btrfs) | [`hosts/backup/README.md`](hosts/backup/README.md) |
| `workstation` (`hosts/workstation/`) | Operator's daily driver (Hyprland, Tailscale leaf) | Framework 16 (Ryzen 7040), LUKS btrfs on NVMe | — |

## Repo layout

```
.
├── flake.nix              # nixosConfigurations.main / .backup / .workstation (pinned nixpkgs 26.05)
├── CLAUDE.md              # architecture + decisions
├── DEPLOY.md              # end-to-end first-install playbook
├── TODO.md
└── hosts/
    ├── main/              # dual-Xeon homeserver
    ├── backup/            # Raspberry Pi backup target
    └── workstation/       # Framework 16 daily driver
```

## Quick rebuild

From any host, once set up:

```bash
sudo nixos-rebuild switch --flake ~/server_config#<main|backup|workstation>
```

## Further reading

- [`CLAUDE.md`](CLAUDE.md) — full architecture, services, backup flow.
- [`DEPLOY.md`](DEPLOY.md) — first-install playbook.
- [`TODO.md`](TODO.md) — outstanding work.
