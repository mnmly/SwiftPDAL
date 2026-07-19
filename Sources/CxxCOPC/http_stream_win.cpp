// Windows stub for the HTTP-range-backed istream (see http_stream.h).
//
// The canonical implementation (http_stream.mm) is Objective-C++ backed by
// Foundation URLSession, which has no Windows equivalent. Rather than pull in a
// WinHTTP/libcurl dependency, this stub reports the remote-COPC-over-HTTP path
// as unavailable on Windows: OpenHttpRangeStream returns nullptr, which
// copc_bridge.cpp already treats as an open failure. Local-file COPC decoding
// is unaffected. A real WinHTTP/libcurl streambuf can replace this later.
#include "http_stream.h"

namespace swiftpdal { namespace copc {

std::unique_ptr<std::istream> OpenHttpRangeStream(const std::string& /*url*/) {
    return nullptr;
}

}} // namespace swiftpdal::copc
