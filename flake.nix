{
  description = "Home server config — main (x86_64 homeserver) + backup (aarch64 Raspberry Pi)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Workstation only. Roll forward: `nix flake update nixpkgs-unstable`.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Operator-managed, outside git. flake.lock only verifies path inputs, so
    # this file must exist on any machine that evaluates the main host.
    site = {
      url = "path:/etc/nixos/site.nix";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, nixos-hardware, agenix, site, ... }:
  let
    specialArgs = {
      siteConfig = import site;
      operatorPubkeyPath = ./keys/operator.pub;
      mainRootPubkeyPath = ./keys/main-root.pub;
    };
  in {
    nixosConfigurations = {
      main = nixpkgs.lib.nixosSystem {
        inherit specialArgs;
        system = "x86_64-linux";
        modules = [
          agenix.nixosModules.default
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

      workstation = nixpkgs-unstable.lib.nixosSystem {
        inherit specialArgs;
        system = "x86_64-linux";
        modules = [
          nixos-hardware.nixosModules.framework-16-7040-amd
          disko.nixosModules.disko
          ./hosts/workstation/disko.nix
          ./hosts/workstation/configuration.nix
        ];
      };
    };

    # For ad-hoc runs; hosts get nixh via modules/common.nix.
    packages.x86_64-linux.nixh =
      nixpkgs-unstable.legacyPackages.x86_64-linux.callPackage ./modules/nixh/package.nix {
        host = "workstation";
      };

    # Exposed for `nix-update --flake spotify-adblock --version=stable`.
    packages.x86_64-linux.spotify-adblock =
      nixpkgs-unstable.legacyPackages.x86_64-linux.callPackage
        ./modules/spotify-adblock/package.nix { };

    packages.x86_64-linux.blender-mcp =
      nixpkgs-unstable.legacyPackages.x86_64-linux.callPackage
        ./modules/blender-mcp/package.nix { };
  };
}
