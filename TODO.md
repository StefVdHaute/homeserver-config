# TODO

## Nix

- [x] Improve first deployment — restic is now declarative via `services.restic.backups`; install flow is nixos-anywhere + disko for both hosts (see each host's README §1)
- [x] Check if the backup script can be replaced by something Nix-native — replaced with `services.restic.backups` in `hosts/main/configuration.nix`
- [x] Migrate inline `pkgs.writeShellScript` → `pkgs.writeShellApplication` across the repo — done; all call sites (`ntfyNotify`, `smartd-ntfy`, `tailscale-healthcheck`, `nixos-upgrade-checks`, `mdadmAlert`) now on the new form with build-time shellcheck.

## Infrastructure

- [x] Firewall rules per service in NixOS config
- [x] SMART disk monitoring via `smartd` with alerts — enabled on both hosts, alerts via ntfy `home-smart`

## Services

- [x] Seafile config with Redis caching (v13)
- [x] Container update monitoring (WUD)
- [x] Configure WUD notification channel — HTTP trigger pointing at ntfy `home-updates`
- [ ] Monitoring/alerting (Grafana + Prometheus + node-exporter)
- [x] DNS/local resolution — AdGuard Home as a NixOS service on main, tailnet + LAN, Quad9/Cloudflare DoT upstreams. UI at `adguard.DOMAIN`.
- [ ] Log viewer (e.g. Dozzle)
- [ ] Uptime monitoring (Uptime Kuma / Gatus) — ideally on the Pi so it probes main from outside and catches network-side failures main can't self-report
- [ ] Photo management (Immich) — phone camera-roll backup, replaces Google Photos
- [ ] Dashboard / home page (Homepage / Heimdall / Dashy) — single landing page linking all services
- [ ] Self-hosted git forge (Forgejo / Gitea) — so `system.autoUpgrade.flake` can pull from a local server instead of `github:...`, removing GitHub as a runtime dependency for daily upgrades.

## Future

- [ ] Self-hosted music stack: Navidrome (server) + Lidarr (auto-download) + Slskd (Soulseek client)
- [ ] Music discovery: look into ListenBrainz (recommendations/scrobbling), Spotify-to-Lidarr playlist sync, Last.fm similar artist feeds
- [ ] Self-hosted game servers (preferably with web dashboard)
  - [ ] Minecraft
  - [ ] CIV
  - [ ] Ask Stijn for more

## Security & Networking

- [x] HTTPS certs for Caddy — went with Let's Encrypt via NixOS `security.acme` + deSEC DNS-01 instead of `tailscale cert` (the latter can't issue for subdomains of a tailnet hostname). Real trusted certs on every service URL.
- [ ] Email sending / notification system for services (password resets, alerts)
- [x] Migrate `/etc/restic/env` + `/etc/acme/credentials.env` + main's `/root/.ssh/id_ed25519` to agenix — encrypted in `secrets/*.age`, decrypted at activation. `/etc/nixos/site.nix` stays as a flake path input (not secret, just site-specific). `/etc/ntfy/url` on the Pi and `hosts/main/.env` for compose remain operator-managed (different lifecycles).
- [ ] Harden ntfy auth if ever exposed beyond tailnet — add `NTFY_AUTH_DEFAULT_ACCESS=deny-all` + `NTFY_AUTH_FILE` + per-topic ACLs. Current design ("tailnet membership is the authentication") assumes tailnet-only reach.

## Pi-side alerts

- [x] ntfy alerts from the Pi for: `nixos-upgrade` failure, `/mnt/backups` mount failure, `tailscaled` daemon crash — via `ntfy-infra-failure@.service` → `home-infra` topic.
- [x] Tailscale connectivity health check — 15-min `tailscale-healthcheck.timer` on both hosts checks `BackendState == Running` + `Self.Online`, alerts to `home-infra`. Implemented in `modules/alerts.nix` under the `alerts.tailscaleHealthcheck` option.
- [ ] Fallback alert path when ntfy itself is unreachable — every alert flows through `ntfyNotify` in `modules/alerts.nix`; if the ntfy container on main is down (or main is offline), every alert is lost silently. Options to evaluate: dead-man's-switch via healthchecks.io or uptime-kuma push, SMTP as a secondary, or a redundant ntfy instance on the Pi.

## Backup

- [x] Automate the Pi `restic` user's authorized_keys — done via `mainRootPubkey` flake input (`/etc/nixos/main-root-key.pub` on the workstation). The matching private is encrypted into `secrets/main-root-sshkey.age` and decrypted onto main at `/root/.ssh/id_ed25519`. No manual paste.
- [x] Restic systemd timer schedule
- [x] Scheduled `restic check` — monthly `restic-check-deep.timer` on main runs `--read-data-subset=10%`; alerts via ntfy on failure, silent success ping on `home-backup`.
- [ ] Restore verification — periodic automated restore-to-scratch from the Pi to prove the chain end-to-end works. Post-deploy operational task; needs real data in the repo to be meaningful.
- [x] A talk needs to happen for what the remote backup server will look like — designed as `hosts/backup/` (Raspberry Pi 4, btrfs on external USB SSD; see `CLAUDE.md`)

## Before deployment

- [x] Review all files one by one with help of claude to check for security/configuration problems — done, findings landed as individual commits
- [ ] Create a plan for first deployment success review and to prepare for integration hell
- [x] Recreate this deployment on a smaller scale for the remote Raspberry pi — see `hosts/backup/`
