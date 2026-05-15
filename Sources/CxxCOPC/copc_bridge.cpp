#include "copc_bridge.h"

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

#include <memory>
#include <string>
#include <vector>
#include <exception>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <cstdio>

// --- Node-size histogram ---------------------------------------------------
// Bins observed points-per-node in log2 buckets. Dumps to stderr on process
// exit. Lock-free; safe across the decoder thread pool.
//
// Disabled by default. Enable by setting SWIFTPDAL_NODE_HISTOGRAM=1 in the
// environment before launching the host process. The explicit
// swiftpdal_copc_dump_node_size_histogram() entry point always works, even
// without the env var, but will print only what was recorded since the
// env was last observed.
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

    static bool histogram_enabled() {
        int s = g_enabled_cached.load(std::memory_order_acquire);
        if (s) return s == 1;
        const char* v = std::getenv("SWIFTPDAL_NODE_HISTOGRAM");
        bool on = v && v[0] && !(v[0] == '0' && v[1] == 0);
        int expected = 0;
        g_enabled_cached.compare_exchange_strong(expected, on ? 1 : 2);
        return on;
    }

    static inline int log2_bucket(uint64_t n) {
        if (n == 0) return 0;
        int b = 0;
        while ((n >>= 1) && b + 1 < kHistBuckets) ++b;
        return b;
    }

    static void dump_histogram() {
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

    static inline void record_node_size(uint64_t n) {
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

extern "C" void swiftpdal_copc_dump_node_size_histogram(void) {
    dump_histogram();
}
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

struct copc_handle_s {
    std::vector<std::unique_ptr<copc::FileReader>> readers;
    std::vector<PooledDecompressor> pool;   // parallel to `readers`
    std::vector<std::vector<char>> scratch; // reusable decompressed-bytes buffer per slot
    std::vector<copc::Node> nodes;
    copc::las::LasHeader header;
};

extern "C" copc_handle swiftpdal_copc_open(const char* path, int32_t pool_size) {
    if (!path || pool_size < 1) return nullptr;
    try {
        auto h = new copc_handle_s();
        h->readers.reserve(static_cast<size_t>(pool_size));
        h->pool.resize(static_cast<size_t>(pool_size));
        h->scratch.resize(static_cast<size_t>(pool_size));
        for (int32_t i = 0; i < pool_size; ++i) {
            h->readers.emplace_back(std::make_unique<copc::FileReader>(std::string(path)));
        }
        h->nodes  = h->readers[0]->GetAllNodes();
        h->header = h->readers[0]->CopcConfig().LasHeader();
        return h;
    } catch (const std::exception&) {
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

extern "C" void swiftpdal_copc_close(copc_handle h) {
    if (!h) return;
    h->readers.clear();
    delete h;
}

extern "C" int32_t swiftpdal_copc_pool_size(copc_handle h, int32_t* out) {
    if (!h || !out) return -1;
    *out = static_cast<int32_t>(h->readers.size());
    return 0;
}

extern "C" int32_t swiftpdal_copc_total_points(copc_handle h, int64_t* out) {
    if (!h || !out) return -1;
    int64_t total = 0;
    for (const auto& n : h->nodes) total += n.point_count;
    *out = total;
    return 0;
}

extern "C" int32_t swiftpdal_copc_bounds(copc_handle h, double* out_min, double* out_max) {
    if (!h || !out_min || !out_max) return -1;
    out_min[0] = h->header.min.x;
    out_min[1] = h->header.min.y;
    out_min[2] = h->header.min.z;
    out_max[0] = h->header.max.x;
    out_max[1] = h->header.max.y;
    out_max[2] = h->header.max.z;
    return 0;
}

extern "C" int32_t swiftpdal_copc_node_count(copc_handle h, int32_t* out) {
    if (!h || !out) return -1;
    *out = static_cast<int32_t>(h->nodes.size());
    return 0;
}

extern "C" int32_t swiftpdal_copc_node_at(copc_handle h, int32_t index, copc_node_info* out) {
    if (!h || !out) return -1;
    if (index < 0 || static_cast<size_t>(index) >= h->nodes.size()) return -2;
    const auto& n = h->nodes[index];
    out->depth = n.key.d;
    out->x = n.key.x;
    out->y = n.key.y;
    out->z = n.key.z;
    out->point_count = n.point_count;
    out->offset = n.offset;
    out->byte_size = n.byte_size;

    try {
        copc::Box box(n.key, h->header);
        out->min_x = box.x_min;
        out->min_y = box.y_min;
        out->min_z = box.z_min;
        out->max_x = box.x_max;
        out->max_y = box.y_max;
        out->max_z = box.z_max;
    } catch (...) {
        return -3;
    }
    return 0;
}

extern "C" int32_t swiftpdal_copc_read_node(
    copc_handle h,
    int32_t depth, int32_t x, int32_t y, int32_t z,
    int32_t slot,
    copc_chunk_data* out
) {
    if (!h || !out) return -1;
    if (slot < 0 || static_cast<size_t>(slot) >= h->readers.size()) return -1;
    out->xyz = nullptr;
    out->rgb = nullptr;
    out->point_count = 0;
    out->has_rgb = 0;

    copc::FileReader* reader = h->readers[static_cast<size_t>(slot)].get();

    try {
        copc::VoxelKey key(depth, x, y, z);
        copc::Node node = reader->FindNode(key);
        if (!node.IsValid()) return -2;

        // Pooled decode path. Replaces reader->GetPoints(node), which would
        // build a fresh lazperf decompressor per call. See PooledDecompressor
        // above + Frameworks/lazperf-patches/.
        const int8_t fmt = h->header.PointFormatId();
        const uint16_t eb = h->header.EbByteSize();
        const uint16_t point_size = copc::las::PointByteSize(fmt, eb);

        std::vector<char> compressed = reader->GetPointDataCompressed(node);
        h->pool[static_cast<size_t>(slot)].decode(
            compressed, node.point_count, fmt, eb, point_size,
            h->scratch[static_cast<size_t>(slot)]);
        copc::las::Points points = copc::las::Points::Unpack(
            h->scratch[static_cast<size_t>(slot)], h->header);

        const int32_t n = static_cast<int32_t>(points.Size());
        if (n <= 0) return -3;
        record_node_size(static_cast<uint64_t>(n));

        double*   xyz = static_cast<double*>(std::malloc(sizeof(double) * 3 * n));
        uint16_t* rgb = static_cast<uint16_t*>(std::malloc(sizeof(uint16_t) * 3 * n));
        if (!xyz || !rgb) {
            std::free(xyz);
            std::free(rgb);
            return -4;
        }

        const std::vector<double> xs = points.X();
        const std::vector<double> ys = points.Y();
        const std::vector<double> zs = points.Z();
        for (int32_t i = 0; i < n; ++i) {
            xyz[3*i+0] = xs[i];
            xyz[3*i+1] = ys[i];
            xyz[3*i+2] = zs[i];
        }

        const bool hasRgb = copc::las::FormatHasRgb(static_cast<uint8_t>(h->header.PointFormatId()));
        if (hasRgb) {
            const std::vector<uint16_t> r = points.Red();
            const std::vector<uint16_t> g = points.Green();
            const std::vector<uint16_t> b = points.Blue();
            for (int32_t i = 0; i < n; ++i) {
                rgb[3*i+0] = r[i];
                rgb[3*i+1] = g[i];
                rgb[3*i+2] = b[i];
            }
            out->has_rgb = 1;
        } else {
            std::memset(rgb, 0, sizeof(uint16_t) * 3 * n);
            out->has_rgb = 0;
        }

        out->xyz = xyz;
        out->rgb = rgb;
        out->point_count = n;
        return 0;
    } catch (const std::exception&) {
        return -5;
    } catch (...) {
        return -5;
    }
}

extern "C" void swiftpdal_copc_free_chunk(copc_chunk_data* chunk) {
    if (!chunk) return;
    std::free(chunk->xyz);
    std::free(chunk->rgb);
    chunk->xyz = nullptr;
    chunk->rgb = nullptr;
    chunk->point_count = 0;
    chunk->has_rgb = 0;
}
