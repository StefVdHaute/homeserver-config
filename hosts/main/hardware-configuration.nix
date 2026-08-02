# Committed hand-authored hardware stub. Replaces the on-device
# `nixos-generate-config` output — filesystems are owned by disko
# (see ./disko.nix), so this file only carries low-level platform
# bits: initrd module list, CPU arch, microcode.

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

  # Same omission the workstation had, found 2026-08-02 while debugging that
  # host. A generated hardware-configuration.nix gets this by importing
  # `(modulesPath + "/installer/scan/not-detected.nix")`, whose entire content
  # is this one `mkDefault true`. Hand-authoring the stub dropped it.
  #
  # It matters more here than the missing linux-firmware does: the line below
  # keys off this exact option, so despite this file's header claiming to carry
  # "microcode" — and CLAUDE.md repeating it — `updateMicrocode` evaluated
  # `false` and **no Xeon microcode was ever applied**. On CPUs this old that is
  # the difference between having and not having the Spectre/MDS mitigations
  # that ship as microcode.
  hardware.enableRedistributableFirmware = true;

  hardware.cpu.intel.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
