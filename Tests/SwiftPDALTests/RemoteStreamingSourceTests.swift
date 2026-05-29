// Tests for the COPC-over-HTTP streaming path (open(remoteURL:)).
//
// A minimal range-capable HTTP server (Network framework) serves the bundled
// test.copc.laz over localhost. We then open the same fixture both locally and
// remotely and assert the parsed hierarchy + a full concurrent decode agree —
// proving the HTTP-range istream feeds copc-lib byte-for-byte identical data,
// with independent per-slot stream positions under concurrency.
//
// macOS-only: the embedded server runs host-side, same as StreamingBench.
#if os(macOS)

import Testing
import Foundation
import Network
import simd
@testable import SwiftPDAL

private func fixtureURL() -> URL? {
    guard let path = Bundle.module.path(forResource: "test.copc", ofType: "laz") else {
        return nil
    }
    return URL(fileURLWithPath: path)
}

/// A tiny HTTP/1.1 server that serves one in-memory blob with `Range:`
/// support (206 Partial Content). Just enough for URLSession-backed
/// copc-lib reads — GET + HEAD, byte ranges, keep-alive.
private final class RangeHTTPServer: @unchecked Sendable {
    private let data: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RangeHTTPServer")
    private let lock = NSLock()
    private var _partialContentResponses = 0
    private var _fullResponses = 0

    /// Number of `206 Partial Content` responses served so far.
    var partialContentResponses: Int { lock.withLock { _partialContentResponses } }
    /// Number of `200 OK` (full-body) responses served so far.
    var fullResponses: Int { lock.withLock { _fullResponses } }

    init(serving data: Data) throws {
        self.data = data
        let params = NWParameters.tcp
        self.listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
    }

    /// Starts listening and returns the bound localhost port.
    func start() async -> UInt16 {
        await withCheckedContinuation { cont in
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let port = self?.listener.port {
                    cont.resume(returning: port.rawValue)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(on: conn, buffer: Data())
    }

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }

            // Process any complete request headers in the buffer (no bodies:
            // we only handle GET/HEAD).
            let terminator = Data("\r\n\r\n".utf8)
            while let range = buf.range(of: terminator) {
                let header = buf.subdata(in: buf.startIndex..<range.lowerBound)
                buf.removeSubrange(buf.startIndex..<range.upperBound)
                self.respond(to: header, on: conn)
            }

            if let error {
                _ = error
                conn.cancel()
                return
            }
            if isComplete {
                conn.cancel()
                return
            }
            self.receive(on: conn, buffer: buf)
        }
    }

    private func respond(to header: Data, on conn: NWConnection) {
        guard let text = String(data: header, encoding: .utf8) else {
            conn.cancel(); return
        }
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { conn.cancel(); return }
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"

        // Parse an optional `Range: bytes=a-b` header.
        var rangeStart: Int? = nil
        var rangeEnd: Int? = nil
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:"), let eq = line.firstIndex(of: "=") {
                let spec = line[line.index(after: eq)...]
                let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
                if let a = bounds.first, let start = Int(a) {
                    rangeStart = start
                    if bounds.count > 1, let end = Int(bounds[1]) {
                        rangeEnd = end
                    }
                }
            }
        }

        let total = data.count
        var responseHead: String
        var bodyRange: Range<Int>? = nil

        if let start = rangeStart, start < total {
            let end = min(rangeEnd ?? (total - 1), total - 1)
            let length = end - start + 1
            lock.withLock { _partialContentResponses += 1 }
            responseHead = """
            HTTP/1.1 206 Partial Content\r
            Accept-Ranges: bytes\r
            Content-Range: bytes \(start)-\(end)/\(total)\r
            Content-Length: \(length)\r
            Connection: keep-alive\r
            \r

            """
            bodyRange = start..<(start + length)
        } else {
            lock.withLock { _fullResponses += 1 }
            responseHead = """
            HTTP/1.1 200 OK\r
            Accept-Ranges: bytes\r
            Content-Length: \(total)\r
            Connection: keep-alive\r
            \r

            """
            bodyRange = 0..<total
        }

        var payload = Data(responseHead.utf8)
        if method != "HEAD", let r = bodyRange {
            payload.append(data.subdata(in: r))
        }
        conn.send(content: payload, completion: .contentProcessed { _ in })
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

