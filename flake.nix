{
  description = "Home server config — main (x86_64 homeserver) + backup (aarch64 Raspberry Pi)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations = {
      main = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          disko.nixosModules.disko
          ./hosts/main/disko.nix
          ./hosts/main/configuration.nix
        ];
      };

      backup = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ ./hosts/backup/configuration.nix ];
      };
    };
  };
}
