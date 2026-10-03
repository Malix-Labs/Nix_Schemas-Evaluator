{ lib }:
/**
  Pure, Lazy, and Schema-Native Flake Inventory Adapter.

  Why inventory remains lazy and schema-native:
  The DeterminateSystems `flake-schemas` protocol standardizes how flake outputs
  are described (`children`, `what`, `shortDescription`, `derivationAttrPath`, `forSystems`,
  `evalChecks`) for discovery tools such as `nix flake show`.

  Inventory deliberately does NOT:
  - Materialize JSON payload values or package metadata.
  - Evaluate module options.
  - Inject foreign sidecars (such as `__evaluation`) into child attrsets, which breaks
    downstream schema consumers that iterate over child names.

  Laziness preservation (Approach A):
  Merely querying child attribute names (e.g. `builtins.attrNames inventory.packages.x86_64-linux.children`)
  must never force the underlying derivations or attribute values.

  Failure signaling:
  In `safe = true` mode, caught throws are intercepted at the node's standard `evalChecks`
  (e.g. `evalChecks.evaluates = false` or `evalChecks.isValidApp = false`) without foreign metadata.
  In `safe = false` mode, evaluation is strict and throws propagate immediately.
*/
resolvedFlake: allSchemas:
{
  safe ? true,
}:
let
  protectNode =
    node:
    let
      evalNode = lib.tryEval node;
    in
    if !evalNode.success then
      {
        what = "unknown";
        evalChecks.evaluates = false;
      }
    else if !lib.isAttrs evalNode.value then
      evalNode.value
    else
      let
        val = evalNode.value;

        protectedChildren =
          if val ? children then
            let
              evalChildren = lib.tryEval val.children;
            in
            if !evalChildren.success then
              { }
            else if lib.isAttrs evalChildren.value then
              lib.mapAttrs (_: protectNode) evalChildren.value
            else
              evalChildren.value
          else
            null;

        protectedChecks =
          if val ? evalChecks then
            let
              evalChecksObj = lib.tryEval val.evalChecks;
            in
            if !evalChecksObj.success then
              { evaluates = false; }
            else if lib.isAttrs evalChecksObj.value then
              lib.mapAttrs (
                _: checkVal:
                let
                  res = lib.tryEval checkVal;
                in
                if res.success then res.value else false
              ) evalChecksObj.value
            else
              evalChecksObj.value
          else
            null;
      in
      val
      // (lib.optionalAttrs (protectedChildren != null) { children = protectedChildren; })
      // (lib.optionalAttrs (protectedChecks != null) { evalChecks = protectedChecks; });

  evalSchema =
    schemaKey: schemaDef:
    if !(resolvedFlake ? ${schemaKey}) || !(schemaDef ? inventory) then
      { }
    else if !safe then
      schemaDef.inventory resolvedFlake.${schemaKey}
    else
      let
        rawOutputRes = lib.tryEval resolvedFlake.${schemaKey};
      in
      if !rawOutputRes.success then
        {
          what = "unknown";
          evalChecks.evaluates = false;
        }
      else
        let
          invRes = lib.tryEval (schemaDef.inventory rawOutputRes.value);
        in
        if !invRes.success then
          {
            what = "unknown";
            evalChecks.evaluates = false;
          }
        else
          protectNode invRes.value;
in
lib.mapAttrs evalSchema allSchemas
