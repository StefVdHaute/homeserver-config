# Baseline shared by all hosts: the universal CLI tool belt. Anything
# host-specific (mdadm, restic, desktop tools, …) stays in that host's
# configuration.nix.

{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    git
    vim
    nano
    htop
    curl
    wget
    usbutils    # lsusb
  ];
}
