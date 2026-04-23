{
  description = "Home server config — main (x86_64 homeserver) + backup (aarch64 Raspberry Pi)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # Operator-managed files, outside git, resolved at flake-lock time
    # and copied into the Nix store. Both paths must exist on whichever
    # workstation runs `nixos-anywhere`. Pure eval throughout — no
    # --impure flag needed for lock or build.
    site = {
      url = "path:/etc/nixos/site.nix";
      flake = false;
    };
    operatorPubkey = {
      url = "path:/etc/nixos/operator.pub";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, disko, nixos-hardware, site, operatorPubkey, ... }:
  let
    specialArgs = {
      siteConfig = import site;
      operatorPubkeyPath = operatorPubkey;
    };
  in {
    nixosConfigurations = {
      main = nixpkgs.lib.nixosSystem {
        inherit specialArgs;
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./hosts/main/disko.nix
          ./hosts/main/configuration.nix
        ];
      };

      backup = nixpkgs.lib.nixosSystem {
        inherit specialArgs;
        system = "aarch64-linux";
        modules = [
          nixos-hardware.nixosModules.raspberry-pi-4
          disko.nixosModules.disko
          ./hosts/backup/disko.nix
          ./hosts/backup/configuration.nix
        ];
      };
    };
  };
}
