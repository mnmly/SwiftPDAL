#include "copc_bridge.h"
#include "http_stream.h"

#include <copc-lib/io/copc_reader.hpp>
#include <copc-lib/hierarchy/node.hpp>
#include <copc-lib/hierarchy/key.hpp>
#include <copc-lib/las/header.hpp>
#include <copc-lib/geometry/box.hpp>
#include <copc-lib/geometry/vector3.hpp>

#include <copc-lib/las/point.hpp>
#include <copc-lib/las/points.hpp>
#include <copc-lib/las/utils.hpp>
#include <copc-lib/las/vlr.hpp>

#include <lazperf/lazperf.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <fstream>
#include <istream>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

// --- Node-size histogram ---------------------------------------------------
// Bins observed points-per-node in log2 buckets. Dumps to stderr on process
// exit. Lock-free; safe across the decoder thread pool.
//
// Disabled by default. Enable by setting SWIFTPDAL_NODE_HISTOGRAM=1 in the
// environment before launching the host process. The explicit
// dump_node_size_histogram() entry point always works, even without the env
// var, but will print only what was recorded since the env was last
// observed.
namespace {
    constexpr int kHistBuckets = 22;        // covers 1 .. 2^22 (~4M points)
    std::atomic<uint64_t> g_hist[kHistBuckets] {};
    std::atomic<uint64_t> g_total_nodes {0};
    std::atomic<uint64_t> g_total_points {0};
    std::atomic<uint64_t> g_min_pts {UINT64_MAX};
    std::atomic<uint64_t> g_max_pts {0};
    std::atomic<bool>     g_atexit_registered {false};
    // Tri-state: 0=unchecked, 1=enabled, 2=disabled. Checked once on first
    // node read.
    std::atomic<int>      g_enabled_cached {0};

    bool histogram_enabled() {
        int s = g_enabled_cached.load(std::memory_order_acquire);
        if (s) return s == 1;
        const char* v = std::getenv("SWIFTPDAL_NODE_HISTOGRAM");
        bool on = v && v[0] && !(v[0] == '0' && v[1] == 0);
        int expected = 0;
        g_enabled_cached.compare_exchange_strong(expected, on ? 1 : 2);
        return on;
    }

    inline int log2_bucket(uint64_t n) {
        if (n == 0) return 0;
        int b = 0;
        while ((n >>= 1) && b + 1 < kHistBuckets) ++b;
        return b;
    }

    void dump_histogram() {
        uint64_t total_nodes  = g_total_nodes.load();
        uint64_t total_points = g_total_points.load();
        if (total_nodes == 0) return;
        std::fprintf(stderr, "\n=== swiftpdal_copc_read_node size histogram ===\n");
        std::fprintf(stderr, "  total nodes : %llu\n", (unsigned long long)total_nodes);
        std::fprintf(stderr, "  total points: %llu\n", (unsigned long long)total_points);
        std::fprintf(stderr, "  mean        : %.1f pts/node\n",
                     (double)total_points / (double)total_nodes);
        std::fprintf(stderr, "  min / max   : %llu / %llu pts\n",
                     (unsigned long long)g_min_pts.load(),
                     (unsigned long long)g_max_pts.load());
        std::fprintf(stderr, "  bucket  (range)              count    cum%%   pts-share%%\n");
        uint64_t cum_nodes = 0;
        uint64_t cum_points = 0;
        for (int b = 0; b < kHistBuckets; ++b) {
            uint64_t c = g_hist[b].load();
            if (c == 0) continue;
            cum_nodes += c;
            uint64_t lo = (b == 0) ? 1 : (1ULL << b);
            uint64_t hi = (1ULL << (b + 1)) - 1;
            // Estimate points contributed by this bucket as midpoint * count
            // (rough but enough to see where the mass of *points* lives).
            uint64_t mid = lo + (hi - lo) / 2;
            uint64_t est_pts = mid * c;
            cum_points += est_pts;
            std::fprintf(stderr, "   2^%-2d  [%7llu..%-7llu]  %8llu  %5.1f%%   %5.1f%%\n",
                         b,
                         (unsigned long long)lo,
                         (unsigned long long)hi,
                         (unsigned long long)c,
                         100.0 * cum_nodes / total_nodes,
                         100.0 * cum_points / total_points);
        }
        std::fprintf(stderr, "===============================================\n\n");
        std::fflush(stderr);
    }

    inline void record_node_size(uint64_t n) {
        if (n == 0) return;
        if (!histogram_enabled()) return;
        g_hist[log2_bucket(n)].fetch_add(1, std::memory_order_relaxed);
        g_total_nodes.fetch_add(1, std::memory_order_relaxed);
        g_total_points.fetch_add(n, std::memory_order_relaxed);
        // monotonic min/max via CAS
        uint64_t cur = g_min_pts.load(std::memory_order_relaxed);
        while (n < cur && !g_min_pts.compare_exchange_weak(cur, n)) {}
        cur = g_max_pts.load(std::memory_order_relaxed);
        while (n > cur && !g_max_pts.compare_exchange_weak(cur, n)) {}
        bool expected = false;
        if (g_atexit_registered.compare_exchange_strong(expected, true)) {
            std::atexit(dump_histogram);
        }
    }
} // namespace
// --------------------------------------------------------------------------

