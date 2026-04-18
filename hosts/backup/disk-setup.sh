#!/usr/bin/env bash
# =============================================================
# External USB drive setup for `backupserver` (Pi backup host).
# Creates one GPT partition + btrfs filesystem labelled `backup-data`
# with a subvolume `@homeserver` for the restic repo.
#
# Run this ONCE from the Pi (as root) after first boot, before
# `nixos-rebuild switch` picks up /mnt/backups as a mount point.
#
# Usage:  sudo bash disk-setup.sh /dev/sdX
# =============================================================

set -euo pipefail

DEV="${1:-}"

if [[ -z "$DEV" ]]; then
  echo "Usage: $0 /dev/sdX"
  exit 1
fi

if [[ ! -b "$DEV" ]]; then
  echo "ERROR: $DEV is not a block device"
  exit 1
fi

echo
echo "About to WIPE and reformat: $DEV"
lsblk "$DEV"
echo
read -rp "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || { echo "aborted"; exit 1; }

echo "--> wipefs"
wipefs -a "$DEV"

echo "--> parted (GPT + single partition)"
parted "$DEV" --script mklabel gpt mkpart primary btrfs 0% 100%

# Partition device name: /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
if [[ "$DEV" =~ [0-9]$ ]]; then
  PART="${DEV}p1"
else
  PART="${DEV}1"
fi

echo "--> mkfs.btrfs on $PART"
mkfs.btrfs -L backup-data "$PART"

echo "--> mount + create @homeserver subvolume"
mkdir -p /mnt/backups
mount -o compress=zstd:3,noatime "$PART" /mnt/backups
btrfs subvolume create /mnt/backups/@homeserver
umount /mnt/backups

echo
echo "Done. After nixos-rebuild switch, /mnt/backups will mount the"
echo "@homeserver subvolume automatically (per configuration.nix)."
echo
echo "===================="
echo "Future: convert to btrfs RAID 1 when a second drive is added:"
echo "  sudo btrfs device add /dev/sdYn /mnt/backups"
echo "  sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 /mnt/backups"
echo "===================="
