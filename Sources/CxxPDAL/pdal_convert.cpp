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
#include <pdal/PointRef.hpp>
#include <pdal/Stage.hpp>
#include <pdal/QuickInfo.hpp>
#include <pdal/io/BufferReader.hpp>
#include <sstream>
#include <exception>
#include <memory>

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

// Stream point table for the two-pass path. Behaves like FixedPointTable
// for the upstream stages (so they can stream-execute), but on every
// `reset()` it copies the chunk's points into a long-lived `PointView`
// so the writer can replay them after the read finishes. This is the
// mechanism that lets us report per-chunk progress while still feeding a
// non-streamable writer (e.g. `writers.copc`) a complete dataset.
class CapturingStreamTable : public pdal::FixedPointTable {
public:
    CapturingStreamTable(pdal::point_count_t cap,
                         const pdal::PointViewPtr& sink,
                         ProgressFn cb,
                         void* ctx,
                         uint64_t est_total)
        : pdal::FixedPointTable(cap),
          sink_(sink), cb_(cb), ctx_(ctx), est_total_(est_total) {}

    uint64_t total() const noexcept { return total_; }

protected:
    void reset() override {
        // First invocation: layout is finalized on the upstream side.
        // Mirror our dims into the sink view's layout so the values we
        // copy land in compatible storage. Done lazily because we don't
        // know the dim set until prepare() ran.
        if (!ready_) {
            dims_ = layout()->dimTypes();
            pdal::PointLayoutPtr sinkLayout = sink_->layout();
            for (const auto& d : dims_) {
                sinkLayout->registerDim(d.m_id, d.m_type);
            }
            // The sink table will lazily finalize on first setField, but
            // doing it explicitly here keeps the layout stable for the
            // writer's later prepare() pass.
            sinkLayout->finalize();
            ready_ = true;
        }
        const pdal::point_count_t n = this->numPoints();
        const pdal::PointId base = sink_->size();
        // Copy point-by-point via getPackedData/setPackedData — single
        // call per point, one virtual dispatch per dim is amortized
        // across the packed buffer.
        std::vector<char> pack;
        std::size_t packBytes = 0;
        for (const auto& d : dims_) packBytes += pdal::Dimension::size(d.m_type);
        pack.resize(packBytes);
        for (pdal::PointId i = 0; i < n; ++i) {
            pdal::PointRef src(*this, i);
            src.getPackedData(dims_, pack.data());
            // setField at idx == view->size() grows the view + table.
            for (const auto& d : dims_) {
                sink_->setField(d.m_id, d.m_type, base + i,
                                pack.data() + offsetOf(d));
            }
        }
        total_ += static_cast<uint64_t>(n);
        if (cb_ && !cb_(total_, est_total_, ctx_)) {
            throw CancelledByCaller();
        }
        pdal::FixedPointTable::reset();
    }

private:
    // Cached dim offsets inside the packed buffer.
    std::size_t offsetOf(const pdal::DimType& target) const {
        std::size_t off = 0;
        for (const auto& d : dims_) {
            if (d.m_id == target.m_id) return off;
            off += pdal::Dimension::size(d.m_type);
        }
        return 0;
    }

    pdal::PointViewPtr sink_;
    ProgressFn         cb_;
    void*              ctx_;
    uint64_t           est_total_;
    uint64_t           total_ = 0;
    pdal::DimTypeList  dims_;
    bool               ready_ = false;
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

        const std::size_t cap =
            (chunk_size > 0) ? static_cast<std::size_t>(chunk_size) : 10000u;

        if (streaming && mgr.pipelineStreamable()) {
            // Fast path: entire pipeline streams.
            ProgressFixedTable table(cap, progress, progress_ctx, est_total);
            mgr.executeStream(table);
            r.point_count = table.total();
        } else if (streaming && progress) {
            // Two-pass path: stream-read into a long-lived PointView for
            // per-chunk progress, then run the non-streamable writer over
            // the captured data via BufferReader. Falls back to monolithic
            // execute() if the upstream sub-pipeline isn't streamable on
            // its own either.
            pdal::Stage* writer = mgr.getStage();
            pdal::Stage* upstream = (writer && !writer->getInputs().empty())
                ? writer->getInputs()[0] : nullptr;
            bool twoPassOk = false;
            if (upstream && upstream->pipelineStreamable()) {
                pdal::PointTable phase2Table;
                auto sink = std::make_shared<pdal::PointView>(phase2Table);
                CapturingStreamTable streamTbl(
                    cap, sink, progress, progress_ctx, est_total);

                upstream->prepare(streamTbl);
                upstream->execute(streamTbl);

                // Detach writer from its original upstream and re-wire it
                // to a BufferReader fed by the captured sink view. The
                // original upstream stages will simply not be referenced
                // again — the manager still owns them, so no leaks.
                pdal::BufferReader bufReader;
                bufReader.addView(sink);
                writer->getInputs().clear();
                writer->setInput(bufReader);

                writer->prepare(phase2Table);
                pdal::PointViewSet outs = writer->execute(phase2Table);

                r.point_count = streamTbl.total();
                // Final 100% tick — the writer phase produces no progress
                // events on its own.
                if (!progress(r.point_count, est_total, progress_ctx)) {
                    throw CancelledByCaller();
                }
                twoPassOk = true;
                (void)outs;
            }
            if (!twoPassOk) {
                // Couldn't stream the upstream either — fall back to the
                // monolithic path. Progress fires once at the end.
                mgr.execute();
                for (const auto& view : mgr.views()) {
                    r.point_count += static_cast<uint64_t>(view->size());
                }
                if (!progress(r.point_count, est_total, progress_ctx)) {
                    throw CancelledByCaller();
                }
            }
        } else {
            // streaming==false or no progress callback: monolithic execute.
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