// --- Per-stage decode profiler (env-gated) --------------------------------
// Accumulates wall-clock nanoseconds spent in each per-chunk read_node stage
// (find / fetch-compressed / lazperf-decode / xyz-rgb-extract), lock-free
// across the decode thread pool, and dumps per-chunk averages to stderr on
// process exit. Enable with SWIFTPDAL_DECODE_PROFILE=1. Zero cost when off
// (a single cached atomic-bool check per stage).
namespace {
    std::atomic<uint64_t> g_prof_calls {0};
    std::atomic<uint64_t> g_prof_find_ns {0};
    std::atomic<uint64_t> g_prof_fetch_ns {0};
    std::atomic<uint64_t> g_prof_decode_ns {0};
    std::atomic<uint64_t> g_prof_extract_ns {0};
    std::atomic<uint64_t> g_prof_points {0};
    std::atomic<uint64_t> g_prof_fetch_hits {0};   // served from prefetch cache
    std::atomic<uint64_t> g_prof_fetch_miss {0};   // direct GetPointDataCompressed
    std::atomic<bool>     g_prof_atexit {false};
    std::atomic<int>      g_prof_enabled {0};       // 0=unchecked,1=on,2=off

    bool profile_enabled() {
        int s = g_prof_enabled.load(std::memory_order_acquire);
        if (s) return s == 1;
        const char* v = std::getenv("SWIFTPDAL_DECODE_PROFILE");
        bool on = v && v[0] && !(v[0] == '0' && v[1] == 0);
        int expected = 0;
        g_prof_enabled.compare_exchange_strong(expected, on ? 1 : 2);
        return on;
    }

    void dump_profile() {
        uint64_t calls = g_prof_calls.load();
        if (calls == 0) return;
        auto per = [calls](std::atomic<uint64_t>& a) {
            return (double)a.load() / (double)calls / 1000.0;   // µs/chunk
        };
        double f = per(g_prof_find_ns), fe = per(g_prof_fetch_ns),
               d = per(g_prof_decode_ns), e = per(g_prof_extract_ns);
        std::fprintf(stderr, "\n=== swiftpdal read_node per-stage profile ===\n");
        std::fprintf(stderr, "  chunks decoded : %llu\n", (unsigned long long)calls);
        std::fprintf(stderr, "  points decoded : %llu (avg %.0f pts/chunk)\n",
                     (unsigned long long)g_prof_points.load(),
                     (double)g_prof_points.load() / (double)calls);
        std::fprintf(stderr, "  prefetch hit/miss: %llu / %llu\n",
                     (unsigned long long)g_prof_fetch_hits.load(),
                     (unsigned long long)g_prof_fetch_miss.load());
        std::fprintf(stderr, "  --- µs / chunk (sum of thread time, not wall) ---\n");
        std::fprintf(stderr, "  find (hierarchy lookup) : %8.2f\n", f);
        std::fprintf(stderr, "  fetch (read compressed) : %8.2f\n", fe);
        std::fprintf(stderr, "  decode (lazperf)        : %8.2f\n", d);
        std::fprintf(stderr, "  extract (xyz/rgb pack)  : %8.2f\n", e);
        std::fprintf(stderr, "  TOTAL C++ per chunk     : %8.2f\n", f + fe + d + e);
        std::fprintf(stderr, "============================================\n\n");
        std::fflush(stderr);
    }

