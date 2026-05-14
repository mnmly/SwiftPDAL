# copc-build (spike)

Locally-built copc-lib + laz-perf for the streaming spike. **Not for distribution.**
Replace with a vendored xcframework or SwiftPM C++ source target before shipping.

## What lives here

```
copc-build/
  include/copc-lib/...     # public headers
  include/lazperf/...      # transitively required by copc-lib headers
  lib/libcopc-lib.a        # static
  lib/liblazperf.a         # static
  lib/cmake/...            # CMake package config (unused by SwiftPM)
```

`Package.swift` references this prefix via `unsafeFlags`:

```swift
.target(
    name: "CxxCOPC",
    cxxSettings: [.unsafeFlags(["-I", "Frameworks/copc-build/include"])],
    linkerSettings: [.unsafeFlags([
        "-LFrameworks/copc-build/lib",
        "-lcopc-lib", "-llazperf",
    ])]
)
```

## Rebuild

```sh
cd /tmp
git clone --depth 1 --branch v2.6.3 https://github.com/RockRobotic/copc-lib.git
cd copc-lib
git clone --depth 1 https://github.com/hobuinc/laz-perf.git libs/laz-perf
mkdir build && cd build
cmake .. \
  -DBUILD_SHARED_LIBS=OFF \
  -DWITH_TESTS=OFF \
  -DWITH_PYTHON=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_INSTALL_PREFIX=/path/to/SwiftPDAL/Frameworks/copc-build
make -j install
```

## Why this is throwaway

- Not portable: `Frameworks/copc-build/` is per-dev-machine; shouldn't be committed.
- `unsafeFlags` propagates to anything depending on SwiftPDAL, polluting downstream `Package.swift`.
- `.a` files have no codesign / arch slicing; won't work on iOS/visionOS or in distributed binaries.

## Next step after spike validation

Pick one:

1. **xcframework** — build copc-lib + laz-perf as a fat `.xcframework` (mac+ios+sim slices), upload to GitHub releases, reference via `.binaryTarget` like `pdalcpp` already is. Matches existing pattern in this package.
2. **Vendored source** — add `Sources/CxxLazPerf/` and re-target `CxxCOPC` to compile from source. SwiftPM-native, no external build. ~70 .cpp files total; need to verify they compile under SwiftPM's clang invocation without CMake-defined macros.

Recommendation: (1), matches `pdalcpp.xcframework` pattern in this repo.
