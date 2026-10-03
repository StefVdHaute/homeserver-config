# Disk layout for `homeserver`, applied by `nixos-anywhere` (or
# `sudo disko --mode destroy,format,mount <this-file>`).
#
#   /dev/sda       — 250GB boot SSD: ESP + 8GB swap + btrfs `@nixos`
#                    subvolume mounted at /
#   /dev/sdb..sde  — 4x 1TB spinners, each contributing one partition
#                    to an mdadm RAID 10 array (md/raid10) holding btrfs
#                    with the `@data` subvolume mounted at /mnt/data
#
# VERIFY WITH `lsblk` BEFORE RUNNING and adjust the `device =` lines;
# disko formats whatever they name. Mounts use GPT partlabels, not sd* names.

{ ... }:

{
  disko.devices = {
    disk = {
      boot = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              label = "nixos-boot";
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = {
              label = "nixos-swap";
              size = "8G";
              content = {
                type = "swap";
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
                };
              };
            };
          };
        };
      };

      raid-1 = {
        type = "disk";
        device = "/dev/sdb";
        content = {
          type = "gpt";
          partitions.raid = {
            size = "100%";
            content = { type = "mdraid"; name = "raid10"; };
          };
        };
      };
      raid-2 = {
        type = "disk";
        device = "/dev/sdc";
        content = {
          type = "gpt";
          partitions.raid = {
            size = "100%";
            content = { type = "mdraid"; name = "raid10"; };
          };
        };
      };
      raid-3 = {
        type = "disk";
        device = "/dev/sdd";
        content = {
          type = "gpt";
          partitions.raid = {
            size = "100%";
            content = { type = "mdraid"; name = "raid10"; };
          };
        };
      };
      raid-4 = {
        type = "disk";
        device = "/dev/sde";
        content = {
          type = "gpt";
          partitions.raid = {
            size = "100%";
            content = { type = "mdraid"; name = "raid10"; };
          };
        };
      };
    };

    mdadm = {
      raid10 = {
        type = "mdadm";
        level = 10;
        content = {
          type = "btrfs";
          extraArgs = [ "-L" "data" "-f" ];
          subvolumes = {
            "@data" = {
              mountpoint = "/mnt/data";
              mountOptions = [ "compress=zstd:3" "noatime" "nofail" ];
            };
          };
        };
      };
    };
  };
}
