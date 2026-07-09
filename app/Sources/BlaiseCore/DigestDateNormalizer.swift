import Foundation

/// Deterministic date-correction post-process for the memory digest.
///
/// The LLM digest reliably names the WEEKDAY of a spoken relative reference
/// from context (the model is good at "the review is on Friday"), but it
/// occasionally mis-resolves that weekday to an ISO calendar date that is ONE
/// day off (it writes a weekday word IMMEDIATELY before an ISO date that is the
/// adjacent day — e.g. `Friday (2026-06-13)` when 2026-06-13 is a Saturday — so
/// it is snapped back to the matching Friday). The weekday WORD is the model's
/// reliable signal; the exact DATE is an arithmetic the app can do
/// deterministically.
///
/// `normalize` is a PURE function (same inputs → same output, no I/O) run as
/// the LAST step before the digest string is returned, AFTER any verify/repair
/// pass, so it corrects both synthesis-only and verified output. It NEVER
/// touches a prompt and is NOT env-gated — it is a straight deterministic
/// improvement, the same deterministic-floor discipline as `SLabelNeutralizer`.
///
/// The correction is intentionally NARROW and SAFE — it never rewrites a
/// correct date and never fires on text that merely resembles a weekday:
///
/// 1. VOCABULARY — only UNAMBIGUOUS weekday tokens. Portuguese long forms
///    (`domingo`, `segunda-feira`, `terça-feira`/`terca-feira`,
///    `quarta-feira`, `quinta-feira`, `sexta-feira`, `sábado`/`sabado`) and
///    English full names (`sunday`…`saturday`). The bare PT short forms
///    (`segunda`, `terça`, `quarta`, `quinta`, `sexta`) are DELIBERATELY
///    EXCLUDED: they collide with ordinals/nouns ("segundo lugar", "sexta
///    posição"), so admitting them would corrupt unrelated dates.
/// 2. TIGHT ADJACENCY — the weekday word must sit IMMEDIATELY before the
///    `(YYYY-MM-DD)`: only whitespace and light punctuation between them
///    (`[\s,;:.–—-]{0,3}`), NEVER an intervening letter or digit. So
///    "sexta-feira (2026-06-13)" matches, but "sextante foi calibrado
///    (2026-06-13)" and "Monday.com rollout (2026-06-18)" do NOT — the word
///    right before the paren there is "calibrado"/"rollout", not a weekday.
/// 3. WORD BOUNDARY — Unicode-aware. The weekday token must be preceded by
///    start-of-string or a non-letter (a lookbehind `(?<![\p{L}])`, since `\b`
///    is ASCII-only and mis-fires on á/ç) and not be immediately followed by a
///    letter that would make it a longer word (`(?![\p{L}])`). So "sextante"
///    never matches its "sexta" prefix.
/// 4. ±1 DAY ONLY — correct ONLY when the parsed ISO's weekday is exactly ONE
///    day off from the named weekday (the dominant real slip). A ≥2-day
///    disagreement is LEFT UNCHANGED: it is more likely a legitimately
///    different reference than a slip, and a multi-day snap is not trustworthy.
///    A malformed (calendar-invalid) ISO is left unchanged too.
///
/// The weekday word and the gap text between it and the parenthesis are
/// preserved byte-for-byte; only the ten-character `YYYY-MM-DD` is replaced.
public enum DigestDateNormalizer {
    /// Maximum signed correction (in days) we are willing to apply. The dominant
    /// real model slip is exactly one day; a ≥2-day disagreement is left as-is
    /// (a multi-day "snap" toward a guessed weekday is not trustworthy).
    private static let maxCorrectionDays = 1

