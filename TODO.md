# TODO

## Nix

- [x] Improve first deployment — restic is now declarative via `services.restic.backups`
- [x] Check if the backup script can be replaced by something Nix-native — replaced with `services.restic.backups` in `hosts/main/configuration.nix`

## Infrastructure

- [x] Firewall rules per service in NixOS config
- [x] SMART disk monitoring via `smartd` with alerts — enabled on both hosts, alerts via ntfy `home-smart`

## Services

- [x] Seafile config with Redis caching (v13)
- [x] Container update monitoring (WUD)
- [x] Configure WUD notification channel — HTTP trigger pointing at ntfy `home-updates`
- [ ] Monitoring/alerting (Grafana + Prometheus + node-exporter)
- [ ] DNS/local resolution (e.g. AdGuard Home or Pi-hole)
- [ ] Log viewer (e.g. Dozzle)

## Future

- [ ] Self-hosted music stack: Navidrome (server) + Lidarr (auto-download) + Slskd (Soulseek client)
- [ ] Music discovery: look into ListenBrainz (recommendations/scrobbling), Spotify-to-Lidarr playlist sync, Last.fm similar artist feeds
- [ ] Self-hosted game servers (preferably with web dashboard)
  - [ ] Minecraft
  - [ ] CIV
  - [ ] Ask Stijn for more

## Security & Networking

- [ ] HTTPS certs via Tailscale (`tailscale cert`) — replace Caddy's internal CA
- [ ] Email sending / notification system for services (password resets, alerts)
- [ ] Migrate `/etc/restic/env` and `/etc/ntfy/url` (and future secrets) to sops-nix or agenix

## Pi-side alerts

- [x] ntfy alerts from the Pi for: `nixos-upgrade` failure, `/mnt/backups` mount failure, `tailscaled` daemon crash — via `ntfy-infra-failure@.service` → `home-infra` topic.
- [x] Tailscale connectivity health check — 15-min `tailscale-healthcheck.timer` on both hosts checks `BackendState == Running` + `Self.Online`, alerts to `home-infra`. Implemented in `modules/alerts.nix` under the `alerts.tailscaleHealthcheck` option.

## Backup

- [x] Restic systemd timer schedule
- [ ] Scheduled `restic check` and restore verification
- [x] A talk needs to happen for what the remote backup server will look like — designed as `hosts/backup/` (Raspberry Pi 4, btrfs on external USB SSD; see `CLAUDE.md`)

## Before deployment

- [ ] Review all files one by one with help of claude to check for security/configuration problems
- [ ] Create a plan for first deployment success review and to prepare for integration hell
- [x] Recreate this deployment on a smaller scale for the remote Raspberry pi — see `hosts/backup/`
