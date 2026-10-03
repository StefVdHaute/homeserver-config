# NixOS config for `backupserver` — Raspberry Pi 4 restic backup target.
#
# The restic password never lives on this host; everything that needs it
# runs from main. Nothing here may touch the restic repo encryption keys.

{ config, pkgs, ntfyNotify, operatorPubkeyPath, mainRootPubkeyPath, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/alerts.nix
  ];

  # Operator alerts → main's ntfy; base URL comes from a one-line file.
  alerts.ntfy.urlFile = "/etc/ntfy/url";
  alerts.smartd = {
    enable = true;
    useDSat = true;   # USB-SATA bridge needs -d sat for SMART passthrough
    # DEVICESCAN can't scan with -d sat, so drives are listed by-id.
    devices = [ "/dev/disk/by-id/usb-WDC_WDS2_40G2G0A-00JH30_0000000001A7-0:0" ];
  };
  alerts.tailscaleHealthcheck.enable = true;

  # ============================================================
  # Swap — compressed in-RAM swap via zram
  # ============================================================
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # ============================================================
  # Storage — backup data drive
  # Outside disko so no install/reinstall can format the restic repo;
  # provision a fresh drive with ./disko-data.nix.
  # ============================================================
  fileSystems."/mnt/backups" = {
    device = "/dev/disk/by-label/backup-data";
    fsType = "btrfs";
    options = [ "subvol=@homeserver" "compress=zstd:3" "noatime" "nofail" ];
  };

  # ============================================================
  # Docker — edge-replicated services / side projects
  # ============================================================
  virtualisation.docker = {
    enable = true;
    daemon.settings = {
      data-root = "/srv/projects/docker";
      # Caps container logs so they can't fill the SSD.
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
      };
    };
  };

  # ============================================================
  # Maintenance
  # ============================================================
  # Monthly btrfs scrub; with no redundancy it only reports bad blocks.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" "/mnt/backups" ];
  };

  # Garbage-collect old store paths weekly + hard-link duplicates.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

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
  users.users.operator = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    # keys/operator.pub, via flake specialArgs.
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
  };

  # Restic SFTP target for main. sftp-server ignores the login shell, so
  # nologin denies main's root key an interactive shell.
  users.users.restic = {
    isSystemUser = true;
    group = "restic";
    home = "/var/lib/restic";
    createHome = true;
    shell = "${pkgs.util-linux}/bin/nologin";
    # keys/main-root.pub; private half is secrets/main-root-sshkey.age.
    openssh.authorizedKeys.keyFiles = [ mainRootPubkeyPath ];
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
    authKeyFile = "/etc/tailscale/authkey";
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
  # Packages
  # ============================================================
  # Baseline CLI tools come from modules/common.nix
  environment.systemPackages = with pkgs; [
    tailscale
    btrfs-progs
    smartmontools
    docker-compose
  ];

  # ============================================================
  # Automatic Upgrades
  # Runs daily at 05:30, only when a recent restic snapshot has landed.
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "05:30";
    flake = "github:StefVdHaute/homeserver-config#backup";
    flags = [ "-L" ];
  };

  # Skip the upgrade if:
  #   - the backup repo dir doesn't exist (first install, or /mnt/backups
  #     not mounted), OR
  #   - no restic snapshot is newer than 24h, OR
  #   - main's ntfy /v1/health is unreachable.
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

  # tailscaled daemon crash.
  systemd.services.tailscaled.unitConfig.OnFailure =
    [ "ntfy-infra-failure@tailscaled.service" ];

  # /mnt/backups mount failure (USB drive detached, fs errors, etc.).
  systemd.units."mnt-backups.mount" = {
    overrideStrategy = "asDropin";
    text = ''
      [Unit]
      OnFailure=ntfy-infra-failure@mnt-backups.mount.service
    '';
  };

  system.stateVersion = "26.05";
}
