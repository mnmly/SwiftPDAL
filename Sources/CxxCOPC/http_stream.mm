// HTTP-range-backed std::istream for copc-lib (see http_stream.h).
//
// A std::streambuf subclass that satisfies copc-lib's synchronous reads by
// issuing HTTP `Range:` requests via Foundation URLSession. copc-lib seeks to a
// node's byte offset (absolute, from beg) and reads its compressed block; we
// translate that into ranged GETs with a read-ahead buffer to amortize RTT.
//
// This is the only Objective-C++ translation unit; the header it exposes is
// pure C++ so copc_bridge.cpp can include it.

#import <Foundation/Foundation.h>

#include "http_stream.h"

#include <algorithm>
#include <cstring>
#include <streambuf>
#include <vector>

namespace {

// ARC-agnostic ObjC ownership helpers. SwiftPM does not enable ARC for .mm
// sources by default, but a consumer build setting could; __has_feature lets
// the same source compile correctly either way.
inline void* retainObj(id obj) {
#if __has_feature(objc_arc)
    return obj ? (void*)CFBridgingRetain(obj) : nullptr;
#else
    return (void*)[obj retain];
#endif
}
inline void releaseObj(void* p) {
    if (!p) return;
#if __has_feature(objc_arc)
    CFBridgingRelease(p);
#else
    [(id)p release];
#endif
}
inline id asObj(void* p) {
#if __has_feature(objc_arc)
    return (__bridge id)p;
#else
    return (id)p;
#endif
}

constexpr long long kReadAhead = 512 * 1024;   // bytes fetched per underflow
constexpr NSTimeInterval kRequestTimeout = 60.0;

class HttpRangeStreambuf : public std::streambuf {
public:
    HttpRangeStreambuf() = default;

    ~HttpRangeStreambuf() override {
        @autoreleasepool {
            if (session_) {
                [asObj(session_) invalidateAndCancel];
            }
        }
        releaseObj(session_);
        releaseObj(url_);
    }

    // One-time setup: store the URL, build a session, and learn the total
    // content length via a `bytes=0-0` probe. Returns false (caller discards)
    // if the resource can't be opened or the server doesn't honor ranges.
    bool open(const std::string& urlString) {
        @autoreleasepool {
            NSString* s = [NSString stringWithUTF8String:urlString.c_str()];
            NSURL* u = s ? [NSURL URLWithString:s] : nil;
            if (!u) return false;
            url_ = retainObj(u);

            NSURLSessionConfiguration* cfg =
                [NSURLSessionConfiguration ephemeralSessionConfiguration];
            cfg.timeoutIntervalForRequest = kRequestTimeout;
            cfg.HTTPShouldUsePipelining = YES;
            NSURLSession* sess = [NSURLSession sessionWithConfiguration:cfg];
            session_ = retainObj(sess);

            return probeLength();
        }
    }

protected:
    int_type underflow() override {
        if (fill_pos_ >= length_) return traits_type::eof();
        long long want = std::min<long long>(kReadAhead, length_ - fill_pos_);
        buf_.resize(static_cast<size_t>(want));
        long long got = httpRangeGet(fill_pos_, want, buf_.data());
        if (got <= 0) return traits_type::eof();
        buf_.resize(static_cast<size_t>(got));
        buf_off_ = fill_pos_;
        fill_pos_ += got;
        setg(buf_.data(), buf_.data(), buf_.data() + buf_.size());
        return traits_type::to_int_type(*gptr());
    }

    // Bulk read. copc-lib reads a node's whole compressed block contiguously;
    // for blocks larger than the read-ahead buffer we fetch straight into the
    // destination, skipping the intermediate copy.
    std::streamsize xsgetn(char* dst, std::streamsize n) override {
        std::streamsize total = 0;
        while (total < n) {
            std::streamsize avail = egptr() - gptr();
            if (avail > 0) {
                std::streamsize take = std::min<std::streamsize>(avail, n - total);
                std::memcpy(dst + total, gptr(), static_cast<size_t>(take));
                gbump(static_cast<int>(take));
                total += take;
                continue;
            }
            std::streamsize remaining = n - total;
            if (remaining >= static_cast<std::streamsize>(kReadAhead)) {
                long long want = std::min<long long>(remaining, length_ - fill_pos_);
                if (want <= 0) break;
                long long got = httpRangeGet(fill_pos_, want, dst + total);
                if (got <= 0) break;
                fill_pos_ += got;
                setg(nullptr, nullptr, nullptr);  // buffer no longer valid
                total += got;
                if (got < want) break;  // short read => EOF
            } else {
                if (underflow() == traits_type::eof()) break;
            }
        }
        return total;
    }

    pos_type seekpos(pos_type pos, std::ios_base::openmode which) override {
        return seekoff(off_type(pos), std::ios_base::beg, which);
    }

