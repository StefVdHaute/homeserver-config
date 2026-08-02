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
              # NOT "cryptroot". This one string lands in two namespaces
              # with different scopes: disko emits it both as the runtime
              # `cryptsetup open <dev> <name>` argument and as the
              # boot.initrd.luks.devices.<name> entry. The initrd side only
              # has to be unique within this install; the script side has to
              # be unique among the device-mapper names *live on whatever
              # machine runs it* — here, booted Arch, whose own root mapper
              # is called `cryptroot` (the mkinitcpio convention, which is
              # why both sides reach for the same name). `cryptsetup open`
              # refuses a name already in use, and the script runs under
              # `set -efux`, so the collision aborts the install partway
              # instead of corrupting anything. Prefix keeps the two apart.
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
                  # Split out so a root rollback doesn't discard the logs
                  # explaining why it was needed. Compression stays on —
                  # journals are text and compress very well. NixOS marks
                  # /var/log needed-for-boot automatically (it's in
                  # utils.pathsNeededForBoot), so no flag is required here.
                  "@log" = {
                    mountpoint = "/var/log";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # Steam library. Its own subvolume so it stays out of any
                  # future @home snapshot — btrfs snapshots don't recurse
                  # into nested subvolumes. Carved out now because
                  # converting a full library directory later means moving
                  # every byte.
                  #
                  # This carried compress=no until 2026-08-02. Removed for
                  # two reasons. It never worked: compress is applied per
                  # superblock, and "only options in the first mounted
                  # subvolume will take effect... you can't set
                  # per-subvolume nodatacow, nodatasum, or compress using
                  # mount options" (btrfs docs) — @nixos mounts first, so
                  # this was inert, and had @games ever mounted first it
                  # would have disabled compression filesystem-wide. And it
                  # wasn't needed: without compress-force btrfs samples
                  # each file and "if the first portion of data being
                  # compressed is not smaller than the original, the
                  # compression of the whole file is disabled" — game
                  # assets are already compressed, so zstd:3 backs off on
                  # its own. Don't reintroduce it, and don't reach for the
                  # btrfs compression property either; it buys one skipped
                  # entropy sample per file.
                  "@games" = {
                    mountpoint = "/home/stef/Games";
                    mountOptions = [ "compress=zstd:3" "noatime" ];
                  };
                  # Swapfiles must be NODATACOW and uncompressed, but that
                  # can't be expressed here either (same per-superblock
                  # limitation). It doesn't need to be: `btrfs filesystem
                  # mkswapfile`, which disko uses, sets both on the file
                  # itself, and btrfs refuses to swapon a file that isn't.
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
