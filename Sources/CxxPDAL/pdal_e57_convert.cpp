// libE57Format → writers.copc bridge.
//
// Why this exists
// ---------------
// PDAL 2.10's `readers.e57` (via its libE57Format plugin) throws
// "E57 exception" partway through certain multi-scan E57 files. The
// repro file in our hands has 16 scans / 437 M points; PDAL dies
// around point ~95.85 M every run, but a direct libE57Format read
// (see /tmp/e57probe/e57probe.cpp in this repo's dev notes) reads
// every scan to completion. So the bug is in PDAL's bridge, not in
// the file and not in libE57Format. Until upstream fixes that, this
// module reads E57 ourselves and hands the captured points to PDAL's
// writer pipeline.
//
// Shape
// -----
// 1) libE57Format read loop:
//      For each Data3D scan:
//        Detect whether the scan stores geometry as cartesian XYZ or
//        spherical range/azimuth/elevation (terrestrial scanners export
//        spherical; that representation carries no cartesian prototype
//        fields, so it must be read as spherical and converted — reading
//        it as cartesian yields all-zero points). Allocate per-chunk
//        buffers (geometry + optional RGB / intensity / invalidState).
//        SetUpData3DPointsData → CompressedVectorReader. Loop reading
//        kChunkSize points at a time; for spherical scans convert to
//        cartesian first; transform XYZ by the scan's pose (translation +
//        quaternion); push into the long-lived sink PointView via
//        setField. Fire user-supplied progress per chunk. Skip points
//        flagged invalid (`cartesian`/`sphericalInvalidState != 0`).
// 2) Writer pipeline:
//      Build `{"pipeline":[<reader-placeholder>, writer]}` JSON,
//      strip the placeholder, attach a BufferReader feeding the
//      captured sink view, and execute. Same writer-progress pump as
//      pdal_convert.cpp's two-pass path.

#include <pdal/PDALUtils.hpp>
#include <pdal/PointTable.hpp>
#include <pdal/PointView.hpp>
#include <pdal/Stage.hpp>
#include <pdal/StageFactory.hpp>
#include <pdal/Options.hpp>
#include <pdal/io/BufferReader.hpp>
#include <pdal/Dimension.hpp>

// libE57Format headers — addressed via the framework module
// (`E57Format.xcframework`), which the binaryTarget makes available
// through the standard `<Framework/Header.h>` form.
#include <E57Format/E57SimpleReader.h>
#include <E57Format/E57SimpleData.h>
#include <E57Format/E57Exception.h>

#include "include/pdal_e57_convert.h"
#include "include/e57_init_guard.h"

#include <atomic>
#include <thread>
#include <memory>
#include <string>
#include <sstream>
#include <vector>
#include <cmath>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

