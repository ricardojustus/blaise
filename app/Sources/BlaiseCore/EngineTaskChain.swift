import Foundation

/// One-shot gate: `wait()` suspends until `open()`. Waiting is promptly
/// cancellable (cancellation handler resumes the waiter with
/// `CancellationError` without waiting for the gate). `whenOpen` callbacks
/// fire on open (immediately if already open).
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private var callbacks: [@Sendable () -> Void] = []

    /// A gate that starts open (the chain's initial tail).
    static func opened() -> OneShotGate {
        let gate = OneShotGate()
        gate.open()
        return gate
    }

    /// Whether the gate has opened (race-correct snapshot).
    func opened() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    func open() {
        lock.lock()
        guard !isOpen else {
            lock.unlock()
            return
        }
        isOpen = true
        let resumable = waiters
        waiters.removeAll()
        let pending = callbacks
        callbacks.removeAll()
        lock.unlock()
        for (_, continuation) in resumable { continuation.resume() }
        for callback in pending { callback() }
    }

    /// Runs `callback` once the gate opens (immediately if already open).
    func whenOpen(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        if isOpen {
            lock.unlock()
            callback()
            return
        }
        callbacks.append(callback)
        lock.unlock()
    }

    /// Suspends until open; throws `CancellationError` promptly if the
    /// waiting task is cancelled (the gate itself is unaffected).
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledWaiters.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard let continuation = waiters.removeValue(forKey: id) else {
                // Cancelled before the continuation was stored.
                cancelledWaiters.insert(id)
                lock.unlock()
                return
            }
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// Explicit FIFO single-flight chain (C3 spec, "Serialization"): actor
/// isolation is NOT serialization — actors are reentrant at suspension
/// points. Public engine entry points are chain links; their bodies are
/// un-chained.
///
/// Normative semantics carried here:
/// - Link isolation: a link's failure or cancellation never propagates to
///   queued links; each link's gate always opens.
/// - Queued cancellation is prompt: the wait-for-turn is wrapped in a
///   cancellation handler; a cancelled queued call throws
///   `EngineError.cancelled` without waiting for the running job, and its
///   gate is opened when its predecessor's opens (the chain stays healthy).
final class EngineTaskChain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = OneShotGate.opened()

    /// Atomically swaps in our gate as the new tail; returns the predecessor.
    private func enqueue(_ myGate: OneShotGate) -> OneShotGate {
        lock.lock()
        defer { lock.unlock() }
        let previousGate = tail
        tail = myGate
        return previousGate
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let myGate = OneShotGate()
        let previousGate = enqueue(myGate)

        do {
            try await previousGate.wait()
        } catch {
            // Cancelled while queued: bail promptly, keep FIFO order intact.
            previousGate.whenOpen { myGate.open() }
            throw EngineError.cancelled
        }
        defer { myGate.open() }
        if Task.isCancelled { throw EngineError.cancelled }
        return try await operation()
    }
}
