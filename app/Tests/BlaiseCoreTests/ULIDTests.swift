import Foundation
import Testing
@testable import BlaiseCore

@Suite struct ULIDTests {
    @Test func formatIs26CrockfordChars() {
        let alphabet = Set(ULID.alphabet)
        for _ in 0..<100 {
            let ulid = ULID.generate()
            #expect(ulid.count == 26)
            #expect(ulid.allSatisfy { alphabet.contains($0) })
        }
    }

    @Test func uniqueness() {
        var seen = Set<String>()
        for _ in 0..<10_000 {
            seen.insert(ULID.generate())
        }
        #expect(seen.count == 10_000)
    }

    @Test func timeOrdering() {
        // Tests run in parallel and the monotonic generator state is global,
        // so use timestamps far beyond anything another test feeds it
        // (sameMillisecondMonotonicity uses now+7200s) to guarantee the
        // fresh-millisecond branch.
        let base = Date().addingTimeInterval(10 * 86_400)
        let earlier = ULID.generate(now: base)
        let later = ULID.generate(now: base.addingTimeInterval(1.0))
        #expect(earlier < later)
        // Distinct milliseconds → distinct 10-char time prefixes.
        #expect(earlier.prefix(10) != later.prefix(10))
    }

    @Test func sameMillisecondMonotonicity() {
        let now = Date().addingTimeInterval(7200)
        var previous = ULID.generate(now: now)
        for _ in 0..<1_000 {
            let next = ULID.generate(now: now)
            #expect(next > previous, "ULIDs within the same millisecond must be strictly increasing")
            previous = next
        }
    }
}
