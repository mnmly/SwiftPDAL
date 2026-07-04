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
/// ## Priority lane
///
/// Waiters park in one of two FIFO lanes. A freed slot is handed to the
/// oldest *priority* waiter first, falling back to the oldest *normal*
/// waiter only when the priority lane is empty. Callers mark the
/// coarse-coverage nodes of a newly-visible cloud — a COPC octree's
/// root/near-root depths — as priority via ``acquire(priority:)`` so their
/// time-to-first-points isn't blocked behind dozens of far-cloud leaf-node
/// decodes when many sources are open at once.
///
/// The normal lane cannot starve indefinitely: priority work is confined to
/// the coarse depths of each octree, which are a small, bounded fraction of
/// any COPC's node set (a handful of nodes near the root versus the
/// exponentially larger leaf population), so the priority lane drains and
/// normal waiters make progress.
///
/// The implementation is a hand-rolled adjustable async semaphore built on
/// `NSLock` plus parked `CheckedContinuation`s, mirroring the package's
/// internal `JobQueue`: continuations are always resumed *outside* the
/// lock, and every parked waiter — in either lane — is guaranteed to be
/// resumed by either the internal `release()` path or ``setLimit(_:)``.
public final class StreamingDecodeGate: @unchecked Sendable {
    /// The shared process-wide gate used by every streaming source.
    public static let shared = StreamingDecodeGate()

    private let lock = NSLock()
    private var limit: Int
    private var inFlight: Int = 0
    /// Waiters that requested priority (coarse-coverage nodes); drained first.
    private var priorityWaiters: [CheckedContinuation<Void, Never>] = []
    /// Ordinary waiters; drained only when the priority lane is empty.
    private var normalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Dequeue the next waiter to hand a freed slot to — the oldest priority
    /// waiter, else the oldest normal waiter, else `nil` (both lanes FIFO).
    /// Must be called with `lock` held.
    private func dequeueNextWaiter() -> CheckedContinuation<Void, Never>? {
        if !priorityWaiters.isEmpty { return priorityWaiters.removeFirst() }
        if !normalWaiters.isEmpty { return normalWaiters.removeFirst() }
        return nil
    }

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
    /// headroom allows (priority lane first, then normal — each counted as
    /// in-flight before being resumed). Lowering the limit applies lazily:
    /// in-flight decodes are never preempted; subsequent acquires park until
    /// releases free up room.
    ///
    /// - Parameter newLimit: The desired cap; clamped to ≥ 1.
    public func setLimit(_ newLimit: Int) {
        let clamped = max(1, newLimit)
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            limit = clamped
            var resumed: [CheckedContinuation<Void, Never>] = []
            while inFlight < limit, let c = dequeueNextWaiter() {
                inFlight += 1
                resumed.append(c)
            }
            return resumed
        }
        for c in toResume { c.resume() }
    }

    /// Wait until a decode slot is available, then claim it.
    ///
    /// Returns immediately if the in-flight count is below the limit;
    /// otherwise parks FIFO within its lane until a ``release()`` or
    /// ``setLimit(_:)`` hands off a slot. Always pair with exactly one
    /// ``release()``.
    ///
    /// - Parameter priority: When `true`, park in the priority lane so this
    ///   acquire is served before any normal waiter. Used for a cloud's
    ///   coarse-coverage nodes so their points reach the screen first.
    func acquire(priority: Bool = false) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            enum Action { case resume, wait }
            // No await happens while holding the lock.
            let action: Action = lock.withLock {
                if inFlight < limit {
                    inFlight += 1
                    return .resume
                }
                if priority {
                    priorityWaiters.append(c)
                } else {
                    normalWaiters.append(c)
                }
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
    /// Hands the freed slot to the oldest priority waiter (else the oldest
    /// normal waiter) when one exists and there is room under the current
    /// limit; otherwise just lowers the in-flight count.
    func release() {
        let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
            inFlight -= 1
            if inFlight < limit, let c = dequeueNextWaiter() {
                inFlight += 1
                return c
            }
            return nil
        }
        toResume?.resume()
    }
}
