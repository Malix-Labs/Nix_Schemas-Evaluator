# Nix Schemas Evaluator

Nix Schemas Evaluator is a pure, lazy, and failure-tolerant evaluation and projection library for Nix Flakes and Nix Schemas (such as the DeterminateSystems [`flake-schemas`](https://github.com/DeterminateSystems/flake-schemas) protocol).

---

## 1. Architecture Overview & Public Contract

The public library entrypoint is target-bound, resolving the flake once per constructor invocation to ensure that all views share the same resolved flake attribute set, input mappings, and lazy Nix heap within one expression without re-evaluation:

```nix
lib.flake = { targetFlake }:
{
  # 1. Pure lazy schema descriptor tree (flake-schemas protocol compliant)
  inventory = {
    safe ? true;
  }: ...;

  # 2. Materialized JSON-serializable manifest (for search, indexers, IDEs)
  manifest = {
    paths ? null;      # null | listOf attrPath, where attrPath = [String]
    options ? true;     # boolean
    safe ? true;        # boolean
  }: ...;

  # 3. Raw derivation collector (for builders: nix-fast-build, nix-eval-jobs, Hydra, CI)
  derivations = {
    paths ? null;      # null | listOf attrPath, where attrPath = [String]
    safe ? true;        # boolean
  }: ...;
};
```

---

## 2. Core Design Rationale & Background

### 2.1 Relationship to `devour-flake` and the NixOS-Search Extraction

This project is the spiritual successor to [`srid/devour-flake`](https://github.com/srid/devour-flake/), particularly addressing [issue #8](https://github.com/srid/devour-flake/issues/8#issuecomment-5255485040). `devour-flake` was created to solve a pressing CI and build orchestration challenge: collecting all buildable derivations across arbitrary flake outputs into a single build graph.

Simultaneously, the search engine behind [search.nixos.org](https://search.nixos.org) required extracting flake metadata, package descriptions, licenses, and module options from untrusted or partially broken flakes without aborting evaluation on the first caught throw. This led to an evaluator prototype in `NixOS/nixos-search` (PRs #1486 and #1489).

Nix Schemas Evaluator extracts these concerns into a clean, standalone library. It unifies:

1. Pure flake output discovery (`inventory`);
2. Safe, JSON-serializable data extraction for search engines and IDEs (`manifest`);
3. Direct Nix-native raw derivation collection for CI schedulers (`derivations`).

### 2.2 Why `inventory`, `manifest`, and `derivations` are Separate Views

A single monolithic output representation cannot satisfy divergent consumer requirements:

- **`inventory` (Strict Upstream Drop-in Compliance — Approach A)**: Downstream tools like `nix flake show` or Flakestry map over child keys to discover flake outputs. Injecting evaluator-specific sidecars (like `__evaluation`) inside `children` breaks these tools by treating metadata as package names. Furthermore, computing parent status aggregates in `inventory` would force evaluation of all leaves, destroying laziness. Therefore, `inventory` strictly adheres to `flake-schemas` metadata (`what`, `shortDescription`, `derivationAttrPath`, `forSystems`, `evalChecks`).
- **`manifest` (Enriched Data Projection)**: Search indexers (Elasticsearch), language servers, and web frontends require fully materialized JSON records containing package names, versions, system platforms, output names, and structured `meta`. Raw derivations cannot be exported directly to JSON because they contain functions, builders, and strings with store contexts. `manifest` explicitly projects these fields and attaches deterministic failure sentinels (`_type = "error"`).
- **`derivations` (Raw Builder Collection)**: Build schedulers (`nix-fast-build`, `nix-eval-jobs`, `nix build`, Hydra) cannot consume JSON records; they need the live, unstripped Nix derivation thunk (`type = "derivation"`, `drvPath`, and output paths). `derivations` collects these raw objects while preserving the flake's output hierarchy.

### 2.3 Input Metadata and the Role of `nix flake metadata`

Input metadata and dependency resolution are handled authoritatively by the Nix CLI via `nix flake metadata --json`. The evaluator deliberately does not duplicate lock-file parsing or invent an evaluated inputs view:

- **Flake Outputs Focus**: The evaluator's core responsibility is output schema discovery, materialization, and derivation collection.
- **Native Resolution**: In Nix, resolved inputs are already natively available on `targetFlake.inputs` when needed; external consumers needing root commit hashes, store locations, or lock graph inspection use `nix flake metadata --json`.

### 2.4 Why `evalModules` Alone is Insufficient

`lib.modules.evalModules` evaluates and merges module graphs when given a complete assembly recipe:

- which entrypoint to load;
- which module system's `evalModules` and extended library to use (e.g. Home Manager's `stdlib-extended.nix`);
- which `class` and `specialArgs` are required.

Nix itself does not infer these recipes from an arbitrary flake output. Flake-schemas describes that an output is shaped like a module, but does not define how to merge it. Nix Schemas Evaluator bridges this gap using thin native-framework descriptors (`src/options.nix`) for NixOS, Home Manager, and nix-darwin while using Nix to perform the actual module evaluation.

### 2.5 Why Nixpkgs Does Not Already Provide This Evaluator

Nixpkgs provides foundational primitives (`lib.modules.evalModules`, `lib.tryEval`, `lib.attrsets`), but deliberately avoids prescribing external metadata wire formats, search index schemas, or flake traversal policies. Flake output conventions are defined upstream by DeterminateSystems `flake-schemas` and RFCs, not the Nixpkgs library. This repository unifies those primitives into a reusable library.

### 2.6 The Direct-Nix-CLI Alternative and Its Tradeoffs

One alternative is direct CLI orchestration (`nix eval --json <target>#<attr>`).

- **Tradeoffs**: Invoking the CLI for each output incurs substantial process spawning overhead, repeatedly re-evaluates the flake, and loses Nix lazy values, functions, and string context at the JSON boundary.
- **Role of the CLI**: Host tools may invoke `nix flake metadata --json` for canonical resolved URLs and process stderr, but core schema traversal and evaluation remain native to Nix.

### 2.7 Roles and Limitations of `nil` and `nixd`

- **`nil`**: A syntax and AST-oriented language server. It parses Nix source into syntax trees to provide formatting, completions, and diagnostics without evaluating the flake. It cannot discover resolved inputs, computed option types, or dynamic module evaluations.
- **`nixd`**: An evaluation-backed language server. It evaluates specific expressions on demand to power documentation lookups and code completions. However, its request-response cycle is an interactive editor protocol, not a batch manifest extraction standard.
- Neither tool is a runtime dependency of this project. The evaluator remains pure, inspectable, and compatible with both tools.

### 2.8 Prior Art for Option Documentation

| Project | Role & Tradeoff |
| --- | --- |
| Nixpkgs `lib.options.optionToDoc` (PR #553364) | **Selected & Supported**. Projects evaluated module options into a nested documentation tree, nesting submodule options under `"*"`. |
| `optionAttrSetToDocList` | **Rejected**. Legacy flat projection (`[ { name = "boot.loader.grub.enable"; ... } ]`). Exposing both would create ambiguity. |
| `nixos-render-docs` | Downstream renderer for manual generation; not an option evaluator. |
| `nmd` | Documentation renderer for Home Manager; not an evaluation engine. |
| `optnix` | Multi-framework TUI search tool; consumer application. |

### 2.9 The `_type = "error"` Sentinel and Causal Path Chain

In safe mode (`safe = true`), evaluation failures must be captured without aborting evaluation.

#### Leaf Failure Representation (Alternative 5B)

A failed value is replaced by a typed error object:

```json
{
  "_type": "error",
  "kind": "evaluation",
  "message": "failed to evaluate field"
}
```

Atomic failure kinds:

- `evaluation`: Caught evaluation throw or abort.
- `non_serializable`: Value cannot be represented in JSON (e.g. functions).
- `typing`: Value does not match expected schema type.
- `missing_attribute`: Explicitly requested attribute does not exist.
- `checks`: Schema `evalChecks` evaluated to false.

#### Causal Ancestor Propagation

Parent containers attach an `__evaluation` sidecar:

```json
"__evaluation": {
  "status": "partial",
  "failures": [
    { "child": "bad", "kind": "cascade" }
  ]
}
```

Ancestors point only to their immediate failed child (`child = "bad"`) with `kind = "cascade"`. This forms a navigable one-hop causal chain (`root -> intermediate -> leaf`) without duplicating nested error messages or creating quadratic path arrays. Passing nodes carry no `__evaluation` sidecar.

### 2.10 Selected-Manifest Path Selection Contract

When `paths` is specified (e.g. `paths = [ [ "packages" "x86_64-linux" "hello" ] ]`):

1. Only requested subtrees are evaluated.
2. Omitted siblings are neither evaluated nor reported as failures.
3. Invalid requested paths receive deterministic `missing_attribute` error objects.
4. Overlapping paths share prefix evaluation without re-evaluation.
5. Path selectors strictly use string lists (`[String]`); dotted strings are unsupported because Nix attribute names may contain literal dots.

### 2.11 The Lazy and Performance Model

Nix is lazy. The evaluator is designed to preserve laziness:

- `lib.flake { targetFlake }` resolves the flake once and creates closures sharing the same heap.
- `inventory` only evaluates child names when keys are requested (`builtins.attrNames`).
- `options = true` in `manifest` only evaluates options when module outputs are actually traversed.
- Raw derivation collection dereferences derivation thunks without triggering builds.

---

## 3. Usage Guide

### 3.1 Using as a Flake Input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    evaluator.url = "github:Malix-Labs/Nix_Schemas-Evaluator";
  };

  outputs = { self, nixpkgs, evaluator }:
    let
      targetFlake = "github:NixOS/nixpkgs";
      ev = evaluator.lib.flake { inherit targetFlake; };
    in
    {
      # Discover output names lazily
      schemaTree = ev.inventory { safe = true; };

      # Materialize hello package metadata
      pkgManifest = ev.manifest {
        paths = [ [ "packages" "x86_64-linux" "hello" ] ];
      };

      # Collect all buildable derivations for CI
      ciJobs = ev.derivations { safe = true; };
    };
}
```

### 3.2 Running Checks

```bash
# Light checks (unit tests, schema evaluation, serialization probes)
nix flake check

# Format check
nix fmt -- --check

# Heavy matrix checks (isolated multi-framework checks: NixOS, Home Manager, Darwin)
nix flake check ./checks
```
