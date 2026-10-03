{ lib }:
/**
  Raw Derivation Collector for Builders (CI, nix-fast-build, nix-eval-jobs, Hydra).

  Why raw derivation collection is distinct from manifest:
  External build schedulers (`nix-fast-build`, `nix-eval-jobs`, `nix build`, Hydra)
  require raw Nix derivation thunks (`type = "derivation"`, `drvPath`, `outPath`).
  Manifest serializes package metadata into plain JSON records, which strips derivation
  internals and cannot be built. `derivations` preserves the raw derivations.

  Output shape (Nested Attribute Set):
  Returns a nested attribute set preserving the flake's natural output hierarchy:
    `derivations.packages.x86_64-linux.hello = <derivation>;`
  This matches `nix-eval-jobs` and `nix-fast-build` tree traversal natively,
  keeps job paths identical to flake output paths, and allows consumers to navigate
  subtrees without string-splitting flattened keys.

  Fault tolerance in safe mode:
  When `safe = true`, packages that throw during evaluation (e.g. unfree assertions,
  broken platform constraints, broken package derivations) are safely omitted so that
  one broken derivation does not crash evaluation for the entire build set.
  When `safe = false`, evaluation is strict and throws propagate immediately.
*/
resolvedFlake: allSchemas:
{
  paths ? null,
  safe ? true,
}:
let
  buildPathTrie =
    pathList:
    let
      insert =
        trie: path:
        if path == [ ] then
          trie // { __match = true; }
        else
          let
            head = lib.head path;
            tail = lib.tail path;
            subTrie = trie.${head} or { };
          in
          trie
          // {
            ${head} = insert subTrie tail;
          };
    in
    lib.foldl' insert { } pathList;

  pathTrie = if paths != null then buildPathTrie paths else null;

  isPathRequested =
    currPath:
    if pathTrie == null then
      "all"
    else
      let
        lookup =
          trie: p:
          if trie ? __match then
            "all"
          else if p == [ ] then
            if trie == { } then "none" else "partial"
          else
            let
              head = lib.head p;
              tail = lib.tail p;
            in
            if trie ? ${head} then lookup trie.${head} tail else "none";
      in
      lookup pathTrie currPath;

  isDerivation =
    val:
    let
      evalIsDrv = lib.tryEval (lib.isDerivation val);
    in
    evalIsDrv.success && evalIsDrv.value;

  checkDrvSafe =
    drv:
    if !safe then
      drv
    else
      let
        # In safe mode, verify drvPath evaluates without throwing
        drvPathRes = lib.tryEval drv.drvPath;
      in
      if drvPathRes.success then drv else null;

  collectTree =
    currPath: node:
    let
      req = isPathRequested currPath;
    in
    if req == "none" then
      null
    else
      let
        nodeEval = lib.tryEval node;
      in
      if !nodeEval.success then
        if !safe then throw "Evaluation failed at path ${lib.concatStringsSep "." currPath}" else null
      else
        let
          val = nodeEval.value;
        in
        if isDerivation val then
          checkDrvSafe val
        else if lib.isAttrs val then
          let
            namesAttempt = lib.tryEval (lib.attrNames val);
            names = if namesAttempt.success then namesAttempt.value else [ ];

            namesToVisit =
              if req == "all" then names else lib.filter (n: isPathRequested (currPath ++ [ n ]) != "none") names;

            collected = map (
              name:
              let
                childPath = currPath ++ [ name ];
                childRes = collectTree childPath val.${name};
              in
              {
                inherit name;
                value = childRes;
              }
            ) namesToVisit;

            validChildren = lib.filter (c: c.value != null) collected;
          in
          if validChildren == [ ] then null else lib.listToAttrs validChildren
        else
          null;

  schemasToVisit =
    if paths == null then
      lib.attrNames allSchemas
    else
      lib.filter (k: isPathRequested [ k ] != "none") (lib.attrNames allSchemas);

  results = map (
    schemaKey:
    if resolvedFlake ? ${schemaKey} then
      let
        collected = collectTree [ schemaKey ] resolvedFlake.${schemaKey};
      in
      if collected != null then
        {
          name = schemaKey;
          value = collected;
        }
      else
        null
    else
      null
  ) schemasToVisit;

  filtered = lib.filter (r: r != null) results;
in
lib.listToAttrs filtered
