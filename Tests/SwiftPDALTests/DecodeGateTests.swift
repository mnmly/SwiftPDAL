import Testing
import Foundation
@testable import SwiftPDAL

/// Lock-protected concurrency tracker: counts how many tasks are
/// simultaneously inside the critical section and remembers the peak.
private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxObserved = 0

    func enter() {
        lock.withLock {
            current += 1
            if current > maxObserved { maxObserved = current }
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

/// Lock-protected completion counter for deterministic polling.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// Poll `condition` until true or `timeout` elapses. Returns whether it
/// became true. Avoids asserting on a bare sleep.
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite struct DecodeGateTests {
    @Test func capRespected() async {
        let gate = StreamingDecodeGate(limit: 3)
        let tracker = ConcurrencyTracker()
        let done = Counter()
        let total = 12

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask {
                    await gate.acquire()
                    tracker.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    tracker.leave()
                    gate.release()
                    done.increment()
                }
            }
        }

        #expect(done.count == total)
        #expect(tracker.maxObserved <= 3)
        #expect(tracker.maxObserved >= 1)
    }

    @Test func raiseResumesWaiters() async {
        let gate = StreamingDecodeGate(limit: 1)
        let tracker = ConcurrencyTracker()
        let entered = Counter()
        let release = ReleaseToken()
        let waiterCount = 5

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<waiterCount {
                group.addTask {
                    await gate.acquire()
                    tracker.enter()
                    entered.increment()
                    await release.wait()
                    tracker.leave()
                    gate.release()
                }
            }

            // Only one should get in under limit 1.
            _ = await waitUntil { entered.count == 1 }
            #expect(entered.count == 1)

            // Raise the limit; up to 4 parked waiters should resume.
            gate.setLimit(4)

            let reached = await waitUntil { entered.count == 4 }
            #expect(reached)
            #expect(tracker.maxObserved <= 4)

            // Let everyone finish and drain.
            release.fire()
        }

        #expect(entered.count == waiterCount)
        #expect(tracker.maxObserved <= 4)
    }

    @Test func lowerAppliesLazily() async {
        let gate = StreamingDecodeGate(limit: 4)
        let tracker = ConcurrencyTracker()
        let holdRelease = ReleaseToken()
        let lateEntered = Counter()
        let holders = 4

        await withTaskGroup(of: Void.self) { group in
            // Fill all 4 slots and hold them.
            for _ in 0..<holders {
                group.addTask {
                    await gate.acquire()
                    tracker.enter()
                    await holdRelease.wait()
                    tracker.leave()
                    gate.release()
                }
            }
            _ = await waitUntil { tracker.maxObserved == 4 }

            // Lower the limit while all 4 are in flight.
            gate.setLimit(1)
            #expect(gate.currentLimit == 1)

            // A new acquirer must park — no headroom (4 in flight > limit 1).
            group.addTask {
                await gate.acquire()
                tracker.enter()
                lateEntered.increment()
                try? await Task.sleep(for: .milliseconds(10))
                tracker.leave()
                gate.release()
            }

            // It shouldn't proceed while holders are still in.
            try? await Task.sleep(for: .milliseconds(50))
            #expect(lateEntered.count == 0)

            // Release the 4 holders; in-flight drops, late acquirer proceeds.
            holdRelease.fire()

            let proceeded = await waitUntil { lateEntered.count == 1 }
            #expect(proceeded)
        }

        #expect(lateEntered.count == 1)
        #expect(tracker.maxObserved <= 4)
    }

    @Test func clampsToOne() async {
        let gate = StreamingDecodeGate(limit: 1)
        gate.setLimit(0)
        #expect(gate.currentLimit == 1)

        let tracker = ConcurrencyTracker()
        let done = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await gate.acquire()
                    tracker.enter()
                    try? await Task.sleep(for: .milliseconds(10))
                    tracker.leave()
                    gate.release()
                    done.increment()
                }
            }
        }

        #expect(done.count == 4)
        #expect(tracker.maxObserved == 1)
    }
}

/// One-shot async gate: callers `await wait()` until `fire()` is called,
/// then all (current and future) waiters proceed. Deterministic checkpoint
/// for releasing held slots without timing guesswork.
private final class ReleaseToken: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if fired { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }

    func fire() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            fired = true
            let w = waiters
            waiters.removeAll()
            return w
        }
        for c in toResume { c.resume() }
    }
}
