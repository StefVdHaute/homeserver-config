{ config, pkgs, ... }:

let
  # Operator-alert helper. POSTs to the locally-running ntfy container
  # (see hosts/main/compose/ntfy.yml, port-mapped 127.0.0.1:8085 → :80).
  #   ntfyNotify <topic> <priority> <title> <message>
  ntfyNotify = pkgs.writeShellScript "ntfy-notify" ''
    set -euo pipefail
    topic="$1"; priority="$2"; title="$3"; message="$4"
    ${pkgs.curl}/bin/curl -fsS \
      -H "Priority: $priority" \
      -H "Title: $title" \
      -d "$message" \
      "http://127.0.0.1:8085/$topic" >/dev/null
  '';

  # Shared options for every restic backup job on this host.
  # /etc/restic/env holds RESTIC_REPOSITORY= and RESTIC_PASSWORD=,
  # read by the service at runtime (expected repo:
  # sftp:restic@backupserver.<tailnet>.ts.net:/mnt/backups/homeserver).
  resticCommon = {
    environmentFile = "/etc/restic/env";
    initialize = true;
    timerConfig = {
      OnCalendar = "03:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
    checkOpts = [ ];   # empty = structural check every run, no --read-data
  };
in

{
  imports = [
    ./hardware-configuration.nix
  ];

  # ============================================================
  # Boot & Bootloader
  # ============================================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Cross-compile aarch64 (Pi backup host) from this x86_64 machine
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # RAID support in initrd
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "usbhid" "sd_mod"
    "raid10" "md_mod"
  ];

  boot.swraid = {
    enable = true;
    mdadmConf = ''
      MAILADDR root
      AUTO +imsm +1.x homehost=homeserver
    '';
  };

  # ============================================================
  # File Systems
  # ============================================================

  # Boot SSD (250GB) — adjust labels to match your actual device
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos-root";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/nixos-boot";
    fsType = "vfat";
  };

  # RAID 10 array — /dev/md0 is created from 4x 1TB drives
  # Label this after first boot with: e2label /dev/md0 data
  fileSystems."/mnt/data" = {
    device = "/dev/disk/by-label/data";
    fsType = "ext4";
    options = [ "defaults" "nofail" ];
  };

  # ============================================================
  # Swap
  # ============================================================
  swapDevices = [
    { device = "/dev/disk/by-label/nixos-swap"; }
  ];

  # ============================================================
  # Networking
  # ============================================================
  networking.hostName = "homeserver";
  networking.networkmanager.enable = true;

  # ============================================================
  # Time & Locale
  # ============================================================
  time.timeZone = "Europe/Brussels";
  i18n.defaultLocale = "en_US.UTF-8";

  # ============================================================
  # Users
  # ============================================================
  users.users.stef = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    # Set password on first boot with: passwd stef
  };

  # ============================================================
  # Docker
  # ============================================================
  virtualisation.docker = {
    enable = true;
    # Store Docker data on the RAID array, not the boot SSD
    daemon.settings = {
      data-root = "/mnt/data/docker";
    };
  };

  # ============================================================
  # SSH
  # ============================================================
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ============================================================
  # Tailscale
  # ============================================================
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };

  # ============================================================
  # Basic Packages
  # ============================================================
  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    mdadm
    docker-compose
    curl
    wget
    restic
    pwgen       # needed to generate Seafile JWT_PRIVATE_KEY
  ];

  # ============================================================
  # Firewall
  # ============================================================
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22      # SSH
      80      # HTTP  (Caddy)
      443     # HTTPS (Caddy)
    ];
    allowedUDPPorts = [
      41641   # Tailscale direct connections
    ];
    # Trust all traffic from Tailscale interface
    trustedInterfaces = [ "tailscale0" ];
  };

  # ============================================================
  # SMART disk monitoring (alerts to ntfy /home-smart)
  # ============================================================
  services.smartd = {
    enable = true;
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../6/03) -M exec ${pkgs.writeShellScript "smartd-ntfy" ''
      exec ${ntfyNotify} home-smart 4 \
        "SMART alert: homeserver — $SMARTD_DEVICE" \
        "$SMARTD_MESSAGE"
    ''}";
  };

  # ============================================================
  # Backups (restic → backupserver over SFTP/Tailscale)
  # Silent success ping + audible failure ping go to ntfy /home-backup.
  # ============================================================
  services.restic.backups = {
    docker-volumes = resticCommon // {
      paths = [ "/mnt/data/docker/volumes" ];
      exclude = [ "*.tmp" "*.log" ];
      extraBackupArgs = [ "--tag" "docker-volumes" ];
      backupCleanupCommand = "${ntfyNotify} home-backup 1 'Backup OK' 'docker-volumes snapshot completed'";
    };
    seafile-data = resticCommon // {
      paths = [ "/mnt/data/seafile" ];
      extraBackupArgs = [ "--tag" "seafile-data" ];
      backupCleanupCommand = "${ntfyNotify} home-backup 1 'Backup OK' 'seafile-data snapshot completed'";
    };
  };

  # Wire each backup unit's failure path to the templated notifier below.
  systemd.services.restic-backups-docker-volumes.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-docker-volumes.service" ];
  systemd.services.restic-backups-seafile-data.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-seafile-data.service" ];

  # Templated notifier: reusable for any future OnFailure hook that should
  # land on the backup topic. %i = the failed unit's name.
  systemd.services."ntfy-backup-failure@" = {
    description = "Notify ntfy of failed backup unit %i";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ntfyNotify} home-backup 3 'Backup FAILED' 'unit %i failed — run journalctl -u %i for details'";
    };
  };

  # ============================================================
  # Automatic Upgrades
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:30";
  };

  # Only upgrade after both restic backup jobs succeeded today
  systemd.services.nixos-upgrade = {
    after = [
      "restic-backups-docker-volumes.service"
      "restic-backups-seafile-data.service"
    ];
    requires = [
      "restic-backups-docker-volumes.service"
      "restic-backups-seafile-data.service"
    ];
  };

  system.stateVersion = "25.11";
}
