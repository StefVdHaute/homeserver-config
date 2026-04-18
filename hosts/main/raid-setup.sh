#!/usr/bin/env bash
# =============================================================
# RAID 10 Setup Script
# Run this from the NixOS live installer before installing.
#
# Assumes:
#   Boot SSD:          /dev/sda  (250GB)
#   Storage drives:    /dev/sdb, /dev/sdc, /dev/sdd, /dev/sde  (4x 1TB)
#
# IMPORTANT: Adjust device names to match your actual hardware.
# Run 'lsblk' first to confirm device names.
# =============================================================

set -euo pipefail

echo ">>> Listing block devices — confirm your device names:"
lsblk
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# -------------------------------------------------------------
# 1. Partition the boot SSD
# -------------------------------------------------------------
echo ">>> Partitioning boot SSD (/dev/sda)..."
parted /dev/sda --script \
  mklabel gpt \
  mkpart ESP fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart primary linux-swap 512MiB 8GiB \
  mkpart primary ext4 8GiB 100%

# Format boot partitions
mkfs.fat -F32 -n nixos-boot /dev/sda1
mkswap -L nixos-swap /dev/sda2
mkfs.ext4 -L nixos-root /dev/sda3

echo ">>> Boot SSD partitioned and formatted."

# -------------------------------------------------------------
# 2. Wipe storage drives
# -------------------------------------------------------------
echo ">>> Wiping storage drives..."
for dev in /dev/sdb /dev/sdc /dev/sdd /dev/sde; do
  wipefs -a "$dev"
  parted "$dev" --script mklabel gpt mkpart primary 0% 100%
done

echo ">>> Storage drives wiped."

# -------------------------------------------------------------
# 3. Create RAID 10 array
# -------------------------------------------------------------
echo ">>> Creating RAID 10 array..."
mdadm --create /dev/md0 \
  --level=10 \
  --raid-devices=4 \
  /dev/sdb1 /dev/sdc1 /dev/sdd1 /dev/sde1

# Wait for array to initialize
echo ">>> Waiting for RAID sync to start..."
sleep 5
cat /proc/mdstat

# -------------------------------------------------------------
# 4. Format and label RAID array
# -------------------------------------------------------------
echo ">>> Formatting RAID array..."
mkfs.ext4 -L data /dev/md0

echo ">>> RAID 10 array created and formatted as /dev/md0"
echo ""
echo ">>> Summary:"
mdadm --detail /dev/md0

echo ""
echo ">>> Done! You can now run nixos-install."
echo "    Make sure configuration.nix references /dev/disk/by-label/data for /mnt/data"
