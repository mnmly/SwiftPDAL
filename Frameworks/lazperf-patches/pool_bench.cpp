// Perf comparison: fresh-ctor-per-chunk vs reset-pooled decompressor.
// Mirrors a typical streaming workload — many distinct chunks decoded
// one after another. The pooled path keeps a single decompressor alive
// and calls reset() between chunks.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <random>
#include <vector>

#include <lazperf/lazperf.hpp>

constexpr size_t REC = 36; // format-7 record size

using clk = std::chrono::steady_clock;
static inline double sec(clk::duration d) { return std::chrono::duration<double>(d).count(); }

static void pack_point7(char *dst, int i, std::mt19937 &rng) {
    std::uniform_int_distribution<int> jitter(-50, 50);
    auto put32 = [&](int32_t v) { std::memcpy(dst, &v, 4); dst += 4; };
    auto put16 = [&](uint16_t v) { std::memcpy(dst, &v, 2); dst += 2; };
    auto put8  = [&](uint8_t  v) { *dst++ = (char)v; };
    auto putd  = [&](double   v) { std::memcpy(dst, &v, 8); dst += 8; };
    put32(i * 100 + jitter(rng));
    put32(i * 73  + jitter(rng));
    put32(i / 4   + jitter(rng));
    put16((uint16_t)((i * 7) & 0xFFF));
    put8((uint8_t)((i & 0x0F) | ((1 + (i & 3)) << 4)));
    put8((uint8_t)(0x02));
    put8((uint8_t)(i & 0x1F));
    put8((uint8_t)((i >> 3) & 0xFF));
    put16((uint16_t)((i & 0x7F) - 64));
    put16((uint16_t)(1));
    putd((double)i * 1e-3);
    put16((uint16_t)((i * 257) & 0xFFFF));
    put16((uint16_t)((i * 131) & 0xFFFF));
    put16((uint16_t)((i * 17)  & 0xFFFF));
}

static std::vector<unsigned char> compress_chunk(int n, std::mt19937 &rng) {
    std::vector<unsigned char> bytes;
    bytes.reserve(n * REC / 4);
    lazperf::OutputCb cb = [&](const unsigned char *p, size_t cnt) {
        bytes.insert(bytes.end(), p, p + cnt);
    };
    auto c = lazperf::build_las_compressor(cb, 7, 0);
    std::vector<char> raw(n * REC);
    for (int i = 0; i < n; ++i) pack_point7(raw.data() + i * REC, i, rng);
    for (int i = 0; i < n; ++i) c->compress(raw.data() + i * REC);
    c->done();
    return bytes;
}

int main(int argc, char** argv) {
    // Mean node size from real workload was 34,275 — pick that for the
    // dominant test, plus a smaller node case to bracket the win.
    int chunk_pts = (argc > 1) ? std::atoi(argv[1]) : 34275;
    int n_chunks  = (argc > 2) ? std::atoi(argv[2]) : 100;

    // Build n_chunks worth of distinct compressed chunks
    std::printf("Preparing %d chunks of %d points each...\n", n_chunks, chunk_pts);
    std::mt19937 rng(123);
    std::vector<std::vector<unsigned char>> chunks;
    chunks.reserve(n_chunks);
    for (int i = 0; i < n_chunks; ++i)
        chunks.push_back(compress_chunk(chunk_pts, rng));

    auto decode_fresh_one = [&](const std::vector<unsigned char>& bytes) {
        auto idx_p = std::make_shared<size_t>(0);
        lazperf::InputCb cb = [&bytes, idx_p](unsigned char *p, size_t cnt) {
            std::memcpy(p, bytes.data() + *idx_p, cnt);
            *idx_p += cnt;
        };
        auto d = lazperf::build_las_decompressor(cb, 7, 0);
        char buf[REC];
        for (int i = 0; i < chunk_pts; ++i) d->decompress(buf);
    };

    auto decode_pooled_one = [&](lazperf::las_decompressor& d,
                                 const std::vector<unsigned char>& bytes) {
        auto idx_p = std::make_shared<size_t>(0);
        lazperf::InputCb cb = [&bytes, idx_p](unsigned char *p, size_t cnt) {
            std::memcpy(p, bytes.data() + *idx_p, cnt);
            *idx_p += cnt;
        };
        d.reset(cb);
        char buf[REC];
        for (int i = 0; i < chunk_pts; ++i) d.decompress(buf);
    };

    // Warm-up
    for (int r = 0; r < 2; ++r) {
        for (auto& c : chunks) decode_fresh_one(c);
    }

    // --- Status-quo: fresh decompressor per chunk ---
    auto t0 = clk::now();
    int iters_a = 0;
    while (sec(clk::now() - t0) < 2.0) {
        for (auto& c : chunks) decode_fresh_one(c);
        ++iters_a;
    }
    double full_a = sec(clk::now() - t0);
    double per_a  = full_a / (iters_a * n_chunks);

    // --- Pooled: one decompressor, reset between chunks ---
    {
        auto first_idx_p = std::make_shared<size_t>(0);
        lazperf::InputCb dummy = [](unsigned char*, size_t){};
        auto pooled = lazperf::build_las_decompressor(dummy, 7, 0);

        auto t1 = clk::now();
        int iters_b = 0;
        while (sec(clk::now() - t1) < 2.0) {
            for (auto& c : chunks) decode_pooled_one(*pooled, c);
            ++iters_b;
        }
        double full_b = sec(clk::now() - t1);
        double per_b  = full_b / (iters_b * n_chunks);

        std::printf("\nWorkload: %d chunks x %d points (real-workload mean ~34275)\n", n_chunks, chunk_pts);
        std::printf("  status-quo (ctor each): %.3f ms/chunk  total=%.2fs  iters=%d\n", per_a*1e3, full_a, iters_a);
        std::printf("  pooled (reset)        : %.3f ms/chunk  total=%.2fs  iters=%d\n", per_b*1e3, full_b, iters_b);
        std::printf("  speedup               : %.2fx (saves %.3f ms/chunk = %.1f%%)\n",
                    per_a / per_b, (per_a - per_b)*1e3, 100.0*(1.0 - per_b/per_a));
    }
    return 0;
}
