{ lib, flake }:
let
  evaluatorFor =
    targetFlake:
    flake {
      inherit targetFlake;
    };

  # 1. NixOS module schema
  nixosFlake = {
    schemas = { };
    nixosModules.test = _: {
      options.myService.enable = lib.mkEnableOption "test service";
    };
  };
  nixosManifest = (evaluatorFor nixosFlake).manifest { options = true; };

  # 2. Home Manager module schema
  hmFlake = {
    schemas = { };
    homeModules.test = _: {
      options.programs.myTool.enable = lib.mkEnableOption "test tool";
    };
  };
  hmManifest = (evaluatorFor hmFlake).manifest { options = true; };

  # 3. nix-darwin module schema
  darwinFlake = {
    schemas = { };
    darwinModules.test = _: {
      options.services.myDaemon.enable = lib.mkEnableOption "test daemon";
    };
  };
  darwinManifest = (evaluatorFor darwinFlake).manifest { options = true; };

  tests = {
    testNixosModuleDescriptor = {
      expr = {
        hasSchema = nixosManifest.nixosModules.test.__options ? "$schema";
        enableType = nixosManifest.nixosModules.test.__options.properties.myService.properties.enable.type;
      };
      expected = {
        hasSchema = true;
        enableType = "boolean";
      };
    };

    testHomeManagerModuleDescriptor = {
      expr = {
        hasSchema = hmManifest.homeModules.test.__options ? "$schema";
        enableType =
          hmManifest.homeModules.test.__options.properties.programs.properties.myTool.properties.enable.type;
      };
      expected = {
        hasSchema = true;
        enableType = "boolean";
      };
    };

    testDarwinModuleDescriptor = {
      expr = {
        hasSchema = darwinManifest.darwinModules.test.__options ? "$schema";
        enableType =
          darwinManifest.darwinModules.test.__options.properties.services.properties.myDaemon.properties.enable.type;
      };
      expected = {
        hasSchema = true;
        enableType = "boolean";
      };
    };
  };

  results = lib.mapAttrs (
    name: test:
    if test.expr == test.expected then
      "pass"
    else
      throw "Test '${name}' failed: expected ${builtins.toJSON test.expected}, got ${builtins.toJSON test.expr}"
  ) tests;
in
results