namespace {
constexpr int32_t kPdalOk            = 0;
constexpr int32_t kPdalErrPdal       = -2;
constexpr int32_t kPdalErrStdExcept  = -3;
constexpr int32_t kPdalErrUnknown    = -6;
constexpr int32_t kCancelled         = -11;

constexpr size_t  kDefaultChunk      = 100000;

struct CancelledByCaller : public std::exception {
    const char* what() const noexcept override { return "cancelled by caller"; }
};

// Apply E57 scan pose (translation + quaternion rotation) to a chunk
// of XYZ floats in place. Quaternion is (w, x, y, z) order.
inline void applyScanPose(float* x, float* y, float* z, size_t n,
                          double tx, double ty, double tz,
                          double qw, double qx, double qy, double qz)
{
    // Precompute rotation matrix from quaternion. The doubles let us
    // preserve scan-to-world precision; result is cast to float on
    // store. For large coordinates we'd need a global translation —
    // writers.copc applies its own offset/scale so leaving the values
    // in source space is fine.
    const double m00 = 1 - 2*(qy*qy + qz*qz);
    const double m01 =     2*(qx*qy - qz*qw);
    const double m02 =     2*(qx*qz + qy*qw);
    const double m10 =     2*(qx*qy + qz*qw);
    const double m11 = 1 - 2*(qx*qx + qz*qz);
    const double m12 =     2*(qy*qz - qx*qw);
    const double m20 =     2*(qx*qz - qy*qw);
    const double m21 =     2*(qy*qz + qx*qw);
    const double m22 = 1 - 2*(qx*qx + qy*qy);
    for (size_t i = 0; i < n; ++i) {
        const double px = x[i], py = y[i], pz = z[i];
        x[i] = static_cast<float>(m00*px + m01*py + m02*pz + tx);
        y[i] = static_cast<float>(m10*px + m11*py + m12*pz + ty);
        z[i] = static_cast<float>(m20*px + m21*py + m22*pz + tz);
    }
}

// Drains PDAL's setProgressFd output to the user's progress callback
// during the writer phase. Copied verbatim from pdal_convert.cpp; we'd
// share if there was a clean place for the type. Kept small enough that
// duplication is cheaper than refactoring.
class WriterProgressPump {
public:
    WriterProgressPump(swiftpdal::convert::ProgressFn cb, void* ctx, uint64_t known_points)
        : cb_(cb), ctx_(ctx), known_points_(known_points)
    {
        if (!cb_) return;
        int fds[2] = { -1, -1 };
        if (::pipe(fds) != 0) return;
        readFd_ = fds[0];
        writeFd_ = fds[1];
        ::fcntl(writeFd_, F_SETNOSIGPIPE, 1);
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
            if (n > 0) { carry.append(buf, (size_t)n); parseLines(carry); }
            else if (n == 0) break;
            else if (errno == EAGAIN || errno == EWOULDBLOCK) { ::usleep(50*1000); continue; }
            else if (errno == EINTR) continue;
            else break;
        }
        if (!carry.empty()) parseLines(carry, true);
    }
    void parseLines(std::string& buf, bool flush = false) noexcept {
        size_t pos = 0;
        while (true) {
            size_t nl = buf.find('\n', pos);
            if (nl == std::string::npos) break;
            handleLine(buf.substr(pos, nl - pos));
            pos = nl + 1;
        }
        if (pos > 0) buf.erase(0, pos);
        if (flush && !buf.empty()) { handleLine(buf); buf.clear(); }
    }
    void handleLine(const std::string& line) noexcept {
        size_t i = 0;
        while (i < line.size() &&
               !(line[i]=='-'||line[i]=='.'||(line[i]>='0'&&line[i]<='9'))) ++i;
        if (i >= line.size()) return;
        try {
            size_t consumed = 0;
            double v = std::stod(line.c_str() + i, &consumed);
            if (consumed == 0) return;
            double frac = (v > 1.0) ? (v / 100.0) : v;
            if (frac < 0) frac = 0; if (frac > 1) frac = 1;
            uint64_t pts = known_points_ > 0
                ? (uint64_t)(frac * (double)known_points_) : 0;
            if (cb_) (void)cb_(pts, known_points_, ctx_);
        } catch (...) {}
    }
    swiftpdal::convert::ProgressFn cb_;
    void* ctx_;
    uint64_t known_points_;
    int readFd_  = -1;
    int writeFd_ = -1;
    std::atomic<bool> running_{false};
    std::thread reader_;
};

} // anonymous namespace

