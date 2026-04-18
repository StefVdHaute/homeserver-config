# server_config

Reproducible NixOS + Docker config for a two-host home setup.

| Host | Role | Hardware | Guide |
|---|---|---|---|
| `homeserver` (`hosts/main/`) | Main server — all user-facing services behind Caddy | Dual Xeon, 32–48GB DDR3, 250GB SSD boot + 4×1TB RAID 10 | [`hosts/main/README.md`](hosts/main/README.md) |
| `backupserver` (`hosts/backup/`) | Restic backup target + room for future edge services | Raspberry Pi 4, external USB SSD (btrfs) | [`hosts/backup/README.md`](hosts/backup/README.md) |

## Repo layout

```
.
├── flake.nix              # nixosConfigurations.main + .backup (pinned nixpkgs 25.11)
├── BRIEFING.md            # architecture overview (both hosts)
├── TODO.md
└── hosts/
    ├── main/              # dual-Xeon homeserver
    └── backup/            # Raspberry Pi backup target
```

## Quick rebuild

From either host, once set up:

```bash
sudo nixos-rebuild switch --flake ~/server_config#<main|backup>
```

## Further reading

- [`BRIEFING.md`](BRIEFING.md) — full architecture, services, backup flow.
- [`TODO.md`](TODO.md) — outstanding work.
