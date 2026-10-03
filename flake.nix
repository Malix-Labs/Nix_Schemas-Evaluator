{
  description = "Pure, lazy, and failure-tolerant Nix Schemas Evaluator";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz";
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
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      evalLib = import ./lib {
        inherit (inputs) nixpkgs flake-schemas;
      };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.git-hooks-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          ...
        }:
        let
          inherit (pkgs) lib;
          evaluation = import ./src/evaluation.nix { inherit lib; };

          testNested = import ./test/nested-failure.nix {
            inherit lib evaluation;
          };
          testSerialization = import ./test/serialization.nix {
            inherit lib evaluation;
          };
          testInventory = import ./test/inventory.nix {
            inherit lib;
            inherit (evalLib) flake;
          };
          testManifest = import ./test/manifest.nix {
            inherit lib;
            inherit (evalLib) flake;
          };
          testSelection = import ./test/manifest-selection.nix {
            inherit lib;
            inherit (evalLib) flake;
          };
          testDerivations = import ./test/derivations.nix {
            inherit lib;
            inherit (evalLib) flake;
          };
          testOptions = import ./test/options.nix {
            inherit lib;
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

          lightCheck =
            assert allPassing;
            pkgs.runCommand "evalSchema-light" { } "touch $out";
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

          # Waiting for https://github.com/cachix/git-hooks.nix/pull/743
          formatter =
            let
              cfg = config.pre-commit.settings;
            in
            pkgs.writeShellScriptBin "pre-commit-fmt" ''
              set -euo pipefail
              export PATH="${
                pkgs.lib.makeBinPath (
                  [
                    cfg.gitPackage
                    cfg.package
                  ]
                  ++ cfg.enabledPackages
                )
              }:$PATH"

              exitcode=0
              if [ "$#" -gt 0 ]; then
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@" || exitcode=$?
              else
                if [ -n "''${PRJ_ROOT:-}" ]; then
                  cd "$PRJ_ROOT"
                fi
                ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files || exitcode=$?
              fi

              # pre-commit returns 1 when files were modified by hooks.
              # For a formatter (`nix fmt`), modifying files is the intended outcome.
              # If exit code was 1, re-run to distinguish between successful formatting changes (clean on 2nd pass)
              # and actual errors/syntax failures (fails again on 2nd pass).
              if [ "$exitcode" -eq 1 ]; then
                if [ "$#" -gt 0 ]; then
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --files "$@"
                else
                  ${pkgs.lib.getExe cfg.package} run -c ${cfg.configFile} --all-files
                fi
              else
                exit "$exitcode"
              fi
            '';

          packages = {
            evalSchema-light = lightCheck;
            default = lightCheck;
          };

          checks = {
            evalSchema-light = lightCheck;
          };

          devShells.default = config.pre-commit.devShell;
        };

      flake = {
        lib = {
          inherit (evalLib) flake;
        };
      };
    };
}
