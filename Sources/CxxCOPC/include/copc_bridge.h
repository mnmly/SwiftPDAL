#ifndef SWIFTPDAL_COPC_BRIDGE_H
#define SWIFTPDAL_COPC_BRIDGE_H

#include <array>
#include <cstdint>
#include <string>
#include <vector>

#if __has_include(<swift/bridging>)
#include <swift/bridging>
#else
#define SWIFT_NONCOPYABLE
#define SWIFT_SHARED_REFERENCE(retain, release)
#endif

namespace swiftpdal { namespace copc {

// VoxelKey + node AABB (world coords) + LAZ block location + point count.
struct NodeInfo {
    int32_t depth = 0;
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    double  min_x = 0, min_y = 0, min_z = 0;
    double  max_x = 0, max_y = 0, max_z = 0;
    int32_t point_count = 0;
    uint64_t offset = 0;
    int32_t byte_size = 0;
};

// A COPC octree voxel key `(depth, x, y, z)`. Passed in bulk to
// Reader::prefetch_nodes to warm a slot's compressed-block cache with one
// coalesced read of offset-adjacent siblings.
struct NodeKey {
    int32_t depth = 0;
    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
};

// One custom "Extra Bytes" dimension declared in the file's Extra Bytes VLR.
// Filled by Reader::eb_field_at. `offset` is the byte offset of this field
// within a point's ExtraBytes() blob; `data_type` is the LAS Extra Bytes type
// code; `size` is the element byte size; `scale`/`offset_value` are applied
// (value = raw*scale + offset_value) when the VLR's option bits request it,
// else default to 1/0.
struct EbFieldInfo {
    char    name[32] = {0};   // null-padded UTF-8 (LAS EB names are <= 32 bytes)
    int32_t byte_offset = 0;
    int32_t data_type = 0;
    int32_t size = 0;
    double  scale = 1.0;
    double  offset_value = 0.0;
};

// A resolved request for one extra per-point scalar, built by the Swift layer
// from the file schema and passed to read_node. kind 0 = standard LAS accessor
// (use `code`); kind 1 = extra-bytes field (slice `size` bytes at `byte_offset`,
// interpret per `data_type`, then value = raw*scale + offset_value).
struct ExtractDesc {
    int32_t kind = 0;
    int32_t code = 0;
    int32_t byte_offset = 0;
    int32_t data_type = 0;
    int32_t size = 0;
    double  scale = 1.0;
    double  offset_value = 0.0;
};

// Decoded chunk: world-space doubles + 16-bit RGB (LAS convention).
//
// Owned by value; returned by-value from Reader::read_node. Marked
// SWIFT_NONCOPYABLE so Swift sees a `~Copyable` value — no surprise
// container copies of the underlying vectors when the chunk is passed
// through callsites.
class ChunkData {
public:
    ChunkData() = default;
    ChunkData(const ChunkData&) = delete;
    ChunkData& operator=(const ChunkData&) = delete;
    ChunkData(ChunkData&&) noexcept = default;
    ChunkData& operator=(ChunkData&&) noexcept = default;

    // Raw pointers for hot consumers (matches the existing
    // ChunkPacker.pack signature that wants UnsafePointer<Double>/UInt16).
    // Pointer is valid for the lifetime of this ChunkData.
    const double*   xyz_data() const { return xyz.data(); }
    const uint16_t* rgb_data() const { return rgb.data(); }
    // Optional per-point scalar dimensions, widened to float, laid out
    // dim-major: extra[d * point_count + i]. Empty unless read_node was
    // asked for extra dims (opt-in; never populated for the default path).
    const float*    extra_data() const { return extra.data(); }

    int32_t point_count() const { return point_count_; }
    bool    has_rgb() const     { return has_rgb_; }
    int32_t extra_dim_count() const { return extra_dim_count_; }

    // Public so the bridge impl can fill these directly; not intended for
    // Swift mutation (Swift only sees const accessors above).
    std::vector<double>   xyz;
    std::vector<uint16_t> rgb;
    std::vector<float>    extra;            // count * extra_dim_count_, dim-major
    int32_t point_count_ = 0;
    bool    has_rgb_     = false;
    int32_t extra_dim_count_ = 0;
} SWIFT_NONCOPYABLE;

class Reader;

// COPC reader + hierarchy snapshot + per-slot lazperf decompressor pool.
//
// Constructed via Reader::open. Behaves as a Swift reference type
// (automatic retain/release). The hierarchy and header are immutable
// after open(); read_node() is safe to call concurrently provided each
// concurrent caller targets a distinct slot in [0, pool_size).
class Reader {
public:
    // Returns nullptr on failure. pool_size must be >= 1.
    static Reader* open(const std::string& path, int32_t pool_size) noexcept;

