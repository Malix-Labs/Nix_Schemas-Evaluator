{ lib, flake }:
let
  targetFlake = "path:" + toString ./_fixtures/minimal-complete-flake;
  evaluator = flake { inherit targetFlake; };

  manifest = evaluator.manifest {
    safe = true;
  };

  # Inspect package projection
  helloPkg = manifest.packages.x86_64-linux.hello;
  testPkg = manifest.packages.x86_64-linux.test-package;
  customMetaPkg = manifest.packages.x86_64-linux.custom-meta-package;
  fieldThrowingPkg = manifest.packages.x86_64-linux.field-throwing-package;
  throwingPkg = manifest.packages.x86_64-linux.throwing-package;

  # Inspect app projection
  helloApp = manifest.apps.x86_64-linux.app-hello;
  throwingApp = manifest.apps.x86_64-linux.throwing-app;

  tests = {
    # 1. Package projection contains explicit fields
    testPackageExplicitFields = {
      expr = {
        hasName = builtins.isString helloPkg.name;
        hasOutputs = lib.isList helloPkg.outputs;
        hasOutputName = helloPkg.outputName == "out";
        hasMeta = lib.isAttrs helloPkg.meta;
      };
      expected = {
        hasName = true;
        hasOutputs = true;
        hasOutputName = true;
        hasMeta = true;
      };
    };

    # 2. Package metadata correctly materialized
    testPackageMetadata = {
      expr = {
        desc = testPkg.meta.description;
        licenseFullName = testPkg.meta.license.fullName;
        customField = customMetaPkg.meta.customAttr;
      };
      expected = {
        desc = "A test package";
        licenseFullName = "MIT License";
        customField = "new_future_field";
      };
    };

    # 3. Field failure inside meta creates typed error and causal links
    testFieldFailureInsideMeta = {
      expr = {
        brokenType = fieldThrowingPkg.meta.brokenKey._type;
        brokenKind = fieldThrowingPkg.meta.brokenKey.kind;
        metaStatus = fieldThrowingPkg.meta.__evaluation.status;
        metaFailureChild = (lib.head fieldThrowingPkg.meta.__evaluation.failures).child;
        pkgStatus = fieldThrowingPkg.__evaluation.status;
        pkgFailureChild = (lib.head fieldThrowingPkg.__evaluation.failures).child;
      };
      expected = {
        brokenType = "error";
        brokenKind = "evaluation";
        metaStatus = "partial";
        metaFailureChild = "brokenKey";
        pkgStatus = "partial";
        pkgFailureChild = "meta";
      };
    };

    # 4. Derivation name throw creates typed error on name
    testDerivationNameThrow = {
      expr = {
        nameType = throwingPkg.name._type;
        nameKind = throwingPkg.name.kind;
        pkgStatus = throwingPkg.__evaluation.status;
        pkgFailureChild = (lib.head throwingPkg.__evaluation.failures).child;
      };
      expected = {
        nameType = "error";
        nameKind = "evaluation";
        pkgStatus = "partial";
        pkgFailureChild = "name";
      };
    };

    # 5. App preserves standard 'program' and 'type = app'
    testAppProjection = {
      expr = {
        type = helloApp.type;
        hasProgram = builtins.isString helloApp.program;
      };
      expected = {
        type = "app";
        hasProgram = true;
      };
    };

    # 6. Throwing app replaces program with typed error
    testThrowingApp = {
      expr = {
        programType = throwingApp.program._type;
        programKind = throwingApp.program.kind;
        appStatus = throwingApp.__evaluation.status;
        appFailureChild = (lib.head throwingApp.__evaluation.failures).child;
      };
      expected = {
        programType = "error";
        programKind = "evaluation";
        appStatus = "failing";
        appFailureChild = "program";
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
