{
  lib,
  evaluation,
  customOptionToDoc ? null,
  frameworkDescriptors ? { },
  pkgs ? null,
}:
/**
  Module Descriptor and Option Projection Engine for Nix Schemas.

  Why generic module engine with thin native-framework descriptors:
  Nix evaluates arbitrary module code when supplied with an assembly recipe:
  which module system's `evalModules` and extended `lib` to use, which `class`
  and `specialArgs` are required, and which module list entrypoint to import.
  A generic engine avoids duplicating module evaluation across frameworks,
  while thin descriptors supply the framework-specific parameters that Nix
  cannot infer from arbitrary output values.

  Selected option-data projection (Nixpkgs PR #553364):
  `lib.options.optionToDoc` preserves the option tree hierarchy and nests
  submodule and attrTag children under the `"*"` wildcard key. Each option
  record carries standard documentation fields with `_type = "option"`.
  Flat projections (`optionAttrSetToDocList`) are deliberately unsupported
  to maintain one canonical hierarchical format.

  Failure behavior:
  A whole option evaluation failure leaves `__options = null` and attaches
  a failure diagnostic at `child = "__options"`. Individual field failures
  receive typed error objects and propagate causal status up the option tree.
*/
let
  inherit (evaluation)
    mkError
    addEvaluation
    ;

  rawOptionToDoc =
    if lib.isFunction customOptionToDoc then
      customOptionToDoc
    else if lib.isAttrs customOptionToDoc && customOptionToDoc ? optionToDoc then
      customOptionToDoc.optionToDoc
    else
      lib.options.optionToDoc
        or (throw "lib.options.optionToDoc is not available in nixpkgs and no customOptionToDoc was provided.");

  # Safely checks if a value is serializable to JSON with depth and derivation protection
  isSafeJsonValue =
    depth: v:
    if depth > 4 then
      false
    else
      let
        evalRes = lib.tryEval v;
      in
      if !evalRes.success then
        false
      else
        let
          val = evalRes.value;
          t = builtins.typeOf val;
        in
        if
          lib.elem t [
            "null"
            "bool"
            "int"
            "float"
            "string"
            "path"
          ]
        then
          true
        else if t == "list" then
          lib.all (isSafeJsonValue (depth + 1)) val
        else if t == "set" && !val ? _type && !lib.isDerivation val then
          lib.all (isSafeJsonValue (depth + 1)) (lib.attrValues val)
        else
          false;

  optLib =
    if lib.options ? foldOptionSet && lib.options ? typeToSchema then
      lib.options
    else if customOptionToDoc ? foldOptionSet then
      customOptionToDoc
    else
      null;

  safeTypeToSchema =
    depth: type: subDocs:
    if depth > 5 || !lib.isAttrs type then
      { }
    else
      let
        name = lib.toLower (type.name or "");
        nested = type.nestedTypes or { };
        elemSchema =
          if nested ? elemType then safeTypeToSchema (depth + 1) nested.elemType subDocs else { };
      in
      if lib.hasInfix "int" name then
        { type = "integer"; }
      else if lib.hasPrefix "bool" name then
        { type = "boolean"; }
      else if lib.hasInfix "float" name || lib.hasInfix "number" name then
        { type = "number"; }
      else if
        lib.hasInfix "str" name
        || lib.elem name [
          "lines"
          "path"
          "package"
        ]
      then
        { type = "string"; }
      else if name == "enum" then
        {
          type = "string";
          enum = type.functor.payload.values or [ ];
        }
      else if name == "nullor" then
        {
          anyOf = [
            { type = "null"; }
            elemSchema
          ];
        }
      else if name == "either" then
        {
          anyOf = [
            (safeTypeToSchema (depth + 1) (nested.left or { }) { })
            (safeTypeToSchema (depth + 1) (nested.right or { }) { })
          ];
        }
      else if name == "coercedto" then
        {
          anyOf = [
            (safeTypeToSchema (depth + 1) (nested.coercedType or { }) { })
            (safeTypeToSchema (depth + 1) (nested.finalType or { }) subDocs)
          ];
        }
      else if name == "listof" then
        {
          type = "array";
          items = elemSchema;
        }
      else if lib.hasInfix "attrsof" name then
        {
          type = "object";
          additionalProperties = elemSchema;
        }
      else if name == "attrs" then
        {
          type = "object";
          additionalProperties = true;
        }
      else if name == "submodule" then
        subDocs
        // {
          additionalProperties =
            if nested ? freeformType then
              safeTypeToSchema (depth + 1) (nested.freeformType.nestedTypes.elemType or nested.freeformType) { }
            else
              false;
        }
      else if nested ? elemType then
        elemSchema
      else
        { };

  buildSafeOptionToDoc =
    options:
    {
      "$schema" = "https://json-schema.org/draft/2020-12/schema";
      "$defs" = { };
    }
    // optLib.foldOptionSet {
      onOption =
        doc: subDocs: opt:
        let
          defaultAttempt =
            if opt ? defaultText then
              { success = false; }
            else if opt ? default then
              let
                tryVal = lib.tryEval opt.default;
              in
              if tryVal.success && isSafeJsonValue 0 tryVal.value then
                {
                  success = true;
                  inherit (tryVal) value;
                }
              else
                { success = false; }
            else
              { success = false; };
        in
        builtins.removeAttrs doc (
          [
            "type"
            "default"
          ]
          ++ lib.optional (doc.description == null) "description"
        )
        // safeTypeToSchema 0 opt.type subDocs
        // lib.optionalAttrs defaultAttempt.success { default = defaultAttempt.value; }
        // lib.optionalAttrs (doc ? default) { defaultText = doc.default; }
        // {
          nixType = doc.type;
        };
      onAttrSet =
        recurse: set:
        let
          clean = builtins.removeAttrs set [
            "_module"
            "_freeformOptions"
          ];
          req = lib.filter (
            n:
            let
              opt = clean.${n};
            in
            optLib.isOption opt && !(opt ? default || opt ? defaultText)
          ) (builtins.attrNames clean);
        in
        {
          type = "object";
          properties = lib.mapAttrs (_: recurse) clean;
        }
        // lib.optionalAttrs (req != [ ]) {
          required = req;
        };
    } options;

  # Sanitizes option tree before passing to optionToDoc to prevent infinite recursion
  # or missing attribute evaluation when defaults are expressions like config.foo or derivations.
  sanitizeOptionTree =
    tree:
    if !lib.isAttrs tree then
      tree
    else if tree ? _type && tree._type == "option" then
      if tree ? defaultText || (tree.type.name or "") == "package" then
        # When defaultText is provided or type is package, default is a derivation or complex expression.
        # Let defaultText document it without forcing evaluation.
        tree
        // {
          default = {
            _type = "deferred-default";
          };
        }
      else if tree ? default then
        if isSafeJsonValue 0 tree.default then
          tree
        else
          tree
          // {
            default = {
              _type = "non-serializable";
            };
          }
      else
        tree
    else
      lib.mapAttrs (_: sanitizeOptionTree) (builtins.removeAttrs tree [ "_module" ]);

  optionToDoc =
    rawOptions:
    if optLib != null then
      buildSafeOptionToDoc (sanitizeOptionTree rawOptions)
    else
      rawOptionToDoc (sanitizeOptionTree rawOptions);

  baseModules = [
    {
      _module.check = false;
    }
  ]
  ++ (lib.optional (pkgs != null) {
    _module.args.pkgs = pkgs;
  });

  # Default framework descriptors specifying module evaluation recipes
  defaultFrameworkDescriptors = {
    nixosModules = {
      name = "NixOS";
      eval =
        module:
        let
          evaled = lib.evalModules {
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };

    darwinModules = {
      name = "nix-darwin";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "darwin";
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };

    homeModules = {
      name = "Home Manager";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "home-manager";
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };

    homeManagerModules = {
      name = "Home Manager";
      eval = effectiveFrameworkDescriptors.homeModules.eval;
    };

    hjemModules = {
      name = "hjem";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "hjem";
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };

    nixOnDroidModules = {
      name = "nix-on-droid";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "nix-on-droid";
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };

    nixbsdModules = {
      name = "nixbsd";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "nixbsd";
            modules = baseModules ++ [ module ];
          };
        in
        evaled.options;
    };
  };

  effectiveFrameworkDescriptors = defaultFrameworkDescriptors // frameworkDescriptors;

  isModuleSchema = schemaKey: effectiveFrameworkDescriptors ? ${schemaKey};
