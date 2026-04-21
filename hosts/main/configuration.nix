{ config, pkgs, ntfyNotify, ... }:

let
  # Site-specific values kept out of git (operator creates this file
  # before the first `nixos-rebuild switch`; see hosts/main/README.md).
  # Expected shape:
  #   { acmeDomain = "home.dedyn.io"; acmeEmail = "you@example.com"; }
  site = import /etc/nixos/site.nix;

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
    ../../modules/alerts.nix
  ];

  # Operator alerts → local ntfy container (127.0.0.1:8085 via compose port map).
  alerts.ntfy.url = "http://127.0.0.1:8085";
  alerts.smartd.enable = true;
  alerts.tailscaleHealthcheck.enable = true;

  # ============================================================
  # TLS certificates via Let's Encrypt DNS-01 ACME through deSEC.
  # Produces a wildcard cert covering *.${site.acmeDomain} at
  # /var/lib/acme/${site.acmeDomain}/. Caddy reads it via a read-only
  # bind mount (see hosts/main/compose/caddy.yml + the `acme_tls`
  # snippet in Caddyfile).
  #
  # DNS provider credentials live in /etc/acme/credentials.env
  # (operator-managed, outside Nix, same pattern as /etc/restic/env and
  # /etc/ntfy/url). For deSEC the file contains `DESEC_TOKEN=...`; if you
  # ever switch providers, replace the variable name accordingly and
  # flip `dnsProvider` below.
  # ============================================================
  security.acme = {
    acceptTerms = true;
    defaults.email = site.acmeEmail;
  };
  security.acme.certs.${site.acmeDomain} = {
    domain = site.acmeDomain;
    extraDomainNames = [ "*.${site.acmeDomain}" ];
    dnsProvider = "desec";
    credentialsFile = "/etc/acme/credentials.env";
    group = "caddy-certs";
    reloadServices = [ "caddy-reload-certs.service" ];
  };

  # Group the acme user and the Caddy container both belong to, so
  # cert files (owned acme:caddy-certs, mode 0640) are readable by
  # Caddy. Fixed GID so compose's `group_add: ["2100"]` matches.
  users.groups.caddy-certs.gid = 2100;

  # Restart Caddy after each renewal so new cert files take effect.
  # `|| true` so renewal doesn't fail on first deploy before Caddy is up.
  systemd.services.caddy-reload-certs = {
    description = "Restart Caddy after ACME cert renewal";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker restart caddy || true'";
    };
  };

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

  # Wire each backup unit's failure path to the templated notifier from
  # modules/alerts.nix.
  systemd.services.restic-backups-docker-volumes.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-docker-volumes.service" ];
  systemd.services.restic-backups-seafile-data.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-seafile-data.service" ];

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
