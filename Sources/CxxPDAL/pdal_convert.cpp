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
#include <atomic>
#include <thread>
#include <string>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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

// Pipes PDAL's native progress-fd output into our progress callback.
//
// `Stage::setProgressFd(fd)` tells PDAL to write progress messages to
// `fd`. The format is text — `<percent> <message>\n` or similar — used
// by the `pdal` CLI's progress bar. We give PDAL a pipe's write end,
// spawn a reader thread that drains the read end line-by-line, parses
// the leading number, and calls `progress(known_points, total, ctx)`
// with a *synthesised* point count derived from the percentage and the
// known total (from phase 1).
//
// Lifetime: construct after phase 1 + before writer.execute, destruct
// after writer.execute returns. The destructor closes the write end,
// the reader thread sees EOF, exits, and gets joined. SIGPIPE is
// suppressed via F_SETNOSIGPIPE so PDAL writes don't kill the process
// if the reader thread is somehow slow to drain.
class WriterProgressPump {
public:
    WriterProgressPump(ProgressFn cb, void* ctx, uint64_t known_points)
        : cb_(cb), ctx_(ctx), known_points_(known_points)
    {
        if (!cb_) return;
        int fds[2] = { -1, -1 };
        if (::pipe(fds) != 0) return;
        readFd_ = fds[0];
        writeFd_ = fds[1];
        // Suppress SIGPIPE on the write end — PDAL uses fprintf-style
        // writes which would otherwise raise SIGPIPE if our reader
        // closes first.
        ::fcntl(writeFd_, F_SETNOSIGPIPE, 1);
        // Non-blocking reads, polled in the drain loop.
        int flags = ::fcntl(readFd_, F_GETFL, 0);
        ::fcntl(readFd_, F_SETFL, flags | O_NONBLOCK);
        running_.store(true, std::memory_order_release);
        reader_ = std::thread([this]() { drainLoop(); });
    }

    int writeFd() const noexcept { return writeFd_; }
    bool active() const noexcept { return writeFd_ >= 0; }

    ~WriterProgressPump() {
        if (writeFd_ >= 0) { ::close(writeFd_); writeFd_ = -1; }
        running_.store(false, std::memory_order_release);
        if (reader_.joinable()) reader_.join();
        if (readFd_ >= 0) { ::close(readFd_); readFd_ = -1; }
    }

private:
    void drainLoop() noexcept {
        std::string carry;
        char buf[1024];
        while (running_.load(std::memory_order_acquire)) {
            ssize_t n = ::read(readFd_, buf, sizeof(buf));
            if (n > 0) {
                carry.append(buf, static_cast<std::size_t>(n));
                parseLines(carry);
            } else if (n == 0) {
                // EOF — write end closed.
                break;
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // No data right now; sleep briefly to avoid spin.
                    ::usleep(50 * 1000);
                    continue;
                }
                if (errno == EINTR) continue;
                break;
            }
        }
        // Drain any remaining bytes after EOF.
        if (!carry.empty()) parseLines(carry, /*flush=*/true);
    }

    void parseLines(std::string& buf, bool flush = false) noexcept {
        std::size_t pos = 0;
        while (true) {
            std::size_t nl = buf.find('\n', pos);
            if (nl == std::string::npos) break;
            handleLine(buf.substr(pos, nl - pos));
            pos = nl + 1;
        }
        if (pos > 0) buf.erase(0, pos);
        if (flush && !buf.empty()) {
            handleLine(buf);
            buf.clear();
        }
    }

    void handleLine(const std::string& line) noexcept {
        // PDAL emits lines beginning with a number (percent or fraction).
        // Parse leniently — leading whitespace, any non-numeric prefix is
        // ignored, the first numeric token wins.
        std::size_t i = 0;
        while (i < line.size() &&
               !(line[i] == '-' || line[i] == '.' || (line[i] >= '0' && line[i] <= '9'))) {
            ++i;
        }
        if (i >= line.size()) return;
        try {
            std::size_t consumed = 0;
            double v = std::stod(line.c_str() + i, &consumed);
            if (consumed == 0) return;
            // PDAL emits percents in [0,100] historically; if we see a
            // value > 1 treat it as percent.
            double frac = (v > 1.0) ? (v / 100.0) : v;
            if (frac < 0) frac = 0;
            if (frac > 1) frac = 1;
            // Synthesise a point count so the existing
            // (pointsSoFar / estimatedTotal) UI still works during the
            // writer phase.
            uint64_t pts = known_points_ > 0
                ? static_cast<uint64_t>(frac * static_cast<double>(known_points_))
                : 0;
            uint64_t total = known_points_;
            if (cb_) (void)cb_(pts, total, ctx_);
        } catch (...) {
            // Non-numeric line — ignore.
        }
    }

    ProgressFn cb_;
    void*      ctx_;
    uint64_t   known_points_;
    int        readFd_  = -1;
    int        writeFd_ = -1;
    std::atomic<bool> running_{false};
    std::thread reader_;
};

