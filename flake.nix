{
  description = "Pure, lazy, and failure-tolerant Nix Schemas Evaluator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-schemas.url = "github:DeterminateSystems/flake-schemas";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-schemas,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;

      evalLib = import ./lib {
        inherit nixpkgs flake-schemas;
      };

      mkLightCheck =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          evaluation = import ./src/evaluation.nix { inherit (pkgs) lib; };

          testNested = import ./test/nested-failure.nix {
            inherit (pkgs) lib;
            inherit evaluation;
          };
          testSerialization = import ./test/serialization.nix {
            inherit (pkgs) lib;
            inherit evaluation;
          };
          testInventory = import ./test/inventory.nix {
            inherit (pkgs) lib;
            inherit (evalLib) flake;
          };
          testManifest = import ./test/manifest.nix {
            inherit (pkgs) lib;
            inherit (evalLib) flake;
          };
          testSelection = import ./test/manifest-selection.nix {
            inherit (pkgs) lib;
            inherit (evalLib) flake;
          };
          testDerivations = import ./test/derivations.nix {
            inherit (pkgs) lib;
            inherit (evalLib) flake;
          };
          testOptions = import ./test/options.nix {
            inherit (pkgs) lib;
            inherit (evalLib) flake;
          };

          allPassing =
            (lib.all (v: v == "pass") (lib.attrValues testNested))
            && (lib.all (v: v == "pass") (lib.attrValues testSerialization))
            && (lib.all (v: v == "pass") (lib.attrValues testInventory))
            && (lib.all (v: v == "pass") (lib.attrValues testManifest))
            && (lib.all (v: v == "pass") (lib.attrValues testSelection))
            && (lib.all (v: v == "pass") (lib.attrValues testDerivations))
            && (lib.all (v: v == "pass") (lib.attrValues testOptions));
        in
        assert allPassing;
        pkgs.runCommand "evalSchema-light" { } "touch $out";
    in
    {
      lib = {
        inherit (evalLib) flake;
      };

      packages = forAllSystems (system: {
        evalSchema-light = mkLightCheck system;
        default = mkLightCheck system;
      });

      checks = forAllSystems (system: {
        evalSchema-light = mkLightCheck system;
      });

      formatter = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.nixfmt-tree or pkgs.nixfmt
      );
    };
}
