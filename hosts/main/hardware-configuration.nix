# Hand-authored hardware stub for the Dell PowerEdge R720; filesystems come
# from ./disko.nix, boot and RAID from ./storage.nix.

{ config, lib, pkgs, ... }:

{
  nixpkgs.hostPlatform = "x86_64-linux";

  # mpt3sas: the PERC H710P Mini cross-flashed to IT mode (LSI SAS2308).
  # ahci: onboard SATA ports (empty, kept for a later SSD).
  boot.initrd.availableKernelModules = [
    "mpt3sas" "ahci" "ehci_pci" "xhci_pci" "usbhid" "sd_mod"
    "raid10" "md_mod" "btrfs"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" "ipmi_si" "ipmi_devintf" ];
  boot.extraModulePackages = [ ];

  # Also gates the Intel microcode updates below.
  hardware.enableRedistributableFirmware = true;

  hardware.cpu.intel.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
