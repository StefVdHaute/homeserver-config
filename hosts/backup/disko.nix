# Disk layout for `backupserver` (Raspberry Pi 4), OS disk only. Flash flow
# is DEPLOY.md §4.
#
# 240GB SATA SSD in a USB adapter, EEPROM USB boot (bootloader ≥ 2020-10-28
# for GPT):
#   - 1G FAT32 at /boot: Pi firmware + U-Boot + extlinux + kernels. U-Boot
#     can't read the btrfs subvolume, so the whole boot chain lives here.
#   - btrfs: @nixos at /, @projects at /srv/projects.
#
# The backup data drive is deliberately not declared here, so no install
# can format the restic repo. Provision a new one with ./disko-data.nix.
#
# device= is the SSD's by-id path through its USB-SATA adapter. If the
# adapter changes, re-check with: ls -l /dev/disk/by-id/ | grep usb

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
