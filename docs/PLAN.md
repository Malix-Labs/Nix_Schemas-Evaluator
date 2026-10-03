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
lib.flake = {
  inventory = { targetFlake = ...; };
  manifest = { targetFlake = ...; paths ? null; };
};
```

`targetFlake` accepts either a flake reference string or an already resolved flake attrset. A string is resolved once by the shared evaluator constructor; an attrset is used as supplied. `lib.flake.eval` is also exposed as the sharing-oriented constructor:

```nix
lib.flake.eval { targetFlake = ...; }
# returns
{
  inventory = ...;
  manifest = { paths ? null; }:
}
```

The convenience functions are projections over the same constructor implementation. A caller requesting both views in one Nix expression uses `lib.flake.eval`, so the target is resolved once and both views share one lazy graph. Separate calls to separate functions are separate Nix expressions and cannot share an evaluator heap; this is documented rather than hidden.

- `lib.flake.inventory` is lazy, Nix-native, and flake-schemas-shaped.
- `lib.flake.manifest` is a materialized output projection for external consumers.
- `manifest` never silently requires a second Nix evaluation for information within its output contract.
- `inventory` and `manifest` are not tailored to Rust, Elasticsearch, the web frontend, MCPs, or any other consumer.

If packaged outputs are added later, `pkgs.flake.inventory` and `pkgs.flake.manifest` must have the same semantic contracts and call the same library implementation. Packaging may add transport behavior but may not create a second evaluator.

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

### 5.3 `inventory` and `manifest`

**Alternative A — one eager output.** Rejected: it forces all values, breaks Nix-first laziness, and makes large module frameworks expensive for callers needing one path.

**Alternative B — only lazy inventory.** Rejected: external consumers would need additional Nix evaluation to materialize derivations, app values, options, and failures.

**Alternative C — two views with one shared evaluator graph (selected):** `inventory` remains lazy/schema-native; `manifest` is a single function with `paths ? null`. `null` requests the complete output tree; a string requests one logical path; a list requests one shared-prefix batch. Full, single, and batch modes use one selector/materializer implementation.

### 5.4 Failure representation and causal path propagation

**Alternative A — omit failed fields.** Rejected: omission hides whether a field was absent or attempted and failed.

**Alternative B — wrap every value as `{ value, evaluation }`.** Rejected: it changes ordinary value types and makes every consumer unwrap every field.

**Alternative C — detailed failure only at the leaf plus ancestor status-only summaries.** Rejected: an ancestor gives no direct route to its cause; a consumer must scan descendants to find it.

**Alternative D — duplicate the complete final path at every ancestor.** Rejected: it duplicates information already represented by the chain and makes each ancestor pretend to know the transitive leaf cause.

**Alternative E — one scalar child link at every non-passing materialized node (selected).** A failed leaf is represented by `null` and an atomic failure record. Every non-passing materialized parent receives a record whose `child` field names only its immediate failed child or field. `child` is one string attrset key or one integer list index; it is never a list. A consumer follows `child` links from node to node until it reaches the atomic failure. There is no separate `trace` field, and `path` remains reserved for full logical manifest-selection paths.

This mirrors the useful part of Nix’s own diagnostic frames. A direct probe with Nix 3.22.0 reports a nested throw as:

```text
while evaluating the attribute 'children.bad.value'
while calling the 'throw' builtin
error: leaf boom
```

The first frame identifies the expression path, and the later frame identifies the atomic operation. The manifest represents that relationship as local hops instead of copying the full final path into every record.

Conceptually:

```json
{
  "children": {
    "good": { "value": 1 },
    "bad": {
      "value": null,
      "__evaluation": {
        "status": "failing",
        "failures": [
          { "child": "value", "kind": "evaluation_failure" }
        ]
      }
    },
    "__evaluation": {
      "status": "partial",
      "failures": [
        {
          "child": "bad",
          "kind": "child_evaluation_failure"
        }
      ]
    }
  },
  "__evaluation": {
    "status": "partial",
    "failures": [
      {
        "child": "children",
        "kind": "child_evaluation_failure"
      }
    ]
  }
}
```

Here the root sidecar has `child = "children"`; the `children` container sidecar has `child = "bad"`; the `children.bad` sidecar has `child = "value"`; and the leaf record identifies the atomic failure. This is deliberate: `children` is a materialized attrset in the manifest and needs its own sidecar to make the causal chain locally navigable, even though its keys are schema children rather than an independent flake-schemas node. `__evaluation` is reserved metadata, not a child, and consumers must exclude it when iterating schema children. If the `children` map itself throws before any child exists, the owning node records a direct atomic failure at `child = "children"`, and there is no child-container sidecar to traverse.

The same rule applies to any materialized attrset: if it contains failed descendants, it may carry a node-local `__evaluation` sidecar; the sidecar is placed in the attrset being reported, not in a separate namespace. This gives every non-passing materialized boundary one scalar `child` link without pretending that the container’s derived propagation kind is the atomic cause. `path` remains available for a complete logical path in manifest selection or an atomic failure’s own field path; it is not overloaded for a one-hop relation.

This deliberately duplicates **one-hop child/status records**, not complete final paths or error payloads. The tradeoff is:

- good: a consumer inspecting any non-passing node has a direct path to the next diagnostic node and never scans unrelated descendants;
- good: each parent records only what it knows—that its immediate child failed—while the leaf remains the single authoritative atomic cause;
- cost: one small record per semantic level increases manifest size and parsing/storage/RAM/CPU linearly with failure depth;
- mitigation: keep paths relative, do not duplicate messages, and test deeply nested failures for linear growth;
- safety: propagation records are derived links, not independent causes, so consumers should display the leaf kind as the actual reason.

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

### 5.8 Derivation projection

**Alternative A — recursively pass through every derivation attribute.** Rejected: derivations contain implementation details, builders, arguments, passthru internals, functions, possible recursive structures, and large unstable data.

**Alternative B — silently filter whatever happens to be unsafe.** Rejected: it makes the manifest unpredictable and hides missing information.

**Alternative C — explicit stable package projection (selected):** project exactly:

```text
name, pname, version, system, outputs, outputName, meta
```

Recursively materialize `meta` with the shared safe evaluator and retain failed selected fields as `null` plus `__evaluation`. This is a deliberate package boundary because raw derivation internals are not a stable external contract. Adding fields later is an explicit contract change with tests. Preserve all other non-derivation schema attrsets by the generic materializer unless their schema explicitly defines another projection.

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

1. `manifest { paths = [ "custom.children.good" ]; }` returns `good`, does not force/return `bad`, and reports no failure from the unrequested sibling;
2. `manifest { paths = [ "custom.children.bad" ]; }` returns `bad.value = null` with one atomic `evaluation_failure` at the smallest owner;
3. `manifest { paths = [ "custom.children" ]; }` returns both children, gives the requested parent `status = "partial"`, and carries `child = "children"` to the materialized children attrset; that sidecar carries `child = "bad"` while the atomic reason remains only on `bad`; `__evaluation` is excluded when iterating child names;
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
├── flake.nix
├── flake.lock
├── checks/
│   ├── flake.nix
│   └── flake.lock
├── lib/
│   ├── default.nix                 # thin importable wrapper
│   └── lock.nix                    # small standard flake.lock helper
├── src/
│   ├── evalFlake.nix               # flake-family adapter exposed through lib.flake.*
│   ├── evaluation.nix              # shared schema evaluation helpers
│   ├── inventory.nix                # flake inventory adapter used by lib.flake.inventory
│   ├── manifest.nix                 # shared materialization/selection helpers used by lib.flake.manifest
│   └── options.nix                  # module descriptor and option projection helpers
├── test/
│   ├── _fixtures/
│   │   └── minimal-complete-flake/  # renamed copied basic-flake fixture
│   ├── _snapshots/
│   ├── agenix.nix
│   ├── basic-flake.nix
│   ├── deploy-rs.nix
│   ├── hydra.nix
│   ├── manifest-selection.nix
│   ├── serialization.nix
│   ├── nested-failure.nix
│   ├── inventory.nix
│   ├── manifest.nix
│   └── nix-unit/
└── docs/README.md
```

