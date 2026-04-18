{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  # ============================================================
  # Boot & Bootloader
  # ============================================================
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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
  # Automatic Upgrades
  # ============================================================
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:30";
  };

  # Only upgrade after a successful backup
  systemd.services.nixos-upgrade = {
    after = [ "restic-backup.service" ];
    requires = [ "restic-backup.service" ];
  };

  system.stateVersion = "25.11";
}
