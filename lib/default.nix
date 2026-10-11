{
  nixpkgs ? (import <nixpkgs> { }),
  flake-schemas ? (builtins.getFlake "github:DeterminateSystems/flake-schemas"),
  optionToDoc ? null,
  frameworkDescriptors ? { },
  pkgs ? null,
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
    inherit
      nixpkgs
      flake-schemas
      optionToDoc
      frameworkDescriptors
      pkgs
      ;
  };
in
{
  /**
    Target-bound flake schema evaluator constructor.
    Resolves `targetFlake` once to ensure shared evaluation heap across all views.
  */
  flake = evalFlakeModule;

  /**
    Direct flake-outputs selector conforming to `nix-eval-jobs --select` and `nix-fast-build`.
    Can be used as:
      `lib.select { system = "x86_64-linux"; } flakeOutputs`
    or directly passed without options:
      `lib.select { } flakeOutputs`
  */
  select = opts: flakeOutputs: (evalFlakeModule { targetFlake = flakeOutputs; }).select opts;
}
