import Foundation
import Synchronization

// G10 §1: explicit cancel TOKEN for in-flight processing.
//
// Swift task cancellation rides the local heavy stages (SubprocessRunner's
// SIGTERM→SIGKILL, the diarizer's cooperative flag) — but the in-flight CLOUD
// attempt is SHIELDED from task cancellation: interrupting a sent Messages
// call would make Anthropic-side spend invisible to the ledger. So the cloud
// engine binds the cancel at ATTEMPT BOUNDARIES only, via this token: it is
// checked before each send (the max-tokens retry, the fallback hop, a new
// call), never mid-flight. The token is set FIRST at click (before the status
// write), so no send can start after the user clicks Cancel even if the
// status transaction is momentarily delayed.

/// A one-way cancel flag for a single in-flight pipeline run, shared between
/// the pipeline's stage checkpoints and the engine's attempt-boundary checks.
public final class CancellationToken: Sendable {
    private let cancelled = Mutex(false)

    public init() {}

    public var isCancelled: Bool { cancelled.withLock { $0 } }

    public func cancel() { cancelled.withLock { $0 = true } }

    /// Set around the cloud engine call by the pipeline so the engine can
    /// check the run's token at each attempt boundary WITHOUT the token being
    /// threaded through the engine-agnostic `generateNotes` signature (the
    /// swappable-engine interface stays unchanged).
    @TaskLocal public static var current: CancellationToken?
}