/// A view-projection that admits the entire hierarchy (every AABB passes the
/// frustum test), for pure decode-throughput coverage. Mirrors StreamingBench.
private func admitAllView(bounds: Bounds) -> StreamingCameraView {
    var vp = simd_float4x4(0)
    vp.columns.3 = SIMD4<Float>(0, 0, 0, 1)
    let center = (bounds.min + bounds.max) * 0.5
    let radius = simd_length(bounds.max - bounds.min) * 2
    return StreamingCameraView(
        position: center + SIMD3<Float>(0, 0, radius),
        viewProjection: vp,
        pixelScale: 1000,
        depthTolerance: 32
    )
}

@Test func remoteStreamingSource_matchesLocalOpen() async throws {
    guard let url = fixtureURL() else {
        Issue.record("test.copc.laz fixture missing")
        return
    }
    let fileData = try Data(contentsOf: url)
    let server = try RangeHTTPServer(serving: fileData)
    let port = await server.start()
    defer { server.stop() }

    let remoteURL = URL(string: "http://127.0.0.1:\(port)/test.copc.laz")!

    // Parse the same file locally and remotely; the header/hierarchy must agree.
    let local = try await CopcStreamingPointCloudSource.open(url, options: .init(
        prefetchRoot: false, driverTickInterval: .milliseconds(10)
    ))
    defer { local.close() }

    let remote = try await CopcStreamingPointCloudSource.open(
        remoteURL: remoteURL,
        options: .init(
            maxInFlightLoads: 16,
            decodeConcurrency: 4,            // >1: exercise per-slot independent streams
            prefetchRoot: false,
            evictionDelayTicks: 100,
            driverTickInterval: .milliseconds(10)
        )
    )
    defer { remote.close() }

    #expect(remote.info.totalPoints == local.info.totalPoints,
            "remote totalPoints (\(remote.info.totalPoints)) must match local (\(local.info.totalPoints))")
    #expect(remote.info.bounds.min == local.info.bounds.min, "bounds.min mismatch")
    #expect(remote.info.bounds.max == local.info.bounds.max, "bounds.max mismatch")
    #expect(remote.info.maxDepth == local.info.maxDepth, "maxDepth mismatch")

    // Concurrent full decode over the network: residency should converge to
    // the complete point set, proving the per-slot HTTP streams don't race.
    remote.setBudget(Int.max)
    remote.submit(view: admitAllView(bounds: remote.info.bounds))

    var distinct = Set<ChunkID>()
    var residentPoints = 0
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(50))
        if let update = remote.pollLatest() {
            for chunk in update.added where distinct.insert(chunk.id).inserted {
                residentPoints += chunk.totalPointCount
            }
        }
        let snap = await remote._debugSnapshot()
        if snap.resident == snap.wanted && snap.inFlight == 0 && snap.wanted > 0 {
            try await Task.sleep(for: .milliseconds(60))
            if let update = remote.pollLatest() {
                for chunk in update.added where distinct.insert(chunk.id).inserted {
                    residentPoints += chunk.totalPointCount
                }
            }
            break
        }
    }

    #expect(residentPoints == Int(remote.info.totalPoints),
            "remote concurrent decode should load every point (got \(residentPoints) of \(remote.info.totalPoints))")
    // The reads must have gone over byte ranges, not one full GET.
    #expect(server.partialContentResponses > 1,
            "expected multiple 206 Partial Content responses (got \(server.partialContentResponses))")
}

#endif
