# Declarative disk layout for `backupserver` (Raspberry Pi 4). Realised
# by disko during `nixos-anywhere` install (or `sudo disko --mode
# destroy,format,mount <this-file>` from a running system).
#
# Replaces the imperative disk-setup.sh. Layout:
#   /dev/mmcblk0   — SD card: 512MB FAT32 firmware partition + ext4 root
#   /dev/sda       — external USB SSD: single GPT partition, btrfs
#                    labelled "backup-data" with the @homeserver subvolume
#                    mounted at /mnt/backups
#
# VERIFY WITH `lsblk` BEFORE RUNNING. If the USB drive enumerates as
# /dev/sdb (second USB port etc.) adjust the `device =` line below.
# After disko has run the partitions carry GPT partlabels ("nixos-root"
# etc.) and the btrfs fs carries label "backup-data", so subsequent
# mounts don't depend on the /dev/sdX enumeration staying stable.

{ ... }:

{
  disko.devices = {
    disk = {
      sd = {
        type = "disk";
        device = "/dev/mmcblk0";
        content = {
          type = "gpt";
          partitions = {
            firmware = {
              label = "FIRMWARE";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot/firmware";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              label = "nixos-root";
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };

      usb = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions.data = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-L" "backup-data" "-f" ];
              subvolumes = {
                "@homeserver" = {
                  mountpoint = "/mnt/backups";
                  mountOptions = [ "compress=zstd:3" "noatime" "nofail" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
