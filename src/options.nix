{
  lib,
  evaluation,
  customOptionToDoc ? null,
  frameworkDescriptors ? { },
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

  optionToDoc =
    if customOptionToDoc != null then
      customOptionToDoc
    else
      lib.options.optionToDoc
        or (throw "lib.options.optionToDoc is not available in nixpkgs and no customOptionToDoc was provided.");

  # Default framework descriptors specifying module evaluation recipes
  defaultFrameworkDescriptors = {
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

    hjemModules = {
      name = "hjem";
      eval =
        module:
        let
          evaled = lib.evalModules {
            class = "hjem";
            modules = [ module ];
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
            modules = [ module ];
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
            modules = [ module ];
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
