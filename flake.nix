{
  description = "Mainline Linux BSP for Lenovo TB378FC (zhiyu)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      };
      p = pkgs.zhiyu.packages;
      # Evaluate hardware options in a private context. The check never
      # constructs a system toplevel or exports a distribution configuration.
      cfg =
        (nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            {
              zhiyu.enable = true;
              boot.kernelParams = [ "zhiyu.root=sd" ];
              system.stateVersion = "26.05";
            }
          ];
        }).config;
    in
    {
      overlays.default = import ./nix/overlay.nix;
      packages.${system} = p;
      nixosModules.default = import ./nix/nixos-module.nix;
      checks.${system} = import ./nix/checks.nix { inherit pkgs p cfg; };
      formatter = nixpkgs.lib.genAttrs [ "x86_64-linux" system ] (
        platform: nixpkgs.legacyPackages.${platform}.nixfmt
      );
    };
}
