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
      submoduleTest =
        { ... }:
        {
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

      failingModule =
        { ... }:
        {
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
    # 1. NixOS module options are projected as nested attribute sets with _type = "option"
    testModuleOptionStructure = {
      expr = {
        hasOptions = manifestWithOptions.nixosModules.default ? __options;
        optType = manifestWithOptions.nixosModules.default.__options.testOpt._type;
        optDesc = manifestWithOptions.nixosModules.default.__options.testOpt.description;
        optDefault = manifestWithOptions.nixosModules.default.__options.testOpt.default.text;
      };
      expected = {
        hasOptions = true;
        optType = "option";
        optDesc = "Test option";
        optDefault = "\"val\"";
      };
    };

    # 2. Submodule options are nested under "*"
    testSubmoduleOptionsNestedUnderWildcard = {
      expr = {
        hasOptions = submoduleManifest.nixosModules.submoduleTest ? __options;
        serverOpt = submoduleManifest.nixosModules.submoduleTest.__options.server._type;
        hasSubmodule = submoduleManifest.nixosModules.submoduleTest.__options.server ? "*";
        portOpt = submoduleManifest.nixosModules.submoduleTest.__options.server."*".port._type;
        portDefault = submoduleManifest.nixosModules.submoduleTest.__options.server."*".port.default.text;
      };
      expected = {
        hasOptions = true;
        serverOpt = "option";
        hasSubmodule = true;
        portOpt = "option";
        portDefault = "8080";
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