    struct StageTimer {
        bool on;
        std::chrono::steady_clock::time_point t;
        explicit StageTimer(bool enabled) : on(enabled) {
            if (on) t = std::chrono::steady_clock::now();
        }
        // Returns elapsed ns since construction/last lap and resets the clock.
        uint64_t lap() {
            if (!on) return 0;
            auto now = std::chrono::steady_clock::now();
            uint64_t ns = (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(now - t).count();
            t = now;
            return ns;
        }
    };
} // namespace
// --------------------------------------------------------------------------

// --- PooledDecompressor (phase 2 perf optimization) -----------------------
// Holds a single lazperf::las_decompressor alive across many chunks. On each
// node decode, calls reset(InputCb) on the existing instance instead of
// rebuilding the arithmetic-coder model state from scratch. Caller is
// responsible for thread-safety; in this bridge we keep one Pool per
// FileReader slot, matching the existing one-slot-per-thread contract.
namespace {
class PooledDecompressor {
public:
    // Decompresses `point_count` points of LAZ point-format `point_format_id`
    // from `compressed` into `out_bytes` (resized to N * record_size).
    void decode(const std::vector<char>& compressed,
                int point_count,
                int8_t point_format_id,
                uint16_t eb_byte_size,
                size_t point_size,
                std::vector<char>& out_bytes)
    {
        if (!decomp_ || cached_format_ != point_format_id || cached_eb_ != eb_byte_size) {
            // First call (or shape change): build a new decompressor.
            // The InputCb we hand here is a no-op placeholder; reset() below
            // immediately rebinds to a real source for the first chunk.
            lazperf::InputCb dummy = [](unsigned char*, size_t) {};
            decomp_ = lazperf::build_las_decompressor(dummy, point_format_id, eb_byte_size);
            cached_format_ = point_format_id;
            cached_eb_ = eb_byte_size;
        }

        // Bind a fresh callback that walks the just-loaded compressed bytes.
        // The lambda captures by value (a pointer + index), keeping ownership
        // of progression even though `compressed` outlives the call.
        const char* src = compressed.data();
        const size_t total = compressed.size();
        auto idx = std::make_shared<size_t>(0);
        lazperf::InputCb cb = [src, total, idx](unsigned char* dst, size_t n) {
            // lazperf may try to read past the chunk end as part of its
            // sentinel handling. The original DecompressBytes implementation
            // tolerates this via in_stream.clear() afterwards; we mimic by
            // zero-filling any over-read so we don't UB.
            size_t avail = (*idx < total) ? (total - *idx) : 0;
            size_t copy = std::min(n, avail);
            if (copy) std::memcpy(dst, src + *idx, copy);
            if (copy < n) std::memset(dst + copy, 0, n - copy);
            *idx += n;
        };

        decomp_->reset(std::move(cb));

        out_bytes.resize(static_cast<size_t>(point_count) * point_size);
        // Decompress each record straight into its slot in out_bytes. lazperf
        // writes exactly `point_size` bytes per call (the record size the
        // decompressor was built for: base format + Extra Bytes). A fixed-size
        // stack bounce buffer is unsafe: files with many Extra Bytes dimensions
        // produce records larger than any fixed cap (e.g. a 320-byte record for
        // ~65 EB dims overflows a 256-byte buffer and smashes the stack).
        for (int i = 0; i < point_count; ++i) {
            decomp_->decompress(out_bytes.data() + static_cast<size_t>(i) * point_size);
        }
    }

private:
    lazperf::las_decompressor::ptr decomp_;
    int8_t cached_format_ = -1;
    uint16_t cached_eb_ = 0;
};
} // namespace
// --------------------------------------------------------------------------

// --- Node prefetch coalescing thresholds ----------------------------------
// Max byte gap between two consecutive COPC compressed blocks that
// prefetch_nodes will still bridge in one read. Mirrored on the Swift side
// (NodePrefetch.gapLocalBytes / gapHttpBytes) — keep the two in sync.
namespace {
// Local files: a seek is cheap, so only coalesce across a gap smaller than the
// cost of reading (and discarding) the gap bytes — 256 KB.
constexpr uint64_t kPrefetchGapLocal = 256ull * 1024;
// HTTP: a round-trip dominates, so coalesce across gaps up to a megabyte — a
// megabyte of wasted body is cheaper than a second RTT on any plausible link.
constexpr uint64_t kPrefetchGapHttp = 1024ull * 1024;

// Pack a voxel key into a single uint64 to key the per-slot cache. Layout is
// arbitrary (only needs to be stable + collision-free between prefetch and
// read_node within a slot); mirrors Swift's ChunkID packing for readability.
inline uint64_t pack_node_key(int32_t d, int32_t x, int32_t y, int32_t z) noexcept {
    return (static_cast<uint64_t>(d & 0x1F) << 57) |
           (static_cast<uint64_t>(x & 0x7FFFF) << 38) |
           (static_cast<uint64_t>(y & 0x7FFFF) << 19) |
            static_cast<uint64_t>(z & 0x7FFFF);
}
} // namespace
// --------------------------------------------------------------------------

namespace swiftpdal { namespace copc {

struct Reader::Impl {
    std::atomic<int> refcount {1};
    // Backing streams for the HTTP path. Declared BEFORE `readers` so they are
    // destroyed AFTER the readers: an istream-backed ::copc::Reader holds a raw
    // std::istream* it does not own, so the stream must outlive it. Empty for
    // the local-file path (FileReader owns its own fstream).
    std::vector<std::unique_ptr<std::istream>> streams;
    // ::copc::Reader (base), not FileReader: holds either a FileReader (local)
    // or an istream-backed Reader (HTTP). FindNode / GetPointDataCompressed /
    // CopcConfig / GetAllNodes are all on the base, so read_node() is agnostic.
    std::vector<std::unique_ptr<::copc::Reader>> readers;
    std::vector<PooledDecompressor> pool;   // parallel to `readers`
    std::vector<std::vector<char>> scratch; // reusable decompressed-bytes buffer per slot
    // Per-slot prefetch state. `prefetch_streams` are dedicated raw byte
    // streams for coalesced span reads (local: an ifstream owned here; HTTP:
    // an aliasing pointer into `streams`, non-owning). `prefetch_cache` holds
    // sliced compressed blocks keyed by packed voxel key — read_node pops on
    // hit. Both are parallel to `readers`; a slot is only ever touched by its
    // single worker, so neither needs locking.
    std::vector<std::unique_ptr<std::ifstream>> prefetch_local_streams;
    std::vector<std::unordered_map<uint64_t, std::vector<char>>> prefetch_cache;
    std::vector<::copc::Node> nodes;
    ::copc::las::LasHeader header;
    std::vector<EbFieldInfo> eb_fields;  // resolved Extra Bytes schema
    bool closed = false;
};

// Byte size of a LAS Extra Bytes data_type code (0 / array types → 0 = skip).
static int32_t eb_type_size(uint8_t dt) noexcept {
    switch (dt) {
        case 1: case 2: return 1;            // uint8 / int8
        case 3: case 4: return 2;            // uint16 / int16
        case 5: case 6: case 9: return 4;    // uint32 / int32 / float
        case 7: case 8: case 10: return 8;   // uint64 / int64 / double
        default: return 0;                   // undocumented / 2D-3D arrays — unsupported
    }
}

// Reinterpret `size` bytes at `p` as data_type `dt`, widened to float.
static float eb_read_float(const uint8_t* p, uint8_t dt) noexcept {
    switch (dt) {
        case 1:  { uint8_t  v; std::memcpy(&v, p, 1); return float(v); }
        case 2:  { int8_t   v; std::memcpy(&v, p, 1); return float(v); }
        case 3:  { uint16_t v; std::memcpy(&v, p, 2); return float(v); }
        case 4:  { int16_t  v; std::memcpy(&v, p, 2); return float(v); }
        case 5:  { uint32_t v; std::memcpy(&v, p, 4); return float(v); }
        case 6:  { int32_t  v; std::memcpy(&v, p, 4); return float(v); }
        case 7:  { uint64_t v; std::memcpy(&v, p, 8); return float(v); }
        case 8:  { int64_t  v; std::memcpy(&v, p, 8); return float(v); }
        case 9:  { float    v; std::memcpy(&v, p, 4); return v; }
        case 10: { double   v; std::memcpy(&v, p, 8); return float(v); }
        default: return 0.0f;
    }
}

// Build the Extra Bytes schema (name/offset/type/size/scale/offset) from the
// file's EB VLR, computing each field's byte offset within a point's
// ExtraBytes() blob as the running sum of preceding field sizes.
static std::vector<EbFieldInfo> build_eb_fields(const ::copc::las::EbVlr& vlr) {
    std::vector<EbFieldInfo> out;
    int32_t offset = 0;
    for (const auto& f : vlr.items) {
        EbFieldInfo e;
        const std::string& nm = f.name;
        const size_t n = std::min(nm.size(), size_t{31});
        std::memcpy(e.name, nm.data(), n);
        e.name[n] = '\0';
        e.data_type   = f.data_type;
        e.size        = eb_type_size(f.data_type);
        e.byte_offset = offset;
        // LAS Extra Bytes option bits: 0x08 = scale present, 0x10 = offset present.
        e.scale        = (f.options & 0x08) ? f.scale[0]  : 1.0;
        e.offset_value = (f.options & 0x10) ? f.offset[0] : 0.0;
        out.push_back(e);
        // Advance by the on-disk size (undocumented/type 0 uses `options` bytes).
        offset += e.size > 0 ? e.size : int32_t(f.options);
    }
    return out;
}

Reader::~Reader() {
    delete impl_;
}

Reader* Reader::open(const std::string& path, int32_t pool_size) noexcept {
    if (path.empty() || pool_size < 1) return nullptr;
    try {
        auto* r = new Reader();
        r->impl_ = new Impl();
        r->impl_->readers.reserve(static_cast<size_t>(pool_size));
        r->impl_->pool.resize(static_cast<size_t>(pool_size));
        r->impl_->scratch.resize(static_cast<size_t>(pool_size));
        r->impl_->prefetch_cache.resize(static_cast<size_t>(pool_size));
        r->impl_->prefetch_local_streams.reserve(static_cast<size_t>(pool_size));
        for (int32_t i = 0; i < pool_size; ++i) {
            r->impl_->readers.emplace_back(std::make_unique<::copc::FileReader>(path));
            // A dedicated raw ifstream per slot for coalesced prefetch reads.
            // Separate from copc-lib's own internal fstream, so a prefetch seek
            // never disturbs a concurrent decode's read position.
            auto pf = std::make_unique<std::ifstream>(path, std::ios::in | std::ios::binary);
            r->impl_->prefetch_local_streams.emplace_back(std::move(pf));
        }
        r->impl_->nodes  = r->impl_->readers[0]->GetAllNodes();
        r->impl_->header = r->impl_->readers[0]->CopcConfig().LasHeader();
        r->impl_->eb_fields = build_eb_fields(r->impl_->readers[0]->CopcConfig().ExtraBytesVlr());
        return r;
    } catch (const std::exception&) {
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

Reader* Reader::open_http(const std::string& url, int32_t pool_size) noexcept {
    if (url.empty() || pool_size < 1) return nullptr;
    try {
        auto* r = new Reader();
        r->impl_ = new Impl();
        r->impl_->streams.reserve(static_cast<size_t>(pool_size));
        r->impl_->readers.reserve(static_cast<size_t>(pool_size));
        r->impl_->pool.resize(static_cast<size_t>(pool_size));
        r->impl_->scratch.resize(static_cast<size_t>(pool_size));
        r->impl_->prefetch_cache.resize(static_cast<size_t>(pool_size));
        // No dedicated prefetch streams for HTTP: coalesced reads reuse each
        // slot's own range istream (see prefetch_nodes).
        for (int32_t i = 0; i < pool_size; ++i) {
            // Each slot gets an independent HTTP stream with its own read
            // position — required by read_node's lock-free per-slot contract.
            std::unique_ptr<std::istream> stream = OpenHttpRangeStream(url);
            if (!stream) { delete r; return nullptr; }
            r->impl_->readers.emplace_back(
                std::make_unique<::copc::Reader>(stream.get()));
            r->impl_->streams.emplace_back(std::move(stream));
        }
        r->impl_->nodes  = r->impl_->readers[0]->GetAllNodes();
        r->impl_->header = r->impl_->readers[0]->CopcConfig().LasHeader();
        r->impl_->eb_fields = build_eb_fields(r->impl_->readers[0]->CopcConfig().ExtraBytesVlr());
        return r;
    } catch (const std::exception&) {
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

void Reader::__retain() noexcept {
    impl_->refcount.fetch_add(1, std::memory_order_relaxed);
}

void Reader::__release() noexcept {
    if (impl_->refcount.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete this;
    }
}

int32_t Reader::pool_size() const noexcept {
    return static_cast<int32_t>(impl_->readers.size());
}

int64_t Reader::total_points() const noexcept {
    int64_t total = 0;
    for (const auto& n : impl_->nodes) total += n.point_count;
    return total;
}

std::array<double, 3> Reader::bounds_min() const noexcept {
    return { impl_->header.min.x, impl_->header.min.y, impl_->header.min.z };
}

std::array<double, 3> Reader::bounds_max() const noexcept {
    return { impl_->header.max.x, impl_->header.max.y, impl_->header.max.z };
}

int32_t Reader::node_count() const noexcept {
    return static_cast<int32_t>(impl_->nodes.size());
}

bool Reader::node_at(int32_t index, NodeInfo& out) const noexcept {
    if (index < 0 || static_cast<size_t>(index) >= impl_->nodes.size()) return false;
    const auto& n = impl_->nodes[index];
    out.depth       = n.key.d;
    out.x           = n.key.x;
    out.y           = n.key.y;
    out.z           = n.key.z;
    out.point_count = n.point_count;
    out.offset      = n.offset;
    out.byte_size   = n.byte_size;
    try {
        ::copc::Box box(n.key, impl_->header);
        out.min_x = box.x_min;
        out.min_y = box.y_min;
        out.min_z = box.z_min;
        out.max_x = box.x_max;
        out.max_y = box.y_max;
        out.max_z = box.z_max;
    } catch (...) {
        return false;
    }
    return true;
}

int8_t Reader::point_format_id() const noexcept {
    if (impl_->closed) return -1;
    return impl_->header.PointFormatId();
}

int32_t Reader::eb_field_count() const noexcept {
    return static_cast<int32_t>(impl_->eb_fields.size());
}

bool Reader::eb_field_at(int32_t index, EbFieldInfo& out) const noexcept {
    if (index < 0 || static_cast<size_t>(index) >= impl_->eb_fields.size()) return false;
    out = impl_->eb_fields[static_cast<size_t>(index)];
    return true;
}

// Fast XYZ(+RGB) extraction straight from the decompressed LAS records,
// bypassing copc::las::Points::Unpack — which heap-allocates a
// shared_ptr<Point> per record, parses each field through a std::istream, then
// returns six freshly-allocated std::vector<double/uint16> from X()/Y()/Z()/
// Red()/Green()/Blue(). For the streaming-render path (no extra dims) all of
// that is pure overhead: X/Y/Z are int32 at byte offsets 0/4/8 in every LAS
// point format, and RGB (3×uint16) sits at the tail of the base record, after
// which NIR (uint16), when present, follows. We derive the RGB offset from
// copclib's own PointBaseByteSize so we never hardcode per-format magic.
//
// Restricted to point formats 6/7/8 — the only formats COPC permits and the
// only ones copclib's FormatHasRgb / PointBaseByteSize accept (they THROW for
// anything else). Since this function is noexcept, calling them on a stray
// legacy/wavepacket format would std::terminate; instead we return false and
// let read_node's try/catch-guarded Unpack path handle (and gracefully reject)
// it. For 6/7/8 the RGB triple sits at the tail of the base record, with NIR
// (format 8) following it — derived from PointBaseByteSize, never hardcoded.
static bool read_node_fast(const std::vector<char>& recs, int32_t n,
                           size_t point_size, int8_t fmt,
                           const ::copc::las::LasHeader& header,
                           ChunkData& out) noexcept {
    if (fmt != 6 && fmt != 7 && fmt != 8) return false;

    const bool hasRgb = ::copc::las::FormatHasRgb(static_cast<uint8_t>(fmt));
    const bool hasNir = ::copc::las::FormatHasNir(static_cast<uint8_t>(fmt));
    const int32_t base = static_cast<int32_t>(::copc::las::PointBaseByteSize(fmt));
    const int32_t rgbOff = hasRgb ? base - (hasNir ? 8 : 6) : -1;
    // Defend against a record stride that can't hold the fields we read.
    if (static_cast<int32_t>(point_size) < 12) return false;
    if (rgbOff >= 0 && rgbOff + 6 > static_cast<int32_t>(point_size)) return false;

    const ::copc::Vector3 scale = header.Scale();
    const ::copc::Vector3 offset = header.Offset();

    out.xyz.resize(static_cast<size_t>(n) * 3);
    out.rgb.assign(static_cast<size_t>(n) * 3, uint16_t{0});

    const char* p = recs.data();
    for (int32_t i = 0; i < n; ++i) {
        const char* rec = p + static_cast<size_t>(i) * point_size;
        int32_t xi, yi, zi;
        std::memcpy(&xi, rec + 0, 4);
        std::memcpy(&yi, rec + 4, 4);
        std::memcpy(&zi, rec + 8, 4);
        out.xyz[3 * i + 0] = static_cast<double>(xi) * scale.x + offset.x;
        out.xyz[3 * i + 1] = static_cast<double>(yi) * scale.y + offset.y;
        out.xyz[3 * i + 2] = static_cast<double>(zi) * scale.z + offset.z;
        if (rgbOff >= 0) {
            uint16_t r, g, b;
            std::memcpy(&r, rec + rgbOff + 0, 2);
            std::memcpy(&g, rec + rgbOff + 2, 2);
            std::memcpy(&b, rec + rgbOff + 4, 2);
            out.rgb[3 * i + 0] = r;
            out.rgb[3 * i + 1] = g;
            out.rgb[3 * i + 2] = b;
        }
    }
    out.has_rgb_ = hasRgb;
    out.point_count_ = n;
    return true;
}

ChunkData Reader::read_node(int32_t depth, int32_t x, int32_t y, int32_t z,
                            int32_t slot,
                            const ExtractDesc* descs, int32_t desc_count) noexcept {
    ChunkData out;
    if (impl_->closed) return out;
    if (slot < 0 || static_cast<size_t>(slot) >= impl_->readers.size()) return out;

    const bool prof = profile_enabled();
    StageTimer timer(prof);

    ::copc::Reader* reader = impl_->readers[static_cast<size_t>(slot)].get();
    try {
        ::copc::VoxelKey key(depth, x, y, z);
        ::copc::Node node = reader->FindNode(key);
        if (!node.IsValid()) return out;

        // Pooled decode path. Replaces reader->GetPoints(node), which would
        // build a fresh lazperf decompressor per call. See PooledDecompressor
        // above + Frameworks/lazperf-patches/.
        const int8_t fmt = impl_->header.PointFormatId();
        const uint16_t eb = impl_->header.EbByteSize();
        const uint16_t point_size = ::copc::las::PointByteSize(fmt, eb);
        if (prof) g_prof_find_ns.fetch_add(timer.lap(), std::memory_order_relaxed);

        // Consult this slot's prefetch cache first: a prior prefetch_nodes may
        // have already read this node's compressed block as part of a coalesced
        // span. Single-use — pop it so the cache stays bounded. On a miss (no
        // prefetch, cancelled cluster, or short read) fall back to the direct
        // read, exactly as before.
        std::vector<char> compressed;
        auto& cache = impl_->prefetch_cache[static_cast<size_t>(slot)];
        auto hit = cache.find(pack_node_key(depth, x, y, z));
        if (hit != cache.end()) {
            compressed = std::move(hit->second);
            cache.erase(hit);
            if (prof) g_prof_fetch_hits.fetch_add(1, std::memory_order_relaxed);
        } else {
            compressed = reader->GetPointDataCompressed(node);
            if (prof) g_prof_fetch_miss.fetch_add(1, std::memory_order_relaxed);
        }
        if (prof) g_prof_fetch_ns.fetch_add(timer.lap(), std::memory_order_relaxed);

        impl_->pool[static_cast<size_t>(slot)].decode(
            compressed, node.point_count, fmt, eb, point_size,
            impl_->scratch[static_cast<size_t>(slot)]);
        if (prof) g_prof_decode_ns.fetch_add(timer.lap(), std::memory_order_relaxed);

        // Fast path: no extra dims requested → read XYZ/RGB straight from the
        // decompressed records, skipping the per-point Point object model.
        if (desc_count <= 0) {
            const int32_t n = static_cast<int32_t>(node.point_count);
            if (n <= 0) return out;
            if (read_node_fast(impl_->scratch[static_cast<size_t>(slot)],
                               n, point_size, fmt, impl_->header, out)) {
                record_node_size(static_cast<uint64_t>(n));
                if (prof) {
                    g_prof_extract_ns.fetch_add(timer.lap(), std::memory_order_relaxed);
                    g_prof_points.fetch_add((uint64_t)n, std::memory_order_relaxed);
                    g_prof_calls.fetch_add(1, std::memory_order_relaxed);
                    bool ex = false;
                    if (g_prof_atexit.compare_exchange_strong(ex, true)) std::atexit(dump_profile);
                }
                return out;
            }
        }

        // Fallback (extra dims requested, or a fast-path-unsupported format):
        // full Unpack into copc Point objects.
        ::copc::las::Points points = ::copc::las::Points::Unpack(
            impl_->scratch[static_cast<size_t>(slot)], impl_->header);

        const int32_t n = static_cast<int32_t>(points.Size());
        if (n <= 0) return out;
        record_node_size(static_cast<uint64_t>(n));

        out.xyz.resize(static_cast<size_t>(n) * 3);
        out.rgb.resize(static_cast<size_t>(n) * 3);

        const std::vector<double> xs = points.X();
        const std::vector<double> ys = points.Y();
        const std::vector<double> zs = points.Z();
        for (int32_t i = 0; i < n; ++i) {
            out.xyz[3*i+0] = xs[i];
            out.xyz[3*i+1] = ys[i];
            out.xyz[3*i+2] = zs[i];
        }

        const bool hasRgb = ::copc::las::FormatHasRgb(
            static_cast<uint8_t>(impl_->header.PointFormatId()));
        if (hasRgb) {
            const std::vector<uint16_t> r = points.Red();
            const std::vector<uint16_t> g = points.Green();
            const std::vector<uint16_t> b = points.Blue();
            for (int32_t i = 0; i < n; ++i) {
                out.rgb[3*i+0] = r[i];
                out.rgb[3*i+1] = g[i];
                out.rgb[3*i+2] = b[i];
            }
            out.has_rgb_ = true;
        } else {
            // vector default-constructs to zero for trivial types — but
            // resize() above only guarantees value-init when growing from
            // empty, which we are. Be explicit anyway.
            std::fill(out.rgb.begin(), out.rgb.end(), uint16_t{0});
            out.has_rgb_ = false;
        }

        // Optional per-point scalar dimensions (opt-in). dim-major float layout:
        // extra[d*n + i]. desc_count == 0 ⇒ no work (original path).
        if (descs != nullptr && desc_count > 0) {
            out.extra.assign(static_cast<size_t>(n) * static_cast<size_t>(desc_count), 0.0f);
            for (int32_t i = 0; i < n; ++i) {
                const auto& p = points[static_cast<size_t>(i)];
                std::vector<uint8_t> ebBytes;
                bool fetchedEb = false;
                for (int32_t d = 0; d < desc_count; ++d) {
                    const ExtractDesc& dd = descs[d];
                    double v = 0.0;
                    if (dd.kind == 0) {
                        switch (dd.code) {
                            case 0: v = double(p->Classification());   break;
                            case 1: v = double(p->Intensity());        break;
                            case 2: v = double(p->ReturnNumber());     break;
                            case 3: v = double(p->NumberOfReturns());  break;
                            case 4: v = double(p->ScanAngle());        break;
                            case 5: v = double(p->UserData());         break;
                            case 6: v = double(p->PointSourceId());    break;
                            case 7: v = p->GPSTime();                  break;
                            default: v = 0.0;                          break;
                        }
                    } else if (dd.kind == 1 && dd.size > 0) {
                        if (!fetchedEb) { ebBytes = p->ExtraBytes(); fetchedEb = true; }
                        const int32_t end = dd.byte_offset + dd.size;
                        if (dd.byte_offset >= 0 && end <= static_cast<int32_t>(ebBytes.size())) {
                            const float raw = eb_read_float(ebBytes.data() + dd.byte_offset,
                                                            static_cast<uint8_t>(dd.data_type));
                            v = double(raw) * dd.scale + dd.offset_value;
                        }
                    }
                    out.extra[static_cast<size_t>(d) * static_cast<size_t>(n) + static_cast<size_t>(i)] = float(v);
                }
            }
            out.extra_dim_count_ = desc_count;
        }

        out.point_count_ = n;
        return out;
    } catch (const std::exception&) {
        return ChunkData{};
    } catch (...) {
        return ChunkData{};
    }
}

void Reader::prefetch_nodes(const NodeKey* keys, int32_t count, int32_t slot) noexcept {
    if (!impl_ || impl_->closed) return;
    if (slot < 0 || static_cast<size_t>(slot) >= impl_->readers.size()) return;

    auto& cache = impl_->prefetch_cache[static_cast<size_t>(slot)];
    // Clear leftover blocks from a prior (possibly cancelled) cluster so per-slot
    // memory stays bounded to at most one cluster's span.
    cache.clear();
    if (keys == nullptr || count <= 0) return;

    const bool http = !impl_->streams.empty();
    const uint64_t gap = http ? kPrefetchGapHttp : kPrefetchGapLocal;

    try {
        ::copc::Reader* reader = impl_->readers[static_cast<size_t>(slot)].get();

        // Resolve each requested node's on-disk (offset, byte_size). FindNode is
        // an in-memory hierarchy lookup (same one read_node does), so this adds
        // no I/O. Skip nodes that aren't present or are empty.
        struct Blk { uint64_t key; uint64_t offset; uint64_t size; };
        std::vector<Blk> blks;
        blks.reserve(static_cast<size_t>(count));
        for (int32_t i = 0; i < count; ++i) {
            ::copc::VoxelKey vk(keys[i].depth, keys[i].x, keys[i].y, keys[i].z);
            ::copc::Node node = reader->FindNode(vk);
            if (!node.IsValid() || node.byte_size <= 0) continue;
            blks.push_back({ pack_node_key(keys[i].depth, keys[i].x, keys[i].y, keys[i].z),
                             node.offset, static_cast<uint64_t>(node.byte_size) });
        }
        if (blks.empty()) return;

        std::sort(blks.begin(), blks.end(),
                  [](const Blk& a, const Blk& b) { return a.offset < b.offset; });

        // Raw byte stream for this slot: local uses its dedicated ifstream; HTTP
        // reuses the slot's range istream (the same object copc-lib reads
        // through — safe because a slot is serviced by exactly one worker, so
        // prefetch and decode never interleave within a slot).
        std::istream* s = http
            ? impl_->streams[static_cast<size_t>(slot)].get()
            : impl_->prefetch_local_streams[static_cast<size_t>(slot)].get();
        if (!s) return;

        // Coalesce offset-adjacent blocks into spans (gap <= threshold), one
        // read per span, then slice each block out of the span into the cache.
        std::vector<char> span;
        size_t i = 0;
        while (i < blks.size()) {
            const uint64_t span_start = blks[i].offset;
            uint64_t span_end = blks[i].offset + blks[i].size;
            size_t j = i + 1;
            while (j < blks.size()) {
                const uint64_t next_off = blks[j].offset;
                // Sorted ascending, so next_off >= span_start. Gap is the gap
                // past the current span end; clamp overlap/adjacency to 0.
                const uint64_t g = (next_off > span_end) ? (next_off - span_end) : 0;
                if (g > gap) break;
                span_end = std::max(span_end, next_off + blks[j].size);
                ++j;
            }

            // One read for [span_start, span_end).
            const uint64_t span_len = span_end - span_start;
            span.resize(static_cast<size_t>(span_len));
            s->clear();
            s->seekg(static_cast<std::streamoff>(span_start), std::ios::beg);
            s->read(span.data(), static_cast<std::streamsize>(span_len));
            const uint64_t got = static_cast<uint64_t>(std::max<std::streamsize>(0, s->gcount()));
            s->clear();  // leave the stream usable for the next seek (prefetch or decode)

            // Slice each block out of the covered span into the cache. Any block
            // a short read didn't fully cover is skipped — read_node then falls
            // back to a direct read for it.
            for (size_t k = i; k < j; ++k) {
                const uint64_t rel = blks[k].offset - span_start;
                if (rel + blks[k].size > got) continue;
                cache.emplace(
                    blks[k].key,
                    std::vector<char>(span.begin() + static_cast<std::ptrdiff_t>(rel),
                                      span.begin() + static_cast<std::ptrdiff_t>(rel + blks[k].size)));
            }
            i = j;
        }
    } catch (const std::exception&) {
        cache.clear();
    } catch (...) {
        cache.clear();
    }
}

void Reader::close() noexcept {
    if (!impl_ || impl_->closed) return;
    impl_->closed = true;
    impl_->readers.clear();
    // Streams cleared after readers: an istream-backed Reader references its
    // stream by raw pointer, so the reader must go first.
    impl_->streams.clear();
    impl_->prefetch_local_streams.clear();
    impl_->prefetch_cache.clear();
    impl_->pool.clear();
    impl_->scratch.clear();
    impl_->nodes.clear();
}

void dump_node_size_histogram() noexcept {
    dump_histogram();
}

void dump_decode_profile() noexcept {
    dump_profile();
}

}} // namespace swiftpdal::copc

void swiftpdal_copc_reader_retain(swiftpdal::copc::Reader* r) noexcept {
    if (r) r->__retain();
}

void swiftpdal_copc_reader_release(swiftpdal::copc::Reader* r) noexcept {
    if (r) r->__release();
}
