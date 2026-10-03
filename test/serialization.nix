{ lib, evaluation }:
let
  inherit (evaluation) safeValue;

  # Test suite testing JSON boundary serialization
  scalarsAndContainers = {
    nullField = null;
    boolTrue = true;
    boolFalse = false;
    intVal = 42;
    floatVal = 3.14159;
    strVal = "hello world";
    pathVal = ./.;
    listVal = [
      1
      "two"
      false
      null
    ];
    nestedSet = {
      inner = {
        deep = [
          1
          2
          3
        ];
      };
    };
  };

  # String with Nix store path context
  stringWithContext = {
    content = "" + ./.;
  };

  # Source position attribute set
  sourcePosition = {
    file = "path/to/file.nix";
    line = 42;
    column = 1;
  };

  # Unsupported values that must be safely transformed before JSON serialization
  unsupportedValues = {
    fnLeaf = x: x;
    builtinLeaf = builtins.attrNames;
    throwingLeaf = throw "kaboom";
    validSibling = "survives";
  };

  # Perform safe evaluation
  scalarsRes = safeValue scalarsAndContainers;
  contextRes = safeValue stringWithContext;
  posRes = safeValue sourcePosition;
  unsupportedRes = safeValue unsupportedValues;

  # Verify that builtins.toJSON succeeds on all transformed values without runtime exceptions
  jsonScalars = builtins.toJSON scalarsRes.value;
  jsonContext = builtins.toJSON contextRes.value;
  jsonPos = builtins.toJSON posRes.value;
  jsonUnsupported = builtins.toJSON unsupportedRes.value;

  # Parse back from JSON to ensure round-trip integrity
  parsedScalars = builtins.fromJSON (builtins.unsafeDiscardStringContext jsonScalars);
  parsedUnsupported = builtins.fromJSON (builtins.unsafeDiscardStringContext jsonUnsupported);

  tests = {
    testScalarsSerializability = {
      expr = {
        nullVal = parsedScalars.nullField;
        boolVal = parsedScalars.boolTrue;
        intVal = parsedScalars.intVal;
        strVal = parsedScalars.strVal;
        listLen = builtins.length parsedScalars.listVal;
      };
      expected = {
        nullVal = null;
        boolVal = true;
        intVal = 42;
        strVal = "hello world";
        listLen = 4;
      };
    };

    testUnsupportedTransformations = {
      expr = {
        fnType = parsedUnsupported.fnLeaf._type;
        fnKind = parsedUnsupported.fnLeaf.kind;
        builtinType = parsedUnsupported.builtinLeaf._type;
        builtinKind = parsedUnsupported.builtinLeaf.kind;
        throwType = parsedUnsupported.throwingLeaf._type;
        throwKind = parsedUnsupported.throwingLeaf.kind;
        sibling = parsedUnsupported.validSibling;
        status = parsedUnsupported.__evaluation.status;
      };
      expected = {
        fnType = "error";
        fnKind = "non_serializable";
        builtinType = "error";
        builtinKind = "non_serializable";
        throwType = "error";
        throwKind = "evaluation";
        sibling = "survives";
        status = "partial";
      };
    };

    testStringWithContext = {
      expr = builtins.isString jsonContext;
      expected = true;
    };

    testSourcePosition = {
      expr = builtins.isString jsonPos;
      expected = true;
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
