{ lib }:
/**
  Evaluation and Failure Representation Engine for Nix Schemas.

  Why failures are atomic and retained:
  In safe mode (`safe = true`), caught evaluation throws or broken schema items
  must not abort the entire evaluation graph. Instead, evaluation failures are
  captured and represented locally using Alternative 5B (`_type = "error"`).

  Difference between valid null and unavailable null:
  A legitimate Nix `null` (e.g. `meta.description = null;`) evaluates successfully
  as `null` with status `"passing"`. An evaluation failure (e.g. `throw "boom"`)
  is captured as a self-describing typed error object:
    `{ _type = "error"; kind = "..."; message = "..."; }`
  This eliminates ambiguity: consumers never need to inspect parent sidecars just
  to know whether a field succeeded as `null` or failed.

  Why causal path hops are propagated:
  Parent containers record one-hop scalar links (`child = "name"`) with `kind = "cascade"`.
  This creates a navigable causal chain (root -> child -> leaf) without duplicating
  descendant error messages or accumulating quadratic path arrays in ancestors.
*/
rec {
  /**
    Constructs a typed error object (Alternative 5B).
  */
  mkError =
    {
      kind ? "evaluation",
      message ? null,
    }:
    {
      _type = "error";
      inherit kind;
    }
    // lib.optionalAttrs (message != null) { inherit message; };

  /**
    Checks if a value is a typed error object.
  */
  isError = value: lib.isAttrs value && (value._type or null) == "error";

  /**
    Checks if a value has a specific `_type` attribute.
  */
  isType = type: value: lib.isAttrs value && (value._type or null) == type;

  /**
    Computes aggregate status from a list of child statuses.
    Deterministic rules:
    - Empty list -> "passing"
    - All children "failing" -> "failing"
    - Any non-"passing" child -> "partial"
    - Otherwise -> "passing"
  */
  statusFromStatuses =
    statuses:
    if statuses == [ ] then
      "passing"
    else if lib.all (s: s == "failing") statuses then
      "failing"
    else if lib.any (s: s != "passing") statuses then
      "partial"
    else
      "passing";

  /**
    Removes the evaluator internal `__evaluation` sidecar from an attribute set
    so that child iteration never treats `__evaluation` as a child node.
  */
  stripEvaluation =
    attrs: if lib.isAttrs attrs then builtins.removeAttrs attrs [ "__evaluation" ] else attrs;

  /**
    Attaches an `__evaluation` sidecar to an attribute set if status is non-passing.
    Passing nodes do not carry an `__evaluation` sidecar.
  */
  addEvaluation =
    {
      status,
      failures ? [ ],
      value,
    }:
    if status == "passing" then
      value
    else
      let
        base = if lib.isAttrs value then value else { inherit value; };
      in
      base
      // {
        __evaluation = {
          inherit status;
          failures = lib.unique failures;
        };
      };

  /**
    Safely evaluates an arbitrary Nix value recursively for manifest JSON serialization.

    Returns:
    {
      success = bool;
      value = evaluatedValueOrTypedError;
      status = "passing" | "partial" | "failing";
      failures = [ { child = "..."; kind = "cascade"; } ];
    }
  */
  safeValue =
    value:
    let
      evalAttempt = lib.tryEval value;
    in
    if !evalAttempt.success then
      {
        success = false;
        value = mkError {
          kind = "evaluation";
          message = "evaluation failed";
        };
        status = "failing";
        failures = [ ];
      }
    else if lib.isFunction evalAttempt.value then
      {
        success = false;
        value = mkError {
          kind = "non_serializable";
          message = "cannot serialize function to JSON";
        };
        status = "failing";
        failures = [ ];
      }
    else if lib.isAttrs evalAttempt.value then
      # If already a typed error, preserve as failing leaf
      if isError evalAttempt.value then
        {
          success = false;
          value = evalAttempt.value;
          status = "failing";
          failures = [ ];
        }
      else
        let
          namesAttempt = lib.tryEval (lib.attrNames evalAttempt.value);
        in
        if !namesAttempt.success then
          {
            success = false;
            value = mkError {
              kind = "evaluation";
              message = "failed to evaluate attribute names";
            };
            status = "failing";
            failures = [ ];
          }
        else
          let
            # Filter out __evaluation if already present
            cleanNames = lib.filter (n: n != "__evaluation") namesAttempt.value;

            childrenResults = map (
              name:
              let
                childRes = safeValue evalAttempt.value.${name};
              in
              {
                inherit name childRes;
              }
            ) cleanNames;

            childStatuses = map (c: c.childRes.status) childrenResults;
            status = statusFromStatuses childStatuses;

            # One-hop causal links: point directly to non-passing children
            failures = lib.concatLists (
              map (
                c:
                if c.childRes.status != "passing" then
                  [
                    {
                      child = c.name;
                      kind = "cascade";
                    }
                  ]
                else
                  [ ]
              ) childrenResults
            );

            materializedValues = lib.listToAttrs (
              map (c: {
                name = c.name;
                value = c.childRes.value;
              }) childrenResults
            );
          in
          {
            success = status == "passing";
            value = addEvaluation {
              inherit status failures;
              value = materializedValues;
            };
            inherit status failures;
          }
    else if lib.isList evalAttempt.value then
      let
        itemsResults = lib.imap0 (
          index: item:
          let
            itemRes = safeValue item;
          in
          {
            index = toString index;
            inherit itemRes;
          }
        ) evalAttempt.value;

        itemStatuses = map (i: i.itemRes.status) itemsResults;
        status = statusFromStatuses itemStatuses;

        failures = lib.concatLists (
          map (
            i:
            if i.itemRes.status != "passing" then
              [
                {
                  child = i.index;
                  kind = "cascade";
                }
              ]
            else
              [ ]
          ) itemsResults
        );

        materializedList = map (i: i.itemRes.value) itemsResults;
      in
      {
        success = status == "passing";
        value = materializedList;
        inherit status failures;
      }
    else
      # Primitive scalar value (null, bool, int, float, string, path)
      {
        success = true;
        value = evalAttempt.value;
        status = "passing";
        failures = [ ];
      };
}
