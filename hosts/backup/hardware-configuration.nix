# Committed hand-authored hardware stub for `backupserver` (Pi 4, USB SSD
# boot). Filesystems are owned by disko (./disko.nix); extlinux + kernel
# defaults come from nixos-hardware.nixosModules.raspberry-pi-4. This file
# carries the platform bits that make the EEPROM → start4.elf → U-Boot →
# extlinux chain work from a USB drive.

{ config, lib, pkgs, ... }:

let
  # Boot-chain file set for the FAT /boot partition; mirrors nixpkgs'
  # sd-image-aarch64.nix, trimmed to the Pi 4 parts.
  configTxt = pkgs.writeText "config.txt" ''
    [pi4]
    kernel=u-boot-rpi4.bin
    enable_gic=1
    armstub=armstub8-gic.bin
    disable_overscan=1
    arm_boost=1

    [all]
    arm_64bit=1
    enable_uart=1
    avoid_warnings=1
  '';

  firmware = pkgs.runCommand "rpi4-boot-firmware" { } ''
    mkdir $out
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/start4*.elf $out/
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/fixup4*.dat $out/
    cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-4-b.dtb $out/
    cp ${pkgs.ubootRaspberryPi4_64bit}/u-boot.bin $out/u-boot-rpi4.bin
    cp ${pkgs.raspberrypi-armstubs}/armstub8-gic.bin $out/
    cp ${configTxt} $out/config.txt
  '';
in
{
  nixpkgs.hostPlatform = "aarch64-linux";

  # Root is on USB: the PCIe→XHCI→UAS/usb-storage→sd chain must be in the
  # initrd. pcie-brcmstb + reset-raspberrypi come from nixos-hardware.
  boot.initrd.availableKernelModules = [
    "xhci_pci" "usbhid" "usb_storage" "uas" "sd_mod" "mmc_block"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # Same 6.12.47-stable_20250916 source as nixos-hardware's default kernel,
  # but the nixpkgs build is on cache.nixos.org — no kernel compile under
  # qemu on workstation cross-builds.
  boot.kernelPackages = pkgs.linuxPackages_rpi4;

  # Serial console for headless boot debugging (enable_uart=1 in config.txt).
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];

  # /boot is 1G FAT; each generation stages its kernel+initrd (~75MB).
  boot.loader.generic-extlinux-compatible.configurationLimit = 10;

  # Wrap the stock extlinux installer so every bootloader install (first
  # nixos-install AND each rebuild/auto-upgrade) also syncs Pi firmware +
  # U-Boot into /boot. config.txt is Nix-owned — hand edits get clobbered.
  system.build.installBootLoader = lib.mkForce (
    pkgs.writeShellScript "install-rpi4-bootloader" ''
      set -euo pipefail
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c "$1" -d /boot
      cp ${firmware}/* /boot/
    ''
  );
}
