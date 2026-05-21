//
//  pdal_convert.cpp
//  SwiftPDAL
//
//  Implementation note: PDAL headers are included BEFORE the local
//  `pdal_convert.h` to keep the textual-include path consistent with
//  `pdal_wrapper.cpp`. Mixing module-imported and textually-included
//  copies of headers like pdal/util/NullOStream.hpp tickles a clang
//  `#pragma once` + module dedup bug that surfaces as `redefinition
//  of 'NullStreambuf'`. Keeping the includes in this order avoids it.
//

#include <pdal/PipelineManager.hpp>
#include <pdal/PipelineWriter.hpp>
#include <pdal/PDALUtils.hpp>
#include <pdal/StageFactory.hpp>
#include <pdal/PointTable.hpp>
#include <pdal/PointView.hpp>
#include <pdal/Stage.hpp>
#include <pdal/QuickInfo.hpp>
#include <sstream>
#include <exception>

#include "include/pdal_convert.h"

// PDAL_OK / PDAL_ERR_* are defined as plain ints in pdal_wrapper.h.
// Re-declare just the ones we need here to avoid pulling pdal_wrapper.h
// (and its full PDAL header chain) into this translation unit twice via
// both module-import and textual-include paths.
namespace {
constexpr int32_t kPdalOk            = 0;
constexpr int32_t kPdalErrPdal       = -2;
constexpr int32_t kPdalErrStdExcept  = -3;
constexpr int32_t kPdalErrUnknown    = -6;
}

namespace swiftpdal { namespace convert {

namespace {

// Thrown from the progress hook when the Swift callback returns false.
// Caught by execute_pipeline_json and translated to kCancelled.
struct CancelledByCaller : public std::exception {
    const char* what() const noexcept override { return "cancelled by caller"; }
};

// FixedPointTable subclass that fires `progress` at every chunk
// boundary with the cumulative point count processed so far.
//
// PDAL drives streaming execution by repeatedly filling the table up
// to its capacity, flushing it to downstream stages, then calling
// reset() to start the next chunk. Hooking reset() gives us a clean
// per-chunk progress signal without touching the pipeline graph.
class ProgressFixedTable : public pdal::FixedPointTable {
public:
    ProgressFixedTable(pdal::point_count_t cap,
                       ProgressFn cb,
                       void* ctx,
                       uint64_t est_total)
        : pdal::FixedPointTable(cap), cb_(cb), ctx_(ctx), est_total_(est_total) {}

    uint64_t total() const noexcept { return total_; }

protected:
    void reset() override {
        total_ += static_cast<uint64_t>(this->numPoints());
        if (cb_ && !cb_(total_, est_total_, ctx_)) {
            throw CancelledByCaller();
        }
        pdal::FixedPointTable::reset();
    }

private:
    ProgressFn cb_;
    void*      ctx_;
    uint64_t   est_total_;
    uint64_t   total_ = 0;
};

// Best-effort total-point estimate from the pipeline's root stage's
// preview(). Stage::preview() is recursive — readers fill in their
// point count and intermediate stages forward it — so this gives us
// the leaf-reader totals without us walking the graph ourselves.
// Returns 0 when no preview is available.
uint64_t estimate_total_points(pdal::PipelineManager& mgr) noexcept
{
    try {
        if (pdal::Stage* root = mgr.getStage()) {
            pdal::QuickInfo qi = root->preview();
            if (qi.valid()) {
                return static_cast<uint64_t>(qi.m_pointCount);
            }
        }
    } catch (...) { /* fall through */ }
    return 0;
}

} // anonymous namespace

Result execute_pipeline_json(const std::string& json,
                             bool streaming,
                             int32_t chunk_size,
                             ProgressFn progress,
                             void* progress_ctx) noexcept
{
    Result r;
    try {
        pdal::PipelineManager mgr;
        std::stringstream ss(json);
        mgr.readPipeline(ss);

        const uint64_t est_total = progress ? estimate_total_points(mgr) : 0;

        if (streaming && mgr.pipelineStreamable()) {
            const std::size_t cap =
                (chunk_size > 0) ? static_cast<std::size_t>(chunk_size) : 10000u;
            ProgressFixedTable table(cap, progress, progress_ctx, est_total);
            mgr.executeStream(table);
            r.point_count = table.total();
        } else {
            mgr.execute();
            for (const auto& view : mgr.views()) {
                r.point_count += static_cast<uint64_t>(view->size());
            }
            if (progress && !progress(r.point_count, est_total, progress_ctx)) {
                throw CancelledByCaller();
            }
        }

        std::stringstream meta;
        pdal::MetadataNode root = mgr.getMetadata().clone("metadata");
        pdal::Utils::toJSON(root, meta);
        r.metadata_json = meta.str();
        r.status = kPdalOk;
    } catch (const CancelledByCaller&) {
        r.status = kCancelled;
        r.error_message = "cancelled by caller";
    } catch (const pdal::pdal_error& e) {
        r.status = kPdalErrPdal;
        r.error_message = e.what();
    } catch (const std::exception& e) {
        r.status = kPdalErrStdExcept;
        r.error_message = e.what();
    } catch (...) {
        r.status = kPdalErrUnknown;
        r.error_message = "unknown C++ exception";
    }
    return r;
}

bool driver_is_registered(const std::string& name) noexcept
{
    try {
        pdal::StageFactory factory(/*no_plugins=*/false);
        pdal::Stage* s = factory.createStage(name);
        if (!s) return false;
        factory.destroyStage(s);
        return true;
    } catch (...) {
        return false;
    }
}

}} // namespace swiftpdal::convert
