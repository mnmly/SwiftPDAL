//
//  e57_init_guard.h
//  SwiftPDAL
//
//  Serializes libE57Format's Xerces-C bring-up across threads.
//
//  Why
//  ---
//  libE57Format constructs a SAX2 parser per E57 open and calls
//  `XMLPlatformUtils::Initialize()` in `E57XmlParser::init()` and
//  `Terminate()` in its destructor — the source even comments
//  "This is not thread safe for multiple simultaneous E57 readers."
//  Xerces gates its real global init/cleanup on a non-atomic refcount,
//  so two concurrent first-time opens crash inside `XMLPlatformUtils`
//  (seen as a SIGSEGV in `XMLMutexLock`).
//
//  The parser is a local in libE57Format's `ImageFileImpl::construct2`,
//  so the entire Initialize → parse → Terminate cycle is confined to the
//  E57 file *open* — i.e. to PDAL's `Stage::prepare()` (which runs
//  `E57Reader::initialize()`) or to a direct `e57::Reader` construction.
//  Nothing Xerces-related happens afterward; point reading is binary.
//
//  Holding ``E57InitGuard`` around those open sites therefore makes
//  concurrent E57 reads safe without serializing the heavy read phase:
//  it engages only for `.e57` inputs and is a no-op otherwise.
//

#ifndef SWIFTPDAL_E57_INIT_GUARD_H
#define SWIFTPDAL_E57_INIT_GUARD_H

#ifdef __cplusplus

#include <mutex>
#include <string>
#include <cctype>

namespace swiftpdal {

/// Process-wide mutex guarding libE57Format/Xerces initialization.
/// Defined via an inline function so all translation units share one
/// instance.
inline std::mutex& e57_init_mutex() {
    static std::mutex m;
    return m;
}

/// RAII lock engaged only for `.e57` filenames. Lock for the duration of
/// an E57 open (`prepare()` / `e57::Reader` construction); a no-op for
/// every other format.
struct E57InitGuard {
    std::unique_lock<std::mutex> lock;
    explicit E57InitGuard(const std::string& filename) {
        if (isE57(filename)) {
            lock = std::unique_lock<std::mutex>(e57_init_mutex());
        }
    }

    static bool isE57(const std::string& filename) {
        const std::string suffix = ".e57";
        if (filename.size() < suffix.size()) return false;
        std::string tail = filename.substr(filename.size() - suffix.size());
        for (char& c : tail) c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
        return tail == suffix;
    }
};

} // namespace swiftpdal

#endif // __cplusplus
#endif // SWIFTPDAL_E57_INIT_GUARD_H
