# NixOS config for `backupserver` — Raspberry Pi 4 restic backup target.
#
# Security invariant: the restic password never lives on this host. All
# operations that need the password (backup, prune, check, restore) run
# from `homeserver` (main). A compromise of this Pi cannot decrypt backups.
# Running other services here (Docker, edge-replicated services, etc.)
# remains fine — they just must not touch the restic repo encryption keys.

{ config, lib, pkgs, ... }:

let
  # Operator-alert helper. Reads the base URL of the ntfy server from
  # /etc/ntfy/url (operator-managed, e.g. `https://ntfy.<tailnet>.ts.net`)
  # and appends the topic.
  #   ntfyNotify <topic> <priority> <title> <message>
  ntfyNotify = pkgs.writeShellScript "ntfy-notify" ''
    set -euo pipefail
    topic="$1"; priority="$2"; title="$3"; message="$4"
    base="$(cat /etc/ntfy/url)"
    ${pkgs.curl}/bin/curl -fsS \
      -H "Priority: $priority" \
      -H "Title: $title" \
      -d "$message" \
      "$base/$topic" >/dev/null
  '';
in

{
  imports = [
    ./hardware-configuration.nix
  ];

  # ============================================================
  # Boot & Bootloader — Pi 4 uses extlinux
  # ============================================================
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # ============================================================
  # File Systems — /mnt/backups on the external btrfs USB drive
  # SD-card root fs comes from hardware-configuration.nix (generated on-device)
  # ============================================================
  fileSystems."/mnt/backups" = {
    device = "/dev/disk/by-label/backup-data";
    fsType = "btrfs";
    options = [ "compress=zstd:3" "noatime" "nofail" "subvol=@homeserver" ];
  };

  # ============================================================
  # Swap — 4GB swapfile on the external drive, not the SD card (SD wear)
  # ============================================================
  swapDevices = [
    {
      device = "/mnt/backups/.swapfile";
      size = 4 * 1024; # MB
    }
  ];

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
    openssh.authorizedKeys.keys = [
      # TODO: paste your workstation's SSH pubkey here before first deploy
    ];
  };

  # Dedicated user for restic SFTP pushes from main
  users.users.restic = {
    isSystemUser = true;
    group = "restic";
    home = "/var/lib/restic";
    createHome = true;
    shell = pkgs.bashInteractive; # SFTP via OpenSSH needs a real shell
    openssh.authorizedKeys.keys = [
      # TODO: paste main server's ~/.ssh/id_ed25519.pub here before first deploy
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
  # SMART disk monitoring (alerts to ntfy /home-smart via main's Caddy)
  # USB-SATA bridges usually need `-d sat` for SMART passthrough; verify
  # with `sudo smartctl -a -d sat /dev/sda` after first boot.
  # ============================================================
  services.smartd = {
    enable = true;
    defaults.monitored = "-a -d sat -o on -s (S/../.././02|L/../../6/03) -M exec ${pkgs.writeShellScript "smartd-ntfy" ''
      exec ${ntfyNotify} home-smart 4 \
        "SMART alert: backupserver — $SMARTD_DEVICE" \
        "$SMARTD_MESSAGE"
    ''}";
  };

  # ============================================================
  # Automatic Upgrades
  # Runs daily at 05:30, but only when a recent restic snapshot has landed
  # (proof that main is alive and the backup pipeline is working).
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "05:30";
    flake = "/home/stef/server_config#backup";
    flags = [ "-L" ];
  };

  # Skip the upgrade if no snapshot file on the backup repo has been written
  # in the last 24h. This catches "main has been offline for a week" and
  # "backups have been silently failing."
  systemd.services.nixos-upgrade.serviceConfig.ExecCondition =
    let
      script = pkgs.writeShellScript "backup-fresh" ''
        snapdir=/mnt/backups/homeserver/snapshots
        if [ ! -d "$snapdir" ]; then
          echo "no backup repo yet — skipping upgrade"
          exit 1
        fi
        recent=$(find "$snapdir" -type f -newermt '-24 hours' -print -quit)
        if [ -z "$recent" ]; then
          echo "no restic snapshot newer than 24h — skipping upgrade"
          exit 1
        fi
        exit 0
      '';
    in "${script}";

  system.stateVersion = "25.11";
}
