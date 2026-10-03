{
  description = "Heavy module framework matrix checks for Nix Schemas Evaluator";

  inputs = {
    evaluator.url = "path:..";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:LnL7/nix-darwin";
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
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          evalLib = import "${inputs.evaluator}/lib" {
            inherit (inputs) nixpkgs;
            inherit (inputs.evaluator.inputs) flake-schemas;
            optionToDoc =
              inputs.nixpkgs.lib.options.optionToDoc or (import "${inputs.evaluator.inputs.nixpkgs-pr553364}/lib")
              .options.optionToDoc;
          };
        in
        {
          checks = {
            matrix-nixos =
              let
                target = {
                  nixosModules.test =
                    {
                      config,
                      lib,
                      pkgs,
                      ...
                    }:
                    {
                      options.services.myService = {
                        enable = lib.mkEnableOption "test service";
                        port = lib.mkOption {
                          type = lib.types.port;
                          default = 8080;
                          description = "Service port";
                        };
                      };
                      config = lib.mkIf config.services.myService.enable {
                        environment.systemPackages = [ pkgs.hello ];
                      };
                    };
                };
                manifest =
                  (evalLib.flake {
                    targetFlake = target;
                    frameworkDescriptors = {
                      nixosModules = {
                        name = "NixOS";
                        eval =
                          module:
                          let
                            evaled = inputs.nixpkgs.lib.nixosSystem {
                              inherit (pkgs) system;
                              modules = [
                                module
                                {
                                  system.stateVersion = "24.05";
                                  boot.loader.grub.enable = false;
                                  fileSystems."/".device = "/dev/null";
                                }
                              ];
                            };
                          in
                          evaled.options;
                      };
                    };
                  }).manifest
                    { options = true; };
              in
              assert manifest.nixosModules.test.__options ? "$schema";
              assert
                manifest.nixosModules.test.__options.properties.services.properties.myService.properties.enable.type
                == "boolean";
              assert
                manifest.nixosModules.test.__options.properties.services.properties.myService.properties.port.type
                == "integer";
              assert
                manifest.nixosModules.test.__options.properties.boot.properties.loader.properties.grub.properties.enable.type
                == "boolean";
              pkgs.runCommand "check-matrix-nixos" { } "touch $out";

            matrix-home-manager =
              let
                target = {
                  homeModules.test =
                    {
                      config,
                      lib,
                      pkgs,
                      ...
                    }:
                    {
                      options.programs.myTool = {
                        enable = lib.mkEnableOption "test tool";
                      };
                      config = lib.mkIf config.programs.myTool.enable {
                        home.packages = [ pkgs.hello ];
                        home.activation.myToolHook = lib.hm.dag.entryAfter [ "writeBoundary" ] "echo tool ready";
                      };
                    };
                };
                manifest =
                  (evalLib.flake {
                    targetFlake = target;
                    frameworkDescriptors = {
                      homeModules = {
                        name = "Home Manager";
                        eval =
                          module:
                          let
                            hmConfig = inputs.home-manager.lib.homeManagerConfiguration {
                              inherit pkgs;
                              modules = [
                                module
                                {
                                  home = {
                                    username = "testuser";
                                    homeDirectory = "/home/testuser";
                                    stateVersion = "24.05";
                                  };
                                }
                              ];
                            };
                          in
                          hmConfig.options;
                      };
                    };
                  }).manifest
                    { options = true; };
              in
              assert manifest.homeModules.test.__options ? "$schema";
              assert
                manifest.homeModules.test.__options.properties.programs.properties.myTool.properties.enable.type
                == "boolean";
              assert manifest.homeModules.test.__options.properties.home.properties.username.type == "string";
              pkgs.runCommand "check-matrix-home-manager" { } "touch $out";

            matrix-darwin =
              let
                target = {
                  darwinModules.test =
                    {
                      config,
                      lib,
                      pkgs,
                      ...
                    }:
                    {
                      options.services.myDaemon = {
                        enable = lib.mkEnableOption "test daemon";
                      };
                      config = lib.mkIf config.services.myDaemon.enable {
                        environment.systemPackages = [ pkgs.hello ];
                      };
                    };
                };
                manifest =
                  (evalLib.flake {
                    targetFlake = target;
                    frameworkDescriptors = {
                      darwinModules = {
                        name = "nix-darwin";
                        eval =
                          module:
                          let
                            darwinSys = inputs.nix-darwin.lib.darwinSystem {
                              system = "x86_64-darwin";
                              modules = [
                                module
                                {
                                  system.stateVersion = 4;
                                }
                              ];
                            };
                          in
                          darwinSys.options;
                      };
                    };
                  }).manifest
                    { options = true; };
              in
              assert manifest.darwinModules.test.__options ? "$schema";
              assert
                manifest.darwinModules.test.__options.properties.services.properties.myDaemon.properties.enable.type
                == "boolean";
              assert
                manifest.darwinModules.test.__options.properties.system.properties.stateVersion.type == "integer";
              pkgs.runCommand "check-matrix-darwin" { } "touch $out";
          };
        };
    };
}
