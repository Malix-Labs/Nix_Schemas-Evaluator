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
      evaluator,
      nixpkgs,
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
        { pkgs, system, ... }:
        let
          evalLib = import "${inputs.evaluator}/lib" {
            nixpkgs = inputs.nixpkgs;
            inherit (inputs.evaluator.inputs) flake-schemas;
          };
        in
        {
          checks = {
            matrix-nixos =
              let
                target = {
                  nixosModules.test =
                    { ... }:
                    {
                      options.myService.enable = inputs.nixpkgs.lib.mkEnableOption "test service";
                    };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.nixosModules.test.__options.myService.enable._type == "option";
              pkgs.runCommand "check-matrix-nixos" { } "touch $out";

            matrix-home-manager =
              let
                target = {
                  homeModules.test =
                    { ... }:
                    {
                      options.programs.myTool.enable = inputs.nixpkgs.lib.mkEnableOption "test tool";
                    };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.homeModules.test.__options.programs.myTool.enable._type == "option";
              pkgs.runCommand "check-matrix-home-manager" { } "touch $out";

            matrix-darwin =
              let
                target = {
                  darwinModules.test =
                    { ... }:
                    {
                      options.services.myDaemon.enable = inputs.nixpkgs.lib.mkEnableOption "test daemon";
                    };
                };
                manifest = (evalLib.flake { targetFlake = target; }).manifest { options = true; };
              in
              assert manifest.darwinModules.test.__options.services.myDaemon.enable._type == "option";
              pkgs.runCommand "check-matrix-darwin" { } "touch $out";
          };
        };
    };
}
