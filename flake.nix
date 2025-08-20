{
  description = "A logging library for the Zig programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = {
    nixpkgs,
    flake-utils,
    zig,
    ...
  }: let
    zig-version = "0.14.1";
    overlays = [zig.overlays.default];
    systems = builtins.attrNames zig.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
      in {
        # nix run .
        apps.default = flake-utils.lib.mkApp {
          drv = pkgs.zigpkgs."${zig-version}";
        };

        # nix develop .
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            zigpkgs."${zig-version}"
          ];
        };
      }
    );
}
