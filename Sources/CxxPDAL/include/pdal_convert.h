//
//  pdal_convert.h
//  SwiftPDAL
//
//  Namespaced C++ bridge for `pdal convert`-style pipelines.
//  Follows the cxx-interop conventions used by CxxCOPC: no extern "C",
//  std::string at the boundary, errors surfaced via a returned struct.
//

#ifndef SWIFTPDAL_PDAL_CONVERT_H
#define SWIFTPDAL_PDAL_CONVERT_H

#include <cstdint>
#include <string>

namespace swiftpdal { namespace convert {

/// Returned in ``Result::status`` when a progress callback returned
/// false to request cancellation.
constexpr int32_t kCancelled = -11;

/// Progress callback signature.
///
/// - Parameters:
///   - points_so_far: Cumulative points processed (writer-side).
///   - estimated_total: Reader's preview count when available, else 0.
///   - ctx: Opaque context pointer passed to ``execute_pipeline_json``.
/// - Returns: `true` to continue, `false` to cancel.
using ProgressFn = bool (*)(uint64_t points_so_far,
                            uint64_t estimated_total,
                            void* ctx);

/// Outcome of a single ``execute_pipeline_json`` call.
struct Result {
    /// 0 on success, negative on failure (mirrors ``PDALError`` raw values).
    int32_t status = 0;
    /// Total points written across all output views. 0 when streaming
    /// without a final point view (PDAL doesn't track this in stream mode).
    uint64_t point_count = 0;
    /// Pipeline metadata as a JSON string (empty on failure).
    std::string metadata_json;
    /// Point layout as a JSON array of `{"name","size","type"}` objects,
    /// where `type` is one of `"signed"`, `"unsigned"`, `"floating"`
    /// (the STAC pointcloud-extension `pc:schemas` vocabulary). Empty
    /// when the layout could not be captured. Serialized from the
    /// finalized layout after execution — the metadata JSON carries
    /// per-dimension statistics but not dimension sizes/types.
    std::string schema_json;
    /// Human-readable error detail (empty on success).
    std::string error_message;
};

/// Execute a PDAL pipeline expressed as a JSON string.
///
/// - Parameters:
///   - json: PDAL pipeline JSON (the same format accepted by
///     ``PipelineManager::readPipeline``).
///   - streaming: If true, the pipeline is executed in streaming mode
///     when every stage supports it; otherwise it falls back to
///     whole-file execution.
///   - chunk_size: Streaming point-table capacity. Ignored when
///     ``streaming`` is false. Values < 1 are clamped to 10000.
/// Execute a PDAL pipeline expressed as a JSON string.
///
/// Pass `nullptr` for ``progress`` to skip progress reporting. When
/// supplied, the callback fires:
///   * after each streaming chunk in streaming mode, with the
///     cumulative writer-side point count,
///   * exactly once in whole-file mode, with the final total.
Result execute_pipeline_json(const std::string& json,
                             bool streaming,
                             int32_t chunk_size,
                             ProgressFn progress,
                             void* progress_ctx) noexcept;

/// True if ``name`` resolves to a registered PDAL stage driver
/// (e.g. ``"writers.copc"``). Useful for probing whether the linked
/// pdalcpp build includes a particular reader/writer/filter.
bool driver_is_registered(const std::string& name) noexcept;

}} // namespace swiftpdal::convert

#endif // SWIFTPDAL_PDAL_CONVERT_H
