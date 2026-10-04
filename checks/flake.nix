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
              assert manifest.nixosModules.age.__options ? "$schema";
              assert manifest.nixosModules.age.__options.properties ? age;
              assert manifest.nixosModules.age.__options.properties.age.properties ? secrets;
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
              assert manifest.packages.${pkgs.system} ? deploy-rs;
              assert manifest.overlays ? default;
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
              assert manifest.nixosModules.hydra.__options ? "$schema";
              assert manifest.nixosModules.hydra.__options.properties ? services;
              assert manifest.nixosModules.hydra.__options.properties.services.properties ? hydra-dev;
              pkgs.writeText "check-flake-hydra.json" (builtins.toJSON manifest);

            # Framework flakes evaluated using native framework descriptors and full option trees
            flake-home-manager =
              let
                hmExtendedLib = import (inputs.home-manager + "/modules/lib/stdlib-extended.nix") pkgs.lib;
                eval = evalLib.flake {
                  targetFlake = inputs.home-manager // {
                    homeModules = {
                      default = {
                        _file = "home-manager";
                        imports = import (inputs.home-manager + "/modules/modules.nix") {
                          inherit pkgs;
                          lib = hmExtendedLib;
                          check = false;
                        };
                      };
                    };
                  };
                  frameworkDescriptors = {
                    homeModules = {
                      name = "Home Manager";
                      eval =
                        module:
                        (hmExtendedLib.evalModules {
                          class = "homeManager";
                          modules = [
                            {
                              _module.check = false;
                              home = {
                                username = "test";
                                homeDirectory = "/home/test";
                                stateVersion = "24.11";
                              };
                            }
                            module
                          ];
                          specialArgs = {
                            inherit pkgs;
                            modulesPath = toString (inputs.home-manager + "/modules");
                          };
                        }).options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [
                    [ "homeModules" ]
                    [ "nixosModules" ]
                  ];
                  options = true;
                };
              in
              assert manifest.homeModules.default ? __options;
              assert manifest.homeModules.default.__options ? "$schema";
              assert manifest.homeModules.default.__options.properties ? programs;
              assert manifest.homeModules.default.__options.properties ? services;
              assert manifest.homeModules.default.__options.properties ? home;
              pkgs.writeText "check-flake-home-manager.json" (builtins.toJSON manifest);

            flake-nix-darwin =
              let
                darwinLib = pkgs.lib.extend (
                  _: prev: {
                    maintainers = prev.maintainers // {
                      lnl7 = "lnl7";
                    };
                  }
                );
                eval = evalLib.flake {
                  targetFlake = inputs.nix-darwin // {
                    darwinModules = (inputs.nix-darwin.darwinModules or { }) // {
                      default = {
                        _file = "nix-darwin";
                        imports = import (inputs.nix-darwin + "/modules/module-list.nix");
                      };
                    };
                  };
                  frameworkDescriptors = {
                    darwinModules = {
                      name = "nix-darwin";
                      eval =
                        module:
                        (import (inputs.nix-darwin + "/eval-config.nix") {
                          lib = darwinLib;
                          modules = [
                            {
                              _module.check = false;
                              nixpkgs.pkgs = pkgs;
                              system.stateVersion = 5;
                              system.primaryUser = "runner";
                            }
                            module
                          ];
                          enableNixpkgsReleaseCheck = false;
                          check = false;
                        }).options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [ [ "darwinModules" ] ];
                  options = true;
                };
              in
              assert manifest.darwinModules.default ? __options;
              assert manifest.darwinModules.default.__options ? "$schema";
              assert manifest.darwinModules.default.__options.properties ? environment;
              assert manifest.darwinModules.default.__options.properties ? services;
              assert manifest.darwinModules.default.__options.properties ? system;
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
              assert manifest.nixosModules.default.__options ? "$schema";
              assert manifest.nixosModules.default.__options.properties ? hjem;
              assert manifest.darwinModules.default.__options ? "$schema";
              assert manifest.darwinModules.default.__options.properties ? hjem;
              pkgs.writeText "check-flake-hjem.json" (builtins.toJSON manifest);

            flake-nix-on-droid =
              let
                nodLib = pkgs.lib.extend (
                  _: prev: {
                    mdDoc = prev.mdDoc or (x: x);
                  }
                );
                nodPkgs = pkgs // {
                  lib = nodLib;
                };
                eval = evalLib.flake {
                  targetFlake = inputs.nix-on-droid // {
                    schemas = {
                      nixOnDroidModules = {
                        version = 1;
                        doc = "nix-on-droid modules";
                      };
                    };
                    nixOnDroidModules = {
                      default = {
                        _file = "nix-on-droid";
                        imports = import (inputs.nix-on-droid + "/modules/module-list.nix") {
                          pkgs = nodPkgs;
                          home-manager-path = inputs.home-manager;
                          isFlake = true;
                          targetSystem = "aarch64-linux";
                        };
                      };
                    };
                  };
                  frameworkDescriptors = {
                    nixOnDroidModules = {
                      name = "nix-on-droid";
                      eval =
                        module:
                        (nodLib.evalModules {
                          class = "nixOnDroid";
                          modules = [
                            {
                              _module.check = false;
                              system.stateVersion = "24.05";
                            }
                            module
                          ];
                          specialArgs = {
                            pkgs = nodPkgs;
                            lib = nodLib;
                          };
                        }).options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [ [ "nixOnDroidModules" ] ];
                  options = true;
                };
              in
              assert manifest.nixOnDroidModules.default ? __options;
              assert manifest.nixOnDroidModules.default.__options ? "$schema";
              assert manifest.nixOnDroidModules.default.__options.properties ? android-integration;
              assert manifest.nixOnDroidModules.default.__options.properties ? environment;
              pkgs.writeText "check-flake-nix-on-droid.json" (builtins.toJSON manifest);

            flake-nixbsd =
              let
                eval = evalLib.flake {
                  targetFlake = inputs.nixbsd // {
                    schemas = {
                      nixbsdModules = {
                        version = 1;
                        doc = "nixbsd modules";
                      };
                    };
                    nixbsdModules = {
                      default = {
                        _file = "nixbsd";
                        imports = [
                          (inputs.nixbsd + "/modules/nixos-compat.nix")
                          (inputs.nixbsd + "/modules/services/base-system.nix")
                          (inputs.nixbsd + "/modules/services/system/nix-daemon.nix")
                          (inputs.nixbsd + "/modules/system/boot/init/freebsd-rc.nix")
                        ];
                      };
                    };
                  };
                  frameworkDescriptors = {
                    nixbsdModules = {
                      name = "nixbsd";
                      eval =
                        module:
                        (pkgs.lib.evalModules {
                          class = "nixbsd";
                          modules = [
                            { _module.check = false; }
                            module
                          ];
                        }).options;
                    };
                  };
                };
                manifest = eval.manifest {
                  paths = [ [ "nixbsdModules" ] ];
                  options = true;
                };
              in
              assert manifest.nixbsdModules.default ? __options;
              assert manifest.nixbsdModules.default.__options ? "$schema";
              assert manifest.nixbsdModules.default.__options.properties ? services;
              assert manifest.nixbsdModules.default.__options.properties ? freebsd;
              pkgs.writeText "check-flake-nixbsd.json" (builtins.toJSON manifest);
          };
        };
    };
}
