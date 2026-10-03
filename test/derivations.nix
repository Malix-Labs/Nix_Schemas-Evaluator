{ lib, flake }:
let
  targetFlake = "path:" + toString ./_fixtures/minimal-complete-flake;
  evaluator = flake { inherit targetFlake; };

  # Full collection in safe mode
  allDerivationsSafe = evaluator.derivations {
    safe = true;
  };

  # Path-selected collection
  selectedDerivations = evaluator.derivations {
    paths = [
      [
        "packages"
        "x86_64-linux"
        "hello"
      ]
    ];
    safe = true;
  };

  # Verify hello derivation
  helloDrv = allDerivationsSafe.packages.x86_64-linux.hello;

  tests = {
    # 1. Preserves raw derivation thunk (type = "derivation", drvPath, outPath)
    testPreservesRawDerivationThunk = {
      expr = {
        isDrv = lib.isDerivation helloDrv;
        inherit (helloDrv) type;
        hasDrvPath = builtins.isString helloDrv.drvPath;
        hasOutPath = builtins.isString helloDrv.outPath;
      };
      expected = {
        isDrv = true;
        type = "derivation";
        hasDrvPath = true;
        hasOutPath = true;
      };
    };

    # 2. Output shape preserves flake hierarchy (packages.x86_64-linux.<name>)
    testPreservesHierarchy = {
      expr = allDerivationsSafe.packages ? x86_64-linux;
      expected = true;
    };

    # 3. Fault tolerance: broken packages and throwing packages are omitted in safe mode
    testFaultToleranceInSafeMode = {
      expr = {
        hasHello = allDerivationsSafe.packages.x86_64-linux ? hello;
        hasTestPkg = allDerivationsSafe.packages.x86_64-linux ? test-package;
        # throwing-package threw in its derivation name or attributes, so it should not crash the collector
        hasThrowing = allDerivationsSafe.packages.x86_64-linux ? throwing-package;
        # not-a-derivation was an attrset without type = derivation, must be omitted
        hasNotDrv = allDerivationsSafe.packages.x86_64-linux ? not-a-derivation;
      };
      expected = {
        hasHello = true;
        hasTestPkg = true;
        hasThrowing = false;
        hasNotDrv = false;
      };
    };

    # 4. Path selection returns only requested derivations
    testPathSelection = {
      expr = {
        hasHello = selectedDerivations.packages.x86_64-linux ? hello;
        hasTestPkg = selectedDerivations.packages.x86_64-linux ? test-package;
      };
      expected = {
        hasHello = true;
        hasTestPkg = false;
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
