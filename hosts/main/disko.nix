# Declarative disk layout for `homeserver`. Realised by disko during
# `nixos-anywhere` install (or `sudo disko --mode destroy,format,mount
# <this-file>` from a running system).
#
# Replaces the imperative raid-setup.sh. Matches the historical layout:
#   /dev/sda       — 250GB boot SSD: ESP + 8GB swap + ext4 root
#   /dev/sdb..sde  — 4x 1TB spinners, each contributing one partition
#                    to an mdadm RAID 10 array (md/raid10), ext4
#                    filesystem mounted at /mnt/data
#
# VERIFY WITH `lsblk` BEFORE RUNNING. If the server's device names
# differ, adjust the `device =` lines below. Once disko has run, the
# partitions have GPT partlabels ("nixos-boot" etc.) so subsequent
# mounts don't depend on the sd* enumeration order staying stable.

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
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [ "noatime" ];
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
          type = "filesystem";
          format = "ext4";
          mountpoint = "/mnt/data";
          mountOptions = [ "defaults" "nofail" ];
        };
      };
    };
  };
}
