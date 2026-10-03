{ lib, flake }:
let
  targetFlake = "path:" + toString ./_fixtures/minimal-complete-flake;
  evaluator = flake { inherit targetFlake; };

  # Module option projection enabled
  manifestWithOptions = evaluator.manifest {
    paths = [
      [
        "nixosModules"
        "default"
      ]
    ];
    options = true;
    safe = true;
  };

  # Module option projection disabled
  manifestWithoutOptions = evaluator.manifest {
    paths = [
      [
        "nixosModules"
        "default"
      ]
    ];
    options = false;
    safe = true;
  };

  # Synthetic flake with a submodule and a failing module
  syntheticFlake = {
    schemas = { };
    nixosModules = {
      submoduleTest = _: {
        options.server = lib.mkOption {
          type = lib.types.submodule {
            options = {
              port = lib.mkOption {
                type = lib.types.int;
                default = 8080;
                description = "Server port";
              };
            };
          };
          description = "Server settings";
        };
      };

      failingModule = _: {
        options.broken = throw "module evaluation boom";
      };
    };
  };

  syntheticEvaluator = flake { targetFlake = syntheticFlake; };

  submoduleManifest = syntheticEvaluator.manifest {
    paths = [
      [
        "nixosModules"
        "submoduleTest"
      ]
    ];
    options = true;
    safe = true;
  };

  failingManifest = syntheticEvaluator.manifest {
    paths = [
      [
        "nixosModules"
        "failingModule"
      ]
    ];
    options = true;
    safe = true;
  };

  tests = {
    # 1. NixOS module options are projected as JSON Schema Draft 2020-12
    testModuleOptionStructure = {
      expr = {
        hasOptions = manifestWithOptions.nixosModules.default ? __options;
        hasSchema = manifestWithOptions.nixosModules.default.__options ? "$schema";
        rootType = manifestWithOptions.nixosModules.default.__options.type;
        optType = manifestWithOptions.nixosModules.default.__options.properties.testOpt.type;
        optNixType = manifestWithOptions.nixosModules.default.__options.properties.testOpt.nixType;
        optDesc = manifestWithOptions.nixosModules.default.__options.properties.testOpt.description;
        optDefault = manifestWithOptions.nixosModules.default.__options.properties.testOpt.default;
      };
      expected = {
        hasOptions = true;
        hasSchema = true;
        rootType = "object";
        optType = "string";
        optNixType = "string";
        optDesc = "Test option";
        optDefault = "val";
      };
    };

    # 2. Submodule options are nested under properties.<name>.properties
    testSubmoduleOptionsNestedUnderProperties = {
      expr = {
        hasOptions = submoduleManifest.nixosModules.submoduleTest ? __options;
        serverType = submoduleManifest.nixosModules.submoduleTest.__options.properties.server.type;
        serverNixType = submoduleManifest.nixosModules.submoduleTest.__options.properties.server.nixType;
        portType =
          submoduleManifest.nixosModules.submoduleTest.__options.properties.server.properties.port.type;
        portDefault =
          submoduleManifest.nixosModules.submoduleTest.__options.properties.server.properties.port.default;
      };
      expected = {
        hasOptions = true;
        serverType = "object";
        serverNixType = "submodule";
        portType = "integer";
        portDefault = 8080;
      };
    };

    # 3. options = false omits __options
    testOptionsFalseOmitsOptions = {
      expr = manifestWithoutOptions.nixosModules.default ? __options;
      expected = false;
    };

    # 4. Whole option evaluation failure gives __options = null and child = "__options"
    testWholeOptionFailure = {
      expr = {
        optionsNull = failingManifest.nixosModules.failingModule.__options == null;
        status = failingManifest.nixosModules.failingModule.__evaluation.status;
        failureChild = (lib.head failingManifest.nixosModules.failingModule.__evaluation.failures).child;
      };
      expected = {
        optionsNull = true;
        status = "failing";
        failureChild = "__options";
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
