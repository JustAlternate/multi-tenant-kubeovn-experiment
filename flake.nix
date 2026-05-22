{
  description = "Nixos config flake for all nodes";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable-nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      unstable-nixpkgs,
      ...
    }@inputs:
    let
      system = "aarch64-linux";
      systemArm = "aarch64-linux";

      nixos-overlays = [
        (_: prev: {
          unstable = import unstable-nixpkgs {
            inherit (prev) system;
            config.allowUnfree = true;
          };
        })
      ];
    in
    {
      # NixOS configurations
      nixosConfigurations = {
        nodeNixos = nixpkgs.lib.nixosSystem {
          specialArgs = { inherit inputs; };
          inherit system;
          modules = [
            ./sac/
            { nixpkgs.overlays = nixos-overlays; }
          ];
        };
      };
    };
}
