# NixOS config for `backupserver` — Raspberry Pi 4 restic backup target.
#
# Security invariant: the restic password never lives on this host. All
# operations that need the password (backup, prune, check, restore) run
# from `homeserver` (main). A compromise of this Pi cannot decrypt backups.
# Running other services here (Docker, edge-replicated services, etc.)
# remains fine — they just must not touch the restic repo encryption keys.

{ config, pkgs, ntfyNotify, operatorPubkeyPath, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/alerts.nix
  ];

  # Operator alerts → main's ntfy, via tailnet Caddy. Base URL kept out of
  # Nix (tailnet hostname is site-specific) and supplied by a one-line file.
  alerts.ntfy.urlFile = "/etc/ntfy/url";
  alerts.smartd = {
    enable = true;
    useDSat = true;   # USB-SATA bridge needs -d sat for SMART passthrough
  };
  alerts.tailscaleHealthcheck.enable = true;

  # ============================================================
  # Swap — compressed in-RAM swap via zram. No disk wear (SD or USB),
  # no btrfs-CoW gotcha that a swapfile on /mnt/backups would hit, and
  # the Pi's workload (receiving SFTP pushes) rarely needs to swap out
  # anyway. 50% of RAM as zstd-compressed swap gives effective ~100%
  # RAM headroom on a Pi 4.
  #
  # Boot/bootloader wiring and /mnt/backups are declared outside this
  # file: bootloader comes from nixos-hardware.nixosModules.raspberry-
  # pi-4, disk layout + /mnt/backups mount come from ./disko.nix.
  # ============================================================
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # ============================================================
  # Networking
  # ============================================================
  networking.hostName = "backupserver";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Brussels";
  i18n.defaultLocale = "en_US.UTF-8";

  # ============================================================
  # Users
  # ============================================================
  users.users.stef = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # Operator pubkey comes in as `operatorPubkeyPath` via specialArgs
    # from flake.nix (path input to /etc/nixos/operator.pub). Pure eval;
    # SSH works immediately after first boot. Mirrors main.
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
  };

  # Dedicated user for restic SFTP pushes from main. SFTP via OpenSSH's
  # sftp-server subsystem does NOT invoke the user's shell, so nologin
  # is safe; keeps an attacker with main's root key from getting an
  # interactive shell on the Pi.
  users.users.restic = {
    isSystemUser = true;
    group = "restic";
    home = "/var/lib/restic";
    createHome = true;
    shell = "${pkgs.util-linux}/bin/nologin";
    openssh.authorizedKeys.keys = [
      # TODO: paste main server's /root/.ssh/id_ed25519.pub here before
      # deploy. See TODO.md "Automate restic host pubkey on Pi".
    ];
  };
  users.groups.restic = { };

  # Pre-create the repository directory owned by `restic`
  systemd.tmpfiles.rules = [
    "d /mnt/backups/homeserver 0700 restic restic - -"
  ];

  # ============================================================
  # SSH — only reachable via tailnet (firewall below enforces)
  # ============================================================
  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ============================================================
  # Tailscale — leaf node, no route advertising
  # ============================================================
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "none";
  };

  # ============================================================
  # Firewall
  # Net effect:
  #   eth0/wlan0 → drop everything
  #   tailscale0 → trusted (SSH 22 reachable here only)
  # ============================================================
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ 41641 ]; # Tailscale direct connections
    trustedInterfaces = [ "tailscale0" ];
    logRefusedConnections = true;
  };

  # ============================================================
  # Packages — minimal by default. Adding Docker etc. later is a one-liner.
  # ============================================================
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    tailscale
    btrfs-progs
    smartmontools
  ];

  # ============================================================
  # Automatic Upgrades
  # Runs daily at 05:30, but only when a recent restic snapshot has landed
  # (proof that main is alive and the backup pipeline is working).
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "05:30";
    flake = "github:StefVdHaute/homeserver-config#backup";
    flags = [ "-L" ];
  };

  # Skip the upgrade if:
  #   - the backup repo dir doesn't exist (first-install state; systemd's
  #     ConditionPathIsDirectory skips the unit silently — the underlying
  #     cause, a failed /mnt/backups mount, alerts separately via the
  #     mnt-backups.mount OnFailure drop-in below), OR
  #   - no fresh restic snapshot (<24h) — backup pipeline / main offline, OR
  #   - main's ntfy /v1/health is unreachable — main is degraded; don't
  #     follow it into brokenness.
  systemd.services.nixos-upgrade = {
    unitConfig = {
      ConditionPathIsDirectory = "/mnt/backups/homeserver/snapshots";
      OnFailure = [ "ntfy-infra-failure@nixos-upgrade.service" ];
    };
    serviceConfig.ExecCondition =
      let
        script = pkgs.writeShellApplication {
          name = "nixos-upgrade-checks";
          runtimeInputs = [ pkgs.findutils pkgs.curl pkgs.coreutils ];
          text = ''
            recent=$(find /mnt/backups/homeserver/snapshots -type f -newermt '-24 hours' -print -quit)
            if [ -z "$recent" ]; then
              echo "no restic snapshot newer than 24h — skipping upgrade"
              exit 1
            fi
            base="$(tr -d '\n' < /etc/ntfy/url)"
            if ! curl -fsS --connect-timeout 5 --max-time 10 "$base/v1/health" >/dev/null 2>&1; then
              echo "main ntfy /v1/health unreachable — skipping upgrade"
              exit 1
            fi
          '';
        };
      in "${script}/bin/nixos-upgrade-checks";
  };

  # ============================================================
  # Pi-side infra-failure alerts (→ ntfy /home-infra)
  # The templated ntfy-infra-failure@.service lives in modules/alerts.nix.
  # ============================================================

  # tailscaled daemon crash. Only catches the daemon process dying;
  # "daemon up but tailnet unreachable" needs an active health check
  # (tracked in TODO.md).
  systemd.services.tailscaled.unitConfig.OnFailure =
    [ "ntfy-infra-failure@tailscaled.service" ];

  # /mnt/backups mount failure (USB drive detached, fs errors, etc.).
  # The mount unit is auto-generated (by disko/fileSystems), so we attach
  # OnFailure via a drop-in rather than redefining the unit. `nofail` in
  # the fs options keeps boot succeeding, but the unit still enters
  # `failed` state and fires OnFailure.
  systemd.units."mnt-backups.mount" = {
    overrideStrategy = "asDropinIfExists";
    text = ''
      [Unit]
      OnFailure=ntfy-infra-failure@mnt-backups.mount
    '';
  };

  system.stateVersion = "25.11";
}
