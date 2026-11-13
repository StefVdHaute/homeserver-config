# Baseline shared by all hosts: CLI tool belt, Nix maintenance, locale,
# key-only SSH, and Tailscale with a firewall that trusts the tailnet.

{ pkgs, ... }:

{
  imports = [ ./nixh ];

  # nh and fzf stay inside nixh's wrapper, off PATH.
  programs.nixh.enable = true;

  environment.systemPackages = with pkgs; [
    git
    vim
    nano
    htop
    curl
    wget
    usbutils
    smartmontools
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Weekly garbage collection, plus hard-linking of duplicate store paths.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  time.timeZone = "Europe/Brussels";
  i18n.defaultLocale = "en_US.UTF-8";

  networking.networkmanager.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Hosts set useRoutingFeatures and their auth key themselves.
  services.tailscale.enable = true;

  networking.firewall = {
    enable = true;
    allowedUDPPorts = [ 41641 ];   # Tailscale direct connections
    trustedInterfaces = [ "tailscale0" ];
  };
}
