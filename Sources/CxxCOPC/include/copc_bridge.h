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

    int32_t point_count() const { return point_count_; }
    bool    has_rgb() const     { return has_rgb_; }

    // Public so the bridge impl can fill these directly; not intended for
    // Swift mutation (Swift only sees const accessors above).
    std::vector<double>   xyz;
    std::vector<uint16_t> rgb;
    int32_t point_count_ = 0;
    bool    has_rgb_     = false;
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

    int32_t pool_size() const noexcept;
    int64_t total_points() const noexcept;

    // Returns [min, max] world-space bounds as two 3-element arrays.
    std::array<double, 3> bounds_min() const noexcept;
    std::array<double, 3> bounds_max() const noexcept;

    int32_t node_count() const noexcept;

    // Returns true and fills `out` if index is valid; returns false
    // otherwise.
    bool node_at(int32_t index, NodeInfo& out) const noexcept;

    // Decode the node at (depth, x, y, z) using FileReader slot `slot`.
    // Returns an empty ChunkData (point_count() == 0) on failure or if
    // the node is not present in the hierarchy.
    ChunkData read_node(int32_t depth, int32_t x, int32_t y, int32_t z,
                        int32_t slot) noexcept;

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
