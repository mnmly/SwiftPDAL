# Task: stream COPC point clouds directly over HTTP (range requests)

## Goal

Add the ability to open a COPC (`*.copc.laz`) point cloud for **streaming**
directly from an `http(s)://` URL, instead of requiring a local file. The reader
should pull only the octree nodes the renderer asks for (LOD + frustum), via HTTP
**range requests** — no full download first.

This is a SwiftPDAL change (primarily the `CxxCOPC` C++ bridge). Consumers
(`WABFPointCloud` / sketches) will call a new remote entry point; those are out
of scope for this repo but described at the end so the API shape is right.

## Why this approach (and not GDAL `/vsicurl/`)

The COPC **streaming** path bypasses PDAL/GDAL entirely and talks to copc-lib
directly:

- `Sources/CxxCOPC/copc_bridge.cpp:201-220` — `Reader::open(path, pool_size)`
  builds a pool of `::copc::FileReader(path)` instances.
- GDAL's `/vsicurl/` is only reachable through PDAL's `readers.copc` pipeline
  (the non-streaming packed path) and is compiled **macOS-only**
  (`gdal-xcframework-builder/build.sh:380` sets `-DGDAL_USE_CURL=OFF` for iOS).

copc-lib natively reads from a `std::istream*`, so we feed it an HTTP-range-backed
stream and keep the existing streaming engine intact, on **macOS and iOS**:

```cpp
// copclib.xcframework/.../io/base_reader.hpp:21
BaseReader(std::istream *in_stream) : in_stream_(in_stream) { InitReader(); }
// copclib.xcframework/.../io/copc_reader.hpp:26
Reader(std::istream *in_stream) : BaseReader(in_stream) { InitCopcReader(); }
```

`FindNode`, `GetPointDataCompressed`, `CopcConfig().LasHeader()` are all on the
base classes, so an istream-backed `Reader` has the full surface the bridge
already uses. copc-lib has **no** curl/GDAL/VSI dependency (confirmed by grep of
the installed headers).

## CRITICAL constraint: one-slot-per-thread, independent stream positions

The bridge is lock-free and relies on caller discipline:

- `Reader::open` creates `pool_size` **independent** `FileReader`s
  (`copc_bridge.cpp:206-211`).
