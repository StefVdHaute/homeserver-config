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

  # A machine-generated hardware-configuration.nix gets this by importing
  # `(modulesPath + "/installer/scan/not-detected.nix")`, whose entire content
  # is this one `mkDefault true`. Hand-authoring the stub dropped it, and
  # nothing else turns it back on — nixos-hardware's framework-16-7040-amd
  # module does not set it (verified: it evaluated `false` with that module
  # imported). Set it directly rather than importing the scan file, which is
  # named for a code path this stub deliberately doesn't use.
  #
  # Without it there is no linux-firmware, so `amdgpu` cannot initialise the
  # Phoenix iGPU and the machine falls back to simpledrm + llvmpipe: SDDM
  # renders in software (garbled glyphs, no cursor), and VT switching is
  # broken. It also silently disabled AMD microcode updates, since the line
  # below keys off this exact option.
  hardware.enableRedistributableFirmware = true;

  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
}
