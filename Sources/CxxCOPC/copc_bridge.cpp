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

#include <lazperf/lazperf.hpp>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
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
        char buf[256]; // any LAS point record fits
        for (int i = 0; i < point_count; ++i) {
            decomp_->decompress(buf);
            std::memcpy(out_bytes.data() + static_cast<size_t>(i) * point_size, buf, point_size);
        }
    }

private:
    lazperf::las_decompressor::ptr decomp_;
    int8_t cached_format_ = -1;
    uint16_t cached_eb_ = 0;
};
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
    std::vector<::copc::Node> nodes;
    ::copc::las::LasHeader header;
    bool closed = false;
};

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
        for (int32_t i = 0; i < pool_size; ++i) {
            r->impl_->readers.emplace_back(std::make_unique<::copc::FileReader>(path));
        }
        r->impl_->nodes  = r->impl_->readers[0]->GetAllNodes();
        r->impl_->header = r->impl_->readers[0]->CopcConfig().LasHeader();
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

ChunkData Reader::read_node(int32_t depth, int32_t x, int32_t y, int32_t z,
                            int32_t slot) noexcept {
    ChunkData out;
    if (impl_->closed) return out;
    if (slot < 0 || static_cast<size_t>(slot) >= impl_->readers.size()) return out;

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

        std::vector<char> compressed = reader->GetPointDataCompressed(node);
        impl_->pool[static_cast<size_t>(slot)].decode(
            compressed, node.point_count, fmt, eb, point_size,
            impl_->scratch[static_cast<size_t>(slot)]);
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
        out.point_count_ = n;
        return out;
    } catch (const std::exception&) {
        return ChunkData{};
    } catch (...) {
        return ChunkData{};
    }
}

void Reader::close() noexcept {
    if (!impl_ || impl_->closed) return;
    impl_->closed = true;
    impl_->readers.clear();
    // Streams cleared after readers: an istream-backed Reader references its
    // stream by raw pointer, so the reader must go first.
    impl_->streams.clear();
    impl_->pool.clear();
    impl_->scratch.clear();
    impl_->nodes.clear();
}

void dump_node_size_histogram() noexcept {
    dump_histogram();
}

}} // namespace swiftpdal::copc

void swiftpdal_copc_reader_retain(swiftpdal::copc::Reader* r) noexcept {
    if (r) r->__retain();
}

void swiftpdal_copc_reader_release(swiftpdal::copc::Reader* r) noexcept {
    if (r) r->__release();
}