- `read_node(depth,x,y,z, slot)` indexes `impl_->readers[slot]` with **no
  mutex** (`copc_bridge.cpp:278-346`). Contract documented at
  `copc_bridge.h:68-69` ("read_node() is safe to call concurrently provided each
  concurrent caller targets a distinct slot").
- The Swift side spins up `decodeConcurrency` workers (default = core count),
  each calling `read_node` with its own `slot`
  (`Sources/SwiftPDAL/Streaming/StreamingPointCloudSource.swift:743-758`).

**Implication:** each slot must have its **own** `std::istream` with an
**independent read position**. A single shared HTTP stream would race and corrupt
reads. Build `pool_size` independent HTTP streams — one per `::copc::Reader`.

## What copc-lib does to the stream

- Reads the LAS public header, VLRs, and the COPC hierarchy **once** at
  construction (`InitReader()` + `InitCopcReader()`), then on each
  `GetPointDataCompressed(node)` it seeks to the node's byte offset and reads
  `byte_size` bytes.
- Stream ops used: absolute `seekg`/`seekpos` (`std::ios::beg`), sequential
  `read(buf, n)`, and `clear()` (lazperf may over-read during decompression — the
  streambuf must tolerate an EOF/`clear()` without throwing).
- Node byte ranges are knowable up front from the hierarchy
  (`NodeInfo.offset` + `NodeInfo.byte_size`, already surfaced by the bridge), so
  range requests are exact.

## Implementation

### 1. New HTTP-range `std::istream` (Objective-C++ shim)

Add `Sources/CxxCOPC/http_stream.mm` + a header in `Sources/CxxCOPC/include/`.

- Implement a `std::streambuf` subclass backed by `NSURLSession` range requests
  (`Range: bytes=<a>-<b>`), wrapped in a `std::istream`.
- **Networking: Foundation `URLSession`, NOT the Network framework
  (`NWConnection`).** `URLSession` speaks both `http://` and `https://`
  transparently (TLS handled automatically for https) — the same scheme/URL,
  no code difference. `NWConnection` is a raw TCP/TLS socket and would force us
  to implement HTTP/1.1, range semantics, redirects, and TLS by hand — wrong
  layer. **Do NOT pull in libcurl** either (CxxCOPC does not link it; only
  CxxPDAL does, and only on iOS via the prebuilt pdalcpp).
- **http vs https both work** with no code change. The only catch is App
  Transport Security: plain `http://` requires an ATS exception in the *app's*
  Info.plist (already present in WABF for the Hooke host). `https://` needs
  nothing. This is an app-config concern, not a SwiftPDAL one.
- **Async→sync bridge (important):** copc-lib calls `in_stream->read(...)`
  **synchronously** and blocks. `URLSession` is async, so `underflow` must issue
  the ranged request and block the calling worker until bytes arrive. Use a
  completion-handler `dataTask` + `dispatch_semaphore_wait` on a dedicated
  serial/`.utility` `DispatchQueue` (or a `URLSession` with its own
  `delegateQueue`). Do **not** `await` URLSession's `async` API from inside the
  sync C++ call — that would block a Swift cooperative-pool thread. Blocking the
  decode worker is fine: it's a `Task.detached` per slot and already blocks on
  local-file `read()` today.
- Minimum streambuf methods: `seekpos` / `seekoff` (absolute, `beg`),
  `underflow` / `xsgetn` (range GET to fill the buffer on demand), graceful EOF
  so copc-lib's `clear()` works.
- Add a small read-ahead buffer (e.g. 256 KB–1 MB) to amortize RTT; copc-lib
  reads a node's compressed block contiguously after seeking.
- One total length is needed up front (HEAD, or first ranged GET parsing the
  `Content-Range` total) to bound `seekg(end)`-style positioning if copc-lib
  uses it.

### 2. `Reader::open_http` in the bridge

In `Sources/CxxCOPC/copc_bridge.{h,cpp}`:

```cpp
static Reader* open_http(const std::string& url, int32_t pool_size) noexcept;
```

- Build `pool_size` independent `HttpRangeStream` instances and one
  `::copc::Reader(stream*)` per slot. Store the streams in `Impl` alongside the
  readers so they outlive the readers (the `Reader` only holds a raw
  `std::istream*`).
- Read `nodes` + `header` from slot 0 exactly as `open` does
  (`copc_bridge.cpp:212-213`).
- **Reuse `read_node` unchanged** — it operates on `impl_->readers[slot]`
  regardless of whether the reader is file- or stream-backed. Only construction
  forks.
- Mirror the existing `noexcept` + nullptr-on-failure error handling.

### 3. `Package.swift`

In the `CxxCOPC` target:

```swift
.target(
    name: "CxxCOPC",
    dependencies: ["copclib"],
    path: "Sources/CxxCOPC",
    sources: ["copc_bridge.cpp", "http_stream.mm"],   // add the shim
    publicHeadersPath: "include",
    cxxSettings: [ .headerSearchPath("include") ],
    linkerSettings: [ .linkedFramework("Foundation") ] // URLSession
),
```

`.mm` (Objective-C++) compiles fine in an SPM C++ target; ensure the file uses
`#import <Foundation/Foundation.h>` and exposes only a plain C++ interface to
`copc_bridge.cpp` (keep ObjC types out of the header).

### 4. Swift streaming source

In `Sources/SwiftPDAL/Streaming/StreamingPointCloudSource.swift`, add a sibling
to `CopcStreamingPointCloudSource.open(_ url:options:)` (~line 643):

```swift
public static func open(
    remoteURL url: URL,
    options: StreamingOptions = .init()
) async throws -> CopcStreamingPointCloudSource {
    let poolSize = Int32(max(1, options.decodeConcurrency))
    guard let reader = CopcReader.open_http(std.string(url.absoluteString), poolSize) else {
        throw StreamingSourceError.openFailed(url)
    }
    // …identical hierarchy parse + worker-pool + driver setup as open(_:)…
}
```

Everything after obtaining the reader handle is identical to the file path — the
worker/slot model, `StreamingSourceInfo` (bounds, originShift, totalPoints,
pointsPerBatch), and driver are unchanged.

## Verification (in this repo)

1. **StreamingBench**: extend `Sources/StreamingBench` to accept an `http(s)://`
   argument and route to `open(remoteURL:)`. Run:
   `swift run -c release StreamingBench http://<host>/<file>.copc.laz 8 10` and
   confirm nodes decode over the network with **no local file**.
2. **Unit test** in `Tests/SwiftPDALTests`: serve `Resources/test.copc.laz` over
   a localhost range-capable HTTP server, open it via `open(remoteURL:)`, and
   assert `info.totalPoints` and `info.bounds` match the local `open(_:)` result.
   Also exercise concurrent decode (`decodeConcurrency > 1`) to prove the
   per-slot independent-stream invariant.
3. Watch the server access log for `206 Partial Content` responses (range
   requests), not a single `200` full GET.
4. Build for iOS (`swift build` with an iOS destination, or via the consuming
   app) to confirm the istream path has no GDAL/curl dependency.

## Reference: how it's consumed downstream (out of scope here, for API shape)

The consumer is `WABF` (`Sources/WABFPointCloud/LoadPointCloud.swift`):
`loadPointCloud(url:into:options:)` → `openCopcSource` →
`CopcStreamingPointCloudSource.open(url, options:)` → `installStreaming(...)`.
A new `loadPointCloud(remoteURL:into:options:)` will call the new
`open(remoteURL:)` and reuse `installStreaming` unchanged. A sketch
(`WABF_Sketches/Hooke_STAC`) currently downloads each tile to
`~/Library/Caches/WABF/HookeSTAC/` then loads locally; it will switch to passing
`asset.href` straight to the remote loader. Keep that in mind for the API
signature, but the WABF-side wiring is not part of this task.

## Files to touch (this repo)

- `Sources/CxxCOPC/http_stream.mm` **(new)** + `Sources/CxxCOPC/include/http_stream.h` **(new)**
- `Sources/CxxCOPC/copc_bridge.cpp` (+ `include/copc_bridge.h`) — add `open_http`
- `Package.swift` — CxxCOPC sources + `Foundation` link
- `Sources/SwiftPDAL/Streaming/StreamingPointCloudSource.swift` — `open(remoteURL:)`
- `Sources/StreamingBench/*` + `Tests/SwiftPDALTests/*` — verification

## Gotchas

- Per-node range GETs add RTT vs. local mmap; the read-ahead buffer + copc-lib's
  existing LOD/prefetch scheduling keep interaction smooth. Tune buffer size.
- Plain-HTTP hosts need an ATS exception in the **app** (already handled in WABF's
  Info.plist for the test host) — not a SwiftPDAL concern, but expect `http://`.
- Keep ObjC out of the public C++ header so `copc_bridge.cpp` (pure C++) can
  include it; the `.mm` file is the only Objective-C++ translation unit.
- copc-lib ships **headers + static lib only** (no `.cpp`), so you cannot patch
  copc-lib itself — everything must go through the public `Reader(std::istream*)`
  constructor.
