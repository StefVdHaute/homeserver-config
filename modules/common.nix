# CLI tool belt shared by all hosts.

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
}
