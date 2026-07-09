import Foundation
import Testing
@testable import BlaiseCore

// Deterministic date-correction post-process: the model names the weekday from
// context, the app computes the exact ISO date. All data is fictional (Vexatron
// Labs / generic prose) — no real names, partners, or content.
//
// The meeting date used as the anchor is Monday 2026-06-15. Reference calendar
// for the week, so the expectations are self-checking:
//   2026-06-14 Sun, -15 Mon, -16 Tue, -17 Wed, -18 Thu, -19 Fri, -20 Sat,
//   2026-06-12 Fri, -13 Sat.
//
// NEW (narrow+safe) contract under test:
//   - VOCABULARY: only UNAMBIGUOUS weekday tokens — PT long forms (the `-feira`
//     weekdays + domingo/sábado) and EN full names. Bare PT short forms
//     (segunda/terça/quarta/quinta/sexta) are DROPPED (they collide with
//     ordinals/nouns).
//   - ADJACENCY: the weekday word must sit IMMEDIATELY before `(YYYY-MM-DD)`
//     (only 0–3 whitespace/light-punctuation chars between; never a letter or
//     digit).
//   - BOUNDARY: Unicode-aware — a weekday must not be a substring of a longer
//     word ("sextante" never matches "sexta").
//   - ±1 DAY ONLY: correct only an exactly-one-day-off slip; a ≥2-day
//     disagreement is left unchanged; a malformed ISO is left unchanged.
@Suite struct DigestDateNormalizerTests {
    /// A fixed time zone so the gregorian weekday arithmetic is deterministic
    /// regardless of the machine running the test.
    private let zone = TimeZone(identifier: "UTC")!

