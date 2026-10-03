{
  nixpkgs ? (import <nixpkgs> { }),
  flake-schemas ? (builtins.getFlake "github:DeterminateSystems/flake-schemas"),
  # Optional direct call compatibility: if targetFlake is provided directly in first argument set
  targetFlake ? null,
}:
/**
  Flake-family schema adapter exposed as `lib.flake`.

  Why this is the flake-family adapter:
  This module adapts Nix Flake evaluation to the Nix Schemas architecture.
  While future schema families (e.g. non-flake modules, standalone repo schemas)
  will have their own adapters, the shared traversal, typed error sentinels,
  causal propagation, and derivation collectors remain common and reusable.

  Target-bound constructor design:
  Resolving `targetFlake` once in this constructor ensures that `inventory`,
  `manifest`, and `derivations` share the exact same resolved flake attribute set,
  input mappings, and lazy Nix heap within an expression without re-evaluation.
*/
let
  inherit (nixpkgs) lib;

  evaluation = import ./evaluation.nix { inherit lib; };
  optionsEngine = import ./options.nix { inherit lib evaluation; };
  inventoryAdapter = import ./inventory.nix { inherit lib; };
  manifestAdapter = import ./manifest.nix {
    inherit lib evaluation optionsEngine;
  };
  derivationsAdapter = import ./derivations.nix { inherit lib; };

  resolveFlake =
    tf:
    if lib.isAttrs tf then
      tf
    else if lib.isPath tf then
      let
        flakeExpr = import (tf + "/flake.nix");
        resolvedSelf = flakeExpr.outputs {
          self = resolvedSelf;
          inherit nixpkgs;
        };
      in
      resolvedSelf
    else if lib.isString tf then
      if lib.hasPrefix "path:" tf then
        let
          rawPath = lib.removePrefix "path:" tf;
          pathVal = /. + rawPath;
          flakeExpr = import (pathVal + "/flake.nix");
          resolvedSelf = flakeExpr.outputs {
            self = resolvedSelf;
            inherit nixpkgs;
          };
        in
        resolvedSelf
      else
        builtins.getFlake tf
    else
      throw "lib.flake: targetFlake must be a flake reference string, path, or already resolved attribute set";

  mkConstructor =
    { targetFlake }:
    let
      resolved = resolveFlake targetFlake;

      # Combine default schemas with any schemas declared/exported by the target flake
      allSchemas = flake-schemas.schemas // (resolved.schemas or resolved.exportedSchemas or { });
    in
    {
      /**
        Pure, lazy, DeterminateSystems flake-schemas protocol compliant descriptive tree.
      */
      inventory = inventoryAdapter resolved allSchemas;

      /**
        Materialized JSON-serializable manifest for search engines, IDEs, and frontends.
      */
      manifest = manifestAdapter resolved allSchemas;

      /**
        Raw Nix derivation collector preserving buildable thunks for builders and CI.
      */
      derivations = derivationsAdapter resolved allSchemas;
    };
in
if targetFlake != null then mkConstructor { inherit targetFlake; } else mkConstructor
