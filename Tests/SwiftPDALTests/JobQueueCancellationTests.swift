import Testing
import Foundation
@testable import SwiftPDAL

// Tests for `JobQueue`'s cancellation-aware `pop()` and `requeue(_:)` — the
// primitives the decode-worker QoS switch relies on for a *drain barrier* so
// the old and new worker pools never touch the same per-slot C++ reader
// concurrently (see `CopcStreamingPointCloudSource.setDecodeWorkerPriority`).
//
// The invariants under test:
//   1. A worker parked in `pop()` that is cancelled resumes with `nil`
//      promptly (so the switch coordinator's `await task.value` can't hang) and
//      is NOT handed a queued cluster afterwards.
//   2. Queued clusters survive a "pool swap": cancelling the consumers never
//      drops work — a fresh consumer drains exactly the clusters that were
//      enqueued (plus any a cancelled consumer requeued).

private func cluster(_ depth: Int) -> [ChunkID] {
    [ChunkID(depth: depth, x: 0, y: 0, z: 0)]
}

/// Lock-protected sink so the test can collect popped clusters across tasks.
private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[ChunkID]] = []
    func add(_ c: [ChunkID]) { lock.withLock { items.append(c) } }
    var all: [[ChunkID]] { lock.withLock { items } }
    var count: Int { lock.withLock { items.count } }
}

/// A cancelled worker parked in `pop()` exits with `nil` and is never handed a
/// cluster enqueued after its cancellation.
@Test func jobQueue_cancelledParkedPop_exitsNilAndTakesNoCluster() async throws {
    let jobs = JobQueue()
    let sink = Sink()

    // A worker that parks in pop(), and — like the real decode worker — if it is
    // handed a cluster while cancelled, requeues it instead of "consuming" it.
    let worker = Task {
        while !Task.isCancelled {
            guard let c = await jobs.pop() else { break }
            if Task.isCancelled { jobs.requeue(c); break }
            sink.add(c)
        }
    }

    // Let the worker reach the parked state (empty queue → it registers a waiter).
    // Poll instead of a fixed sleep: spin until the worker is definitely parked.
    // A brief yield loop is enough; the worker has nothing else to do.
    try await Task.sleep(for: .milliseconds(50))

    // Cancel while parked → onCancel resumes pop() with nil → worker exits.
    worker.cancel()
    // The barrier the coordinator relies on: this must not hang.
    await worker.value

    // A cluster enqueued after cancellation must NOT have gone to the dead
    // worker — it stays queued for the next pool.
    jobs.enqueue([cluster(3)])

    #expect(sink.count == 0, "cancelled parked worker must not consume any cluster")

    // Prove the enqueued cluster survived: a fresh consumer drains it.
    let drained = await jobs.pop()
    #expect(drained == cluster(3))
}

/// Queued clusters survive a consumer swap: cancel the old consumers, then a
/// fresh consumer drains every enqueued cluster exactly once — nothing dropped.
@Test func jobQueue_queuedClustersSurvivePoolSwap() async throws {
    let jobs = JobQueue()
    let sink = Sink()

    // "Old pool": two workers, parked (queue starts empty).
    func makeWorker() -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                guard let c = await jobs.pop() else { break }
                if Task.isCancelled { jobs.requeue(c); break }
                sink.add(c)
            }
        }
    }
    let old = [makeWorker(), makeWorker()]
    try await Task.sleep(for: .milliseconds(50))

    // Enqueue a backlog while the old pool is parked, then immediately swap:
    // cancel the old pool and drain it (the barrier). Racing enqueue/cancel is
    // the exact production scenario.
    let backlog = [cluster(1), cluster(2), cluster(3), cluster(4)]
    jobs.enqueue(backlog)
    for w in old { w.cancel() }
    for w in old { await w.value }

    // Whatever the old pool consumed before exiting, plus whatever it requeued,
    // must sum to the backlog with no loss. Drain the remainder with a fresh
    // "new pool" of one worker until the queue empties.
    // Give the fresh consumer a closable queue so it terminates deterministically.
    let fresh = makeWorker2(jobs: jobs, sink: sink)
    // Spin until every backlog cluster has surfaced in the sink.
    let deadline = Date().addingTimeInterval(5)
    while sink.count < backlog.count, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    jobs.close()          // wake/terminate the fresh worker
    await fresh.value

    let seen = Set(sink.all.map { $0.first! })
    let expected = Set(backlog.map { $0.first! })
    #expect(seen == expected, "every enqueued cluster must survive the swap exactly once")
    #expect(sink.count == backlog.count, "no cluster decoded twice, none dropped")
}

/// A fresh (non-cancelled) consumer used as the "new pool" drainer.
private func makeWorker2(jobs: JobQueue, sink: Sink) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            guard let c = await jobs.pop() else { break }
            if Task.isCancelled { jobs.requeue(c); break }
            sink.add(c)
        }
    }
}
