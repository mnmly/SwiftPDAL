// In-memory point filter → writer bridge.
//
// SwiftPDAL's convert path is strictly file→file; there is no public way
// to read a cloud, decide per-point whether to keep it in Swift, and
// write only the survivors while preserving every dimension. This bridge
// fills that gap with a three-step, view-resident flow (same
// BufferReader→writer shape as pdal_e57_convert.cpp):
//
//   1) fw_open       — read every point of a file into a resident
//                      PointView (all dims) and materialize interleaved
//                      world-space XYZ doubles for the caller to test.
//   2) fw_xyz        — borrow that interleaved XYZ buffer (count*3
//                      doubles) so Swift can run an arbitrary geometric
//                      test (e.g. point-in-mesh) at full double precision.
//   3) fw_write_masked — append the kept points (mask[i] != 0) into a new
//                      view — copying ALL dimensions, not just XYZ — and
//                      run it through a writer stage (default writers.copc),
//                      forwarding the source LAS scale/offset so the output
//                      keeps the original coordinate quantization.
//
// Follows the cxx-interop conventions used elsewhere in CxxPDAL: no
// extern "C", std::string at the boundary, errors surfaced via a
// returned struct, opaque handle as void*.

#ifndef SWIFTPDAL_PDAL_BOOLEAN_H
#define SWIFTPDAL_PDAL_BOOLEAN_H

#include <cstdint>
#include <string>

namespace swiftpdal { namespace boolean_filter {

struct OpenResult {
    int32_t     status        = 0;   // 0 ok, negative on failure
    uint64_t    point_count   = 0;   // points loaded into the view
    std::string error_message;
    void*       handle        = nullptr;  // opaque FilterContext*, or null on failure
};

struct WriteResult {
    int32_t     status        = 0;
    uint64_t    point_count   = 0;   // points actually written (kept)
    std::string error_message;
};

/// Read every point of `input_path` into a resident PointView using
/// `reader_type` (empty ⇒ "readers.copc"). On success `handle` owns the
/// view/table until `fw_free`; `point_count` is the number of points read.
OpenResult fw_open(const std::string& input_path,
                   const std::string& reader_type) noexcept;

/// Borrow the interleaved world-space XYZ buffer (X0,Y0,Z0,X1,…), length
/// `point_count * 3` doubles. Valid until `fw_free`. Returns null for a
/// null/empty handle.
const double* fw_xyz(void* handle) noexcept;

/// Append points where `keep[i] != 0` (for i in 0..<keep_count, clamped to
/// the loaded count) into a new view — copying every dimension — and write
/// it to `output_path` via `writer_type` (empty ⇒ "writers.copc").
/// `writer_options_kv` is newline-separated `key=value` lines; `filename`
/// is injected automatically. The source scale/offset are forwarded unless
/// overridden here.
WriteResult fw_write_masked(void*              handle,
                            const uint8_t*     keep,
                            uint64_t           keep_count,
                            const std::string& output_path,
                            const std::string& writer_type,
                            const std::string& writer_options_kv) noexcept;

/// Release the resident view/table. Safe on a null handle.
void fw_free(void* handle) noexcept;

}} // namespace swiftpdal::boolean_filter

#endif // SWIFTPDAL_PDAL_BOOLEAN_H
