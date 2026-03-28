{
  description = "A logging library for the Zig programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      url = "github:zigtools/zls";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig";
      };
    };
  };

  outputs =
    inputs:
    let
      forAllSystems = f: builtins.mapAttrs f inputs.nixpkgs.legacyPackages;
    in
    {
      devShells = forAllSystems (
        system: pkgs: {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              bash
              # zig_0_15
              # zls_0_15
              inputs.zig.packages.${system}.master
              inputs.zls.packages.${system}.default
            ];
          };
        }
      );

      formatter = forAllSystems (_: pkgs: pkgs.nixfmt-tree);
    };
}
