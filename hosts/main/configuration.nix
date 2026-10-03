{ config, lib, pkgs, ntfyNotify, siteConfig, operatorPubkeyPath, ... }:

let
  # `siteConfig` is /etc/nixos/site.nix, shape:
  #   { acmeDomain = "home.dedyn.io"; acmeEmail = "you@example.com"; }
  site = siteConfig;

  # Shared options for every restic backup job.
  # RESTIC_REPOSITORY + RESTIC_PASSWORD come from secrets/restic.env.age.
  resticCommon = {
    environmentFile = config.age.secrets.restic-env.path;
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
    extraBackupArgs = [ "--compression" "max" ];
  };

  # mdadm PROGRAM hook; argv: event, array, [device].
  mdadmAlert = pkgs.writeShellApplication {
    name = "mdadm-alert";
    text = ''
      event="$1"
      array="''${2:-unknown}"
      device="''${3:-N/A}"
      ${ntfyNotify} home-smart 4 \
        "mdadm: $event on $array" \
        "Device: $device (host: homeserver)"
    '';
  };
in

{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common.nix
    ../../modules/alerts.nix
  ];

  # ============================================================
  # Secrets (agenix); recipients in secrets/secrets.nix.
  # ============================================================
  age.secrets = {
    restic-env.file = ../../secrets/restic.env.age;

    acme-credentials = {
      file = ../../secrets/acme-credentials.env.age;
      owner = "acme";
      group = "acme";
      mode = "0400";
    };

    # Root's SSH identity for restic SFTP to the Pi's `restic` user.
    main-root-sshkey = {
      file = ../../secrets/main-root-sshkey.age;
      path = "/root/.ssh/id_ed25519";
      mode = "0600";
    };

    tailscale-authkey.file = ../../secrets/tailscale-authkey.age;
  };

  # Local ntfy container (compose port map).
  alerts.ntfy.url = "http://127.0.0.1:8085";
  alerts.smartd.enable = true;
  alerts.tailscaleHealthcheck.enable = true;

  # ============================================================
  # TLS: wildcard Let's Encrypt cert via deSEC DNS-01, written to
  # /var/lib/acme/${site.acmeDomain}/ and bind-mounted read-only into Caddy.
  # secrets/acme-credentials.env.age holds `DESEC_TOKEN=...`.
  # ============================================================
  # /etc/nixos/site.nix must be a real file on this host; auto-upgrade
  # evaluates the flake against it. Never manage it via environment.etc:
  # the `site` input then points at its own output and the flake stops evaluating.

  security.acme = {
    acceptTerms = true;
    defaults.email = site.acmeEmail;
  };
  security.acme.certs.${site.acmeDomain} = {
    domain = site.acmeDomain;
    extraDomainNames = [ "*.${site.acmeDomain}" ];
    dnsProvider = "desec";
    environmentFile = config.age.secrets.acme-credentials.path;
    group = "caddy-certs";
    reloadServices = [ "caddy-reload-certs.service" ];
  };

  # Shared by acme and the Caddy container; GID matches compose `group_add: ["2100"]`.
  users.groups.caddy-certs.gid = 2100;

  # Caddy reads certs only at startup, so restart it after each renewal.
  systemd.services.caddy-reload-certs = {
    description = "Restart Caddy after ACME cert renewal";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.docker}/bin/docker restart caddy";
    };
  };

  # ============================================================
  # Boot & Bootloader
  # ============================================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Cross-compile aarch64 (Pi backup host) from this x86_64 machine
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # Assembles the RAID 10 array from ./disko.nix at boot.
  boot.swraid.enable = true;

  # Route mdadm array events to ntfy home-smart.
  boot.swraid.mdadmConf = ''
    PROGRAM ${mdadmAlert}/bin/mdadm-alert
  '';

  # ============================================================
  # Maintenance
  # ============================================================
  # RAID 10 lets scrub repair /mnt/data; on the boot SSD it only reports errors.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" "/mnt/data" ];
  };

  systemd.tmpfiles.rules = [
    "d /mnt/data/seafile 0750 operator users - -"
    "d /mnt/data/backups 0750 operator users - -"
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

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
  users.users.operator = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    # keys/operator.pub
    openssh.authorizedKeys.keyFiles = [ operatorPubkeyPath ];
    # Set password on first boot with: passwd operator
  };

  # ============================================================
  # Nix CLI — enable flakes + nix-command for interactive use on the host
  # ============================================================
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ============================================================
  # Docker
  # ============================================================
  virtualisation.docker = {
    enable = true;
    # Store Docker data on the RAID array, not the boot SSD
    daemon.settings = {
      data-root = "/mnt/data/docker";
      # 10MB × 3 = 30MB max log per container.
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
      };
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
    authKeyFile = config.age.secrets.tailscale-authkey.path;
  };

  # ============================================================
  # Basic Packages
  # ============================================================
  # Baseline CLI tools come from modules/common.nix
  environment.systemPackages = with pkgs; [
    mdadm
    docker-compose
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
      53      # DNS (AdGuard Home)
      80      # HTTP  (Caddy)
      443     # HTTPS (Caddy)
    ];
    allowedUDPPorts = [
      53      # DNS (AdGuard Home)
      41641   # Tailscale direct connections
    ];
    # Trust all traffic from Tailscale interface
    trustedInterfaces = [ "tailscale0" ];
  };

  # ============================================================
  # DNS + ad-blocking (AdGuard Home)
  # Web UI on 127.0.0.1:3000 behind Caddy at `adguard.${DOMAIN}`;
  # DNS on 0.0.0.0:53. With mutableSettings the web UI owns state after
  # the first run.
  # ============================================================
  services.adguardhome = {
    enable = true;
    openFirewall = false;     # firewall above already opens 53
    mutableSettings = true;
    host = "127.0.0.1";
    port = 3000;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;
        # Quad9 primary, Cloudflare fallback, both over DoT.
        upstream_dns = [
          "tls://dns.quad9.net"
          "tls://1.1.1.1"
        ];
        # Plaintext resolvers used to bootstrap the DoT hostnames above.
        bootstrap_dns = [ "9.9.9.9" "1.1.1.1" ];
        enable_dnssec = true;
      };
      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };
      # Blocklists are picked in the setup wizard.
      filters = [ ];
    };
  };

  # ============================================================
  # Backups (restic → backupserver over SFTP/Tailscale)
  # Silent success ping + audible failure ping go to ntfy /home-backup.
  # ============================================================
  services.restic.backups = {
    docker-volumes = resticCommon // {
      paths = [ "/mnt/data/docker/volumes" ];
      exclude = [ "*.tmp" "*.log" ];
      extraBackupArgs = resticCommon.extraBackupArgs ++ [ "--tag" "docker-volumes" ];
      backupCleanupCommand = "${ntfyNotify} home-backup 1 'Backup OK' 'docker-volumes snapshot completed'";
    };
    seafile-data = resticCommon // {
      paths = [ "/mnt/data/seafile" ];
      extraBackupArgs = resticCommon.extraBackupArgs ++ [ "--tag" "seafile-data" ];
      backupCleanupCommand = "${ntfyNotify} home-backup 1 'Backup OK' 'seafile-data snapshot completed'";
    };
    # /var/lib/AdGuardHome is a DynamicUser symlink into /var/lib/private;
    # restic follows it. After a restore, stop adguardhome and `chown -R`
    # the files to its current UID before starting it.
    adguard-state = resticCommon // {
      paths = [ "/var/lib/AdGuardHome" ];
      extraBackupArgs = resticCommon.extraBackupArgs ++ [ "--tag" "adguard-state" ];
      backupCleanupCommand = "${ntfyNotify} home-backup 1 'Backup OK' 'adguard-state snapshot completed'";
    };
  };

  # Failure notifier from modules/alerts.nix.
  systemd.services.restic-backups-docker-volumes.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-docker-volumes.service" ];
  systemd.services.restic-backups-seafile-data.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-seafile-data.service" ];
  systemd.services.restic-backups-adguard-state.unitConfig.OnFailure =
    [ "ntfy-backup-failure@restic-backups-adguard-state.service" ];

  # Monthly deep check: reads and verifies a 10% sample of pack data over
  # SFTP, covering the whole repo statistically over ~10 months.
  systemd.services.restic-check-deep = {
    description = "Deep restic repository check (--read-data-subset=10%)";
    path = [ pkgs.restic pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.age.secrets.restic-env.path;
      ExecStart = "${pkgs.restic}/bin/restic check --read-data-subset=10%";
      ExecStartPost = "${ntfyNotify} home-backup 1 'Backup check OK' 'Monthly deep restic check passed (10% subset)'";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    unitConfig.OnFailure = [ "ntfy-backup-failure@restic-check-deep.service" ];
  };
  systemd.timers.restic-check-deep = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";        # first of every month
      Persistent = true;
      RandomizedDelaySec = "6h";     # clear of the 03:00 backup
    };
  };

  # ============================================================
  # Automatic Upgrades
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:30";
    flake = "github:StefVdHaute/homeserver-config#main";
    flags = [ "-L" ];
  };

  # Upgrade only after both restic jobs succeed.
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

  system.stateVersion = "26.05";
}
