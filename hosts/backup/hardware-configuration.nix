# Hand-authored hardware stub for `backupserver` (Pi 4, USB SSD boot via
# EEPROM → start4.elf → U-Boot → extlinux). Filesystems come from
# ./disko.nix; extlinux + kernel defaults from nixos-hardware's raspberry-pi-4.

{ config, lib, pkgs, ... }:

let
  # Boot-chain files for the FAT /boot partition (Pi 4 subset of nixpkgs'
  # sd-image-aarch64.nix).
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

  # Mainline kernel: channel-cached, so the Pi never compiles one.
  boot.kernelPackages = pkgs.linuxPackages;

  # Serial console for headless boot debugging (enable_uart=1 in config.txt).
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];

  # /boot is 1G FAT; each generation stages its kernel+initrd (~75MB).
  boot.loader.generic-extlinux-compatible.configurationLimit = 10;

  # Every bootloader install (nixos-install, rebuilds, auto-upgrades) also
  # syncs Pi firmware + U-Boot into /boot. config.txt is Nix-owned — hand
  # edits get clobbered.
  system.build.installBootLoader = lib.mkForce (
    # Runs with no PATH — every command needs its store path.
    pkgs.writeShellScript "install-rpi4-bootloader" ''
      set -euo pipefail
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} -c "$1" -d /boot
      ${pkgs.coreutils}/bin/cp ${firmware}/* /boot/
    ''
  );
}
