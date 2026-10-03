# Layout for the external backup data drive. Not imported by the flake, so
# no install path can format the restic repo.
#
# Run manually ONLY to provision a brand-new data drive, after setting
# device= to its by-id path (ls -l /dev/disk/by-id/):
#
#   sudo nix run --extra-experimental-features 'nix-command flakes' \
#     github:nix-community/disko -- --mode destroy,format,mount ./disko-data.nix
#
# The runtime mount is in ./configuration.nix (by-label "backup-data").

{ ... }:

{
  disko.devices = {
    disk = {
      data = {
        type = "disk";
        device = "/dev/disk/by-id/usb-ICY_BOX_IB-1806MT-CU31_20114400532209355-0:0";
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
