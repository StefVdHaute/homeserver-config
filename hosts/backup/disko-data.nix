# Standalone layout for the external backup data drive. Deliberately NOT
# imported by the flake — the restic repo must survive OS reinstalls, so
# no automated install path may ever format this disk.
#
# Run manually ONLY when provisioning a brand-new data drive, after
# setting device= to the drive's by-id path (ls -l /dev/disk/by-id/):
#
#   sudo nix run --extra-experimental-features 'nix-command flakes' \
#     github:nix-community/disko -- --mode destroy,format,mount ./disko-data.nix
#
# The runtime mount is declared in ./configuration.nix (by-label
# "backup-data"), so enumeration and this file don't matter after format.

{ ... }:

{
  disko.devices = {
    disk = {
      data = {
        type = "disk";
        device = "/dev/disk/by-id/CHANGE-ME";
        content = {
          type = "gpt";
          partitions.data = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-L" "backup-data" "-f" ];
              subvolumes = {
                "@homeserver" = {
                  mountpoint = "/mnt/backups";
                  mountOptions = [ "compress=zstd:3" "noatime" "nofail" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
