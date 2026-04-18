{
  description = "Home server config — main (x86_64 homeserver) + backup (aarch64 Raspberry Pi)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations = {
      main = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/main/configuration.nix ];
      };

      backup = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ ./hosts/backup/configuration.nix ];
      };
    };
  };
}
