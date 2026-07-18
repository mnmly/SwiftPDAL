// In-memory point filter → writer bridge. See pdal_boolean.h for the
// three-step contract. The write half mirrors pdal_e57_convert.cpp's
// phase 2: a BufferReader feeding a StageFactory-built writer, driven
// directly via prepare/execute (PDAL ships no "null reader", so a
// pipeline-JSON path isn't available for in-memory views).

#include <pdal/PointTable.hpp>
#include <pdal/PointView.hpp>
#include <pdal/Stage.hpp>
#include <pdal/StageFactory.hpp>
#include <pdal/Options.hpp>
#include <pdal/Dimension.hpp>
#include <pdal/io/BufferReader.hpp>

#include "include/pdal_boolean.h"

#include <cstdio>
#include <memory>
#include <string>
#include <vector>

namespace {
constexpr int32_t kPdalOk           = 0;
constexpr int32_t kPdalErrPdal      = -2;
constexpr int32_t kPdalErrStdExcept = -3;
constexpr int32_t kPdalErrUnknown   = -6;
constexpr int32_t kBadArg           = -12;

struct FilterContext {
    std::shared_ptr<pdal::PointTable> table;
    pdal::PointViewPtr                view;
    std::vector<double>               xyz;        // interleaved, size = count*3
    std::string                       srsWkt;     // source SRS, forwarded as a_srs
    double scale[3]  = {0, 0, 0};
    double offset[3] = {0, 0, 0};
    bool   haveScaleOffset = false;
    bool   hasRGB    = false;   // source carried Red/Green/Blue
};

// Add the source LAS scale/offset (if captured) plus the caller's
// `key=value\n` overrides to a writer Options bag. `filename` is always
// forced to output_path. Caller keys win over the forwarded defaults.
void buildWriterOptions(pdal::Options& opts,
                        const FilterContext& ctx,
                        const std::string& output_path,
                        const std::string& writer_options_kv)
{
    if (ctx.haveScaleOffset) {
        opts.add("scale_x",  ctx.scale[0]);
        opts.add("scale_y",  ctx.scale[1]);
        opts.add("scale_z",  ctx.scale[2]);
        opts.add("offset_x", ctx.offset[0]);
        opts.add("offset_y", ctx.offset[1]);
        opts.add("offset_z", ctx.offset[2]);
    }
    // BufferReader carries no source SRS through to the writer, so forward
    // the captured WKT explicitly.
    if (!ctx.srsWkt.empty())
        opts.add("a_srs", ctx.srsWkt);
    size_t pos = 0;
    const std::string& s = writer_options_kv;
    while (pos < s.size()) {
        size_t lineEnd = s.find('\n', pos);
        if (lineEnd == std::string::npos) lineEnd = s.size();
        if (lineEnd > pos) {
            size_t eq = s.find('=', pos);
            if (eq != std::string::npos && eq < lineEnd) {
                std::string key = s.substr(pos, eq - pos);
                std::string val = s.substr(eq + 1, lineEnd - eq - 1);
                if (!key.empty() && key != "filename")
                    opts.add(key, val);
            }
        }
        pos = lineEnd + 1;
    }
    opts.add("filename", output_path);
}

// Pull scale_x/offset_x… out of a reader's post-execute metadata, if present.
void captureScaleOffset(pdal::Stage& reader, FilterContext& ctx)
{
    pdal::MetadataNode m = reader.getMetadata();
    const char* sk[3] = {"scale_x", "scale_y", "scale_z"};
    const char* ok[3] = {"offset_x", "offset_y", "offset_z"};
    bool all = true;
    double sc[3], of[3];
    for (int i = 0; i < 3; ++i) {
        pdal::MetadataNode s = m.findChild(sk[i]);
        pdal::MetadataNode o = m.findChild(ok[i]);
        if (!s.valid() || !o.valid()) { all = false; break; }
        sc[i] = s.value<double>();
        of[i] = o.value<double>();
    }
    if (all) {
        for (int i = 0; i < 3; ++i) { ctx.scale[i] = sc[i]; ctx.offset[i] = of[i]; }
        ctx.haveScaleOffset = true;
    }
}

} // anonymous namespace