namespace swiftpdal { namespace convert {

E57Result execute_e57_to_copc(const std::string& input_path,
                              const std::string& output_path,
                              const std::string& writer_type,
                              const std::string& writer_options_kv,
                              int32_t            chunk_size,
                              ProgressFn         progress,
                              void*              progress_ctx) noexcept
{
    E57Result r;
    const size_t cap = (chunk_size > 0) ? (size_t)chunk_size : kDefaultChunk;

    // -------- Phase 1: libE57Format read into a long-lived PointView --------
    pdal::PointTable phase2Table;
    auto sink = std::make_shared<pdal::PointView>(phase2Table);

    // Register the dim set we plan to populate. writers.copc will add
    // any additional dims it needs at prepare() time.
    pdal::PointLayoutPtr layout = sink->layout();
    layout->registerDim(pdal::Dimension::Id::X);
    layout->registerDim(pdal::Dimension::Id::Y);
    layout->registerDim(pdal::Dimension::Id::Z);
    layout->registerDim(pdal::Dimension::Id::Red);
    layout->registerDim(pdal::Dimension::Id::Green);
    layout->registerDim(pdal::Dimension::Id::Blue);
    layout->registerDim(pdal::Dimension::Id::Intensity);
    layout->finalize();

    uint64_t total_points_estimate = 0;
    try {
        // Serialize libE57Format's Xerces bring-up — the ImageFile ctor
        // runs the non-thread-safe XMLPlatformUtils Initialize/Terminate
        // cycle. See e57_init_guard.h. The lock covers only construction;
        // the read loop below runs unlocked.
        std::unique_ptr<e57::Reader> readerPtr;
        {
            swiftpdal::E57InitGuard g(input_path);
            readerPtr = std::make_unique<e57::Reader>(input_path, e57::ReaderOptions{});
        }
        e57::Reader& reader = *readerPtr;
        int64_t nScans = reader.GetData3DCount();

        // Sum point counts up-front so we have a real `estimatedTotal`
        // for progress callbacks throughout the read.
        for (int64_t i = 0; i < nScans; ++i) {
            e57::Data3D hdr;
            if (reader.ReadData3D(i, hdr) && hdr.pointCount > 0)
                total_points_estimate += (uint64_t)hdr.pointCount;
        }

        uint64_t pointsSoFar = 0;
        std::vector<float>    x(cap), y(cap), z(cap);
        std::vector<int8_t>   validXYZ(cap);
        // Spherical-coordinate scans (range/azimuth/elevation) — the
        // native representation for most terrestrial scanners (FARO,
        // Leica, Z+F). Such files carry *no* cartesian prototype fields,
        // so we read the spherical triples here and convert to cartesian
        // ourselves (see the read loop below). `validSph` mirrors
        // `sphericalInvalidState`.
        std::vector<float>    sr(cap), sa(cap), se(cap);
        std::vector<int8_t>   validSph(cap);
        // RGB and intensity are optional. libE57Format's
        // Data3DPointsFloat exposes color channels as `uint16_t*` and
        // intensity as `double*` (regardless of the cartesian-float
        // suffix in the struct name), so we mirror those types here.
        std::vector<uint16_t> r16(cap), g16(cap), b16(cap);
        std::vector<int8_t>   validRGB(cap);
        std::vector<double>   intensity(cap);
        std::vector<int8_t>   validI(cap);

        // Per-scan skip-and-continue. Files exist in the wild where one
        // scan has a corrupted page (typically a single CompressedVector
        // packet with a bad checksum) while the rest are fine. PDAL's
        // own reader bails on the first exception and never gets back to
        // the surviving scans; we'd rather keep going and surface what
        // we got. Failures are accumulated in `scan_warnings_` for the
        // caller (currently logged below; could be plumbed up via
        // ConvertResult.warnings later).
        std::vector<std::string> scan_warnings;
        for (int64_t i = 0; i < nScans; ++i) {
            e57::Data3D hdr;
            if (!reader.ReadData3D(i, hdr) || hdr.pointCount <= 0) continue;
            const bool hasRGB = hdr.pointFields.colorRedField &&
                                hdr.pointFields.colorGreenField &&
                                hdr.pointFields.colorBlueField;
            const bool hasI   = hdr.pointFields.intensityField;

            // A scan stores its geometry in *either* cartesian XYZ *or*
            // spherical range/azimuth/elevation — never both. Which one
            // decides how we set up buffers and whether we convert below.
            // libE57Format only fills a buffer when the matching field is
            // present in the scan's prototype, so requesting cartesian
            // buffers on a spherical scan silently yields zeros — the
            // original bug this path had (every scan collapsed onto its
            // pose translation, exploding the bounding box).
            const bool hasCartesian = hdr.pointFields.cartesianXField &&
                                      hdr.pointFields.cartesianYField &&
                                      hdr.pointFields.cartesianZField;
            const bool hasSpherical = hdr.pointFields.sphericalRangeField &&
                                      hdr.pointFields.sphericalAzimuthField &&
                                      hdr.pointFields.sphericalElevationField;
            if (!hasCartesian && !hasSpherical) {
                std::ostringstream w;
                w << "scan " << i << " ('" << hdr.name << "', "
                  << hdr.pointCount << " pts) skipped: no cartesian or "
                     "spherical point fields in prototype";
                scan_warnings.push_back(w.str());
                std::fprintf(stderr, "[swiftpdal::e57] %s\n", w.str().c_str());
                continue;
            }

            // E57's quaternion is (w, x, y, z); translation is x, y, z.
            const double tx = hdr.pose.translation.x;
            const double ty = hdr.pose.translation.y;
            const double tz = hdr.pose.translation.z;
            const double qw = hdr.pose.rotation.w;
            const double qx = hdr.pose.rotation.x;
            const double qy = hdr.pose.rotation.y;
            const double qz = hdr.pose.rotation.z;

            e57::Data3DPointsFloat buffers;
            if (hasCartesian) {
                buffers.cartesianX = x.data();
                buffers.cartesianY = y.data();
                buffers.cartesianZ = z.data();
                buffers.cartesianInvalidState = validXYZ.data();
            } else { // hasSpherical
                buffers.sphericalRange     = sr.data();
                buffers.sphericalAzimuth   = sa.data();
                buffers.sphericalElevation = se.data();
                buffers.sphericalInvalidState = validSph.data();
            }
            if (hasRGB) {
                buffers.colorRed       = r16.data();
                buffers.colorGreen     = g16.data();
                buffers.colorBlue      = b16.data();
                buffers.isColorInvalid = validRGB.data();
            }
            if (hasI) {
                buffers.intensity          = intensity.data();
                buffers.isIntensityInvalid = validI.data();
            }

            // Per-scan exception boundary. Anything other than a clean
            // CancelledByCaller propagates out as a *warning* and we
            // move on to the next scan.
            try {
            auto vr = reader.SetUpData3DPointsData((int)i, cap, buffers);
            // Which invalid-state array the read filled depends on the
            // representation; 0 == valid in E57 for both.
            const int8_t* invalid = hasCartesian ? validXYZ.data()
                                                  : validSph.data();
            size_t got = 0;
            while ((got = vr.read()) > 0) {
                // Spherical → cartesian (E57 / ASTM E2807 convention),
                // matching PDAL's readers.e57 so both paths agree. Angles
                // are radians; result lands in x/y/z for the pose step.
                if (hasSpherical) {
                    for (size_t p = 0; p < got; ++p) {
                        const double range = sr[p], az = sa[p], el = se[p];
                        const double ce = std::cos(el);
                        x[p] = static_cast<float>(range * ce * std::cos(az));
                        y[p] = static_cast<float>(range * ce * std::sin(az));
                        z[p] = static_cast<float>(range * std::sin(el));
                    }
                }
                applyScanPose(x.data(), y.data(), z.data(), got,
                              tx, ty, tz, qw, qx, qy, qz);
                pdal::PointId baseId = sink->size();
                pdal::PointId outIdx = baseId;
                for (size_t p = 0; p < got; ++p) {
                    if (invalid[p]) continue; // 0 == valid in E57
                    sink->setField(pdal::Dimension::Id::X, outIdx, (double)x[p]);
                    sink->setField(pdal::Dimension::Id::Y, outIdx, (double)y[p]);
                    sink->setField(pdal::Dimension::Id::Z, outIdx, (double)z[p]);
                    if (hasRGB) {
                        // libE57Format already returns colour as
                        // uint16_t (full LAS range when the E57 file
                        // stores 8-bit colour, libE57Format expands).
                        sink->setField(pdal::Dimension::Id::Red,   outIdx, r16[p]);
                        sink->setField(pdal::Dimension::Id::Green, outIdx, g16[p]);
                        sink->setField(pdal::Dimension::Id::Blue,  outIdx, b16[p]);
                    }
                    if (hasI) {
                        // E57 intensity is a normalised double (0..1
                        // typical). Map to LAS' uint16 dim.
                        double v = intensity[p];
                        if (v < 0) v = 0; if (v > 1) v = 1;
                        sink->setField(pdal::Dimension::Id::Intensity, outIdx,
                                       (uint16_t)(v * 65535.0));
                    }
                    ++outIdx;
                }
                pointsSoFar += got;
                if (progress && !progress(pointsSoFar, total_points_estimate, progress_ctx)) {
                    vr.close();
                    throw CancelledByCaller();
                }
            }
            vr.close();
            } catch (const CancelledByCaller&) {
                throw; // honour caller cancellation, drop out of the scan loop.
            } catch (const e57::E57Exception& e) {
                std::ostringstream w;
                w << "scan " << i << " ('" << hdr.name << "', "
                  << hdr.pointCount << " pts) skipped: code="
                  << (int)e.errorCode()
                  << " (" << e57::Utilities::errorCodeToString(e.errorCode()) << ")"
                  << " context='" << e.context() << "'";
                scan_warnings.push_back(w.str());
                std::fprintf(stderr, "[swiftpdal::e57] %s\n", scan_warnings.back().c_str());
                continue;
            } catch (const std::exception& e) {
                std::ostringstream w;
                w << "scan " << i << " ('" << hdr.name << "', "
                  << hdr.pointCount << " pts) skipped: " << e.what();
                scan_warnings.push_back(w.str());
                std::fprintf(stderr, "[swiftpdal::e57] %s\n", w.str().c_str());
                continue;
            }
        }
        if (!scan_warnings.empty()) {
            std::fprintf(stderr,
                "[swiftpdal::e57] %zu scan(s) skipped due to errors; "
                "wrote %llu of estimated %llu points\n",
                scan_warnings.size(),
                (unsigned long long)pointsSoFar,
                (unsigned long long)total_points_estimate);
        }
    } catch (const CancelledByCaller&) {
        r.status = kCancelled;
        r.error_message = "cancelled by caller";
        return r;
    } catch (const e57::E57Exception& e) {
        r.status = kPdalErrStdExcept;
        std::ostringstream oss;
        oss << "E57 read failed: code=" << (int)e.errorCode()
            << " (" << e57::Utilities::errorCodeToString(e.errorCode()) << ")"
            << " context='" << e.context() << "'";
        r.error_message = oss.str();
        return r;
    } catch (const std::exception& e) {
        r.status = kPdalErrStdExcept;
        r.error_message = std::string("E57 read failed: ") + e.what();
        return r;
    } catch (...) {
        r.status = kPdalErrUnknown;
        r.error_message = "E57 read failed: unknown C++ exception";
        return r;
    }

    // -------- Phase 2: build writer programmatically, no pipeline JSON --------
    //
    // We *can't* go through `PipelineManager::readPipeline` here because
    // every pipeline needs a reader stage in front of the writer, and
    // PDAL doesn't ship a "do-nothing" reader (`readers.null` doesn't
    // exist, despite some docs implying otherwise — only `writers.null`
    // is real). So we construct the writer with `StageFactory`, attach
    // a `BufferReader` (a built-in PDAL class with no plugin
    // registration — only usable from C++) feeding our captured view,
    // then call prepare/execute directly. Same shape as PDAL's own
    // unit tests that drive writers from in-memory views.
    try {
        std::string writerType = writer_type.empty() ? "writers.copc" : writer_type;

        pdal::StageFactory factory;
        pdal::Stage* writer = factory.createStage(writerType);
        if (!writer) {
            r.status = kPdalErrPdal;
            r.error_message = "Could not create writer stage '" + writerType +
                "' — driver not registered in this pdalcpp build.";
            return r;
        }

        // Build the writer's Options bag from the `key=value\n` lines.
        // Everything is added as a string — PDAL's Option machinery
        // does the right type coercion when the writer reads them
        // (mirrors how `pdal translate` passes options on the command
        // line as strings). `filename` is injected from the call's
        // output_path and overrides anything the caller might have set.
        pdal::Options opts;
        if (writerType == "writers.copc" && writer_options_kv.empty()) {
            // Sensible default for the common case.
            opts.add("forward", std::string("all"));
        }
        {
            size_t pos = 0;
            const auto& s = writer_options_kv;
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
        }
        opts.add("filename", output_path);
        writer->setOptions(opts);

        pdal::BufferReader bufReader;
        bufReader.addView(sink);
        writer->setInput(bufReader);

        WriterProgressPump pump(progress, progress_ctx, sink->size());
        if (pump.active()) writer->setProgressFd(pump.writeFd());

        writer->prepare(phase2Table);
        pdal::PointViewSet outs = writer->execute(phase2Table);
        (void)outs;

        // StageFactory owns the writer's lifetime; we don't manually
        // destroy here because PDAL's factory destructor handles it.

        r.point_count = sink->size();
        if (progress) (void)progress(r.point_count, total_points_estimate, progress_ctx);
        r.status = kPdalOk;
    } catch (const pdal::pdal_error& e) {
        r.status = kPdalErrPdal;
        r.error_message = std::string("COPC write failed: ") + e.what();
    } catch (const std::exception& e) {
        r.status = kPdalErrStdExcept;
        r.error_message = std::string("COPC write failed: ") + e.what();
    } catch (...) {
        r.status = kPdalErrUnknown;
        r.error_message = "COPC write failed: unknown C++ exception";
    }
    return r;
}

}} // namespace swiftpdal::convert
