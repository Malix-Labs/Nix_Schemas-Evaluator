{ lib, flake }:
let
  targetFlake = "path:" + toString ./_fixtures/minimal-complete-flake;
  evaluator = flake { inherit targetFlake; };

  # 1. Querying only "good": does not force "bad", returns good, no failure
  manifestGoodOnly = evaluator.manifest {
    paths = [
      [
        "custom"
        "children"
        "good"
      ]
    ];
  };

  # 2. Querying only "bad": returns bad with _type = "error" and causal links in parents
  manifestBadOnly = evaluator.manifest {
    paths = [
      [
        "custom"
        "children"
        "bad"
      ]
    ];
  };

  # 3. Querying entire "custom.children": returns both, parent status is "partial", sidecar has child = "bad"
  manifestAllCustom = evaluator.manifest {
    paths = [
      [
        "custom"
        "children"
      ]
    ];
  };

  # 4. Invalid path: gets deterministic missing_attribute error
  manifestInvalidPath = evaluator.manifest {
    paths = [
      [
        "custom"
        "children"
        "nonexistent"
      ]
    ];
  };

  # 5. Overlapping paths
  manifestOverlapping = evaluator.manifest {
    paths = [
      [
        "custom"
        "children"
        "good"
      ]
      [
        "custom"
        "children"
      ]
    ];
  };

  # 6. Empty paths selection: returns empty set
  manifestEmpty = evaluator.manifest {
    paths = [ ];
  };

  tests = {
    testGoodOnlySucceedsWithoutBadFailure = {
      expr = {
        hasGood = manifestGoodOnly.custom.children ? good;
        goodVal = manifestGoodOnly.custom.children.good.value;
        hasBad = manifestGoodOnly.custom.children ? bad;
        hasEvalSidecar = manifestGoodOnly.custom ? __evaluation;
      };
      expected = {
        hasGood = true;
        goodVal = 1;
        hasBad = false;
        hasEvalSidecar = false;
      };
    };

    testBadOnlyReturnsTypedErrorWithCausalChain = {
      expr = {
        hasBad = manifestBadOnly.custom.children ? bad;
        badType = manifestBadOnly.custom.children.bad.value._type;
        badKind = manifestBadOnly.custom.children.bad.value.kind;
        parentStatus = manifestBadOnly.custom.children.__evaluation.status;
        parentFailureChild = (lib.head manifestBadOnly.custom.children.__evaluation.failures).child;
        rootStatus = manifestBadOnly.custom.__evaluation.status;
        rootFailureChild = (lib.head manifestBadOnly.custom.__evaluation.failures).child;
      };
      expected = {
        hasBad = true;
        badType = "error";
        badKind = "evaluation";
        parentStatus = "failing";
        parentFailureChild = "bad";
        rootStatus = "failing";
        rootFailureChild = "children";
      };
    };

    testBothChildrenGivesPartialStatus = {
      expr = {
        hasGood = manifestAllCustom.custom.children ? good;
        hasBad = manifestAllCustom.custom.children ? bad;
        parentStatus = manifestAllCustom.custom.children.__evaluation.status;
        parentFailureChild = (lib.head manifestAllCustom.custom.children.__evaluation.failures).child;
        rootStatus = manifestAllCustom.custom.__evaluation.status;
      };
      expected = {
        hasGood = true;
        hasBad = true;
        parentStatus = "partial";
        parentFailureChild = "bad";
        rootStatus = "partial";
      };
    };

    testMissingAttributeOnInvalidPath = {
      expr = {
        isErr = manifestInvalidPath.custom.children.nonexistent._type or null == "error";
        kind = manifestInvalidPath.custom.children.nonexistent.kind or null;
        status = manifestInvalidPath.custom.children.__evaluation.status;
      };
      expected = {
        isErr = true;
        kind = "missing_attribute";
        status = "failing";
      };
    };

    testEmptyPathsReturnsEmpty = {
      expr = manifestEmpty;
      expected = { };
    };

    testOverlappingPathsProducesCompleteSubtree = {
      expr = {
        hasGood = manifestOverlapping.custom.children ? good;
        hasBad = manifestOverlapping.custom.children ? bad;
      };
      expected = {
        hasGood = true;
        hasBad = true;
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
