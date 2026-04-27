# Declarative disk layout for the workstation (Framework 16). Single
# NVMe drive; existing OS on a separate drive is untouched.
#
# Layout:
#   /dev/nvme1n1p1  — ESP (1 GB, FAT32, systemd-boot)
#   /dev/nvme1n1p2  — LUKS-encrypted btrfs `@nixos` mounted at /
#                     (zstd:3, noatime)
#
# VERIFY WITH `lsblk` BEFORE RUNNING. /dev/nvme1n1 will be wiped.

{ ... }:

{
  disko.devices = {
    disk.nvme1n1 = {
      type = "disk";
      device = "/dev/nvme1n1";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            label = "nixos-boot";
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          luks = {
            label = "nixos-luks";
            size = "100%";
            content = {
              type = "luks";
              name = "cryptroot";
              extraFormatArgs = [ "--type" "luks2" ];
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "nixos-root" "-f" ];
                subvolumes = {
                  "@nixos" = {
                    mountpoint = "/";
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
