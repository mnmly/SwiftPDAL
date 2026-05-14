#include "copc_bridge.h"

#include <copc-lib/io/copc_reader.hpp>
#include <copc-lib/hierarchy/node.hpp>
#include <copc-lib/hierarchy/key.hpp>
#include <copc-lib/las/header.hpp>
#include <copc-lib/geometry/box.hpp>
#include <copc-lib/geometry/vector3.hpp>

#include <copc-lib/las/point.hpp>
#include <copc-lib/las/points.hpp>

#include <memory>
#include <string>
#include <vector>
#include <exception>
#include <cstdlib>
#include <cstring>

struct copc_handle_s {
    std::unique_ptr<copc::FileReader> reader;
    std::vector<copc::Node> nodes;
    copc::las::LasHeader header;
};

extern "C" copc_handle swiftpdal_copc_open(const char* path) {
    try {
        auto h = new copc_handle_s();
        h->reader = std::make_unique<copc::FileReader>(std::string(path));
        h->nodes  = h->reader->GetAllNodes();
        h->header = h->reader->CopcConfig().LasHeader();
        return h;
    } catch (const std::exception&) {
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

extern "C" void swiftpdal_copc_close(copc_handle h) {
    if (!h) return;
    h->reader.reset();
    delete h;
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
    copc_chunk_data* out
) {
    if (!h || !out) return -1;
    out->xyz = nullptr;
    out->rgb = nullptr;
    out->point_count = 0;
    out->has_rgb = 0;

    try {
        copc::VoxelKey key(depth, x, y, z);
        copc::Node node = h->reader->FindNode(key);
        if (!node.IsValid()) return -2;

        copc::las::Points points = h->reader->GetPoints(node);
        const int32_t n = static_cast<int32_t>(points.Size());
        if (n <= 0) return -3;

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
