# TODO

## Infrastructure

- [ ] Pi firmware — `backup` evaluates `hardware.enableRedistributableFirmware` to `false`; main and workstation set it in their hand-written hardware stubs (a generated stub gets it from `not-detected.nix`). Check whether the Pi needs anything from `linux-firmware`.

## Services

- [ ] Monitoring/alerting (Grafana + Prometheus + node-exporter)
- [ ] Log viewer (e.g. Dozzle)
- [ ] Uptime monitoring (Uptime Kuma / Gatus) — ideally on the Pi so it probes main from outside and catches network-side failures main can't self-report
- [ ] Photo management (Immich) — phone camera-roll backup, replaces Google Photos
- [ ] Dashboard / home page (Homepage / Heimdall / Dashy) — single landing page linking all services
- [ ] Self-hosted git forge (Forgejo / Gitea) — so `system.autoUpgrade.flake` can pull from a local server instead of `github:...`, removing GitHub as a runtime dependency for daily upgrades.
- [ ] Drop go2rtc from `hosts/backup/compose/fluidd.yml` when the OrcaSlicer Device tab can play WebRTC. go2rtc is there only because that tab (WebKitGTK) has no WebRTC. Two conditions:
  - nixpkgs builds `webkitgtk_4_1` with WebRTC. Now it does so only with `enableExperimental`. Check: `grep -c GStreamerMediaEndpoint` on `libwebkit2gtk-4.1.so` is not 0.
  - OrcaSlicer turns it on (`webkit_settings_set_enable_webrtc`). OrcaSlicer#15362 lists WebRTC cameras as future work.

  Then set the K1C camera to `iframe` with `http://192.168.129.35:8000/`, and remove the `go2rtc` service, `go2rtc.yaml`, `fluidd-nginx.conf.template` and the `/camera` relay in `k1c-proxy`. If go2rtc fixes the K1C first (AlexxIT/go2rtc#2024), only the `/camera` relay can go.

## Future

- [ ] Self-hosted music stack: Navidrome (server) + Lidarr (auto-download) + Slskd (Soulseek client)
- [ ] Music discovery: look into ListenBrainz (recommendations/scrobbling), Spotify-to-Lidarr playlist sync, Last.fm similar artist feeds
- [ ] Self-hosted game servers (preferably with web dashboard)
  - [ ] Minecraft
  - [ ] CIV
  - [ ] Ask Stijn for more

## Security & Networking

- [ ] Email sending / notification system for services (password resets, alerts)
- [ ] Harden ntfy auth if ever exposed beyond tailnet — add `NTFY_AUTH_DEFAULT_ACCESS=deny-all` + `NTFY_AUTH_FILE` + per-topic ACLs. Current design ("tailnet membership is the authentication") assumes tailnet-only reach.

## Pi-side alerts

- [ ] Fallback alert path when ntfy itself is unreachable — every alert flows through `ntfyNotify` in `modules/alerts.nix`; if the ntfy container on main is down (or main is offline), every alert is lost silently. Options to evaluate: dead-man's-switch via healthchecks.io or uptime-kuma push, SMTP as a secondary, or a redundant ntfy instance on the Pi.

## Backup

- [ ] Restore verification — periodic automated restore-to-scratch from the Pi to prove the chain end-to-end works. Post-deploy operational task; needs real data in the repo to be meaningful.
- [ ] Off-site copy of the restic repo — the Pi holds the only copy, so corruption there has no recovery path.

## Workstation

- [ ] Boot-test the Arch entry in the Limine menu — the `uuid()` chainload path has not been confirmed to boot.
- [ ] One real hibernate/resume test — the image should go to the `/swap` swapfile, not zram, but that is inferred.
- [ ] Verify one fwupd capsule update applies — nixpkgs#534574 can make `fwupdmgr update` report success and apply nothing. If it no-ops, update firmware with Framework's EFI updater from a FAT32 USB.
- [ ] Backup — Seafile -> main -> Pi covers synced files and git covers the dotfiles. Not covered: unpushed work, `~/Downloads`, VM images, Proton prefixes, game saves outside Steam Cloud. Don't put main's restic password on the laptop: use a separate repo + password, or treat the laptop as disposable.
- [ ] Snapshot tooling (snapper / btrbk) — none yet, so the subvolume splits give no rollback protection. Add `@nix` and `@docker` subvolumes together with it.
- [ ] Autostart `blueman-applet` — it does not run in the session, and `blueman-manager` can pair but not connect without it as the BlueZ agent.
- [ ] agenix on the workstation — `secrets/secrets.nix` reads `/etc/nixos/main-host-key.pub`, which does not exist here, so every `agenix` command fails to evaluate (raw `age -d -i <key>` works). Fetch it: `ssh operator@homeserver 'cat /etc/ssh/ssh_host_ed25519_key.pub'`.
- [ ] aarch64 emulation — DEPLOY.md section 4 builds the Pi closure on the workstation, but the NixOS workstation has no `boot.binfmt.emulatedSystems = [ "aarch64-linux" ]`.
- [ ] Install docs — DEPLOY.md has no workstation section (path: disko + `nixos-install --flake .#workstation`, like the Pi flash in section 4.1), and there is no `hosts/workstation/README.md`.
- [ ] DEPLOY.md section 2.5 runs `nix flake lock` without `--extra-experimental-features 'nix-command flakes'`; Arch's nix.conf does not enable flakes, so the step fails on a fresh workstation.
- [ ] `site` input — evaluating any host needs `/etc/nixos/site.nix`, though only main reads it. Decide whether it stays a flake-level input.
- [ ] Decide whether the workstation imports `modules/alerts.nix` (smartd -> ntfy for its NVMe).
- [ ] Revisit `hyprpolkitagent` in place of `polkit_gnome` once nixpkgs ships a tagged hyprtoolkit-based release — 0.1.3 breaks the fingerprint flow (hyprpolkitagent#24).

## Before deployment

Main hardware (Dell R720), in this order:

- [ ] Update iDRAC7 firmware (now 2.52.52.52; 2.65.65.65 is the last release) and Lifecycle Controller. BIOS 2.9.0 is already current.
- [ ] Cross-flash the PERC H710P Mini to IT mode (LSI SAS2308) — follow the Fohdeesha guide for the H710P Mini. Note the controller's SAS address before wiping it. The flash leaves the card without a boot ROM, so also flash the UEFI one (`flashboot /root/Bootloaders/x64sas2.rom`); without it the R720's UEFI cannot see the disks and can't boot from them. Afterwards disable `ThirdPartyPCIFanResponse` (fans otherwise stick at ~30%) and set the boot mode back to UEFI. Full procedure: `plan.md` (untracked).
- [ ] Boot an installer, check that all four disks show up as plain disks with SMART (`smartctl -a /dev/sdX`), and put their `/dev/disk/by-id/` paths into `diskIds` in `hosts/main/disko.nix`.
- [ ] Set the iDRAC time zone to Europe/Brussels (it is on UTC-06:00).
- [ ] Test the disk failure path once, before real data: pull one disk with the server running, reboot, check that `/` comes up, `/mnt/data` stays unmounted and the `home-smart` alerts arrive, then follow `hosts/main/README.md` §13 to rebuild.
- [ ] Later: replace the ST1000DM010 desktop disks with NAS-rated ones (ERC/TLER), and/or add an SSD on the free onboard SATA ports for `/`.

- [ ] Create a plan for first deployment success review and to prepare for integration hell
