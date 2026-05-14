# SwiftPDAL — agent notes

## Documentation invariants

This package ships DocC-generated reference docs. Keep them buildable:

- Every **public** or **open** symbol gets a `///` doc comment summarizing
  intent. One sentence is fine for properties; methods get a brief
  paragraph + `- Parameters:` / `- Returns:` / `- Throws:` blocks.
- Parameter names follow the **internal** label. `func foo(forKey key: String)`
  documents `- key:`, not `- forKey:` — DocC warns on the external name.
- Cross-references use signature-sensitive double-backticks:
  `` ``ChunkID/init(depth:x:y:z:)`` ``, not `\``ChunkID.init``\`. Wrong
  signatures silently fail to render as links.
- New top-level public types belong in a `## Topics` group of
  `Sources/SwiftPDAL/SwiftPDAL.docc/SwiftPDAL.md`. Adding a type without
  filing it leaves it unreachable from the landing page.

## Verifying

```sh
scripts/build_docs.sh
```

Expect exit 0 with no unresolved-link warnings on user-authored prose.
(Symbol-graph warnings from pdalcpp's C++ namespace are pre-existing and
out of scope.) For live preview:

```sh
scripts/build_docs.sh preview
```

## Build dependencies

- `Frameworks/pdalcpp.xcframework`, `Frameworks/gdal.xcframework`,
  `Frameworks/copclib.xcframework` are committed binaries. Rebuild
  `copclib.xcframework` via `scripts/build-copc-xcframework.sh`.
- `Frameworks/copc-build/` is an alternate dev-only cmake prefix; not
  shipped, not committed. See `Frameworks/copc-build/README.md`.

## Streaming module

The COPC out-of-core streaming source (`Sources/SwiftPDAL/Streaming/`)
is the newest addition. Design rationale lives in `docs/streaming.md`.
The protocol layer (`StreamingPointCloudSource`) is deliberately
renderer-agnostic; the consuming app (Satin-ComputeRasteriser glue)
adapts `StreamingRasterBatch` into the renderer's identically-laid-out
`RasterBatch`.
