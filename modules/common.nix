# Baseline shared by all hosts: the universal CLI tool belt. Anything
# host-specific (mdadm, restic, desktop tools, …) stays in that host's
# configuration.nix.

{ pkgs, ... }:

{
  imports = [ ./nixh ];

  # nixh carries its own deps (nh, fzf) in its wrapper, so enabling it here
  # does not put them on anyone's PATH. Hosts override programs.nixh.repo.
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
}
