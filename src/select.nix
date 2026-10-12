{ lib }:
/**
  Flat Derivation Selector Adapter for Builders (nix-fast-build, nix-eval-jobs).

  Why this adapter exists:
  Schedulers like \`nix-eval-jobs --select\` and \`nix-fast-build\` require a selector function
  conforming to the signature:
    \`flakeOutputs -> { "path.to.derivation" = <derivation>; ... }\`
  This adapter wraps \`derivations\`, flattens the nested derivation hierarchy into dot-separated
  attribute keys, and filters derivations by system when requested (e.g. currentSystem).
*/
derivationsAdapter: resolvedFlake: allSchemas:
{
  # Target system filter (e.g. "x86_64-linux"). When null, all systems are preserved.
  # Defaults to builtins.currentSystem when evaluated impurely, or null.
  system ? (builtins.currentSystem or null),
  # Paths filter forwarded to derivationsAdapter
  paths ? null,
  # Safe mode forwarded to derivationsAdapter
  safe ? true,
}:
let
  drvsTree = derivationsAdapter resolvedFlake allSchemas {
    inherit paths safe system;
  };

  matchesSystem =
    drv:
    if system == null then
      true
    else
      let
        drvSystem = drv.system or drv.stdenv.hostPlatform.system or null;
      in
      if drvSystem == null then true else drvSystem == system;

  flattenDerivations =
    prefix: node:
    lib.concatMap (
      name:
      let
        val = node.${name};
        path = if prefix == "" then name else "${prefix}.${name}";
      in
      if lib.isDerivation val then
        if matchesSystem val then [ (lib.nameValuePair path val) ] else [ ]
      else if lib.isAttrs val then
        flattenDerivations path val
      else
        [ ]
    ) (lib.attrNames node);
in
lib.listToAttrs (flattenDerivations "" drvsTree)
