# Workstation hardware stub (Framework 16, AMD Ryzen 7000-series).
# Most board-specific bits come from the
# nixos-hardware.nixosModules.framework-16-7040-amd module wired in
# flake.nix; this file just carries platform + initrd kernel modules.

{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "usbhid" "uas" "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