    /// Build a `Date` at the start of `y-m-d` in `zone` (no real-clock reads).
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        return cal.date(from: c)!
    }

    /// Meeting date: Monday 2026-06-15.
    private var meetingDate: Date { date(2026, 6, 15) }

    private func normalize(_ s: String) -> String {
        DigestDateNormalizer.normalize(s, meetingDate: meetingDate, timeZone: zone)
    }

    // MARK: - Off-by-one corrections (the dominant real slip)

    @Test func portugueseOffByOneFridayCorrected() {
        // 2026-06-13 is a Saturday; the named Friday is one day earlier, 06-12.
        let input = "A demo da Vexatron Labs ficou para sexta-feira (2026-06-13)."
        let output = normalize(input)
        #expect(output == "A demo da Vexatron Labs ficou para sexta-feira (2026-06-12).")
    }

    @Test func englishOffByOneFridayCorrected() {
        // 2026-06-13 is a Saturday; the named Friday is one day earlier, 06-12.
        let input = "The Vexatron review on Friday (2026-06-13) is confirmed."
        let output = normalize(input)
        #expect(output == "The Vexatron review on Friday (2026-06-12) is confirmed.")
    }

    @Test func accentVariantTercaRecognized() {
        // Both "terça-feira" and the accent-free "terca-feira" map to Tuesday.
        // 2026-06-15 is Monday → the named Tuesday is one day later, 06-16.
        let withAccent = "Reunião na terça-feira (2026-06-15)."
        let noAccent = "Reuniao na terca-feira (2026-06-15)."
        #expect(normalize(withAccent) == "Reunião na terça-feira (2026-06-16).")
        #expect(normalize(noAccent) == "Reuniao na terca-feira (2026-06-16).")
    }

    // MARK: - No-op cases (already correct)

    @Test func portugueseAlreadyCorrectIsNoop() {
        // 2026-06-18 IS a Thursday → unchanged.
        let input = "O follow-up na quinta-feira (2026-06-18) segue de pé."
        #expect(normalize(input) == input)
    }

    @Test func meetingDateLineWithCorrectWeekdayIsNoop() {
        // The meeting itself: Monday 2026-06-15 → already correct.
        let input = "Reunião de segunda-feira (2026-06-15) com a equipe Vexatron."
        #expect(normalize(input) == input)
    }

    @Test func dateWithNoAdjacentWeekdayWordIsUnchanged() {
        // A bare date with no weekday word before it is never touched, even
        // though 2026-06-13 is a Saturday.
        let input = "Em 2026-06-13, o time da Vexatron fechou o trimestre."
        #expect(normalize(input) == input)
    }

    // MARK: - Negative cases (audit-mandated — MUST be left unchanged)

    @Test func substringWeekdayInLongerWordNotMatched() {
        // "sextante" contains the substring "sexta" but is a different word.
        // The Unicode word boundary forbids a weekday matching as a prefix, and
        // "sexta" is not even in the vocabulary — so 06-13 is untouched.
        let input = "O sextante foi calibrado (2026-06-13)."
        #expect(normalize(input) == input)
    }

    @Test func weekdayEntityNotAdjacentToParenNotMatched() {
        // "Monday.com" names an entity; the word right before the paren is
        // "rollout", not a weekday, so the tight-adjacency rule declines. (And
        // "Monday" here is followed by ".com" letters, breaking the boundary.)
        // 06-18 is a Thursday but stays untouched.
        let input = "Monday.com rollout (2026-06-18)."
        #expect(normalize(input) == input)
    }

    @Test func droppedShortFormNotMatched() {
        // The bare short form "segundo" (ordinal/noun) must NEVER be read as the
        // weekday "segunda" — the short forms are dropped from the vocabulary,
        // so this date is left exactly as written.
        let input = "o segundo lugar (2026-06-13)"
        #expect(normalize(input) == input)
    }

    @Test func droppedShortFormSextaNotMatched() {
        // "sexta" alone (could be "sexta posição") is no longer in the
        // vocabulary — only "sexta-feira" is. 06-13 is left unchanged.
        let input = "Combinado para sexta posição (2026-06-13)."
        #expect(normalize(input) == input)
    }

    @Test func twoDayMismatchLeftUnchanged() {
        // 2026-06-18 is a Thursday; the named Saturday is TWO days later
        // (06-20). A ≥2-day disagreement is NOT a trustworthy ±1 slip, so it is
        // left exactly as written (more likely a genuinely different reference).
        let input = "Encerramento no sábado (2026-06-18)."
        #expect(normalize(input) == input)
    }

    @Test func threeDayMismatchLeftUnchanged() {
        // 2026-06-19 is a Friday; the named Monday is three days off — left as
        // written (under the old ±3 contract this was forced to 06-22; the
        // narrow ±1 contract declines).
        let input = "Combinado para segunda-feira (2026-06-19)."
        #expect(normalize(input) == input)
    }

    @Test func versionStringWithFarWeekdayWordLeftUnchanged() {
        // A weekday word appears in the sentence but a version string and other
        // words sit between it and the `(date)`, so the adjacency rule declines
        // — and even adjacent, 06-18 vs the named Sunday is a 4-day gap. Left
        // exactly as written.
        let input = "domingo lançamos a versão 2.1.0 do app (2026-06-18)."
        #expect(normalize(input) == input)
    }

    // MARK: - Multiple matches

    @Test func multipleMatchesAllCorrected() {
        // Both are Saturdays named as Fridays (±1) → both corrected to Friday.
        let input =
            "Vexatron: a demo na sexta-feira (2026-06-13) e depois "
            + "the review on Friday (2026-06-13) também."
        let output = normalize(input)
        #expect(output ==
            "Vexatron: a demo na sexta-feira (2026-06-12) e depois "
            + "the review on Friday (2026-06-12) também.")
    }

    @Test func mixedCorrectAndIncorrectInOneString() {
        // First is correct (Thursday 06-18), second is off-by-one (Sat→Fri).
        let input =
            "Vexatron sync: quinta-feira (2026-06-18) ok; review na sexta-feira (2026-06-13)."
        let output = normalize(input)
        #expect(output ==
            "Vexatron sync: quinta-feira (2026-06-18) ok; review na sexta-feira (2026-06-12).")
    }

    // MARK: - Longest-match alternation

    @Test func longestFormSextaFeiraTreatedAsFriday() {
        // "sexta-feira" must match as the long form (Friday), not be mis-split
        // into "sexta" + stray "-feira". 2026-06-13 is Saturday → Friday 06-12.
        let input = "Fechamos na sexta-feira (2026-06-13)."
        #expect(normalize(input) == "Fechamos na sexta-feira (2026-06-12).")
    }

    // MARK: - Malformed / non-adjacent input

    @Test func malformedISOLeftUnchanged() {
        // Month 13 / day 40 is not a calendar date → left exactly as written.
        let input = "Algo na sexta-feira (2026-13-40) qualquer."
        #expect(normalize(input) == input)
    }

    @Test func gapWithLettersIsNotMatched() {
        // The weekday word must sit IMMEDIATELY before the parenthesis — any
        // intervening LETTERS break the tight adjacency, so the date is left
        // untouched even though 06-13 is a Saturday and Friday is one day off.
        let input = "sexta-feira depois de tudo (2026-06-13)"
        #expect(normalize(input) == input)
    }

    @Test func tightPunctuationGapStillMatches() {
        // Light punctuation (comma + space) between the weekday and the paren is
        // within the 0–3 allowed gap chars → still corrected (Sat 06-13 → Fri
        // 06-12).
        let input = "Combinado para sexta-feira, (2026-06-13)."
        #expect(normalize(input) == "Combinado para sexta-feira, (2026-06-12).")
    }
}
