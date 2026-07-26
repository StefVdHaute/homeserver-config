# Declarative disk layout for `backupserver` (Raspberry Pi 4) — OS disk
# only. Realised by disko at install time; the flash flow (workstation-
# local disko + nixos-install) is DEPLOY.md §4.
#
# Layout — 240GB SATA SSD in a USB adapter, booted via the Pi 4's EEPROM
# USB boot (needs bootloader ≥ 2020-10-28 for GPT support):
#   - 1G FAT32 at /boot: Pi firmware + U-Boot + extlinux + kernels. One
#     partition for the whole boot chain — U-Boot can't see into the
#     btrfs @nixos subvolume, so extlinux/kernels can't live on /.
#     Firmware files are synced by the installBootLoader wrapper in
#     ./hardware-configuration.nix.
#   - btrfs: @nixos at /, @projects at /srv/projects (side projects).
#
# The backup data drive is deliberately NOT declared here: no install or
# reinstall may ever format the restic repo. Its runtime mount lives in
# ./configuration.nix (by-label); provisioning a brand-new data drive is
# a manual run of ./disko-data.nix.
#
# device= is the SSD's by-id path *through its USB-SATA adapter* — with
# two USB drives on the Pi, /dev/sdX enumeration is a race. If the
# adapter ever changes, re-check with: ls -l /dev/disk/by-id/ | grep usb

{ ... }:

{
  disko.devices = {
    disk = {
      ssd = {
        type = "disk";
        device = "/dev/disk/by-id/usb-WDC_WDS2_40G2G0A-00JH30_0000000001A7-0:0";
        content = {
          type = "gpt";
          partitions = {
            firmware = {
              label = "FIRMWARE";
              size = "1G";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              label = "nixos-root";
              size = "100%";
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "nixos-root" "-f" ];
                subvolumes = {
                  "@nixos" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  "@projects" = {
                    mountpoint = "/srv/projects";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
