{
  nixpkgs ? (import <nixpkgs> { }),
  flake-schemas ? (builtins.getFlake "github:DeterminateSystems/flake-schemas"),
  optionToDoc ? null,
}:
/**
  Nix Schemas Evaluator library entry point.

  Why this entry point exists:
  An importable `lib/default.nix` entry point exists alongside the top-level
  flake's `.lib` output so that non-flake expressions, legacy tooling, and
  external tools can import this evaluator directly (`import ./lib { ... }`)
  without requiring a flake evaluation context or full flake CLI invocation.
  Both entry points expose the exact same library contract.
*/
let
  evalFlakeModule = import ../src/evalFlake.nix {
    inherit nixpkgs flake-schemas optionToDoc;
  };
in
{
  /**
    Target-bound flake schema evaluator constructor.
    Resolves `targetFlake` once to ensure shared evaluation heap across all views.
  */
  flake = evalFlakeModule;
}
