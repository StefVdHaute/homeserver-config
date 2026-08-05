{
  description = "Home server config — main (x86_64 homeserver) + backup (aarch64 Raspberry Pi)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Workstation tracks the rolling nixos-unstable branch; main and backup
    # stay on the pinned 26.05 release. Only the workstation output builds
    # against this input. `nix flake update nixpkgs-unstable` rolls it forward.
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

    # Operator-managed file, outside git (per-site domain/email stay out
    # of the repo). flake.lock only *verifies* path inputs (narHash), it
    # can't supply them — so this file must exist on any machine that
    # evaluates the main host. main materializes it onto its own disk via
    # environment.etc so on-device auto-upgrades keep working. Public
    # keys used to be path inputs too; they live in ./keys now.
    site = {
      url = "path:/etc/nixos/site.nix";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, nixos-hardware, agenix, site, ... }:
  let
    specialArgs = {
      siteConfig = import site;
      sitePath = site;
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

      # Pi has no repo-managed secrets (all its site-specific values
      # are non-secret — URL, pubkey). Skip agenix here; re-add if the
      # Pi ever gains a secret.
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

      # Rolling release: built from nixos-unstable, not the pinned 26.05.
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
  };
}
