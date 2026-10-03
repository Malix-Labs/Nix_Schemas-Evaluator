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
                  nixosModules.test = _: {
                    options.myService.enable = inputs.nixpkgs.lib.mkEnableOption "test service";
                  };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.nixosModules.test.__options ? "$schema";
              assert
                manifest.nixosModules.test.__options.properties.myService.properties.enable.type == "boolean";
              pkgs.runCommand "check-matrix-nixos" { } "touch $out";

            matrix-home-manager =
              let
                target = {
                  homeModules.test = _: {
                    options.programs.myTool.enable = inputs.nixpkgs.lib.mkEnableOption "test tool";
                  };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.homeModules.test.__options ? "$schema";
              assert
                manifest.homeModules.test.__options.properties.programs.properties.myTool.properties.enable.type
                == "boolean";
              pkgs.runCommand "check-matrix-home-manager" { } "touch $out";

            matrix-darwin =
              let
                target = {
                  darwinModules.test = _: {
                    options.services.myDaemon.enable = inputs.nixpkgs.lib.mkEnableOption "test daemon";
                  };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.darwinModules.test.__options ? "$schema";
              assert
                manifest.darwinModules.test.__options.properties.services.properties.myDaemon.properties.enable.type
                == "boolean";
              pkgs.runCommand "check-matrix-darwin" { } "touch $out";
          };
        };
    };
}
