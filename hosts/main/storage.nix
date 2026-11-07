# Boot, RAID and disk-health plumbing for the layout in ./disko.nix:
# GRUB mirrored over four ESPs, mdadm RAID 10 for /, btrfs RAID 1 for
# /mnt/data, zram swap, and alerts for both kinds of RAID.

{ config, lib, pkgs, ntfyNotify, ... }:

let
  # mdadm PROGRAM hook; argv: event, array, [device].
  mdadmAlert = pkgs.writeShellApplication {
    name = "mdadm-alert";
    text = ''
      event="$1"
      array="''${2:-unknown}"
      device="''${3:-N/A}"
      ${ntfyNotify} home-smart 4 \
        "mdadm: $event on $array" \
        "Device: $device (host: ${config.networking.hostName})"
    '';
  };

  # btrfs RAID has no event hook like mdadm's, so poll its per-device error
  # counters and its device count. `btrfs device stats --check` exits non-zero
  # when any counter is above 0.
  btrfsDataCheck = pkgs.writeShellApplication {
    name = "btrfs-data-check";
    runtimeInputs = [ pkgs.btrfs-progs pkgs.util-linux pkgs.gnugrep ];
    text = ''
      if ! mountpoint -q /mnt/data; then
        ${ntfyNotify} home-smart 4 \
          "btrfs: /mnt/data not mounted on ${config.networking.hostName}" \
          "A data disk is probably missing. See hosts/main/README.md, Replacing a disk."
        exit 1
      fi
      problems=""
      if ! stats=$(btrfs device stats --check /mnt/data); then
        problems="$(grep -v ' 0$' <<<"$stats")"
      fi
      if btrfs filesystem show /mnt/data | grep -q -i missing; then
        problems="$problems device-missing"
      fi
      if [ -n "$problems" ]; then
        ${ntfyNotify} home-smart 4 \
          "btrfs: errors on /mnt/data (${config.networking.hostName})" \
          "$problems"
        exit 1
      fi
    '';
  };
in

{
  # ============================================================
  # Bootloader: GRUB on all four ESPs
  # ============================================================
  # Each disk has its own ESP; GRUB installs itself and copies the kernels
  # to every one. The ESPs are not an mdadm mirror, so firmware writes to one
  # of them can't knock a mirror out of sync.
  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    # Also installs to EFI/BOOT/BOOTX64.EFI, so each disk boots even without
    # its NVRAM entry (e.g. after a disk swap).
    efiInstallAsRemovable = true;
    mirroredBoots = map (n: {
      path = "/boot${toString n}";
      devices = [ "nodev" ];
      efiSysMountPoint = "/boot${toString n}";
    }) [ 1 2 3 4 ];
  };
  boot.loader.efi.canTouchEfiVariables = false;   # required by efiInstallAsRemovable

  # ============================================================
  # mdadm RAID 10 for /
  # ============================================================
  boot.swraid.enable = true;
  boot.swraid.mdadmConf = ''
    PROGRAM ${mdadmAlert}/bin/mdadm-alert
  '';

  # ============================================================
  # btrfs RAID 1 for /mnt/data
  # ============================================================
  # disko points the mount at disk 4's partition; the filesystem label is
  # present on every member, so the mount doesn't hinge on that one disk.
  fileSystems."/mnt/data".device = lib.mkForce "/dev/disk/by-label/data";

  # No `degraded` mount option on purpose: a degraded btrfs RAID 1 that keeps
  # writing can end up with single-copy chunks. The mount fails instead, the
  # OS still boots (nofail), and the alerts below fire.
  systemd.services.btrfs-data-check = {
    description = "Check /mnt/data btrfs RAID for device errors or missing disks";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${btrfsDataCheck}/bin/btrfs-data-check";
    };
  };
  systemd.timers.btrfs-data-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "1h";
    };
  };

  # Never let Docker or the backups run on the empty /mnt/data directory of
  # the OS array.
  systemd.services.docker.unitConfig.RequiresMountsFor = [ "/mnt/data" ];
  systemd.services.restic-backups-docker-volumes.unitConfig.RequiresMountsFor = [ "/mnt/data" ];
  systemd.services.restic-backups-seafile-data.unitConfig.RequiresMountsFor = [ "/mnt/data" ];

  # Monthly scrub. On / (mdadm) it can only report bad data; on /mnt/data
  # (btrfs RAID 1) it repairs it from the good copy.
  services.btrfs.autoScrub = {
    enable = true;
    interval = "monthly";
    fileSystems = [ "/" "/mnt/data" ];
  };

  # ============================================================
  # Desktop disks in RAID
  # ============================================================
  # The ST1000DM010 has no ERC/TLER: on a bad sector it can retry for minutes.
  # Raise the kernel's command timeout above that so the disk isn't reset
  # mid-retry and kicked out of the array.
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ENV{ID_MODEL}=="ST1000DM010*", ATTR{device/timeout}="180"
  '';

  # ============================================================
  # Swap
  # ============================================================
  # Compressed RAM swap; a disk swap partition would need its own mirror to
  # survive a dead disk.
  zramSwap.enable = true;
}
