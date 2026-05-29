#ifndef SWIFTPDAL_HTTP_STREAM_H
#define SWIFTPDAL_HTTP_STREAM_H

#include <istream>
#include <memory>
#include <string>

// HTTP-range-backed std::istream for copc-lib.
//
// copc-lib's Reader(std::istream*) reads the LAS header + COPC hierarchy at
// construction and then seeks/reads individual node byte ranges on demand. We
// back that istream with HTTP `Range:` requests (via Foundation URLSession,
// implemented in http_stream.mm) so a COPC file can be streamed straight from
// an http(s):// URL with no full download.
//
// The interface here is deliberately plain C++ — no Objective-C types — so the
// pure-C++ copc_bridge.cpp translation unit can include it. http_stream.mm is
// the only Objective-C++ TU.
namespace swiftpdal { namespace copc {

/// Create an HTTP-range-backed input stream for `url`.
///
/// Performs one synchronous ranged request at construction to learn the total
/// content length (needed to bound end-relative seeks). Subsequent reads issue
/// `Range:` GETs on demand, buffered with read-ahead.
///
/// Each returned stream owns an independent read position and its own
/// URLSession, so callers may use one stream per decode slot concurrently
/// without locking (matching the bridge's one-slot-per-thread contract).
///
/// - url: An http:// or https:// URL.
/// - Returns: An owning std::istream (delete to release the stream + its
///   streambuf), or nullptr if the resource could not be opened (bad URL,
///   network failure, server lacks range support / returns no length).
std::unique_ptr<std::istream> OpenHttpRangeStream(const std::string& url);

}} // namespace swiftpdal::copc

#endif // SWIFTPDAL_HTTP_STREAM_H
