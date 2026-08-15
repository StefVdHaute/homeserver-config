# NixOS module wrapper around ./package.nix. Thin on purpose — the tool itself
# is a plain package so it stays buildable and testable outside a NixOS eval.

{ config, lib, pkgs, ... }:

let
  cfg = config.programs.nixh;
in
{
  options.programs.nixh = {
    enable = lib.mkEnableOption "the nixh command picker";

    flake = lib.mkOption {
      type = lib.types.str;
      default = "github:StefVdHaute/homeserver-config";
      description = ''
        Default flake reference for check/switch/boot. Pass a path as the
        argument (`nixh switch .`) to build from a local checkout instead.
      '';
    };

    repo = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/repositories/homeserver-config";
      description = ''
        Local checkout that bump/commit/push operate on. Expanded by the
        shell at run time, so `$HOME` is fine here. Override per host — the
        servers keep theirs at `~/server_config`.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      # hostName and the flake attribute are not the same string on two of
      # three hosts, so this cannot just be networking.hostName.
      default = {
        homeserver = "main";
        backupserver = "backup";
      }.${config.networking.hostName} or config.networking.hostName;
      defaultText = lib.literalMD "the `nixosConfigurations` attribute matching `networking.hostName`";
      description = "nixosConfigurations attribute this machine builds from.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      (pkgs.callPackage ./package.nix {
        inherit (cfg) flake repo host;
      })
    ];
  };
}
