{
  description = "A logging library for the Zig programming language";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    zig = {
      url = "github:silversquirl/zig-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zls = {
      # https://github.com/zigtools/zls/pull/2469
      url = "github:Ratakor/zls/older-versions";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-flake.follows = "zig";
      };
    };
  };

  outputs = inputs: let
    forAllSystems = f: builtins.mapAttrs f inputs.nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          bash
          inputs.zig.packages.${system}.zig_0_15_1
          inputs.zls.packages.${system}.zls_0_15_0
        ];
      };
    });
  };
}