in
{
  inherit optionToDoc;
  frameworkDescriptors = effectiveFrameworkDescriptors;

  /**
    Determines if a given path corresponds to an evaluable module node.
  */
  isModuleNode = schemaKey: currPath: isModuleSchema schemaKey && builtins.length currPath >= 2;

  /**
    Evaluates module options for a module definition and attaches `__options`.
  */
  attachOptions =
    {
      safe ? true,
      moduleValue,
      node,
      schemaKey ? "nixosModules",
    }:
    let
      descriptor =
        effectiveFrameworkDescriptors.${schemaKey} or effectiveFrameworkDescriptors.nixosModules;

      tryEvalModule =
        let
          evalRes = lib.tryEval (descriptor.eval moduleValue);
        in
        if !evalRes.success then
          {
            success = false;
            options = null;
            error = mkError {
              kind = "evaluation";
              message = "failed to evaluate ${descriptor.name} module options";
            };
          }
        else
          let
            rawOptions = evalRes.value;
            docRes = lib.tryEval (optionToDoc rawOptions);
          in
          if !docRes.success then
            {
              success = false;
              options = null;
              error = mkError {
                kind = "evaluation";
                message = "failed to project ${descriptor.name} module option documentation";
              };
            }
          else
            let
              materializedDoc = evaluation.safeValue docRes.value;
            in
            {
              success = true;
              options = materializedDoc.value;
              error = null;
            };
    in
    if !safe then
      let
        rawOptions = descriptor.eval moduleValue;
        optionsTree = optionToDoc rawOptions;
      in
      {
        value = node // {
          __options = optionsTree;
        };
        status = "passing";
        failures = [ ];
      }
    else
      let
        result = tryEvalModule;
      in
      if !result.success then
        {
          value = addEvaluation {
            status = "failing";
            failures = [
              {
                child = "__options";
                kind = "evaluation";
              }
            ];
            value = node // {
              __options = null;
            };
          };
          status = "failing";
          failures = [
            {
              child = "__options";
              kind = "evaluation";
            }
          ];
        }
      else
        {
          value = node // {
            __options = result.options;
          };
          status = "passing";
          failures = [ ];
        };
}
