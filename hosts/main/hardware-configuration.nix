# Hand-authored hardware stub; filesystems come from ./disko.nix.

{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "usbhid" "sd_mod"
    "raid10" "md_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Also gates the Intel microcode updates below.
  hardware.enableRedistributableFirmware = true;

  hardware.cpu.intel.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