Do not move the copied source/test tree into a new `tests/namaka` hierarchy. Keep the existing `test/` convention and evolve it atomically. `src/evalFlake.nix` remains the public assembly entrypoint; sibling modules are extracted only along the selected boundaries. `lib/default.nix` is a thin importable wrapper and must not duplicate `src` logic.

Use these atomic commits, in order:

1. add importable `lib/default.nix` and expose the same `lib.flake` through the top-level flake;
2. add the small standard `lib.lock` helper for explicit `flake.lock` paths and tests for node/edge/follows identity;
3. pin the nixpkgs revision containing `lib.options.optionToDoc` in the checks partition and add a focused nested-option projection probe;
4. refactor `src/evalFlake.nix` into the single shared target-resolution/evaluator constructor;
5. extract `src/inventory.nix` and implement lazy flake-schemas inventory;
6. extract `src/evaluation.nix`, implement atomic failures plus one-hop causal child propagation, and add focused unit tests;
7. rename/expand `test/_fixtures/basic-flake` into `test/_fixtures/minimal-complete-flake` and update copied snapshots atomically;
8. add `test/nested-failure.nix` and compare concatenated child links with deliberate `nix eval --show-trace` failures;
9. add `test/serialization.nix` and the JSON conversion probes before relying on the serialization contract;
10. extract `src/manifest.nix` and implement the single parameterized manifest selector;
11. add `test/manifest-selection.nix` covering selected paths, omitted siblings, invalid paths, overlap, completeness, status, and causal child links;
12. extract `src/options.nix`, implement the generic module engine and framework descriptors, and use the pinned `lib.options.optionToDoc` projection;
13. add nested `__options` and the heavy module-framework fixtures;
14. implement and test the explicit derivation projection;
15. add the light package/check and verify the heavy partition lock/update workflow;
16. write durable `docs/README.md` rationale and ensure source comments preserve every selected “why”;
17. only after architecture acceptance, add optional host/package tooling or downstream consumers;

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