    /// Scan `digest` for `<unambiguous-weekday> (YYYY-MM-DD)` occurrences where
    /// the weekday word sits IMMEDIATELY before the parenthesis, and — where the
    /// parenthesized ISO date's weekday is exactly ONE day off from the named
    /// weekday — rewrite ONLY the ISO date to the matching ±1-day date. All
    /// non-matching text is preserved exactly; multiple matches are all
    /// corrected. A ≥2-day mismatch, a malformed ISO, or a non-adjacent /
    /// substring weekday is left untouched.
    ///
    /// - Parameters:
    ///   - digest: the rendered digest markdown.
    ///   - meetingDate: the meeting's start date. Reserved for future
    ///     anchoring; the current algorithm corrects each ISO against its own
    ///     named weekday and does not need an anchor, but the meeting date is
    ///     part of the contract so a future refinement can disambiguate.
    ///   - timeZone: the calendar time zone for parsing/formatting the ISO
    ///     date and computing its weekday (defaults to the current zone).
    public static func normalize(
        _ digest: String, meetingDate: Date, timeZone: TimeZone = .current
    ) -> String {
        _ = meetingDate  // part of the contract; see the doc comment.
        guard let regex = Self.matchRegex else { return digest }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")

        let ns = digest as NSString
        let matches = regex.matches(
            in: digest, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return digest }

        // Replace right-to-left so earlier ISO ranges stay valid as we edit.
        var result = digest
        for match in matches.reversed() {
            // Group 1 = weekday word, group 2 = the whole `YYYY-MM-DD` (the gap
            // is a non-capturing class, never rewritten).
            let wordRange = match.range(at: 1)
            let isoRange = match.range(at: 2)
            guard wordRange.location != NSNotFound, isoRange.location != NSNotFound else { continue }

            let word = ns.substring(with: wordRange)
            guard let targetWeekday = Self.weekday(forWord: word) else { continue }

            let isoString = ns.substring(with: isoRange)
            guard let parsed = Self.parseISO(isoString, calendar: calendar) else {
                continue  // malformed ISO (e.g. 2026-13-40) → leave unchanged.
            }

            let actualWeekday = calendar.component(.weekday, from: parsed)
            if actualWeekday == targetWeekday { continue }  // already correct → no-op.

            // Only a ±1-day slip is corrected; a ≥2-day disagreement is left
            // unchanged (it is more likely a different real reference, and a
            // multi-day snap is not trustworthy).
            guard let delta = Self.signedDelta(
                from: actualWeekday, to: targetWeekday, maxMagnitude: maxCorrectionDays)
            else {
                continue  // ≥2 days off → decline to guess.
            }

            guard
                let corrected = calendar.date(byAdding: .day, value: delta, to: parsed),
                let formatted = Self.formatISO(corrected, calendar: calendar)
            else { continue }

            // Replace ONLY the ISO substring; the weekday word and gap text are
            // untouched. `isoRange` is a UTF-16 range; convert to a String range.
            if let swiftRange = Range(isoRange, in: result) {
                result.replaceSubrange(swiftRange, with: formatted)
            }
        }
        return result
    }

    // MARK: - Regex

