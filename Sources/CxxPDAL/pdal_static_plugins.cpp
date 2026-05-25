// pdal_static_plugins.cpp
//
// Symbol anchors for PDAL's file-scope static plugin registrars on iOS.
//
// PDAL registers each Reader/Writer/Filter via `CREATE_STATIC_STAGE`
// (see PluginHelper.hpp) which expands to a file-scope:
//
//     static bool LasReader_b = PluginManager<Stage>::registerPlugin<LasReader>(s_info);
//
// When pdalcpp ships as a static archive (iOS slices), `ld64` drops any
// `.o` whose external symbols are unreferenced. The registrar's `_b`
// flag is `static`, so the only way to keep that translation unit in
// the final image is to reference *some* symbol it defines.
//
// We do that here by `new`-ing one instance of each stage we want
// available at runtime. Construction is cheap (no I/O, no PDAL state
// touched), and the `volatile` sink prevents the optimizer from
// removing the allocation. The single call to
// `swiftpdal::ensureStaticPluginsLinked()` from `pdal_wrapper.cpp`
// keeps this TU itself alive in CxxPDAL.a.
//
// This file targets the *core* set SwiftPDAL's own wrapper invokes:
// readers/writers for las/ply/text/copc plus the four filters used by
// `createConfiguredStage`. Apps running custom JSON pipelines that
// reference other stages must add their own anchors.
//
// macOS links `pdalcpp` as a dynamic framework where every exported
// symbol stays live, so the anchors are harmless but unnecessary
// there. We compile them unconditionally to keep one code path.

#include <pdal/io/LasReader.hpp>
#include <pdal/io/LasWriter.hpp>
#include <pdal/io/PlyReader.hpp>
#include <pdal/io/PlyWriter.hpp>
#include <pdal/io/TextReader.hpp>
#include <pdal/io/TextWriter.hpp>
#include <pdal/io/CopcReader.hpp>
#include <pdal/io/CopcWriter.hpp>
#include <pdal/io/BufferReader.hpp>
#include <pdal/filters/RangeFilter.hpp>
#include <pdal/filters/AssignFilter.hpp>
#include <pdal/filters/ReprojectionFilter.hpp>
#include <pdal/filters/TransformationFilter.hpp>

#include <TargetConditionals.h>

// In-archive anchor for plugin-tree stages whose headers PDAL does
// not expose (e.g. `pdal::E57Reader`, which lives under
// `plugins/e57/io/`). `pdal-xcframework-builder` compiles
// `scripts/pdal_static_anchors.cpp` against the in-tree plugin
// headers, merges the resulting `.o` into `libpdalcpp.a`, and exposes
// this single `extern "C"` entry point. Calling it once is enough to
// drag the anchor TU — and transitively each plugin's `.o` — out of
// the archive on iOS. On macOS pdalcpp is a dynamic framework so the
// stages stay live regardless; the symbol isn't exported from the
// dylib, so we only reference it on iOS.
#if TARGET_OS_IOS
extern "C" void pdal_ensure_static_plugins();
#endif

namespace swiftpdal {

namespace {

template <class T>
void anchor(volatile void** sink) {
    T* p = new T();
    *sink = static_cast<void*>(p);
    delete p;
}

} // namespace

// Called once from pdal_wrapper.cpp's translation unit. The reference
// from a Swift-reachable TU is what keeps *this* TU linked into
// CxxPDAL.a, which in turn drags in each anchored stage's `.o` from
// libpdalcpp.a.
void ensureStaticPluginsLinked() {
    volatile void* sink = nullptr;

    // Readers.
    anchor<pdal::LasReader>(&sink);
    anchor<pdal::PlyReader>(&sink);
    anchor<pdal::TextReader>(&sink);
    anchor<pdal::CopcReader>(&sink);
    anchor<pdal::BufferReader>(&sink);

    // Writers.
    anchor<pdal::LasWriter>(&sink);
    anchor<pdal::PlyWriter>(&sink);
    anchor<pdal::TextWriter>(&sink);
    anchor<pdal::CopcWriter>(&sink);

    // Filters.
    anchor<pdal::RangeFilter>(&sink);
    anchor<pdal::AssignFilter>(&sink);
    anchor<pdal::ReprojectionFilter>(&sink);
    anchor<pdal::TransformationFilter>(&sink);

#if TARGET_OS_IOS
    pdal_ensure_static_plugins();
#endif

    (void)sink;
}

} // namespace swiftpdal