    pos_type seekoff(off_type off, std::ios_base::seekdir dir,
                     std::ios_base::openmode which) override {
        if (!(which & std::ios_base::in)) return pos_type(off_type(-1));

        long long target;
        if (dir == std::ios_base::beg) {
            target = off;
        } else if (dir == std::ios_base::cur) {
            target = current() + off;
        } else { // end
            target = length_ + off;
        }
        if (target < 0) return pos_type(off_type(-1));

        // Seek within the live buffer: just reposition gptr, no fetch.
        if (gptr() && target >= buf_off_ &&
            target <= buf_off_ + static_cast<long long>(egptr() - eback())) {
            setg(eback(), eback() + (target - buf_off_), egptr());
            return pos_type(off_type(target));
        }

        // Outside the buffer: drop it and remember where to refill.
        setg(nullptr, nullptr, nullptr);
        fill_pos_ = target;
        return pos_type(off_type(target));
    }

private:
    // Absolute position of the next byte the consumer will read.
    long long current() const {
        if (gptr()) return buf_off_ + (gptr() - eback());
        return fill_pos_;
    }

    // GET [offset, offset+want) into `dst`. Returns bytes written (may be < want
    // at EOF), or -1 on transport/protocol error. Requires the server to honor
    // ranges (206) for non-zero offsets.
    long long httpRangeGet(long long offset, long long want, char* dst) {
        if (want <= 0) return 0;
        __block long long result = -1;
        @autoreleasepool {
            NSMutableURLRequest* req =
                [NSMutableURLRequest requestWithURL:asObj(url_)];
            req.HTTPMethod = @"GET";
            NSString* range =
                [NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + want - 1];
            [req setValue:range forHTTPHeaderField:@"Range"];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSURLSessionDataTask* task = [asObj(session_)
                dataTaskWithRequest:req
                  completionHandler:^(NSData* data, NSURLResponse* response,
                                      NSError* error) {
                if (error || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
                    dispatch_semaphore_signal(sem);
                    return;
                }
                NSInteger status = [(NSHTTPURLResponse*)response statusCode];
                // 206 = honored range. 200 only acceptable at offset 0 (server
                // returned the whole body, leading bytes are what we want).
                if (status == 206 || (status == 200 && offset == 0)) {
                    long long copy = std::min<long long>(want,
                        static_cast<long long>(data.length));
                    if (copy > 0) {
                        std::memcpy(dst, data.bytes, static_cast<size_t>(copy));
                    }
                    result = copy;
                }
                dispatch_semaphore_signal(sem);
            }];
            [task resume];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
        return result;
    }

    // Learn total length via a `bytes=0-0` probe; parses Content-Range total.
    bool probeLength() {
        __block long long total = -1;
        @autoreleasepool {
            NSMutableURLRequest* req =
                [NSMutableURLRequest requestWithURL:asObj(url_)];
            req.HTTPMethod = @"GET";
            [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            NSURLSessionDataTask* task = [asObj(session_)
                dataTaskWithRequest:req
                  completionHandler:^(NSData* data, NSURLResponse* response,
                                      NSError* error) {
                if (error || ![response isKindOfClass:[NSHTTPURLResponse class]]) {
                    dispatch_semaphore_signal(sem);
                    return;
                }
                NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
                NSInteger status = [http statusCode];
                if (status == 206) {
                    NSString* cr = [http valueForHTTPHeaderField:@"Content-Range"];
                    // Format: "bytes 0-0/12345"
                    NSRange slash = [cr rangeOfString:@"/"];
                    if (cr && slash.location != NSNotFound) {
                        NSString* t = [cr substringFromIndex:slash.location + 1];
                        if (![t isEqualToString:@"*"]) {
                            total = [t longLongValue];
                        }
                    }
                } else if (status == 200) {
                    // Server ignored the range; fall back to full length if
                    // known. Ranged reads at offset 0 still work; non-zero
                    // offsets will be rejected at read time.
                    long long len = [http expectedContentLength];
                    if (len != NSURLResponseUnknownLength) total = len;
                }
                dispatch_semaphore_signal(sem);
            }];
            [task resume];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        }
        if (total < 0) return false;
        length_ = total;
        return true;
    }

    void* url_ = nullptr;       // NSURL* (ARC-agnostic)
    void* session_ = nullptr;   // NSURLSession*
    long long length_ = 0;      // total content length
    long long fill_pos_ = 0;    // absolute offset to fetch on next underflow
    long long buf_off_ = 0;     // absolute offset of buf_[0]
    std::vector<char> buf_;
};

// istream that owns its streambuf, so a single `delete` frees both.
class HttpRangeIStream : public std::istream {
public:
    explicit HttpRangeIStream(std::unique_ptr<HttpRangeStreambuf> buf)
        : std::istream(buf.get()), buf_(std::move(buf)) {}

private:
    std::unique_ptr<HttpRangeStreambuf> buf_;
};

} // namespace

namespace swiftpdal { namespace copc {

std::unique_ptr<std::istream> OpenHttpRangeStream(const std::string& url) {
    auto buf = std::make_unique<HttpRangeStreambuf>();
    if (!buf->open(url)) return nullptr;
    return std::make_unique<HttpRangeIStream>(std::move(buf));
}

}} // namespace swiftpdal::copc
