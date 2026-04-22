# Committed hand-authored hardware stub for `backupserver` (Pi 4).
# Replaces the on-device `nixos-generate-config` output — filesystems
# are owned by disko (see ./disko.nix) and firmware / bootloader /
# kernel wiring come from nixos-hardware.nixosModules.raspberry-pi-4,
# so this file only carries low-level platform bits.

{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "aarch64-linux";

  boot.initrd.availableKernelModules = [
    "usbhid" "usb_storage" "mmc_block"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];
}
