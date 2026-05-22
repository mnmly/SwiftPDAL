// libE57Format → COPC bridge.
//
// PDAL's `readers.e57` bridge to libE57Format has a known defect that
// throws "E57 exception" partway through certain multi-scan files (see
// notes in pdal_e57_convert.cpp). The same files read cleanly when we
// call libE57Format directly. This module replaces PDAL's reader with a
// libE57Format read loop that feeds points into a `pdal::PointView`
// backed by a long-lived `PointTable`, then runs
// `BufferReader → writers.copc` (or whatever writer the caller picks)
// over the captured data — same two-pass shape as `pdal_convert.cpp`.

#pragma once

#include <cstdint>
#include <string>

namespace swiftpdal { namespace convert {

// Re-declared here (rather than reaching into pdal_convert.h) so this
// header stays standalone — Swift's Cxx interop imports each header
// independently.
using ProgressFn = bool(*)(uint64_t pointsSoFar, uint64_t estimatedTotal, void* ctx);

struct E57Result {
    int32_t     status         = 0;  // mirrors pdal_convert::Result.status
    uint64_t    point_count    = 0;
    std::string metadata_json;       // empty for E57 path (no PDAL metadata)
    std::string error_message;
};

// Convert an E57 file at `input_path` to `output_path` using
// libE57Format for the read and a writer stage (default
// `writers.copc`) for the write.
//
// `writer_type` is the PDAL driver name (e.g. `"writers.copc"`); pass
// an empty string to default. `writer_options_kv` is a newline-
// separated list of `key=value` lines (e.g. `"forward=all\n"`); pass
// an empty string for no extra options. `filename` is added
// automatically — don't put it in `writer_options_kv`.
//
// We use this flat string format instead of JSON because PDAL doesn't
// expose its bundled nlohmann::json in public headers, and dragging a
// JSON dependency into CxxPDAL just to parse a handful of options
// isn't worth it.
//
// `progress` is invoked from this thread during the libE57Format read
// loop (per chunk), and from the writer-side progress-fd pump thread
// during the COPC build. Same cancellation contract as
// `execute_pipeline_json`.
E57Result execute_e57_to_copc(const std::string& input_path,
                              const std::string& output_path,
                              const std::string& writer_type,
                              const std::string& writer_options_kv,
                              int32_t            chunk_size,
                              ProgressFn         progress,
                              void*              progress_ctx) noexcept;

}} // namespace swiftpdal::convert
