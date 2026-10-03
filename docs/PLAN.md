# Nix Schemas Evaluator — final architecture and implementation plan

## 0. Purpose and starting baseline

This plan is for the standalone repository [Malix-Labs/Nix_Schemas-Evaluator](https://github.com/Malix-Labs/Nix_Schemas-Evaluator). It is the spiritual successor of [srid/devour-flake](https://github.com/srid/devour-flake/), especially [issue #8](https://github.com/srid/devour-flake/issues/8#issuecomment-5255485040), but is intentionally broader than flakes so future schema families can use the same evaluation principles.

The repository is new, but it is **not empty**. Its starting baseline already contains copied evaluator and test material:

- `/src/evalFlake.nix` was copied from `NixOS/nixos-search/flake-info/assets/commands/evalFlake.nix`;
- `/test/` was copied from `NixOS/nixos-search/flake-info/assets/commands/test/`, including Namaka expressions, `_fixtures/basic-flake`, `_snapshots`, and the `agenix`, `deploy-rs`, `hydra`, and `basic-flake` test expressions.

Implementation starts by auditing and refactoring these copied files. The copied structure is a migration baseline, not an architectural constraint. The final source layout and contracts below supersede the old evaluator design.

This is not a continuation of [NixOS/nixos-search PR #1486](https://github.com/NixOS/nixos-search/pull/1486). PR #1486 will be closed; a new nixos-search PR may later integrate this repository as a consumer. PR #1489 is already merged in nixos-search and is historical context only: it made the old evaluator somewhat failure-resilient, after which the old branch was rebased.

### Historical source material, not current repository layout

These paths explain what was copied and what must be deliberately replaced. They are not subdirectories of this repository, and no implementation should preserve their old architecture merely because it existed there:

- `NixOS/nixos-search/flake-info/assets/commands/evalFlake.nix` — schema traversal, inventory, manifest enrichment, and partial-failure prototype;
- `NixOS/nixos-search/flake.nix` — evaluator exposure and Namaka wiring;
- `NixOS/nixos-search/flake-info/assets/commands/test/` — copied test expressions, fixtures, and snapshots;
- `NixOS/nixos-search/flake-info/src/commands/nix_flake_attrs.rs` — Rust-specific consumer, explicitly not the core design;
- historical `NixOS/nixos-search/flake-info/assets/commands/flake_info.nix` — the previous monolithic evaluator, including option evaluation.

The new repository’s own paths, names, and public contract are defined below.

## 1. Locked public contract

The public library contract is:

```nix
lib.flake = { targetFlake }:
{
  # 1. Lazy schema descriptor tree (flake-schemas protocol compliant)
  inventory = {
    safe ? true;
  }: ...;

  # 2. Materialized JSON-serializable manifest (for search, indexers, IDEs)
  manifest = {
    paths ? null;     # null | listOf attrPath, where attrPath = [String]
    options ? true;    # boolean
    safe ? true;       # boolean
  }: ...;

  # 3. Raw derivation collector (for builders: nix-fast-build, nix-eval-jobs, Hydra, CI)
  derivations = {
    paths ? null;     # null | listOf attrPath, where attrPath = [String]
    safe ? true;       # boolean
  }: ...;
}
```

### 1.1 Constructor semantics

`lib.flake` is a target-bound constructor. `targetFlake` accepts either a flake reference string (e.g. `"github:NixOS/nixpkgs"`) or an already resolved flake attribute set. A string is resolved once by the constructor; an attribute set is used as supplied.

This target-bound design replaces earlier proposals for a separate `lib.flake.eval` helper:
- Resolving `targetFlake` once ensures that `inventory`, `manifest`, and `derivations` share the same resolved flake, input mappings, and lazy Nix heap within one expression without re-evaluation.
- Eliminates passing `targetFlake` redundantly to every sub-call.
- One-liner queries chain naturally: `(lib.flake { inherit targetFlake; }).manifest { ... }`.

### 1.2 Projection views

1. `inventory`: Pure, lazy, Nix-native descriptive tree adhering strictly to the DeterminateSystems `flake-schemas` protocol. It provides output discovery (`children`, `what`, `derivationAttrPath`, `forSystems`) suitable for `nix flake show`-style tools without forcing or materializing arbitrary payload values.
2. `manifest`: Materialized output projection for external data consumers (such as `nixos-search`, Elasticsearch indexers, web frontends, and IDEs). Materializes package metadata, app execution targets, and module option trees into JSON-serializable attribute sets with deterministic error annotations.
3. `derivations`: Nix-native derivation collector for builders (`nix-fast-build`, `nix-eval-jobs`, `nix build`, Hydra, and CI workflows replacing ad-hoc build actions). Unlike `manifest`, it preserves raw Nix derivation thunks (`type = "derivation"`, `drvPath`, `outPath`) so they remain directly buildable.

### 1.3 Parameters and defaults

- `safe` (boolean, default: `true` for all views):
  - In `safe = true` mode, caught evaluation throws, missing attributes, or broken schema items are intercepted without aborting the entire evaluation graph.
  - In `safe = false` mode, evaluation is strict: throws propagate immediately with no sidecars or sentinels, useful for CI assertions.
- `options` (boolean, default: `true` for `manifest`):
  - In `options = true` mode, evaluated module option documentation trees (`__options`) are attached to applicable module nodes (`nixosModules`, `darwinModules`, `homeManagerModules`).
  - Because Nix is lazy, `options = true` incurs zero overhead when selecting non-module paths.
  - `inventory` does not accept an `options` parameter because evaluated options are not part of the `flake-schemas` inventory specification.
- `paths` (`null | listOf attrPath`, default: `null`):
  - `null`: materializes the complete output tree.
  - `[]`: selects nothing.
  - Non-null values specify a list of attribute paths to materialize.
  - Each `attrPath` is typed strictly as a list of strings (`[String]`), following the standard Nix convention used by [`lib.attrsets.attrByPath`](https://github.com/NixOS/nixpkgs/blob/master/lib/attrsets.nix) and RFC 145:
    ```nix
    paths = [ [ "packages" "x86_64-linux" "hello" ] ];
    ```
  - Dotted strings (e.g. `"packages.x86_64-linux.hello"`) are strictly **not supported** in public path selectors, because Nix attribute names can contain literal dots.
  - Non-negative integer indices are strictly internal for error tracking inside lists; they are not accepted in public `paths`.

## 2. Input metadata: lock-file helper versus Nix CLI metadata

### 2.1 What `flake.lock` contains

A `flake.lock` file is a machine-readable JSON graph. It contains named nodes, the root node, input-edge mappings, original input declarations, locked source information, and follows relationships.

A coincidentally identical revision does **not** make two dependencies ambiguous. The lock graph distinguishes nodes by their node names and distinguishes how each parent refers to them through its `inputs` mapping. If two dependencies both use the same nixpkgs revision, they may be represented by one shared node when the lock graph resolves them to the same node, or by distinct node names/edges when they remain distinct. The evaluator must preserve the graph’s node identities and edge mappings; it must never infer identity merely from `rev`, `narHash`, or another value.

A `follows` relationship is therefore parsable from `flake.lock`: it is represented by an input edge pointing at another lock node, while a non-following dependency may have its own node even if its locked content happens to be equal. The lock file is authoritative for declared and locked dependency graph information.

### 2.2 Selected helper design

**Alternative A — no helper at all.** Rejected as a usability choice: consumers can parse JSON themselves, but this project is a utility library and a small standard lock-graph helper is useful.

**Alternative B — make lock parsing part of `lib.flake.inventory`/`manifest`.** Rejected: dependency provenance is not flake-schemas output inventory and is not manifest output enrichment.

**Alternative C — expose a small standalone lock helper (selected):** provide a pure helper such as:

```nix
lib.lock = {
  read = { lockFile }: ...;
  # or an equivalent explicit, dependency-free import helper
};
```

It parses a supplied `flake.lock` and preserves the standard JSON graph without evaluating the target flake or dependency outputs. This is a convenience for consumers, not part of `lib.flake`’s semantic output contract. The helper may use the appropriate existing nixpkgs library JSON/import utilities rather than reimplementing JSON parsing.

The helper accepts an explicit lock-file path or already-parsed lock value. It does not guess a lock file from an arbitrary evaluated attrset and does not silently call `nix flake metadata`.

### 2.3 What requires the Nix CLI

A pure lock helper cannot provide all information that `nix flake metadata --json` can provide after resolving a reference, such as canonical resolved reference/store location and process-level diagnostics. Those are different from lock-file graph data.

**Selected boundary:**

- `lib.lock.read` handles standard `flake.lock` graph data, including follows and node identity;
- the core Nix evaluator handles schema/inventory/manifest semantics;
- an optional host/package tool may invoke `nix flake metadata --json` for resolved metadata, exact stderr, and target references.

This avoids duplicate sources of truth and keeps the Nix library simple. A host tool may combine lock-helper output and CLI metadata in a clearly documented response, but it must not pretend the CLI result is part of the core manifest.

Tools such as [`flake-edit list`](https://github.com/a-kenji/flake-edit#-flake-edit-list) demonstrate the usefulness of host-side flake/lock inspection and editing. That validates providing a small lock helper and optional host tooling; it does not require putting process orchestration into the Nix evaluator or inventing an evaluated input view.

## 3. Maintainer-local context

This section is operational context for the current maintainer. The architecture must remain portable and must not require these absolute paths.

- New repository checkout: `/home/malix/Repositories/Malix-Labs/Nix_Schemas-Evaluator/`.
- Copied evaluator baseline: `/home/malix/Repositories/Malix-Labs/Nix_Schemas-Evaluator/src/evalFlake.nix`.
- Copied test baseline: `/home/malix/Repositories/Malix-Labs/Nix_Schemas-Evaluator/test/`.
- Existing consumer/source repository: `/home/malix/Repositories/NixOS/nixos-search/`.
- Local nixpkgs reference checkout: `/home/malix/Repositories/NixOS/nixpkgs/`.
- Historical evaluator source: `nixos-search/flake-info/assets/commands/evalFlake.nix`.
- Historical evaluator tests: `nixos-search/flake-info/assets/commands/test/`.
- Historical Rust consumer: `nixos-search/flake-info/src/commands/nix_flake_attrs.rs`.
- Historical monolithic evaluator: `nixos-search/flake-info/assets/commands/flake_info.nix` in the history of PR #1486.

A fresh clone must contain everything needed to implement and test the plan. The local paths are investigation references only.

## 4. Durable documentation and source-level “why” comments

The decisions in this plan must not remain only in the plan. They must be preserved in the codebase at the narrowest useful scope.

### 4.1 Documentation location

Keep only `docs/README.md` as the repository-level architecture/documentation entry point. This is deliberate: the repository is intentionally avoiding a root README, while existing repository-policy documents under `docs/` remain independent and are not deleted. Do not create additional per-directory READMEs unless a directory later develops durable rationale that cannot be expressed naturally near its bindings.

`docs/README.md` must explain:

- the relationship to `devour-flake` and the historical nixos-search extraction;
- why `inventory` and `manifest` are separate;
- why a small `lib.lock.read` helper is useful even though `flake.lock` is directly parseable;
- why `evalModules` alone is insufficient;
- why nixpkgs does not already provide this combined evaluator;
- the direct-Nix-CLI alternative, including `nix flake metadata --json`, and its tradeoffs;
- the roles and limitations of `nixd` and `nil`;
- the selected prior art for option documentation and why the other projects are not the canonical evaluator;
- the `__evaluation` causal path-chain and selected-manifest contracts;
- the lazy and performance model;
- why packaged commands are optional wrappers rather than another evaluator.

### 4.2 Source comments

Use RFC 145-style Nix doc-comments (`/** ... */`) on public bindings and helpers. Names and structures convey **what**; algorithms convey **how**; comments explain **why**. Add comments at the narrowest relevant scope:

- `src/evalFlake.nix` initially, and extracted `src/*.nix` helpers after the source split: why this is the flake-family adapter exposed as `lib.flake.*`, while shared traversal/materialization helpers remain reusable for future schema families;
- `src/inventory.nix`: why inventory remains lazy and schema-native;
- `src/manifest.nix`: why materialization is separate, how selected paths work, and why consumers do not need another evaluation;
- `src/evaluation.nix`: why failures are atomic and retained, how valid `null` differs from unavailable `null`, why causal path hops are propagated, and why failure kinds are coarse/deterministic;
- `src/options.nix`: why the selected Nixpkgs option-documentation projection and generic framework descriptor are used;
- `lib/default.nix`: why an importable library entry point exists in addition to the top-level flake’s `.lib` output;
- `lib/lock.nix` or its final equivalent: why node names and edge mappings—not coincidental revisions—define lock-graph identity.

Do not repeat the entire architecture in every file. A scoped directory `README.md` is allowed only when durable rationale cannot be expressed naturally near the relevant binding; do not create one by default.

## 5. Alternatives considered and final choices

This section is normative. The implementer must follow the selected choice in each subsection; no additional architectural choice is delegated to implementation.

### 5.1 Canonical evaluation layer

**Alternative A — Nix library (selected).** Keep schema traversal, lazy values, module evaluation, failure retention, and manifest shaping in Nix.

**Alternative B — host-language evaluator.** Implement traversal in Rust/Go/Python and invoke `nix eval` repeatedly.

**Alternative C — direct CLI orchestration as the semantic API.** Use `nix flake metadata --json`, `nix eval --json`, and `nix eval --json <target>#<attribute>` as the only core interface.

**Choice and tradeoff:** select A. Nix directly sees lazy values, flake-schemas functions, and framework-specific module semantics in one evaluation context. B duplicates Nix/schema semantics and either loses extensibility or starts many processes. C is useful for transport, exact stderr, scheduling, and resource controls, but JSON/stdin loses laziness/functions/module state and multiple commands repeat resolution/evaluation. A future host command may wrap A; it must not replace it.

### 5.2 Nix language tools: how they obtain reporting data

`nil` is selected as a parser/static-analysis development aid. Its core reporting path parses Nix source into syntax/semantic structures and produces diagnostics, completion, navigation, and related language-server responses without evaluating the complete target flake. It is useful for syntax and source-level feedback, but cannot provide resolved inputs, merged module options, dynamic imports, computed defaults, or evaluation failure status.

`nixd` is selected as an evaluation-aware development aid. It combines Nix language tooling with project-aware/evaluation-backed context for features such as expression inspection and completion. Its reporting may ask Nix to evaluate targeted expressions, but that editor request/response cycle is not a stable external manifest protocol and does not define this project’s failure or serialization contract.

Neither is a runtime dependency of `lib.flake`. The code remains explicit-argument, composable, and inspectable by both tools. Focused test expressions are available for editor inspection without forcing the heavy fixture matrix. A future editor integration must query this library or a shared packaged wrapper rather than duplicate semantics.

### 5.3 Architectural boundaries: `flake-schemas`, `inventory`, `manifest`, and `derivations`

To keep the architecture coherent, we must be precise about what upstream `flake-schemas` does and does not define:

#### 5.3.1 What `flake-schemas` is
The DeterminateSystems `flake-schemas` specification is a tool protocol designed primarily for `nix flake show` and `nix flake check`. It standardizes schema declarations (`version`, `doc`, `inventory`, `evalChecks`) so that the Nix CLI can discover and navigate output hierarchies without hard-coding knowledge of every flake convention. An `inventory` function in this protocol returns a descriptive tree of nodes:
- Each non-leaf node has a `children` attribute set.
- Each node carries descriptive metadata (`what`, `shortDescription`, `derivationAttrPath`, `forSystems`, `isLegacy`).

#### 5.3.2 What `flake-schemas` does NOT do
`flake-schemas` intentionally stops at description. It does not define:
- Materialized JSON output for external search engines or web frontends.
- Extraction of evaluated NixOS, Darwin, or Home Manager module options.
- A wire format or error envelope for partial-evaluation failures.
- A collection mechanism for unstripped buildable derivations in CI pipelines.

#### 5.3.3 Architectural boundary and open decision on `inventory` scope

The target-bound constructor exposes three views, with an open architectural decision regarding how strictly `inventory` couples to upstream `flake-schemas`:

1. **`inventory` (Open Decision Point: Strictness vs. Extension)**:
   - **Approach A (Strict drop-in compliance)**: Conforms strictly to DeterminateSystems `flake-schemas`. Returns only the descriptive `children` tree and standard metadata (`what`, `shortDescription`, `derivationAttrPath`, `forSystems`). Evaluator-specific metadata, values, and module options are excluded, ensuring drop-in compatibility with `nix flake show`-like tooling.
   - **Approach B (Enriched descriptive tree)**: Reuses `children` and standard schema fields, but allows evaluator-specific diagnostic metadata or richer descriptive extensions directly in `inventory`.
   - **Approach C (Dual exposure)**: Exposes both a strictly compliant upstream inventory and a separate diagnostic inventory view.

2. **`manifest` (Enriched data projection)**:
   A project-owned, JSON-serializable projection designed for external consumers (`nixos-search`, IDEs, indexers). It materializes package metadata, app execution details, and module options into a structured tree with deterministic partial-failure annotations.

3. **`derivations` (Raw builder collection)**:
   A Nix-native projection designed for CI builders (`nix-fast-build`, `nix-eval-jobs`, `nix build`, Hydra). It collects raw derivation objects (`type = "derivation"`, `drvPath`, `outPath`) directly from the schema nodes without stripping derivation internals or converting them to plain JSON records.

---

### 5.4 Open Decision Point: Failure representation and programming language semantics

In programming language theory, handling partial evaluation across a recursive tree exposes a fundamental semantic distinction between:
- **Absence** (`Option<T> = None | Some(T)`): A field is not defined or has an intentional `null` value.
- **Recoverable Failure** (`Result<T, E> = Ok(T) | Err(E)`): A field was requested or required, but evaluating it produced an exception (e.g. `throw`, `abort`, missing attribute, or type error).

The representation of failure in safe evaluation mode remains an **open architectural decision**. Below are the candidate models, their concrete wire shapes, and their trade-offs:

#### 5.4.1 Candidate failure representations compared

Consider evaluating a flake output with three items:
```nix
custom = {
  good = { value = 1; };
  nil  = { value = null; };         # legitimate Nix null
  bad  = { value = throw "boom"; }; # evaluation failure
};
```

1. **Candidate 1: `null` plus parent sidecar (`__evaluation`)**
   ```json
   {
     "good": { "value": 1 },
     "nil":  { "value": null },
     "bad":  {
       "value": null,
       "__evaluation": { "status": "failing", "failures": [{ "child": "value", "kind": "evaluation_failure" }] }
     }
   }
   ```
   - *Pros*: Preserves standard data types for successful values; no special sentinels at the value position.
   - *Cons*: Introduces semantic ambiguity: `bad.value` is indistinguishable from `nil.value`. A consumer seeing `null` is forced to inspect parent metadata sidecars on every access just to verify whether the field succeeded as `null` or failed.

2. **Candidate 2: Field omission / non-existence plus ancestor sidecar**
   ```json
   {
     "good": { "value": 1 },
     "nil":  { "value": null },
     "bad":  {
       "__evaluation": { "status": "failing", "failures": [{ "child": "value", "kind": "evaluation_failure" }] }
     }
   }
   ```
   - *Pros*: No reserved failure sentinel at the leaf; valid attributes remain completely untouched.
   - *Cons*: `bad ? value` returns `false`. This hides whether `value` was omitted by schema definition or attempted and failed, scoping failure awareness entirely to parent sidecars.

3. **Candidate 3: Per-value `Result` sum-type wrapper**
   ```json
   {
     "good": { "value": { "status": "ok", "value": 1 } },
     "nil":  { "value": { "status": "ok", "value": null } },
     "bad":  { "value": { "status": "error", "error": { "kind": "evaluation_failure" } } }
   }
   ```
   - *Pros*: Formally pure algebraic sum type (`Result<T, E>`), eliminating any ambiguity between presence, absence, and failure.
   - *Cons*: Completely alters ordinary value shapes; every consumer must unwrap every successful field.

4. **Candidate 4: Root/Sidecar error dictionary (GraphQL style `{ data, errors }`)**
   ```json
   {
     "data": { "good": { "value": 1 }, "nil": { "value": null }, "bad": { "value": null } },
     "errors": { "custom.bad.value": { "kind": "evaluation_failure" } }
   }
   ```
   - *Pros*: Leaves data tree free of failure sentinels.
   - *Cons*: Requires client-side path index lookups, string concatenation, and decouples errors from the data tree.

5. **Candidate 5: Sparse tagged sentinel at failed leaves**
   ```json
   {
     "good": { "value": 1 },
     "nil":  { "value": null },
     "bad":  {
       "value": {
         "__error": {
           "kind": "evaluation_failure"
         }
       },
       "__evaluation": {
         "status": "failing",
         "failures": [
           { "child": "value", "kind": "cascade" }
         ]
       }
     }
   }
   ```
   - *Pros*: Successful values and valid `null` retain their exact ordinary shape with zero wrapping overhead. Unavailable values are self-describing at the leaf (`val.__error`), while parent containers retain `__evaluation` for aggregate status and scalar causal links.
   - *Cons*: Reserves the `__error` namespace and replaces a scalar with an object only at failed leaves.

#### 5.4.2 Causal child propagation
Regardless of the leaf failure encoding chosen, non-passing parent containers in `safe = true` mode maintain causal navigation:
- Each non-passing parent container includes an `__evaluation` sidecar.
- The `failures` list contains one-hop records pointing to the immediate non-passing child (`child = "fieldName"`).
- Propagation records use `kind = "cascade"`, allowing a consumer inspecting an ancestor to navigate directly to the failed leaf without scanning unrelated branches.

Statuses are deterministic: all passing → `passing`; mixed → `partial`; all evaluated children failing → `failing`; empty successful node → `passing`; node throw → `failing`.

Nix itself does not expose a stable public machine-readable ID for these failures. Direct probes produced human diagnostics such as:

- `error: leaf boom` for `throw`;
- `error: attribute 'missing' missing` for a missing attribute;
- `error: cannot add a string to an integer` for a type error;
- `error: assertion 'false' failed` for an assertion;
- `error: cannot convert a function to JSON` for JSON serialization.

Nix has internal error classes and structured diagnostic/logging machinery, but those identifiers and rendered fields are not a stable cross-version manifest protocol. `--show-trace` changes diagnostic detail, not the existence of a portable child-failure kind. The project therefore owns normalized kinds and must not claim they are Nix IDs.

The atomic kinds are:

- `evaluation` — a value required by the projection could not be evaluated; this includes an arbitrary caught throw because `tryEval` exposes success/value, not the original exception kind;
- `non_serializable` — the evaluator knowingly encounters a value that the supported JSON boundary cannot represent;
- `typing` — a projection explicitly checks a value and finds the wrong type;
- `missing_attribute` — a projection explicitly requires an absent attribute;
- `checks` — a schema `evalChecks` value evaluates to false.

The propagation kind is:

- `cascade` — the current materialized node is non-passing because an immediate child is non-passing; follow its scalar `child` to that child’s `__evaluation` record.

`cascade` is preferred over `transitive` because the record points only to one immediate child, not every descendant; it is preferred over `cascading` because the noun names the derived relation consistently with the other kind identifiers.

These names are local normalized identifiers, not flake-schemas or Nix names. Exact stderr remains optional host diagnostics, not core manifest data.

### 5.5 Module-option evaluation: what Nix already does, and what it does not infer

The common assumption is: “when a NixOS configuration uses Home Manager, the Nix CLI can import the flake, import the module, select the entrypoint, and understand every option below it; therefore this project should only need to ask Nix for the result.” The first part is true, but it describes evaluation after the module system has been assembled, not automatic discovery of how to assemble every module system.

Nix’s C++ evaluator and CLI can evaluate arbitrary Nix code. If a caller supplies code such as `home-manager.nixosModules.home-manager`, imports it into a NixOS module list, passes the right `specialArgs`, and selects a configuration, Nix evaluates the resulting module graph and can expose its merged options. Nix does not need a C++ implementation of Home Manager’s option semantics because those semantics are Nix code loaded by the evaluator.

What Nix generally does not infer from an arbitrary flake output is the complete assembly recipe:

- which output is the module entrypoint rather than a module-like function with another purpose;
- which module system’s `evalModules` and extended `lib` should be used;
- which module list and framework-specific `class`/`specialArgs` are required;
- whether a framework expects its own `stdlib-extended.nix`, `pkgs`, or preprocessing;
- which configurations/entrypoints should be instantiated for documentation.

For the common Home Manager-on-NixOS case, the caller already supplies that recipe through the Home Manager module and NixOS configuration. The apparent “Nix understands the options” behavior is therefore ordinary evaluation of explicit framework code, not a universal module-schema discovery service. Flake-schemas can describe that a flake output is module-shaped, but the schema does not itself define a universal merge invocation for Home Manager, nix-darwin, nix-on-droid, nixbsd, hjem, or hjem-run.

This does not justify reimplementing Nix in Nix. It just means the evaluator needs a small framework descriptor at the boundary where a framework’s own Nix code is selected. The shared engine remains simple and generic; descriptors only provide the native module evaluator, extended library, module list, entrypoint, class, and special arguments. Nix performs the actual module evaluation.

**Alternative A — hard-code one complete evaluator per framework.** Rejected: duplicates traversal/materialization logic and scales poorly.

**Alternative B — pass every module to nixpkgs `lib.evalModules`.** Rejected: it would bypass framework extensions such as Home Manager’s `stdlib-extended.nix` and own evaluator.

**Alternative C — one generic engine with thin native-framework descriptors (selected):** a descriptor supplies the framework’s actual `evalModules`, matching `lib`, modules, `specialArgs`, class, entrypoint, and provenance. The shared engine invokes that evaluator, obtains `options`, and applies the selected option-documentation projection. Nix remains the semantic evaluator; the descriptor only supplies the recipe that Nix cannot infer from arbitrary output values.

**Alternative D — a host program invokes the Nix CLI on module values.** Rejected as the semantic core: a host program still needs the same framework recipe, while JSON/stdin cannot transport functions, laziness, string context, or module state. It is useful only as optional transport/diagnostics around the Nix library.

The heavy matrix proves this interface against NixOS, Home Manager, nix-darwin, hjem, hjem-run, nix-on-droid, and nixbsd. The project should first check whether each framework already exports a reusable native descriptor/entrypoint before writing any adapter-specific code.
### 5.6 Option-documentation prior art and selected reuse

The following choices are already made:

| Project | Role | Decision and reason |
|---|---|---|
| Nixpkgs `lib.options.optionToDoc` from [PR #553364](https://github.com/NixOS/nixpkgs/pull/553364), with its shared `lib.options.foldOptionSet` traversal | Projects evaluated module options into a nested documentation tree | **Use as the only supported option-data projection when available.** It preserves the option tree and represents submodule/attrTag children under `"*"`. Until merged, pin the PR revision in the checks partition rather than silently substituting the legacy flat projection. |
| `nixos-render-docs` | Renders existing option documentation | **Do not use for evaluation.** Downstream renderer. |
| `nmd` | Renders evaluated module documentation, especially Home Manager docs | **Do not use for evaluation.** Downstream documentation infrastructure. |
| `optnix` | Searches/inspects multiple frameworks in a consumer application | **Use only as multi-framework requirements evidence.** Do not copy its Go/TUI/search schema. |
| `nix-options-doc` / Thunderbottom option-doc tooling | Parses Nix source with `rnix` | **Do not use as canonical manifest data.** Parsing cannot know dynamic imports, merged semantics, or evaluated failures. |
| `nix-doc` | Source search/tags and function documentation | **Do not use for module evaluation.** Source/function documentation tool. |
| `mmdoc` | Source/documentation generation | **Do not use for evaluation.** Documentation consumer. |
| `nixdoc` issue #167 | Discusses adding evaluation to AST-oriented docs | **Use as evidence for the parsing/evaluation boundary**, not as a dependency. |

The canonical option container is node-local `__options`, a nested attrset produced by `lib.options.optionToDoc`. Ordinary option path components are nested as attrset keys; submodule and attrTag children use the upstream helper’s `"*"` key. Each option record contains the standard projected documentation fields, while the tree preserves the option hierarchy without inventing a second dotted-path grammar. This differs from `legacyPackages`, whose nesting is actual flake output structure and follows flake-schemas; it is also deliberately based on an upstream Nixpkgs library projection rather than a flake-schemas rule.

`lib.options.optionAttrSetToDocList` is intentionally **not supported** by this project’s option manifest. It remains useful context because it is the legacy flat upstream projection that `lib.options.optionToDoc` is intended to complement or eventually replace, but exposing both would make the canonical data structure ambiguous and encourage consumers to depend on the older flattened shape. Consumers needing dotted lookup can derive it from the nested manifest in their own layer.

The building blocks have separate responsibilities:

- `lib.modules.evalModules` (or the framework descriptor’s native equivalent) evaluates and merges the module graph, producing the raw `options` attrset. It is not itself a JSON/materialization or failure-reporting layer.
- `lib.options.optionToDoc` projects that evaluated option tree into the only supported nested documentation structure.
- `lib.options.foldOptionSet` is the traversal primitive used internally by the proposed upstream option helpers; reuse it when available rather than copying its traversal algorithm, but do not expose it as a second manifest format.
- `lib.tryEval` catches a forced expression and returns success/value, but cannot expose the original Nix exception as structured data. The shared evaluator must force and protect each option/documentation field at the smallest useful boundary, then attach `__evaluation` and scalar `child` links exactly as it does for flake output values.
- The shared safe materializer handles recursive attrsets/lists, valid `null`, non-serializable values, and field failures. It should be reused by option and flake projections rather than creating a second option-specific failure evaluator.

A whole option evaluation failure gives `__options = null` and a module-node diagnostic at `path = ["__options"]`. A field failure gets a sidecar on the option record and scalar `child` links on each non-passing option-tree attrset. Option tests must validate the nested `optionToDoc` structure directly, including `"*"` submodule children, without generating or snapshotting the unsupported flat list.

### 5.7 Parsing versus evaluation

**Canonical manifest:** evaluated Nix values only. This is selected because correctness requires dynamic imports, framework extensions, merged module semantics, computed defaults/types, lazy failure detection, and flake output values.

**Optional parsing:** allowed later for source-oriented docs, source locations, and unevaluable repositories. It must not override or merge guessed values/status into the canonical manifest, because doing so would make provenance and correctness ambiguous.

### 5.8 Derivation projection (`manifest`) versus derivation collection (`derivations`)

There are two fundamentally different consumer needs regarding flake derivations:

#### 5.8.1 `manifest` derivation projection (JSON consumers)
For search engines, indexers, and web frontends, raw derivations cannot be exported directly because they contain implementation details, builders, functions, cyclic references, and non-serializable strings with store context.

- **Explicit package projection (Selected for `manifest`)**: Project exactly:
  ```text
  name, pname, version, system, outputs, outputName, meta
  ```
- Recursively materialize `meta` with the shared safe evaluator.
- Unavailable or failing fields receive the explicit `__error` sentinel, accompanied by scalar `child` causal links in parent containers.
- This produces a stable, deterministic, JSON-serializable package record.

#### 5.8.2 `derivations` collection (Builders, `nix-fast-build`, `nix-eval-jobs`, and CI)
A JSON manifest cannot be passed to `nix build`, `nix-fast-build`, `nix-eval-jobs`, or Hydra because the Nix derivation machinery requires the raw derivation thunk (`type = "derivation"`, `drvPath`, and output paths).

This project is the spiritual successor to [`srid/devour-flake`](https://github.com/srid/devour-flake/). `devour-flake` existed specifically to solve the CI problem: "how do I collect every buildable derivation in a flake into a single evaluation graph for CI builds?" The previous plan missed this builder use-case by treating derivations exclusively as JSON data.

The `derivations` projection solves this directly at the Nix layer:
- **Schema-guided traversal**: Inspects schema inventory nodes that declare `derivationAttrPath` (or leaves satisfying `lib.isDerivation`).
- **Preserves derivation thunks**: Does not strip derivation internals or coerce attributes into JSON records. Retains raw `type = "derivation"` objects.
- **Evaluation vs. build separation**: Collecting derivations is strictly an evaluation-time operation. It dereferences the derivation graph without triggering builds, allowing external build schedulers (`nix-fast-build`, Hydra, or GitHub Actions runners) to manage compilation, concurrency, and caching.
- **Fault-tolerant collection (`safe = true`)**: In safe mode, derivations that throw during attribute evaluation (e.g. unfree assertions, broken platform constraints) are intercepted so one broken package does not prevent building the rest of the flake.
- **Filtering**: Allows filtering by system (`currentSystem` or declared `forSystems`), and optionally excluding `meta.broken` or unfree packages.

### 5.9 Standard transformations

Selected transformations are only:

- derive package fields through the explicit package projection above;
- preserve standard app `program` rather than renaming it to `bin`;
- materialize values into standard `nix eval --json`-representable data;
- replace unavailable thrown/function leaves with `null` and detailed diagnostics at the smallest owner;
- attach aggregate statuses and one-hop causal paths without duplicating descendant causes.

Do not strip store prefixes, rewrite source positions, sanitize paths, discard string context, or shape data for search/UI consumers. Every transformation must have a nearby source comment explaining this boundary and its reason.

### 5.10 JSON conversion is a tested boundary, not an assumption

The manifest does not promise that every Nix value is representable. It promises that every materialized manifest unit is representable by the project’s supported `nix eval --json` invocation.

Serialization tests explicitly probe:

- `null`, booleans, integers, supported floating-point values, strings, lists, and attrsets;
- Nix paths, verifying the exact JSON representation emitted by the supported Nix version;
- strings with context, verifying that the core evaluator does not manually strip or rewrite context;
- source-position-like attrsets and declaration paths;
- functions, builtins, and thrown values, verifying that they become `null` plus deterministic diagnostics before final JSON serialization;
- derivations, verifying that only the explicit package projection is materialized rather than a raw derivation object;
- nested combinations where one child is unsupported and siblings remain available.

The test evaluates the resulting manifest with `nix eval --json` and compares it with the expected representation produced by the same supported Nix serialization semantics. If a value cannot be represented, the evaluator classifies/replaces it before the final JSON boundary; it never relies on a consumer to catch a serialization abort. The supported Nix version and any version-sensitive representation are documented in `docs/README.md` and covered by focused fixtures.

## 6. Test, lock, and commit topology

### 6.1 Copied baseline and minimal complete fixture

Retain the copied `/test/` tree as the starting point. Its current `agenix.nix`, `basic-flake.nix`, `deploy-rs.nix`, `hydra.nix`, `_fixtures/basic-flake/`, and `_snapshots/` are the migration baseline.

Evolve the copied `test/_fixtures/basic-flake/` into the minimal complete fixture. Rename it to `test/_fixtures/minimal-complete-flake/` in one atomic fixture commit once its expanded role is established; do not create a second disconnected fixture. Check in its own `flake.lock`.

The fixture covers packages, apps, nested/non-nested `legacyPackages`, checks, devShells, formatter, templates, Hydra jobs, overlays, NixOS/Home Manager/Darwin modules/configurations, OCI images, bundlers, schemas/exported schemas, and a custom schema. It contains localized failures for every applicable failure kind, valid `null`, mixed/all-failing parents, metadata failures, list/attrset cases, and option failures. The historical Darwin-only throwing app is replaced with `meta.platforms`; deliberate throws remain in dedicated failure cases.

### 6.2 Selected-manifest semantics and tests

Use the same custom node in the minimal complete fixture for explicit selection tests:

```nix
custom = {
  children = {
    good = { value = 1; };
    bad = { value = throw "bad child"; };
  };
};
```

The tests prove:

1. `manifest { paths = [ [ "custom" "children" "good" ] ]; }` returns `good`, does not force/return `bad`, and reports no failure from the unrequested sibling;
2. `manifest { paths = [ [ "custom" "children" "bad" ] ]; }` returns `bad.value = { __error = { kind = "evaluation_failure"; }; }` with scalar causal links in parents;
3. `manifest { paths = [ [ "custom" "children" ] ]; }` returns both children, gives the requested parent `status = "partial"`, and carries `child = "children"` to the materialized children attrset; that sidecar carries `child = "bad"` while the atomic reason remains only on `bad`; `__evaluation` is excluded when iterating child names;
4. an omitted unrelated branch is not confused with a failed child;
5. an invalid requested path gets deterministic `missing_attribute` data rather than silently returning an empty attrset;
6. a list of overlapping paths evaluates shared prefixes once and produces the same records as the equivalent full request for those units;
7. the selected result documents completeness by path contract: the requested subtree is complete, while omitted siblings are not evaluated and are not failures.

Selected results remain sparse tree-shaped values. No additional `__selection` wrapper is added because it would change the ordinary manifest shape and duplicate request context already owned by the API call.

### 6.3 Failure propagation tests and rationale

Test that every atomic failure appears exactly once as a detailed failure record at the smallest node owning the unavailable value. Test that every non-passing materialized ancestor exposes a propagation record containing:

- one scalar `child` link to its immediate failed child or field;
- a deterministic `cascade` kind when the child, rather than the ancestor itself, failed;
- its own aggregate status.

The test must include a nested semantic-node case and verify the complete chain: root `child` → intermediate `child` → atomic leaf `child`. It must also verify that a `children` map that throws directly receives an atomic record on the owning node at `child = "children"`.

Do not copy the original leaf reason/message or a complete final path into every ancestor. This creates a causal chain analogous to Nix’s diagnostic frames: the leaf has the atomic cause; each parent records only that its immediate child could not be evaluated and points to that child.

The tradeoff is explicit:

- one-hop child/status records make ancestor-only inspection safe and avoid scanning unrelated descendants;
- they increase manifest size, disk/RAM/network use, and JSON parse/serialization work linearly with failure depth;
- avoiding a separate `trace` field and avoiding repeated full paths keeps the duplication minimal and preserves one authoritative atomic cause;
- tests measure the size of a deeply nested deliberate failure and ensure propagation remains linear in depth rather than multiplying records across unrelated branches.

A focused nested-failure test also runs the equivalent deliberate `nix eval --show-trace` expression. It does not compare unstable human-readable stderr byte-for-byte; it compares the concatenated manifest path hops with Nix’s reported structural attribute path and distinguishes the atomic leaf failure from parent propagation. Exact Nix diagnostics remain optional host data.

### 6.4 Heavy framework matrix and lock ownership

Use a `flake-parts` `checks` partition with a separate `checks/flake.nix` and `checks/flake.lock`. The separate lock owns updateable heavy framework inputs and their transitive graph; the top-level lock stays lightweight. Do not embed `*/rev` strings in the top-level flake. Run `nix flake update --flake path:checks` to update the matrix.

The heavy matrix includes nixpkgs/NixOS, Home Manager, nix-darwin, hjem, hjem-run, nix-on-droid, and nixbsd, each through its native module evaluator/extended library contract.

### 6.5 Light checks

Define one light test derivation and expose it as both `checks.<system>.evalSchema-light` and `packages.evalSchema-light`. Do not add a separate app. `nix flake check` covers both light and heavy checks.

## 7. Engineering principles and atomic commits

The scope is intentionally large, but the implementation is not one large commit. Every commit must:

- make one coherent architectural change;
- include only directly related code, documentation, and fixtures;
- include focused tests for the changed contract;
- pass formatting and relevant checks before the next commit;
- preserve or improve simplicity rather than introducing abstraction without payoff;
- use DRY shared helpers instead of copying algorithms between views/frameworks/packaged wrappers;
- use existing `nixpkgs.lib` and framework libraries instead of handwritten `builtins` replacements;
- avoid bypassing library code to “avoid the cost of Nix not being compiled”;
- preserve laziness and avoid duplicate target evaluation where sharing is possible;
- make performance costs visible and measure expensive paths;
- never mix unrelated consumer, infrastructure, fixture, and evaluator changes.

If a commit is a pure extraction and cannot add behavior, it must include a before/after probe or snapshot proving behavior is unchanged. These principles are part of the implementation contract, not merely workflow advice.

## 8. Source layout and implementation order

Before implementation, produce a short committed-or-reviewable baseline report covering the copied `src/evalFlake.nix` and `test/` behavior, current public shape, known failures, and the exact first contract probes. This is an implementation gate, not a commit.

The repository already has the copied `src/evalFlake.nix` and `test/` baseline. Depart from it in this order:

```text
Nix_Schemas-Evaluator/
├── flake.nix                       # top-level lightweight flake entrypoint
├── flake.lock
├── checks/
│   ├── flake.nix                   # heavy test-matrix partition (isolated dependencies)
│   └── flake.lock
├── lib/
│   ├── default.nix                 # thin importable library wrapper
│   └── lock.nix                    # small standard flake.lock helper
├── src/
│   ├── evalFlake.nix               # flake-family adapter exposed through lib.flake
│   ├── evaluation.nix              # shared schema evaluation helpers & error sentinels
│   ├── inventory.nix               # flake inventory adapter used by lib.flake.inventory
│   ├── manifest.nix                # shared materialization/selection helpers used by lib.flake.manifest
│   ├── derivations.nix             # raw derivation collector used by lib.flake.derivations
│   └── options.nix                 # module descriptor and option projection helpers
├── test/
│   ├── _fixtures/
│   │   └── minimal-complete-flake/ # renamed copied basic-flake fixture
│   ├── _snapshots/
│   ├── agenix.nix
│   ├── basic-flake.nix
│   ├── deploy-rs.nix
│   ├── hydra.nix
│   ├── manifest-selection.nix
│   ├── derivations.nix             # builder derivation collection tests
│   ├── serialization.nix
│   ├── nested-failure.nix
│   ├── inventory.nix
│   ├── manifest.nix
│   └── nix-unit/
└── docs/
    ├── README.md
    └── PLAN.md
```

### 8.1 The top-level `flake.nix` specification
The top-level `flake.nix` must remain strictly lightweight:
- **Inputs**: Only pinned `nixpkgs` (for `lib`) and `flake-schemas` (for base schema definitions). It must **not** import NixOS, Home Manager, or Darwin at the root.
- **Outputs**:
  - `lib.flake`: The target-bound constructor (`{ targetFlake }: { inventory, manifest, derivations }`).
  - `lib.lock`: The pure `flake.lock` reader helper.
  - `formatter.<system>`: Configured treefmt / nixfmt.
- Heavy framework dependencies (Home Manager, nix-darwin, nix-on-droid, etc.) are strictly quarantined in `checks/flake.nix` to prevent pulling hundreds of megabytes of inputs into consumer flakes.

### 8.2 Atomic implementation order

Implementation proceeds in three distinct phases: Core & Builders first, Module Options strictly second, Documentation & Wrappers last.

#### Phase A: Core evaluator, standard outputs, and derivation builder collection
1. Add top-level `flake.nix` and importable `lib/default.nix`, exposing `lib.flake` and basic formatter;
2. Add the small standard `lib.lock` helper for explicit `flake.lock` paths and tests for node/edge/follows identity;
3. Refactor `src/evalFlake.nix` into the single target-bound constructor (`lib.flake { targetFlake }`);
4. Extract `src/inventory.nix` and implement lazy, protocol-compliant `flake-schemas` inventory;
5. Extract `src/evaluation.nix`, implement atomic failures with explicit `__error` sentinels and one-hop scalar `child` causal propagation, and add focused unit tests;
6. Rename/expand `test/_fixtures/basic-flake` into `test/_fixtures/minimal-complete-flake` and update copied snapshots atomically;
7. Add `test/nested-failure.nix` and compare concatenated child links with deliberate `nix eval --show-trace` failures;
8. Add `test/serialization.nix` and JSON conversion probes before relying on the serialization contract;
9. Extract `src/manifest.nix` and implement the parameterized manifest selector for standard flake outputs (packages, apps, templates, checks);
10. Extract `src/derivations.nix` and implement the raw derivation collector (`flake.derivations { paths, safe }`) for `nix-fast-build` / CI builders;
11. Add `test/derivations.nix` and `test/manifest-selection.nix` covering selected paths, omitted siblings, invalid paths, and builder derivation thunks;

#### Phase B: Module-option evaluation (staged strictly AFTER Phase A)
12. Pin the nixpkgs revision containing `lib.options.optionToDoc` in `checks/flake.nix` and verify nested option projection;
13. Extract `src/options.nix`, implement the generic module engine and framework descriptors, and wire option evaluation into `manifest` (`options = true`);
14. Add nested `__options` tests and the heavy module-framework matrix in `checks/`;

#### Phase C: Validation, packaging, and durable documentation
15. Add the light package/check and verify the heavy partition lock/update workflow;
16. Write durable `docs/README.md` rationale and ensure source comments preserve every selected “why”;
17. Only after architecture acceptance, add optional host/package tooling or downstream consumers.

## 9. Validation and acceptance gates

Before any downstream consumer integration, validate:

- `nix fmt` and the repository’s configured formatter/linter;
- the copied baseline’s behavior is understood before refactoring;
- importable `lib/default.nix` and top-level `.lib` produce the same contract;
- `lib.lock` preserves node names, parent edge mappings, follows relationships, and distinguishes equal revisions under distinct graph identities;
- one-expression target resolution shares `inventory` and `manifest` evaluation;
- all deterministic atomic failure kinds and valid `null` cases;
- atomic failure details occur once, while the owning node points to `children`, the materialized child container points to its immediate failed child, and the failed leaf points to its failed field;
- `__evaluation` is excluded from child iteration and direct `children`-map failures are distinguished from descendant failures;
- nested and non-nested `legacyPackages`;
- selected-manifest behavior on the same custom fixture, including omitted siblings, invalid paths, completeness, overlap, parent status, and causal paths;
- exact `nix eval --json` serialization probes for supported scalar/container/path/context values;
- functions, builtins, throws, and raw derivations never cause final manifest serialization to abort;
- order-independent keyed option paths;
- all selected module frameworks and Home Manager’s extended evaluator;
- nested `lib.options.optionToDoc` output and `"*"` submodule keys, without exposing or snapshotting `lib.options.optionAttrSetToDocList`;
- explicit derivation projection and absence of consumer-specific sanitization;
- light package/check and the complete light+heavy `nix flake check` matrix;
- heavy lock ownership and update behavior;
- measured evaluation cost, propagation size, and no avoidable duplicate work;
- code remains inspectable by `nil` and usable with `nixd` without hidden runtime environment requirements.

Consumer integration is a hard gate. The author must review and accept every decision in section 5 before Rust, Elasticsearch, frontend, API, MCP, or documentation-consumer integration begins. Later consumers may discard fields, but must never invoke Nix to refill information promised by the manifest.

## 10. Explicit non-goals

- Do not rewrite the canonical evaluator in Rust, Go, Python, or a parsing-only tool.
- Do not make exact Nix stderr a required manifest field.
- Do not spawn `nix` recursively from Nix.
- Do not add `__evaluation` or `__options` to flake-schemas’ upstream `.schemas`/`.exportedSchemas` protocol.
- Do not create a core `lib.flake.inputs` API that duplicates `flake.lock`; use `lib.lock` only for explicit lock-file parsing convenience.
- Do not preserve the old `flake_info.nix` output for backwards compatibility.
- Do not redesign nixos-search’s Elasticsearch/frontend schema in this repository.
- Do not integrate or patch Nix #8892 yet; only explore it after the requested module-option work.
- Do not add framework-specific copies of the generic option engine.
- Do not bypass `nixpkgs.lib` or framework libraries with handwritten replacements.
- Do not add a root README in addition to `docs/README.md`.
