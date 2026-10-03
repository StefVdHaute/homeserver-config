# Declarative disk layout for the workstation (Framework 16). Targets the
# 2 TB Kingston only; the Arch install on the WD_BLACK is untouched.
#
# Address the disk by /dev/disk/by-id/, never /dev/nvmeXn1: kernel names are
# not stable, and the wrong one wipes the Arch drive.
#
# Layout:
#   <disk>-part1  — ESP (2 GB, FAT32, Limine)
#   <disk>-part2  — LUKS-encrypted btrfs, subvolumes:
#                       @nixos — mounted at /                  (zstd:3, noatime)
#                       @home  — mounted at /home              (zstd:3, noatime)
#                       @log   — mounted at /var/log           (zstd:3, noatime)
#                       @games — mounted at /home/stef/Games   (zstd:3, noatime)
#                       @swap  — mounted at /swap              (noatime, 40G swapfile)
#
# @swap holds the hibernate swapfile. After install, read `resume_offset`
# with `btrfs inspect-internal map-swapfile -r /swap/swapfile`.
#
# BEFORE RUNNING, confirm the serial still resolves to the intended empty
# disk: `ls -l /dev/disk/by-id/nvme-KINGSTON_SNV3SM32T0_50026B7283C08359`
# and `lsblk` to check it has no partitions. This disk will be wiped.

{ ... }:

{
  disko.devices = {
    disk.nixos = {
      type = "disk";
      device = "/dev/disk/by-id/nvme-KINGSTON_SNV3SM32T0_50026B7283C08359";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            label = "nixos-boot";
            size = "2G";
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
              # Must differ from the installing host's live mapper names
              # (Arch uses `cryptroot`).
              name = "nixos-cryptroot";
              extraFormatArgs = [ "--type" "luks2" ];
              content = {
                type = "btrfs";
                extraArgs = [ "-L" "nixos-root" "-f" ];
                subvolumes = {
                  "@nixos" = {
                    mountpoint = "/";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # Steam library; excluded from @home snapshots.
                  "@games" = {
                    mountpoint = "/home/stef/Games";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # mkswapfile sets NODATACOW and no compression on the file.
                  "@swap" = {
                    mountpoint = "/swap";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                    swap.swapfile.size = "40G";
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
