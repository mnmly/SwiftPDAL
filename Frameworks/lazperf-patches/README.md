# lazperf patches

Local patches applied on top of upstream `https://github.com/hobuinc/laz-perf` (master) when building the bundled `copclib.xcframework`. Upstream lazperf sees ~2 substantive C++ commits per year, so drift risk is low.

`build-copc-xcframework.sh` applies every `*.patch` in this directory, in lexical order, after cloning lazperf and before invoking cmake.

## 0001-add-reset-api.patch — pooled-decompressor reset API

Adds `reset()` methods that let a `point_decompressor_6/7/8` instance be reused across multiple LAZ chunks without rebuilding (and re-heap-allocating) all the arithmetic-coder model state.

New API surface:

- `las_decompressor::reset(InputCb)` — pure-virtual default that throws; only the 1.4 family overrides.
- `point_decompressor_base_1_4::reset(InputCb)` — rebinds the input stream and resets all sub-decompressors.
- Internal `reset()` on `models::arithmetic`, `models::arithmetic_bit`, `decoders::arithmetic`, `decompressors::integer`, `MemoryStream`, `InCbStream::setCallback`, `Point14Decompressor::reset(InCbStream&)`, `Rgb14Decompressor::reset`, `Nir14Decompressor::reset`, `Byte14Decompressor::reset`, `*::ChannelCtx::resetForDecode`.

All resets are designed to **preserve heap allocations** so the only cost between chunks is the work to re-zero arithmetic-coder state.

### Tests

`reset_test.cpp` (in this directory) compresses three distinct synthetic point-format-7 chunks, decompresses each with a fresh-ctor decompressor (baseline), then decompresses the same chunks again using a single reused decompressor with `reset()` between each. Byte-for-byte compare. Also replays chunk 0 after passing through chunk 2 to catch state leaks across longer reset chains.

Build & run standalone (after applying the patch into a lazperf checkout):

```sh
LP=/path/to/laz-perf/cpp
clang++ -std=c++17 -O2 -I$LP -o reset_test reset_test.cpp \
    $LP/lazperf/{lazperf,readers,writers,header,vlr,charbuf,filestream}.cpp \
    $LP/lazperf/detail/field_{byte10,byte14,gpstime10,nir14,point10,point14,rgb10,rgb14}.cpp
./reset_test
```

Last run on this branch: all chunks match, no replay drift.

### Bench

`pool_bench.cpp` measures fresh-ctor-per-chunk vs reset-pooled across the chunk-size range seen on the real COPC workload. Absolute savings are flat at ~0.27–0.40 ms/chunk (the fixed per-decompressor cost). As a fraction of total decode CPU:

| Chunk size | Savings |
|---|---|
| 2,000 pts | 29% |
| 5,000 pts | 17% |
| 10,000 pts | 12% |
| 34,275 pts (mean) | 5% |
| 80,000 pts | 3% |

Applied to the real-workload histogram (mean 34k pts, dominated by 32–128k buckets): projected total session savings ≈ 5–15% of decode CPU, plus a substantial reduction in allocator pressure.
