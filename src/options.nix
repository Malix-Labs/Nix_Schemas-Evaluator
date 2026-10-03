{
  lib,
  evaluation,
  customOptionToDoc ? null,
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

  # Documentation item projection helper conforming to nixpkgs PR #553364
  optionToDocItem =
    opt:
    let
      name = lib.showOption (opt.loc or [ ]);
      visible = opt.visible or true;
    in
    {
      description = opt.description or null;
      declarations = lib.filter (x: x != (lib.modules.unknownModule or "unknown")) (
        opt.declarations or [ ]
      );
      internal = opt.internal or false;
      visible = if lib.isBool visible then visible else visible == "shallow";
      readOnly = opt.readOnly or false;
      type = opt.type.description or "unspecified";
    }
    // lib.optionalAttrs (opt ? example) {
      example = lib.addErrorContext "while evaluating the example of option `${name}`" (
        lib.options.renderOptionValue opt.example
      );
    }
    // lib.optionalAttrs (opt ? defaultText || opt ? default) {
      default =
        lib.addErrorContext
          "while evaluating the ${
            if opt ? defaultText then "defaultText" else "default value"
          } of option `${name}`"
          (
            if opt ? defaultText then
              lib.options.renderOptionValue opt.defaultText
            else
              lib.options.renderOptionValue opt.default
          );
    };

  # Traversal helper conforming to nixpkgs PR #553364 foldOptionSet
  foldOptionSet =
    {
      onOption,
      onAttrSet,
      empty ? { },
      ...
    }:
    let
      recurse =
        tree:
        if lib.isOption tree then
          let
            v = tree.visible or true;
            subVisible = if lib.isBool v then v else v == "transparent";
            ss = tree.type.getSubOptions tree.loc;
            subDocs = if subVisible && ss != { } then recurse ss else empty;
          in
          onOption (optionToDocItem tree) subDocs tree
        else if lib.isAttrs tree then
          onAttrSet recurse tree
        else
          empty;
    in
    recurse;

  # Nested option projection conforming to lib.options.optionToDoc
  defaultOptionToDoc =
    options:
    let
      docTree = foldOptionSet {
        onOption =
          doc: subDocs: _opt:
          {
            _type = "option";
          }
          // doc
          // lib.optionalAttrs (subDocs != { }) {
            "*" = subDocs;
          };
        onAttrSet = recurse: set: lib.mapAttrs (_: recurse) set;
        empty = { };
      } options;
    in
    docTree;

  optionToDoc =
    if customOptionToDoc != null then
      customOptionToDoc
    else if lib.options ? optionToDoc then
      # If nixpkgs already has optionToDoc
      opt:
      let
        res = lib.options.optionToDoc opt;
      in
      res.options or res
    else
      defaultOptionToDoc;

  # Framework descriptors specifying module evaluation recipes
  frameworkDescriptors = {
    nixosModules = {
      name = "NixOS";
      eval =
        module:
        let
          evaled = lib.evalModules {
            modules = [ module ];
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
            modules = [ module ];
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
            modules = [ module ];
          };
        in
        evaled.options;
    };

    homeManagerModules = {
      name = "Home Manager";
      eval = frameworkDescriptors.homeModules.eval;
    };
  };

  isModuleSchema = schemaKey: frameworkDescriptors ? ${schemaKey};
in
{
  inherit optionToDoc frameworkDescriptors;

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
      descriptor = frameworkDescriptors.${schemaKey} or frameworkDescriptors.nixosModules;

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
            {
              success = true;
              options = docRes.value;
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
