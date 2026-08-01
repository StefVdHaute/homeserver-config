# Declarative disk layout for the workstation (Framework 16). Targets the
# 2 TB Kingston only; the Arch install on the WD_BLACK is untouched.
#
# The device is addressed by /dev/disk/by-id/ ON PURPOSE. Kernel names are
# NOT stable: inserting this drive renumbered the existing Arch drive from
# nvme0n1 to nvme1n1 (observed 2026-08-01), which is exactly the device
# this file used to name. A by-path config would have wiped the work
# install. Never reintroduce /dev/nvmeXn1 here.
#
# Layout:
#   <disk>-part1  — ESP (2 GB, FAT32, Limine)
#   <disk>-part2  — LUKS-encrypted btrfs, subvolumes:
#                       @nixos — mounted at /                  (zstd:3, noatime)
#                       @home  — mounted at /home              (zstd:3, noatime)
#                       @log   — mounted at /var/log           (zstd:3, noatime)
#                       @games — mounted at /home/stef/Games   (no compression)
#                       @swap  — mounted at /swap              (noatime, 40G swapfile)
#                     @home is split out so a rollback or reinstall of
#                     the root subvolume doesn't take /home with it —
#                     mirrors the existing Arch install's split (@,
#                     @home, @swap).
#
# The ESP is 2 GB rather than 1: Limine copies each generation's kernel
# and initrd onto it, so it needs more headroom than systemd-boot did.
#
# @swap exists for hibernate — zram alone can't do it. The swapfile is
# sized above the 32 GB of RAM. NOTE: `resume_offset` is not derivable
# here (disko#651); read it off the real filesystem after install with
# `btrfs inspect-internal map-swapfile -r /swap/swapfile`. Recreating
# the swapfile changes the offset.
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
                  "@home" = {
                    mountpoint = "/home";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # Split out so a root rollback doesn't discard the logs
                  # explaining why it was needed. Compression stays on —
                  # journals are text and compress very well. NixOS marks
                  # /var/log needed-for-boot automatically (it's in
                  # utils.pathsNeededForBoot), so no flag is required here.
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # Steam library. compress=no on purpose: game data is
                  # already compressed, so zstd:3 spends write CPU for
                  # ~nothing. Being its own subvolume also keeps it out of
                  # any future @home snapshot — btrfs snapshots don't
                  # recurse into nested subvolumes. Carved out now because
                  # converting a full library directory later means moving
                  # every byte.
                  "@games" = {
                    mountpoint = "/home/stef/Games";
                    mountOptions = [ "compress=no" "noatime" ];
                  };
                  # No compression here — btrfs requires swapfiles be
                  # NODATACOW and uncompressed.
                  "@swap" = {
                    mountpoint = "/swap";
                    mountOptions = [ "noatime" ];
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
