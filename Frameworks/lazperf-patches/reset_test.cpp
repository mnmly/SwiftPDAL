// Correctness test for the lazperf reset() API.
// Compresses several distinct synthetic chunks, then decompresses each one
// twice: once with a freshly-constructed decompressor (baseline) and once
// against a single decompressor that's reset() between chunks. The two
// outputs must be byte-identical.

#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
#include <vector>

#include <lazperf/lazperf.hpp>

constexpr size_t REC = 36; // format-7 point byte size

static void pack_point7(char *dst, int i, uint32_t seed) {
    std::mt19937 rng(seed + i);
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
    putd((double)i * 1e-3 + (double)seed);
    put16((uint16_t)(((i + seed) * 257) & 0xFFFF));
    put16((uint16_t)(((i + seed) * 131) & 0xFFFF));
    put16((uint16_t)(((i + seed) * 17)  & 0xFFFF));
}

// Compress N synthetic points using `seed` to produce a unique chunk.
static std::vector<unsigned char> make_compressed(int n, uint32_t seed) {
    std::vector<unsigned char> bytes;
    bytes.reserve(n * REC / 4);
    lazperf::OutputCb cb = [&](const unsigned char *p, size_t cnt) {
        bytes.insert(bytes.end(), p, p + cnt);
    };
    auto c = lazperf::build_las_compressor(cb, /*fmt=*/7, /*eb=*/0);
    std::vector<char> raw(n * REC);
    for (int i = 0; i < n; ++i)
        pack_point7(raw.data() + i * REC, i, seed);
    for (int i = 0; i < n; ++i)
        c->compress(raw.data() + i * REC);
    c->done();
    return bytes;
}

// Decompress `n` points from `compressed` into a flat byte vector.
template <class Decomp>
static std::vector<char> decompress_into(Decomp& d, int n,
                                         const std::vector<unsigned char>& compressed) {
    size_t idx = 0;
    // The InputCb is stateful (captures idx). When we hand a fresh callback
    // through reset(), the new closure resets idx implicitly.
    // (For fresh-ctor calls we just construct a new decompressor.)
    lazperf::InputCb cb = [&compressed, idx_p = std::make_shared<size_t>(0)](unsigned char *p, size_t cnt) mutable {
        std::memcpy(p, compressed.data() + *idx_p, cnt);
        *idx_p += cnt;
    };
    d.reset(cb);
    std::vector<char> out(n * REC);
    char buf[REC];
    for (int i = 0; i < n; ++i) {
        d.decompress(buf);
        std::memcpy(out.data() + i * REC, buf, REC);
    }
    return out;
}

static std::vector<char> decompress_fresh(int n, const std::vector<unsigned char>& compressed) {
    size_t idx = 0;
    lazperf::InputCb cb = [&](unsigned char *p, size_t cnt) {
        std::memcpy(p, compressed.data() + idx, cnt);
        idx += cnt;
    };
    auto d = lazperf::build_las_decompressor(cb, 7, 0);
    std::vector<char> out(n * REC);
    char buf[REC];
    for (int i = 0; i < n; ++i) {
        d->decompress(buf);
        std::memcpy(out.data() + i * REC, buf, REC);
    }
    return out;
}

// Decompress using an existing decompressor that's been reset to a fresh
// input callback bound to `compressed`.
static std::vector<char> decompress_reused(lazperf::las_decompressor& d, int n,
                                           const std::vector<unsigned char>& compressed) {
    auto idx_p = std::make_shared<size_t>(0);
    lazperf::InputCb cb = [&compressed, idx_p](unsigned char *p, size_t cnt) {
        std::memcpy(p, compressed.data() + *idx_p, cnt);
        *idx_p += cnt;
    };
    d.reset(cb);
    std::vector<char> out(n * REC);
    char buf[REC];
    for (int i = 0; i < n; ++i) {
        d.decompress(buf);
        std::memcpy(out.data() + i * REC, buf, REC);
    }
    return out;
}

int main() {
    constexpr int N = 5000;

    // Build three distinct chunks
    std::vector<std::vector<unsigned char>> chunks;
    for (uint32_t seed : {1u, 42u, 0xC0FFEEu})
        chunks.push_back(make_compressed(N, seed));

    // Fresh-ctor baselines
    std::vector<std::vector<char>> baselines;
    for (auto& c : chunks)
        baselines.push_back(decompress_fresh(N, c));

    // Now: build ONE decompressor and reuse it across all three chunks
    // (with reset() between each). Compare each output to the matching
    // baseline.
    size_t init_idx = 0;
    lazperf::InputCb dummy = [&](unsigned char *, size_t) { /* placeholder */ };
    // The first decompressor needs a real callback bound; we'll reset
    // before using.
    auto reused = lazperf::build_las_decompressor(dummy, 7, 0);

    int failures = 0;
    for (size_t k = 0; k < chunks.size(); ++k) {
        auto out = decompress_reused(*reused, N, chunks[k]);
        if (out != baselines[k]) {
            std::printf("FAIL chunk %zu: reused output differs from fresh-ctor baseline\n", k);
            // print first divergence
            for (size_t b = 0; b < out.size(); ++b) {
                if (out[b] != baselines[k][b]) {
                    std::printf("  first diff at byte %zu (point %zu, offset %zu): got 0x%02x, want 0x%02x\n",
                                b, b / REC, b % REC,
                                (unsigned)(uint8_t)out[b], (unsigned)(uint8_t)baselines[k][b]);
                    break;
                }
            }
            ++failures;
        } else {
            std::printf("OK   chunk %zu: %d points match baseline exactly\n", k, N);
        }
    }

    // Bonus: replay chunk 0 again after chunk 2, to exercise a longer reset chain
    auto replay = decompress_reused(*reused, N, chunks[0]);
    if (replay != baselines[0]) {
        std::printf("FAIL replay: reused after 3 resets diverges from baseline 0\n");
        ++failures;
    } else {
        std::printf("OK   replay: chunk 0 still matches after 3 resets\n");
    }

    if (failures) {
        std::printf("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    std::printf("\nAll OK.\n");
    return 0;
}
