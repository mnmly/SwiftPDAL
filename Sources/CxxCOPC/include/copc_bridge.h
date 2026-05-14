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
copc_handle swiftpdal_copc_open(const char* path);
void        swiftpdal_copc_close(copc_handle h);

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

int32_t swiftpdal_copc_read_node(
    copc_handle h,
    int32_t depth, int32_t x, int32_t y, int32_t z,
    copc_chunk_data* out
);

void swiftpdal_copc_free_chunk(copc_chunk_data* chunk);

#ifdef __cplusplus
}
#endif

#endif
