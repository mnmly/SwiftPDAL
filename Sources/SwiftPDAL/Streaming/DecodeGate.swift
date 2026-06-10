import Foundation

/// Process-wide, adjustable cap on concurrent LAZ decodes across **all**
/// open streaming sources.
///
/// Each ``CopcStreamingPointCloudSource`` runs its own pool of
/// ``StreamingOptions/decodeConcurrency`` decode workers. With several
/// sources open at once (a mosaic of COPC tiles) the aggregate decode
/// parallelism is the sum of every source's pool, which can saturate the
/// host process — CPU cores, malloc locks, and memory bandwidth — and
/// starve other in-process work such as an embedded editor. This gate
/// bounds that aggregate at a single, shared limit.
///
/// The limit is adjustable at runtime: a host may lower it (e.g. to `2`)
/// while a latency-sensitive UI is focused and restore it afterward via
/// ``currentLimit``. Lowering applies lazily — running decodes finish and
/// new acquires park until headroom frees up — so there is no preemption.
///
/// The implementation is a hand-rolled adjustable async semaphore built on
/// `NSLock` plus parked `CheckedContinuation`s, mirroring the package's
/// internal `JobQueue`: continuations are always resumed *outside* the
/// lock, and every parked waiter is guaranteed to be resumed by either
/// the internal `release()` path or ``setLimit(_:)``.
public final class StreamingDecodeGate: @unchecked Sendable {
    /// The shared process-wide gate used by every streaming source.
    public static let shared = StreamingDecodeGate()

    private let lock = NSLock()
    private var limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Default limit: leave two cores free for the rest of the process,
    /// but never drop below two concurrent decodes.
    private static var defaultLimit: Int {
        max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    private init() {
        self.limit = StreamingDecodeGate.defaultLimit
    }

    /// Test-only initializer that constructs an independent gate with an
    /// explicit starting limit, so tests don't perturb ``shared``.
    ///
    /// - Parameter limit: The initial concurrency cap; clamped to ≥ 1.
    internal init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// The current concurrency cap.
    ///
    /// Lock-protected so a host that lowered the limit can read back the
    /// effective value before restoring it.
    public var currentLimit: Int {
        lock.withLock { limit }
    }

    /// Set a new concurrency cap, taking effect immediately.
    ///
    /// Raising the limit resumes as many parked waiters as the new
    /// headroom allows (each counted as in-flight before being resumed).
    /// Lowering the limit applies lazily: in-flight decodes are never
    /// preempted; subsequent acquires park until releases free up room.
    ///
    /// - Parameter newLimit: The desired cap; clamped to ≥ 1.
    public func setLimit(_ newLimit: Int) {
        let clamped = max(1, newLimit)
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            limit = clamped
            var resumed: [CheckedContinuation<Void, Never>] = []
            while inFlight < limit, !waiters.isEmpty {
                inFlight += 1
                resumed.append(waiters.removeFirst())
            }
            return resumed
        }
        for c in toResume { c.resume() }
    }

    /// Wait until a decode slot is available, then claim it.
    ///
    /// Returns immediately if the in-flight count is below the limit;
    /// otherwise parks FIFO until a ``release()`` or ``setLimit(_:)``
    /// hands off a slot. Always pair with exactly one ``release()``.
    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            enum Action { case resume, wait }
            // No await happens while holding the lock.
            let action: Action = lock.withLock {
                if inFlight < limit {
                    inFlight += 1
                    return .resume
                }
                waiters.append(c)
                return .wait
            }
            switch action {
            case .resume: c.resume()
            case .wait: break
            }
        }
    }

    /// Return a previously acquired slot.
    ///
    /// Hands the freed slot to the oldest parked waiter when one exists
    /// and there is room under the current limit; otherwise just lowers
    /// the in-flight count.
    func release() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            inFlight -= 1
            if inFlight < limit, !waiters.isEmpty {
                inFlight += 1
                return waiters.removeFirst()
            }
            return nil
        }
        toResume?.resume()
    }
}