// Serialize a finalized point layout to a JSON array of
// `{"name","size","type"}` objects, with `type` in the STAC
// pointcloud-extension vocabulary (signed/unsigned/floating). Built by
// hand because the full nlohmann header isn't on PDAL's public include
// path here (same constraint noted in the E57 bridge). Returns an empty
// string on any failure — schema is best-effort metadata.
std::string serialize_schema(const pdal::PointLayoutPtr& layout) noexcept
{
    if (!layout) return std::string();
    try {
        auto escape = [](const std::string& s) {
            std::string out; out.reserve(s.size() + 2);
            for (char c : s) {
                if (c == '"' || c == '\\') { out.push_back('\\'); out.push_back(c); }
                else if (c == '\n') { out += "\\n"; }
                else { out.push_back(c); }
            }
            return out;
        };
        std::ostringstream os;
        os << '[';
        bool first = true;
        for (const auto& dt : layout->dimTypes()) {
            const std::string name = layout->dimName(dt.m_id);
            const std::size_t size = pdal::Dimension::size(dt.m_type);
            const char* base;
            switch (pdal::Dimension::base(dt.m_type)) {
                case pdal::Dimension::BaseType::Signed:   base = "signed";   break;
                case pdal::Dimension::BaseType::Unsigned: base = "unsigned"; break;
                case pdal::Dimension::BaseType::Floating: base = "floating"; break;
                default:                                  base = "unknown";  break;
            }
            if (!first) os << ',';
            first = false;
            os << "{\"name\":\"" << escape(name) << "\",\"size\":" << size
               << ",\"type\":\"" << base << "\"}";
        }
        os << ']';
        return os.str();
    } catch (...) {
        return std::string();
    }
}

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

        // Captured from whichever execution path runs, so we can emit the
        // dimension schema after execution regardless of mode.
        pdal::PointLayoutPtr schemaLayout;

        if (streaming && mgr.pipelineStreamable()) {
            // Fast path: entire pipeline streams.
            ProgressFixedTable table(cap, progress, progress_ctx, est_total);
            mgr.executeStream(table);
            r.point_count = table.total();
            schemaLayout = table.layout();
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

                // Hook PDAL's native progress fd on the writer so we can
                // forward its internal phase percentages (e.g. COPC
                // pyramid build) into the user's callback while
                // writer->execute is blocking. The pump owns the pipe
                // and a reader thread; its destructor joins on scope
                // exit, *after* execute() returns.
                WriterProgressPump pump(progress, progress_ctx,
                                        streamTbl.total());
                if (pump.active()) writer->setProgressFd(pump.writeFd());

                writer->prepare(phase2Table);
                pdal::PointViewSet outs = writer->execute(phase2Table);

                r.point_count = streamTbl.total();
                schemaLayout = sink->layout();
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
                // The manager's own table owns the finalized layout for
                // mgr's lifetime; the writer's output view layout may be
                // freed when execute() returns, so don't read it here.
                schemaLayout = mgr.pointTable().layout();
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
            schemaLayout = mgr.pointTable().layout();
            if (progress && !progress(r.point_count, est_total, progress_ctx)) {
                throw CancelledByCaller();
            }
        }

        r.schema_json = serialize_schema(schemaLayout);

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