    /// `(?i)(?<![\p{L}])(<weekday-alternation>)(?![\p{L}])[\s,;:.–—-]{0,3}\((\d{4}-\d{2}-\d{2})\)`
    ///
    /// Case-insensitive, Unicode-aware. Components, in order:
    /// - `(?<![\p{L}])` — a Unicode word boundary BEFORE the weekday: the token
    ///   must start at start-of-string or after a non-letter. (`\b` is
    ///   ASCII-only and breaks on á/ç; the explicit lookbehind is correct.)
    /// - group 1 — the weekday word, from the UNAMBIGUOUS alternation, built
    ///   LONGEST-FIRST so `segunda-feira` is preferred over any prefix.
    /// - `(?![\p{L}])` — a Unicode word boundary AFTER the weekday: the token
    ///   must not be immediately followed by a letter (so "sextante" never
    ///   matches via its "sexta" prefix — though "sexta" is not even in the
    ///   vocabulary, the long forms get the same protection).
    /// - `[\s,;:.–—-]{0,3}` — the TIGHT gap: 0–3 whitespace/light-punctuation
    ///   chars only. No letters, no digits, no `(`/`)` — so the weekday word
    ///   must sit IMMEDIATELY before the parenthesis. "calibrado (…)" /
    ///   "rollout (…)" do not match (the adjacent word is not a weekday).
    /// - group 2 — the whole `YYYY-MM-DD` (the only substring ever rewritten).
    private static let matchRegex: NSRegularExpression? = {
        let alternation = weekdayWords
            .sorted { $0.word.count > $1.word.count }  // longest form first
            .map { NSRegularExpression.escapedPattern(for: $0.word) }
            .joined(separator: "|")
        // The gap class allows whitespace, light ASCII punctuation, and the en/
        // em dashes (U+2013/U+2014) — written as ICU `\uXXXX` (four hex digits,
        // NO braces; ICU does not accept Swift's `\u{XXXX}` form). A trailing `-`
        // in the class is a literal hyphen.
        let pattern =
            "(?<![\\p{L}])(\(alternation))(?![\\p{L}])[\\s,;:.\\u2013\\u2014-]{0,3}\\((\\d{4}-\\d{2}-\\d{2})\\)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // MARK: - Weekday vocabulary

    /// A weekday word and the `Calendar` weekday it denotes (gregorian: Sunday=1
    /// … Saturday=7). ONLY UNAMBIGUOUS tokens: Portuguese long forms (the
    /// `-feira` weekdays, plus `domingo`/`sábado` which collide with nothing)
    /// with and without the accent on terça/sábado, and English full names. The
    /// bare PT short forms (`segunda`, `terça`, `quarta`, `quinta`, `sexta`) are
    /// DELIBERATELY EXCLUDED — they collide with ordinals/nouns ("segundo",
    /// "sexta posição") and would corrupt unrelated dates. Longer forms are
    /// listed so the alternation can sort them first.
    private static let weekdayWords: [(word: String, weekday: Int)] = [
        // Portuguese — long (`-feira`) forms + the unambiguous domingo/sábado.
        ("domingo", 1),
        ("segunda-feira", 2),
        ("terça-feira", 3), ("terca-feira", 3),
        ("quarta-feira", 4),
        ("quinta-feira", 5),
        ("sexta-feira", 6),
        ("sábado", 7), ("sabado", 7),
        // English full names.
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7),
    ]

    /// The weekday a matched word denotes (case-insensitive lookup).
    private static func weekday(forWord word: String) -> Int? {
        let key = word.lowercased()
        return weekdayWords.first { $0.word == key }?.weekday
    }

    // MARK: - ISO parse / format / weekday arithmetic

    /// Parse `YYYY-MM-DD` to a `Date` at the start of that day in the calendar's
    /// zone. Returns nil for a calendar-invalid date (e.g. month 13, day 40) —
    /// `date(from:)` with a strict gregorian calendar rejects out-of-range
    /// components, so a malformed ISO is left unchanged by the caller.
    private static func parseISO(_ iso: String, calendar: Calendar) -> Date? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // Reject e.g. 2026-02-30: round-trip the produced date and require the
        // numeric components to survive unchanged.
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// Format a `Date` back to `YYYY-MM-DD` in the calendar's zone.
    private static func formatISO(_ date: Date, calendar: Calendar) -> String? {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// The smallest-magnitude signed day delta that moves `from` weekday to `to`
    /// weekday, with |delta| ≤ `maxMagnitude`. Weekdays are 1…7; the difference
    /// is taken modulo 7 into the range (-3…+3]. Returns nil when the required
    /// magnitude exceeds `maxMagnitude` — with `maxMagnitude == 1` only an
    /// exactly-one-day-off pair is corrected; everything ≥2 days apart declines.
    private static func signedDelta(from: Int, to: Int, maxMagnitude: Int) -> Int? {
        var diff = (to - from) % 7
        if diff < 0 { diff += 7 }  // now 0…6
        // Choose the representative in (-3…+3]: if diff > 3, go negative.
        let delta = diff > 3 ? diff - 7 : diff
        return abs(delta) <= maxMagnitude ? delta : nil
    }
}
