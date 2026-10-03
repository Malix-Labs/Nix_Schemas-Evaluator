{ lib, flake }:
let
  targetFlake = "path:" + toString ./_fixtures/minimal-complete-flake;
  evaluator = flake { inherit targetFlake; };

  invSafe = evaluator.inventory { safe = true; };
  invStrict = evaluator.inventory { safe = false; };

  # Verify laziness: accessing attrNames of packages children must succeed
  pkgNames = builtins.attrNames invSafe.packages.children.x86_64-linux.children;

  # Verify app checks in safe mode
  safeAppNode = invSafe.apps.children.aarch64-linux.children.app-hello;
  safeThrowingApp = invSafe.apps.children.aarch64-linux.children.throwing-app;

  tests = {
    testLazinessListingAttrNamesSucceeds = {
      expr = lib.elem "hello" pkgNames && lib.elem "throwing-package" pkgNames;
      expected = true;
    };

    testNoForeignSidecarsInChildren = {
      expr = invSafe.packages.children.x86_64-linux.children ? __evaluation;
      expected = false;
    };

    testProtocolMetadataFieldsPreserved = {
      expr = {
        what = safeAppNode.what;
        hasSystems = lib.elem "aarch64-linux" safeAppNode.forSystems;
        isValid = safeAppNode.evalChecks.isValidApp;
      };
      expected = {
        what = "app";
        hasSystems = true;
        isValid = true;
      };
    };

    testSafeModeCapturesThrowInEvalChecks = {
      expr = safeThrowingApp.evalChecks.isValidApp;
      expected = false;
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
