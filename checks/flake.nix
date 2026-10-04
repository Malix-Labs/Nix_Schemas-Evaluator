{
  description = "Heavy module framework matrix checks for Nix Schemas Evaluator";

  inputs = {
    evaluator.url = "path:..";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    namaka = {
      url = "github:nix-community/namaka";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hydra = {
      url = "github:NixOS/hydra";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hjem = {
      url = "github:feel-co/hjem";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-on-droid = {
      url = "github:nix-community/nix-on-droid";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    nixbsd = {
      url = "github:nixos-bsd/nixbsd";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          prLib = import "${inputs.evaluator.inputs.nixpkgs-pr553364}/lib";
          evalLib = import "${inputs.evaluator}/lib" {
            inherit (inputs) nixpkgs;
            inherit (inputs.evaluator.inputs) flake-schemas;
            inherit pkgs;
            optionToDoc = prLib.options;
          };
        in
        {
          devShells.default = pkgs.mkShell {
            packages = [ inputs.namaka.packages.${pkgs.system}.default ];
          };

          checks = {
            # Namaka snapshot-testing check
            namaka =
              assert
                (inputs.namaka.lib.load {
                  src = ./tests;
                  inputs = {
                    inherit evalLib;
                    inherit (pkgs) lib;
                  };
                }) == { };
              pkgs.runCommand "check-namaka" { } "touch $out";

            # Real production flakes evaluated using default framework descriptors
            flake-agenix =
              let
                eval = evalLib.flake { targetFlake = inputs.agenix; };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "nixosModules" ]
                    [ "darwinModules" ]
                    [ "homeManagerModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? nixosModules || manifest ? packages;
              pkgs.writeText "check-flake-agenix.json" (builtins.toJSON manifest);

            flake-deploy-rs =
              let
                eval = evalLib.flake { targetFlake = inputs.deploy-rs; };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "overlays" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? overlays || manifest ? packages;
              pkgs.writeText "check-flake-deploy-rs.json" (builtins.toJSON manifest);

            flake-hydra =
              let
                hydraPkgs = pkgs.extend (inputs.hydra.overlays.default or (_: _: { }));
                eval = evalLib.flake {
                  targetFlake = inputs.hydra;
                  frameworkDescriptors = {
                    nixosModules = {
                      name = "NixOS";
                      eval =
                        module:
                        let
                          evaled = pkgs.lib.evalModules {
                            specialArgs = {
                              flakePackages = inputs.hydra.packages.${pkgs.system} or { };
                            };
                            modules = [
                              {
                                _module = {
                                  check = false;
                                  args = {
                                    pkgs = hydraPkgs;
                                    flakePackages = inputs.hydra.packages.${pkgs.system} or { };
                                  };
                                };
                              }
                              module
                            ];
                          };
                        in
                        evaled.options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "nixosModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? packages;
              pkgs.writeText "check-flake-hydra.json" (builtins.toJSON manifest);

            # Framework flakes evaluated using default framework descriptors
            flake-home-manager =
              let
                eval = evalLib.flake { targetFlake = inputs.home-manager; };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "nixosModules" ]
                    [ "darwinModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? nixosModules || manifest ? packages;
              pkgs.writeText "check-flake-home-manager.json" (builtins.toJSON manifest);

            flake-nix-darwin =
              let
                eval = evalLib.flake { targetFlake = inputs.nix-darwin; };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "darwinModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? darwinModules || manifest ? packages;
              pkgs.writeText "check-flake-nix-darwin.json" (builtins.toJSON manifest);

            flake-hjem =
              let
                hjemBase = {
                  config._module.check = false;
                  config.users.users = {
                    "<username>" = {
                      name = "<username>";
                      home = "/home/<username>";
                    };
                  };
                  options.users = pkgs.lib.mkOption {
                    type = pkgs.lib.types.raw;
                    default = {
                      users = {
                        "<username>" = {
                          name = "<username>";
                          home = "/home/<username>";
                        };
                      };
                    };
                  };
                };
                eval = evalLib.flake {
                  targetFlake = inputs.hjem;
                  frameworkDescriptors = {
                    darwinModules = {
                      name = "nix-darwin";
                      eval =
                        module:
                        (pkgs.lib.evalModules {
                          class = "darwin";
                          modules = [
                            hjemBase
                            { _module.args.pkgs = pkgs; }
                            module
                          ];
                        }).options;
                    };
                    nixosModules = {
                      name = "NixOS";
                      eval =
                        module:
                        (pkgs.lib.evalModules {
                          modules = [
                            hjemBase
                            {
                              _module.args.pkgs = pkgs;
                              _module.args.utils = import (pkgs.path + "/nixos/lib/utils.nix") {
                                inherit (pkgs) lib;
                                inherit pkgs;
                                config = { };
                              };
                            }
                            module
                          ];
                        }).options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [ "nixosModules" ]
                    [ "darwinModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? darwinModules || manifest ? packages;
              pkgs.writeText "check-flake-hjem.json" (builtins.toJSON manifest);

            flake-nix-on-droid =
              let
                eval = evalLib.flake { targetFlake = inputs.nix-on-droid; };
                manifest = eval.manifest {
                  paths = [
                    [ "overlays" ]
                    [ "templates" ]
                  ];
                  options = true;
                };
              in
              assert manifest ? overlays || manifest ? templates;
              pkgs.writeText "check-flake-nix-on-droid.json" (builtins.toJSON manifest);

            flake-nixbsd =
              let
                eval = evalLib.flake { targetFlake = inputs.nixbsd; };
                manifest = eval.manifest {
                  paths = [
                    [
                      "packages"
                      pkgs.system
                    ]
                    [
                      "formatter"
                      pkgs.system
                    ]
                  ];
                  options = true;
                };
              in
              assert manifest ? packages || manifest ? formatter;
              pkgs.writeText "check-flake-nixbsd.json" (builtins.toJSON manifest);
          };
        };
    };
}
