{
  description = "Pure, lazy, and failure-tolerant Nix Schemas Evaluator";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    systems.url = "github:nix-systems/default";
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-schemas.url = "github:DeterminateSystems/flake-schemas";
    nixpkgs-pr553364.url = "github:NixOS/nixpkgs/pull/553364/head";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      lib-extended =
        if inputs.nixpkgs.lib.options ? optionToDoc then
          inputs.nixpkgs.lib
        else
          inputs.nixpkgs-pr553364.lib;

      evalLib = import ./lib {
        inherit (inputs) nixpkgs flake-schemas;
        optionToDoc = lib-extended.options;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.flake-parts.flakeModules.partitions
        inputs.git-hooks-nix.flakeModule
      ];

      partitionedAttrs.checks = "fixtures";

      partitions.fixtures = {
        extraInputsFlake = ./checks;
        module = import ./checks/flake-module.nix;
      };

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) lib;
          evaluation = import ./src/evaluation.nix { inherit lib; };

          testSuites = [
            (import ./test/nested-failure.nix { inherit lib evaluation; })
            (import ./test/serialization.nix { inherit lib evaluation; })
            (import ./test/inventory.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
            (import ./test/manifest.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
            (import ./test/manifest-selection.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
            (import ./test/derivations.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
            (import ./test/options.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
            (import ./test/frameworks.nix {
              inherit lib;
              inherit (evalLib) flake;
            })
          ];

          allPassing = lib.all (suite: lib.all (v: v == "pass") (lib.attrValues suite)) testSuites;

          unit-tests =
            assert allPassing;
            pkgs.runCommand "unit-tests" { } "touch $out";
        in
        {
          pre-commit.settings.hooks = {
            shfmt.enable = true;
            nixfmt.enable = true;
            shellcheck.enable = true;
            statix.enable = true;
            deadnix.enable = true;
            markdownlint = {
              enable = true;
              excludes = [
                "^LICENSE\\.md$"
                "^\\.github/.*"
                "^docs/PLAN\\.md$"
              ];
              settings.configuration = {
                MD013 = false;
                MD026 = false;
                MD034 = false;
                MD041 = false;
                MD012 = false;
              };
            };
          };

          packages = {
            inherit unit-tests;
            default = unit-tests;
          };

          checks = {
            inherit (config.packages) unit-tests;
          };

          devShells.default = config.pre-commit.devShell;
        };

      flake = {
        lib = {
          inherit (evalLib) flake select;
        };
      };
    };
}
