import Foundation
import Synchronization

/// Minimal ULID generator: Crockford base32, 26 chars, time-ordered,
/// monotonic within the same millisecond by incrementing the random
/// component; on random-part overflow (astronomically unlikely) it spins to
/// the next millisecond. No external dependency.
public enum ULID {
    /// Crockford base32 alphabet (no I, L, O, U).
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static let randomMask: UInt128 = (UInt128(1) << 80) - 1

    private struct State {
        var lastMillis: UInt64 = 0
        var lastRandom: UInt128 = 0
    }

    private static let state = Mutex(State())

    /// A valid ULID: exactly 26 characters from the Crockford alphabet,
    /// first char ≤ "7" (48-bit timestamp bound).
    public static func isValid(_ s: String) -> Bool {
        guard s.count == 26, let first = s.first, first <= "7" else { return false }
        return s.allSatisfy { alphabet.contains($0) }
    }

    /// Generates a new 26-character ULID string.
    public static func generate(now: Date = Date()) -> String {
        let nowMillis = UInt64(now.timeIntervalSince1970 * 1000)
        let (millis, random): (UInt64, UInt128) = state.withLock { s in
            if nowMillis > s.lastMillis {
                s.lastMillis = nowMillis
                s.lastRandom = UInt128.random(in: 0...randomMask)
            } else if s.lastRandom == randomMask {
                // Random-part overflow: spin to the next millisecond.
                s.lastMillis += 1
                s.lastRandom = UInt128.random(in: 0...randomMask)
            } else {
                s.lastRandom += 1
            }
            return (s.lastMillis, s.lastRandom)
        }
        return encode(millis: millis, random: random)
    }

    private static func encode(millis: UInt64, random: UInt128) -> String {
        var chars: [Character] = []
        chars.reserveCapacity(26)
        for shift in stride(from: 45, through: 0, by: -5) {
            chars.append(alphabet[Int((millis >> UInt64(shift)) & 31)])
        }
        for shift in stride(from: 75, through: 0, by: -5) {
            chars.append(alphabet[Int((random >> UInt128(shift)) & 31)])
        }
        return String(chars)
    }
}