namespace swiftpdal { namespace boolean_filter {

OpenResult fw_open(const std::string& input_path,
                   const std::string& reader_type) noexcept
{
    OpenResult r;
    try {
        std::string readerType = reader_type.empty() ? "readers.copc" : reader_type;

        pdal::StageFactory factory;
        pdal::Stage* reader = factory.createStage(readerType);
        if (!reader) {
            r.status = kPdalErrPdal;
            r.error_message = "Could not create reader stage '" + readerType +
                "' — driver not registered in this pdalcpp build.";
            return r;
        }
        pdal::Options ro;
        ro.add("filename", input_path);
        reader->setOptions(ro);

        auto table = std::make_shared<pdal::PointTable>();
        reader->prepare(*table);
        pdal::PointViewSet views = reader->execute(*table);

        pdal::PointViewPtr view;
        if (views.empty()) {
            r.status = kPdalOk;
            r.point_count = 0;
            // Still hand back a valid (empty) context so the caller's flow
            // is uniform; write will simply produce an empty cloud.
            auto* ctx = new FilterContext();
            ctx->table = table;
            ctx->view  = std::make_shared<pdal::PointView>(*table);
            r.handle = ctx;
            return r;
        }
        if (views.size() == 1) {
            view = *views.begin();
        } else {
            view = (*views.begin())->makeNew();
            for (const auto& v : views)
                for (pdal::PointId i = 0; i < v->size(); ++i)
                    view->appendPoint(*v, i);
        }

        auto* ctx = new FilterContext();
        ctx->table  = table;
        ctx->view   = view;
        ctx->srsWkt = view->spatialReference().getWKT();
        ctx->hasRGB = view->layout()->hasDim(pdal::Dimension::Id::Red) &&
                      view->layout()->hasDim(pdal::Dimension::Id::Green) &&
                      view->layout()->hasDim(pdal::Dimension::Id::Blue);
        captureScaleOffset(*reader, *ctx);

        const pdal::point_count_t n = view->size();
        ctx->xyz.resize(static_cast<size_t>(n) * 3);
        for (pdal::PointId i = 0; i < n; ++i) {
            ctx->xyz[3 * i + 0] = view->getFieldAs<double>(pdal::Dimension::Id::X, i);
            ctx->xyz[3 * i + 1] = view->getFieldAs<double>(pdal::Dimension::Id::Y, i);
            ctx->xyz[3 * i + 2] = view->getFieldAs<double>(pdal::Dimension::Id::Z, i);
        }

        r.status = kPdalOk;
        r.point_count = static_cast<uint64_t>(n);
        r.handle = ctx;
        return r;
    } catch (const pdal::pdal_error& e) {
        r.status = kPdalErrPdal;
        r.error_message = std::string("read failed: ") + e.what();
    } catch (const std::exception& e) {
        r.status = kPdalErrStdExcept;
        r.error_message = std::string("read failed: ") + e.what();
    } catch (...) {
        r.status = kPdalErrUnknown;
        r.error_message = "read failed: unknown C++ exception";
    }
    return r;
}

const double* fw_xyz(void* handle) noexcept
{
    if (!handle) return nullptr;
    auto* ctx = static_cast<FilterContext*>(handle);
    return ctx->xyz.empty() ? nullptr : ctx->xyz.data();
}

WriteResult fw_write_masked(void*              handle,
                            const uint8_t*     keep,
                            uint64_t           keep_count,
                            const std::string& output_path,
                            const std::string& writer_type,
                            const std::string& writer_options_kv) noexcept
{
    WriteResult r;
    if (!handle || !keep) {
        r.status = kBadArg;
        r.error_message = "null handle or mask";
        return r;
    }
    auto* ctx = static_cast<FilterContext*>(handle);
    try {
        const pdal::point_count_t n = ctx->view->size();
        const uint64_t limit = keep_count < static_cast<uint64_t>(n)
            ? keep_count : static_cast<uint64_t>(n);

        pdal::PointViewPtr out = ctx->view->makeNew();
        for (uint64_t i = 0; i < limit; ++i)
            if (keep[i]) out->appendPoint(*ctx->view, static_cast<pdal::PointId>(i));

        std::string writerType = writer_type.empty() ? "writers.copc" : writer_type;

        // Direct BufferReader → writer works for LAS/LAZ, but writers.copc
        // can't be told a point format and forwards nothing from a
        // BufferReader (no source header), so it defaults to format 6 and
        // drops RGB. For COPC we therefore stage through a real LAS 1.4 file
        // — which carries a proper header — then convert that to COPC, where
        // CopcWriter forwards the format (7 with colour) correctly.
        pdal::StageFactory factory;

        if (writerType == "writers.copc") {
            const std::string stagePath = output_path + ".stage.laz";

            // Stage 1: kept points → LAS 1.4, format 7 (GPS + RGB) or 6.
            pdal::Stage* lasWriter = factory.createStage("writers.las");
            if (!lasWriter) {
                r.status = kPdalErrPdal;
                r.error_message = "writers.las not registered in this pdalcpp build.";
                return r;
            }
            pdal::Options lasOpts;
            buildWriterOptions(lasOpts, *ctx, stagePath, writer_options_kv);
            lasOpts.add("minor_version", 4);
            lasOpts.add("dataformat_id", ctx->hasRGB ? 7 : 6);
            lasOpts.add("extra_dims", std::string("all"));
            lasWriter->setOptions(lasOpts);

            pdal::BufferReader bufReader;
            bufReader.addView(out);
            lasWriter->setInput(bufReader);
            pdal::PointTable t1;
            lasWriter->prepare(t1);
            lasWriter->execute(t1);

            // Stage 2: LAS → COPC, forwarding the header (keeps format 7).
            pdal::Stage* lasReader = factory.createStage("readers.las");
            pdal::Stage* copcWriter = factory.createStage("writers.copc");
            if (!lasReader || !copcWriter) {
                std::remove(stagePath.c_str());
                r.status = kPdalErrPdal;
                r.error_message = "readers.las / writers.copc not registered.";
                return r;
            }
            pdal::Options rOpts; rOpts.add("filename", stagePath);
            lasReader->setOptions(rOpts);
            pdal::Options cOpts;
            cOpts.add("filename", output_path);
            cOpts.add("forward", std::string("all"));
            cOpts.add("extra_dims", std::string("all"));
            copcWriter->setOptions(cOpts);
            copcWriter->setInput(*lasReader);
            pdal::PointTable t2;
            copcWriter->prepare(t2);
            copcWriter->execute(t2);

            std::remove(stagePath.c_str());
        } else {
            // LAS/LAZ (or any other) writer: BufferReader is fine.
            pdal::Stage* writer = factory.createStage(writerType);
            if (!writer) {
                r.status = kPdalErrPdal;
                r.error_message = "Could not create writer stage '" + writerType +
                    "' — driver not registered in this pdalcpp build.";
                return r;
            }
            pdal::Options opts;
            buildWriterOptions(opts, *ctx, output_path, writer_options_kv);
            opts.add("extra_dims", std::string("all"));
            writer->setOptions(opts);
            pdal::BufferReader bufReader;
            bufReader.addView(out);
            writer->setInput(bufReader);
            pdal::PointTable wtable;
            writer->prepare(wtable);
            writer->execute(wtable);
        }

        r.point_count = out->size();
        r.status = kPdalOk;
    } catch (const pdal::pdal_error& e) {
        r.status = kPdalErrPdal;
        r.error_message = std::string("write failed: ") + e.what();
    } catch (const std::exception& e) {
        r.status = kPdalErrStdExcept;
        r.error_message = std::string("write failed: ") + e.what();
    } catch (...) {
        r.status = kPdalErrUnknown;
        r.error_message = "write failed: unknown C++ exception";
    }
    return r;
}

void fw_free(void* handle) noexcept
{
    if (!handle) return;
    delete static_cast<FilterContext*>(handle);
}

}} // namespace swiftpdal::boolean_filter
