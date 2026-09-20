# Code-level call graphs

The C4 model in `architecture/workspace.dsl` stops at the Component level,
which is intentional — [the C4 model treats "Code" as a fourth,
tool-generated level](https://c4model.com/diagrams/code) that shouldn't be
hand-drawn: *"most IDEs can generate this level of detail on demand."*
These graphs are that fourth level for this codebase — real, function-level
call graphs generated straight from GHC's own name-resolution data.

## Regenerating

```
stack build --ghc-options -fwrite-ide-info
calligraphy -i .stack-work/dist/*/ghc-*/build MODULE... --collapse-data --output-dot values.dot
python3 architecture/callgraphs/annotate_purity.py values.dot purity.dot
dot -Tsvg purity.dot -o architecture/callgraphs/purity-overlay.svg
```

Two gotchas:

- If the installed `calligraphy` panics with an HIE version mismatch, its GHC
  version doesn't match the project's. On this machine use
  `nix shell nixpkgs#haskell.packages.ghc984.calligraphy --command calligraphy ...`.
- `--show-module-path` labels clusters with file paths, but it *also* switches
  the `MODULE` arguments to match against paths, so the two cannot be mixed
  without listing every file. `annotate_purity.py` therefore keys its table on
  module **names**, which is what calligraphy labels clusters with by default.
- In `zsh`, an unquoted `$MODS` holding a space-separated module list is passed
  as a *single* argument and matches nothing. Use `${=MODS}` or list the modules
  literally.

## Current graphs

| Graph | What it shows | Source |
|---|---|---|
| [layers.svg](layers.svg) | Module dependencies grouped by DDD layer, with dependency-rule violations in red | [layers.dot](layers.dot), hand-written from the `import` lists |
| [purity-overlay.svg](purity-overlay.svg) | Every value binding, coloured pure / effectful / "pure logic with an effectful type" | calligraphy + [annotate_purity.py](annotate_purity.py) |
| [purity-overlay-with-types.svg](purity-overlay-with-types.svg) | The same overlay, keeping data types and constructors. Much wider; useful for tracing a specific constructor | same |

Both purity graphs are read alongside
[`architecture/reviews/ddd-structure-and-layering.md`](../reviews/ddd-structure-and-layering.md),
which is where the findings they support are written up.

The purity classification is **not** inferred — `annotate_purity.py` carries an
explicit `(module, binding) -> bucket` table, so it has to be updated by hand
when bindings are added or their types change. That is deliberate: the
interesting bucket, "pure logic wearing an effectful type", is precisely the one
a type-directed classifier cannot find, because the type is the thing that's
wrong.

Two of calligraphy's blind spots matter here and are worth knowing about:

- A module containing only instance declarations produces **zero nodes**, so it
  is invisible in every graph *and* to `check_drift.py`. The codebase no longer
  has any such module — every `ToResp` instance now sits with its type — but
  `layers.dot` still draws the instance edges by hand, because an instance is
  a dependency calligraphy cannot see.
- Logic inside an anonymous lambda has no node either. This used to hide the
  key-expiry rule inside `newRedisTable`, and then the `record` value inside
  the store adapter's `set` closure. Neither survives: the rule is `liveValue`
  in `Redis.Data.Record`, and the workflows build the record now. As of the
  store refactor there is no hidden logic left, which is why the "disguised"
  bucket is empty.

## Stale graphs (pre-DDD-refactor)

`tcp-listener.svg`, `command-handler.svg`, `resp-protocol.svg` and
`in-memory-key-value-store.svg` were generated per C4 component before the
`refactor to DDD` change. Every module they name has since been deleted or
moved, and `architecture/workspace.dsl` has not been remapped yet
(`python3 architecture/check_drift.py` currently reports three MISSING edges).

They are kept until `workspace.dsl` is updated to the new module layout, at
which point one graph per component should be regenerated the same way as
before — one graph per C4 component, covering exactly the modules in that
component's `modules` property.

The proposed **Expiry Reaper** (ADR 0002) has no graph — it doesn't exist in
the code. Generating one once it's implemented is free evidence that the
ADR's target shape was actually built.
