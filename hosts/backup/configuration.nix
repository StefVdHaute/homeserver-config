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
  #
  # Restic must never write to the OS SSD when the drive is absent (main
  # runs `initialize = true` and would init a fresh repo there, reporting
  # success). Two guards:
  #   - automount: an autofs mount always covers /mnt/backups, so with the
  #     drive absent every access fails after device-timeout instead of
  #     landing on the SSD. Boot no longer waits for the drive either.
  #   - the bare mountpoint under it is root:root 0000 (activation script
  #     below), in case the automount is ever stopped.
  # The repo dir /mnt/backups/homeserver lives on the drive, created once
  # at provisioning (README §4).
  # ============================================================
  fileSystems."/mnt/backups" = {
    device = "/dev/disk/by-label/backup-data";
    fsType = "btrfs";
    options = [
      "subvol=@homeserver" "compress=zstd:3" "noatime" "nofail"
      "x-systemd.automount" "x-systemd.device-timeout=30s"
    ];
  };

  # At boot this runs before systemd sets up the automount, so it always
  # reaches the bare directory. Skipped when anything is mounted there
  # (touching the automount would block a switch on an absent drive).
  system.activationScripts.backupMountpoint.text = ''
    if ! ${pkgs.util-linux}/bin/mountpoint -q /mnt/backups; then
      mkdir -p /mnt/backups
      chown root:root /mnt/backups
      chmod 0000 /mnt/backups
    fi
  '';

  # Every 3h: alert when the drive isn't actually mounted. Needed because a
  # drive that never appears leaves mnt-backups.mount inactive, not failed,
  # so its OnFailure hook doesn't fire. The autofs mount always counts as a
  # mountpoint, hence the btrfs type check after triggering it.
  systemd.services.backup-drive-check = {
    description = "Check that the backup data drive is mounted";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-drive-check" ''
        ${pkgs.coreutils}/bin/ls /mnt/backups >/dev/null 2>&1 || true
        if ! ${pkgs.util-linux}/bin/findmnt -t btrfs /mnt/backups >/dev/null; then
          ${ntfyNotify} home-infra 4 \
            "Backup drive missing on ${config.networking.hostName}" \
            "/mnt/backups is not mounted; restic backups from main will fail. Check lsblk -f and journalctl -u mnt-backups.mount"
        fi
      '';
    };
    # Catches the check itself failing (e.g. ntfy unreachable).
    unitConfig.OnFailure = [ "ntfy-infra-failure@backup-drive-check.service" ];
  };
  systemd.timers.backup-drive-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15m";
      OnUnitActiveSec = "3h";
    };
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

  # ============================================================
  # SSH — reachable via tailnet and LAN (firewall below enforces)
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
  #   tailscale0, LAN (192.168.128.0/23, fe80::/10 on end0) → trusted
  #   everything else → drop
  # ============================================================
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ 41641 ]; # Tailscale direct connections
    trustedInterfaces = [ "tailscale0" ];
    extraCommands = ''
      iptables -A nixos-fw -s 192.168.128.0/23 -j nixos-fw-accept
      ip6tables -A nixos-fw -i end0 -s fe80::/10 -j nixos-fw-accept
    '';
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
  # No ConditionPath* on /mnt/backups: PID1 would trigger its own
  # automount. The ExecCondition runs in a child process instead.
  systemd.services.nixos-upgrade = {
    unitConfig.OnFailure = [ "ntfy-infra-failure@nixos-upgrade.service" ];
    serviceConfig.ExecCondition =
      let
        script = pkgs.writeShellApplication {
          name = "nixos-upgrade-checks";
          runtimeInputs = [ pkgs.findutils pkgs.curl pkgs.coreutils ];
          text = ''
            recent=$(find /mnt/backups/homeserver/snapshots -type f -newermt '-24 hours' -print -quit 2>/dev/null || true)
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
