{
  lib,
  evaluation,
  optionsEngine ? null,
}:
/**
  Materialized JSON-Serializable Manifest Evaluator for Nix Schemas.

  Why materialization is separate from inventory:
  Inventory provides pure, lazy output discovery conforming to `flake-schemas`
  for tools like `nix flake show`. External data consumers (such as search engines,
  IDEs, and web frontends) require evaluated package metadata, app execution targets,
  and module options materialized as JSON-serializable structures with deterministic
  error annotations. Materialization is performed in this separate view so that
  inventory remains completely lazy and free of foreign metadata.

  Selected paths and sparse tree contract:
  When `paths` is non-null (a list of attribute paths `[ [ "packages" "x86_64-linux" "hello" ] ]`),
  only the requested paths are materialized. Omitted siblings are neither evaluated
  nor reported as failures. Shared path prefixes are evaluated only once. Invalid
  requested paths deterministically receive a `missing_attribute` error sentinel.

  Transformations boundary:
  - Packages are explicitly projected to: name, pname, version, system, outputs, outputName, meta.
  - Apps preserve standard `program` (never renamed to `bin`).
  - Unavailable or throwing leaves are replaced by typed error objects (`_type = "error"`).
  - Ancestor containers attach deterministic `status` and one-hop scalar `child` causal links.
*/
resolvedFlake: allSchemas:
{
  paths ? null,
  options ? true,
  safe ? true,
}:
let
  inherit (evaluation)
    mkError
    statusFromStatuses
    addEvaluation
    safeValue
    ;

  exportedDerivationKeys = [
    "name"
    "pname"
    "version"
    "outputs"
    "outputName"
    "system"
    "meta"
  ];

  /**
    Path trie helper for fast and accurate path-selection queries.
    Determines whether a given path prefix is:
    - "all": exactly requested or an ancestor of an exact request -> include all descendants
    - "partial": a strict prefix of some requested path -> only include matching children
    - "none": not requested -> omit completely
  */
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

  # Evaluates explicit package derivation fields
  evalDrvPackage =
    _currPath: drv:
    if !safe then
      # Strict evaluation: throw directly if accessing fields throws
      let
        metaVal = drv.meta or { };
      in
      {
        inherit (drv) name;
        pname = drv.pname or null;
        version = drv.version or null;
        system = drv.system or null;
        outputs = drv.outputs or [ "out" ];
        outputName = drv.outputName or "out";
        meta = metaVal;
      }
    else
      let
        namesResult = lib.tryEval (if lib.isAttrs drv then lib.attrNames drv else [ ]);
      in
      if !namesResult.success then
        {
          value = mkError {
            kind = "evaluation";
            message = "failed to evaluate package derivation";
          };
          status = "failing";
          failures = [ ];
        }
      else
        let
          evalField =
            key:
            if key == "meta" then
              if drv ? meta then
                safeValue drv.meta
              else
                {
                  success = true;
                  value = { };
                  status = "passing";
                  failures = [ ];
                }
            else
              let
                fieldVal = drv.${key} or null;
                res = lib.tryEval fieldVal;
              in
              if !res.success then
                {
                  success = false;
                  value = mkError {
                    kind = "evaluation";
                    message = "failed to evaluate field '${key}'";
                  };
                  status = "failing";
                  failures = [ ];
                }
              else
                {
                  success = true;
                  inherit (res) value;
                  status = "passing";
                  failures = [ ];
                };

          evaluatedFields = map (
            key:
            if drv ? ${key} then
              {
                inherit key;
                result = evalField key;
              }
            else
              {
                inherit key;
                result = {
                  success = true;
                  value = null;
                  status = "passing";
                  failures = [ ];
                };
              }
          ) exportedDerivationKeys;

          fieldStatuses = map (f: f.result.status) evaluatedFields;
          status = statusFromStatuses fieldStatuses;

          failures = lib.concatLists (
            map (
              f:
              if f.result.status != "passing" then
                [
                  {
                    child = f.key;
                    kind = "cascade";
                  }
                ]
              else
                [ ]
            ) evaluatedFields
          );

          materializedRecord = lib.listToAttrs (
            map (f: {
              name = f.key;
              value = f.result.value;
            }) evaluatedFields
          );
        in
        {
          value = addEvaluation {
            inherit status failures;
            value = materializedRecord;
          };
          inherit status failures;
        };

  # Evaluates app output
  evalApp =
    _currPath: app:
    if !safe then
      {
        type = "app";
        inherit (app) program;
      }
      // lib.optionalAttrs (app ? meta) { inherit (app) meta; }
    else
      let
        appRes = lib.tryEval app;
      in
      if !appRes.success || !lib.isAttrs appRes.value then
        {
          value = mkError {
            kind = "evaluation";
            message = "failed to evaluate app definition";
          };
          status = "failing";
          failures = [ ];
        }
      else
        let
          appVal = appRes.value;

          programRes = lib.tryEval (appVal.program or null);
          programEval =
            if !programRes.success then
              {
                value = mkError {
                  kind = "evaluation";
                  message = "failed to evaluate app program";
                };
                status = "failing";
              }
            else if programRes.value == null then
              {
                value = mkError {
                  kind = "missing_attribute";
                  message = "app missing required attribute 'program'";
                };
                status = "failing";
              }
            else if !lib.isString programRes.value && !lib.isPath programRes.value then
              {
                value = mkError {
                  kind = "typing";
                  message = "app program must be a string or path";
                };
                status = "failing";
              }
            else
              {
                inherit (programRes) value;
                status = "passing";
              };

          metaRes = if appVal ? meta then safeValue appVal.meta else null;

          failures =
            (lib.optional (programEval.status != "passing") {
              child = "program";
              kind = "cascade";
            })
            ++ (lib.optional (metaRes != null && metaRes.status != "passing") {
              child = "meta";
              kind = "cascade";
            });

          status =
            if metaRes != null then
              statusFromStatuses [
                programEval.status
                metaRes.status
              ]
            else
              programEval.status;

          base = {
            type = "app";
            program = programEval.value;
          }
          // lib.optionalAttrs (appVal ? meta) { meta = metaRes.value; };
        in
        {
          value = addEvaluation {
            inherit status failures;
            value = base;
          };
          inherit status failures;
        };

  # Enrich an individual item (derivation, app, template, etc.)
  enrichItem =
    currPath: schemaKey: _system: _itemName: rawVal: itemInventoryNode:
    let
      isDrv = (lib.tryEval (lib.isDerivation rawVal)).value or false;
      baseNode = itemInventoryNode;

      projected =
        if schemaKey == "apps" then
          evalApp currPath rawVal
        else if
          isDrv || schemaKey == "packages" || schemaKey == "checks" || (baseNode.what or null) == "package"
        then
          evalDrvPackage currPath rawVal
        else
          # Generic safe materialization
          safeValue rawVal;
    in
    if !safe then
      if lib.isAttrs projected then baseNode // projected else baseNode // projected.value
    else
      let
        projVal = projected.value;
        projStatus = projected.status;
        projFailures = projected.failures;

        # Merge base inventory metadata with projected payload
        mergedValue =
          (builtins.removeAttrs baseNode [ "__evaluation" ])
          // (if lib.isAttrs projVal then projVal else { value = projVal; });

        status = projStatus;
        failures = projFailures;
      in
      {
        value = addEvaluation {
          inherit status failures;
          value = mergedValue;
        };
        inherit status failures;
      };

  # Recursively materializes a subtree according to path requests and schema conventions
  materializeSubtree =
    currPath: rawNode: invNode: schemaKey:
    let
      req = isPathRequested currPath;
    in
    if req == "none" then
      null
    else
      let
        # Check if rawNode evaluates
        rawEval = lib.tryEval rawNode;
      in
      if !rawEval.success then
        if !safe then
          throw "Evaluation failed at path ${lib.concatStringsSep "." currPath}"
        else
          {
            value = mkError {
              kind = "evaluation";
              message = "evaluation failed at path ${lib.concatStringsSep "." currPath}";
            };
            status = "failing";
            failures = [ ];
          }
      else
        let
          rawVal = rawEval.value;
          isDrv = (lib.tryEval (lib.isDerivation rawVal)).value or false;
        in
        if
          isDrv
          || (lib.isAttrs invNode && (invNode.what or null) == "app" || (invNode.what or null) == "package")
        then
          let
            system = if builtins.length currPath > 1 then lib.elemAt currPath 1 else "";
          in
          enrichItem currPath schemaKey system (lib.last currPath) rawVal (
            if lib.isAttrs invNode then invNode else { }
          )
        else if optionsEngine != null && optionsEngine.isModuleNode schemaKey currPath then
          let
            baseNode = if lib.isAttrs invNode then invNode else { what = "${schemaKey} module"; };
            attached =
              if options then
                optionsEngine.attachOptions {
                  inherit safe schemaKey;
                  moduleValue = rawVal;
                  node = baseNode;
                }
              else
                {
                  value = baseNode;
                  status = "passing";
                  failures = [ ];
                };
          in
          attached
        else if lib.isAttrs rawVal then
          let
            # Determine available child keys from rawVal and any path requests
            rawNamesAttempt = lib.tryEval (lib.attrNames rawVal);
            rawNames = if rawNamesAttempt.success then rawNamesAttempt.value else [ ];

            # Check if any path specifically requested a child that doesn't exist
            requestedMissingChildren =
              if pathTrie != null then
                let
                  # Find expected child keys at currPath from pathTrie
                  lookupTrie = t: p: if p == [ ] then t else lookupTrie (t.${lib.head p} or { }) (lib.tail p);
                  subTrie = lookupTrie pathTrie currPath;
                  childKeys = lib.filter (k: k != "__match") (lib.attrNames subTrie);
                in
                lib.filter (k: !lib.elem k rawNames) childKeys
              else
                [ ];

            childNamesToVisit =
              if req == "all" then
                rawNames
              else
                # For partial requests, visit only requested children
                lib.filter (name: isPathRequested (currPath ++ [ name ]) != "none") rawNames;

            visitedChildren = map (
              name:
              let
                childPath = currPath ++ [ name ];
                childRaw = rawVal.${name};
                childInv =
                  if lib.isAttrs invNode && invNode ? children && lib.isAttrs invNode.children then
                    invNode.children.${name} or { }
                  else
                    { };
                res = materializeSubtree childPath childRaw childInv schemaKey;
              in
              {
                inherit name res;
              }
            ) childNamesToVisit;

            # Missing children that were explicitly requested
            missingChildren = map (name: {
              inherit name;
              res = {
                value = mkError {
                  kind = "missing_attribute";
                  message = "attribute '${name}' missing at path ${lib.concatStringsSep "." currPath}";
                };
                status = "failing";
                failures = [ ];
              };
            }) requestedMissingChildren;

            allChildResults = visitedChildren ++ missingChildren;
            filteredChildResults = lib.filter (c: c.res != null) allChildResults;

            childStatuses = map (c: c.res.status) filteredChildResults;
            status = statusFromStatuses childStatuses;

            failures = lib.concatLists (
              map (
                c:
                if c.res.status != "passing" then
                  [
                    {
                      child = c.name;
                      kind = "cascade";
                    }
                  ]
                else
                  [ ]
              ) filteredChildResults
            );

            childAttrset = lib.listToAttrs (
              map (c: {
                inherit (c) name;
                value = c.res.value;
              }) filteredChildResults
            );

            # If options requested and this node is a module entrypoint, attach __options
            withOptions =
              if options && optionsEngine != null && optionsEngine.isModuleNode schemaKey currPath then
                optionsEngine.attachOptions {
                  inherit safe schemaKey;
                  moduleValue = rawVal;
                  node = childAttrset;
                }
              else
                childAttrset;
          in
          {
            value = addEvaluation {
              inherit status failures;
              value = withOptions;
            };
            inherit status failures;
          }
        else
          # Fallback for scalar/list nodes
          safeValue rawVal;

  # Top-level manifest evaluation across all schemas
  evalTopLevelSchema =
    schemaKey: schemaDef:
    let
      req = isPathRequested [ schemaKey ];
    in
    if req == "none" then
      null
    else if !(resolvedFlake ? ${schemaKey}) then
      # If whole schema output was explicitly requested but missing from flake
      if req == "all" || req == "partial" then
        if paths != null then
          {
            value = mkError {
              kind = "missing_attribute";
              message = "flake output '${schemaKey}' not found";
            };
            status = "failing";
            failures = [ ];
          }
        else
          null
      else
        null
    else
      let
        rawOutput = resolvedFlake.${schemaKey};
        invNode =
          if schemaDef ? inventory then (lib.tryEval (schemaDef.inventory rawOutput)).value or { } else { };
      in
      materializeSubtree [ schemaKey ] rawOutput invNode schemaKey;

  allSchemaResults = lib.mapAttrs (
    schemaKey: schemaDef: evalTopLevelSchema schemaKey schemaDef
  ) allSchemas;

  filteredResults = lib.filterAttrs (_: v: v != null) allSchemaResults;
in
lib.mapAttrs (_: res: res.value) filteredResults
