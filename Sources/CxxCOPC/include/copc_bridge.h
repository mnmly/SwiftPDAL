#ifndef SWIFTPDAL_COPC_BRIDGE_H
#define SWIFTPDAL_COPC_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle wrapping copc::FileReader + hierarchy snapshot.
typedef struct copc_handle_s* copc_handle;

// Node metadata: VoxelKey + node AABB (world coords) + LAZ block location + point count.
typedef struct {
    int32_t depth;
    int32_t x;
    int32_t y;
    int32_t z;
    double min_x, min_y, min_z;
    double max_x, max_y, max_z;
    int32_t point_count;
    uint64_t offset;
    int32_t byte_size;
} copc_node_info;

// All functions return 0 on success, negative on error.
// On error, swiftpdal_copc_open returns NULL.
//
// pool_size: number of independent FileReader instances opened against
// the same path. Each reader owns its own fstream; concurrent
// swiftpdal_copc_read_node calls are safe provided each call targets a
// distinct slot in [0, pool_size). Must be >= 1.
copc_handle swiftpdal_copc_open(const char* path, int32_t pool_size);
void        swiftpdal_copc_close(copc_handle h);

int32_t swiftpdal_copc_pool_size(copc_handle h, int32_t* out);

int32_t swiftpdal_copc_total_points(copc_handle h, int64_t* out);
int32_t swiftpdal_copc_bounds(copc_handle h, double* out_min_xyz, double* out_max_xyz);
int32_t swiftpdal_copc_node_count(copc_handle h, int32_t* out);
int32_t swiftpdal_copc_node_at(copc_handle h, int32_t index, copc_node_info* out);

// Decoded chunk: world-space doubles + 16-bit RGB (LAS convention).
// Output buffers are malloc'd by the bridge and MUST be released by the
// caller via swiftpdal_copc_free_chunk. has_rgb == 0 means rgb is filled
// with zeros (point format has no RGB channel).
typedef struct {
    double*   xyz;          // length = 3 * point_count
    uint16_t* rgb;          // length = 3 * point_count
    int32_t   point_count;
    int32_t   has_rgb;
} copc_chunk_data;

// slot selects which FileReader in the pool services this call. Caller
// must ensure no two concurrent invocations share a slot on the same
// handle. Valid range: [0, pool_size).
int32_t swiftpdal_copc_read_node(
    copc_handle h,
    int32_t depth, int32_t x, int32_t y, int32_t z,
    int32_t slot,
    copc_chunk_data* out
);

void swiftpdal_copc_free_chunk(copc_chunk_data* chunk);

#ifdef __cplusplus
}
#endif

#endif