    // Open a COPC file streamed over HTTP range requests, instead of from a
    // local path. `url` must be an http:// or https:// URL. Builds pool_size
    // independent HTTP-range-backed streams (one per slot, each with its own
    // read position) so read_node() keeps its lock-free per-slot contract.
    // Returns nullptr on failure (bad URL, network error, non-COPC, or a
    // server that doesn't support range requests). pool_size must be >= 1.
    static Reader* open_http(const std::string& url, int32_t pool_size) noexcept;

    int32_t pool_size() const noexcept;
    int64_t total_points() const noexcept;

    // Returns [min, max] world-space bounds as two 3-element arrays.
    std::array<double, 3> bounds_min() const noexcept;
    std::array<double, 3> bounds_max() const noexcept;

    int32_t node_count() const noexcept;

    // Returns true and fills `out` if index is valid; returns false
    // otherwise.
    bool node_at(int32_t index, NodeInfo& out) const noexcept;

    // LAS point format id of the open file (0..10), or -1 if closed. Drives
    // which standard per-point dimensions are present (Swift maps this to the
    // standard-dimension name set).
    int8_t point_format_id() const noexcept;

    // Count of custom Extra Bytes dimensions declared in the file's EB VLR.
    int32_t eb_field_count() const noexcept;

    // Fills `out` with the `index`-th Extra Bytes field's schema. Returns
    // false if index is out of range.
    bool eb_field_at(int32_t index, EbFieldInfo& out) const noexcept;

    // Decode the node at (depth, x, y, z) using FileReader slot `slot`.
    // Returns an empty ChunkData (point_count() == 0) on failure or if
    // the node is not present in the hierarchy. When `desc_count > 0`,
    // additionally extracts the requested per-point scalars (widened to
    // float, dim-major) into ChunkData::extra. `descs == nullptr` /
    // `desc_count == 0` ⇒ the original position+color-only path, verbatim.
    ChunkData read_node(int32_t depth, int32_t x, int32_t y, int32_t z,
                        int32_t slot,
                        const ExtractDesc* descs, int32_t desc_count) noexcept;

    // Warm slot `slot`'s compressed-block cache for the given nodes. COPC
    // stores sibling nodes contiguously, so a camera move wanting several
    // adjacent nodes can pay one span read instead of one seek / round-trip
    // per node. Resolves each key's (offset, byte_size), sorts by offset,
    // coalesces offset-adjacent blocks into groups (gap <= a local/HTTP
    // threshold), issues one read per group, and slices the span into the
    // per-slot cache. A subsequent read_node on the same slot pops its block
    // from the cache (single-use) instead of reading directly. The cache is
    // cleared on entry, so a cancelled cluster's leftover blocks can't
    // accumulate. Reads I/O only — the caller runs it outside the decode gate.
    //
    // No-op behavior is preserved: read_node without a prior prefetch (or on a
    // cache miss) reads directly, exactly as before. Uses the same per-slot
    // isolation contract as read_node — each concurrent caller must target a
    // distinct slot in [0, pool_size).
    void prefetch_nodes(const NodeKey* keys, int32_t count, int32_t slot) noexcept;

    // Drop the underlying file readers + caches. Subsequent calls become
    // no-ops returning failure / zero. Idempotent. The Reader itself
    // stays alive until the last reference releases.
    void close() noexcept;

    // Internal — used by Reader_retain/release. Public for the
    // SWIFT_SHARED_REFERENCE-generated glue.
    void __retain() noexcept;
    void __release() noexcept;

private:
    Reader() = default;
    ~Reader();

    struct Impl;
    Impl* impl_ = nullptr;
} SWIFT_SHARED_REFERENCE(swiftpdal_copc_reader_retain, swiftpdal_copc_reader_release);

// Optional explicit dump of the node-size histogram (also registered via
// atexit when SWIFTPDAL_NODE_HISTOGRAM=1). Safe to call any time.
void dump_node_size_histogram() noexcept;

}} // namespace swiftpdal::copc

// Free functions implementing the SWIFT_SHARED_REFERENCE retain/release
// contract. The SWIFT_SHARED_REFERENCE macro resolves these by unqualified
// name from global scope, so they cannot live inside the namespace. They
// still have C++ linkage (no extern "C") because they take a C++ type by
// pointer.
void swiftpdal_copc_reader_retain(swiftpdal::copc::Reader* r) noexcept;
void swiftpdal_copc_reader_release(swiftpdal::copc::Reader* r) noexcept;

#endif
