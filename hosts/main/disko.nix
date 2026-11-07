# Disk layout for `homeserver` (Dell PowerEdge R720), applied by
# `nixos-anywhere` (or `sudo disko --mode destroy,format,mount <this-file>`).
#
# Four 1TB disks (Seagate ST1000DM010) in bays 0-3 behind the PERC H710P Mini
# cross-flashed to IT mode (LSI SAS2308, driver mpt3sas), so Linux sees plain
# disks. No separate boot SSD; every disk carries the same three partitions:
#
#   ESP   512M  vfat, mounted at /boot1../boot4; GRUB mirrors itself and the
#               kernels onto all four (mirroredBoots in ./storage.nix), so any
#               disk can boot the machine.
#   os    50G   member of the mdadm RAID 10 `os` (~100G usable): btrfs `@nixos`
#               at /. mdadm keeps / booting unattended with a dead disk.
#   data  rest  member of a btrfs RAID 1 (data) / raid1c3 (metadata) at
#               /mnt/data (~1.9T usable). btrfs holds the copies itself, so a
#               scrub repairs bad blocks from the good copy. A missing disk
#               keeps /mnt/data from mounting until `mount -o degraded` (see
#               hosts/main/README.md, "Replacing a disk").
#
# The disks are addressed by /dev/disk/by-id/, never /dev/sdX (order is not
# stable behind an HBA). The serial in each ID is also printed on the disk's
# label, so a failed disk can be matched to its bay. When a disk is replaced,
# update its entry here. disko formats whatever they name.

{ lib, ... }:

let
  # Bay order 0..3 (LSI end_device-0:0..3), read 2026-11-07.
  diskIds = [
    "/dev/disk/by-id/ata-ST1000DM010-2EP102_W9AR8VR4"   # bay 0
    "/dev/disk/by-id/ata-ST1000DM010-2EP102_W9AR8TMT"   # bay 1
    "/dev/disk/by-id/ata-ST1000DM010-2EP102_W9ARELNA"   # bay 2
    "/dev/disk/by-id/ata-ST1000DM010-2EP102_ZN1TRKNE"   # bay 3
  ];

  # The btrfs RAID 1 is created on the last disk with the other three data
  # partitions as extra devices. disko formats disks alphabetically, so the
  # other partitions exist by then.
  dataLabel = n: "data${toString n}";
  otherDataDevs = map (n: "/dev/disk/by-partlabel/${dataLabel n}") [ 1 2 3 ];

  mkDisk = n: device: {
    type = "disk";
    inherit device;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          label = "boot${toString n}";
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot${toString n}";
            # nofail: a dead disk must not stop the boot.
            mountOptions = [ "umask=0077" "nofail" ];
          };
        };
        os = {
          label = "os${toString n}";
          size = "50G";
          content = { type = "mdraid"; name = "os"; };
        };
        data = {
          label = dataLabel n;
          size = "100%";
          content = lib.mkIf (n == 4) {
            type = "btrfs";
            extraArgs = [ "-f" "-L" "data" "-d" "raid1" "-m" "raid1c3" ] ++ otherDataDevs;
            subvolumes."@data" = {
              mountpoint = "/mnt/data";
              # nofail: boot (and SSH) still come up when the array is
              # degraded; services that need it are gated on the mount.
              mountOptions = [ "compress=zstd:3" "noatime" "nofail" ];
            };
          };
        };
      };
    };
  };
in

{
  disko.devices = {
    disk = lib.listToAttrs (lib.imap1
      (n: device: lib.nameValuePair "disk${toString n}" (mkDisk n device))
      diskIds);

    mdadm.os = {
      type = "mdadm";
      level = 10;
      content = {
        type = "btrfs";
        extraArgs = [ "-f" "-L" "nixos-root" ];
        subvolumes."@nixos" = {
          mountpoint = "/";
          mountOptions = [ "compress=zstd:3" "noatime" ];
        };
      };
    };
  };
}
