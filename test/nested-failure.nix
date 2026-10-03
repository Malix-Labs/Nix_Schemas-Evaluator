{ lib, evaluation }:
let
  inherit (evaluation) safeValue mkError isError;

  # Test tree with a 3-level deep failure: root -> intermediate -> leaf (throws)
  deepTree = {
    intermediate = {
      leaf = {
        value = throw "deep boom";
      };
      sibling = {
        value = "ok";
      };
    };
    passingBranch = {
      child = 42;
    };
  };

  # Tree where a child collection throws directly
  throwingChildMap = {
    children = throw "direct children throw";
  };

  deepResult = safeValue deepTree;
  throwingResult = safeValue throwingChildMap;

  tests = {
    # 1. Leaf failure record must have _type = "error" and kind = "evaluation"
    testAtomicLeafFailure = {
      expr = {
        isErr = isError deepResult.value.intermediate.leaf.value;
        kind = deepResult.value.intermediate.leaf.value.kind;
        type = deepResult.value.intermediate.leaf.value._type;
      };
      expected = {
        isErr = true;
        kind = "evaluation";
        type = "error";
      };
    };

    # 2. Immediate parent of leaf (intermediate.leaf) must point to "value" with kind = "cascade"
    testImmediateParentPropagation = {
      expr = deepResult.value.intermediate.leaf.__evaluation;
      expected = {
        status = "failing";
        failures = [
          {
            child = "value";
            kind = "cascade";
          }
        ];
      };
    };

    # 3. Intermediate container must point to "leaf" with kind = "cascade" and status = "partial" (since sibling passed)
    testIntermediatePropagation = {
      expr = deepResult.value.intermediate.__evaluation;
      expected = {
        status = "partial";
        failures = [
          {
            child = "leaf";
            kind = "cascade";
          }
        ];
      };
    };

    # 4. Root container must point to "intermediate" with kind = "cascade" and status = "partial"
    testRootPropagation = {
      expr = deepResult.value.__evaluation;
      expected = {
        status = "partial";
        failures = [
          {
            child = "intermediate";
            kind = "cascade";
          }
        ];
      };
    };

    # 5. Passing branch must not have __evaluation sidecar
    testPassingBranchClean = {
      expr = deepResult.value.passingBranch ? __evaluation;
      expected = false;
    };

    # 6. Sibling of failed leaf must not have __evaluation sidecar
    testSiblingClean = {
      expr = deepResult.value.intermediate.sibling ? __evaluation;
      expected = false;
    };

    # 7. Direct children throw gets atomic record at child = "children" on owning node
    testDirectChildrenThrow = {
      expr = {
        status = throwingResult.status;
        isErr = isError throwingResult.value.children;
        kind = throwingResult.value.children.kind;
      };
      expected = {
        status = "failing";
        isErr = true;
        kind = "evaluation";
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
