import Foundation
import Testing

@testable import BlaiseCore

// C11 AC1: two-track interleave (pinned tie-break), indicator state
// machine, mic-silence health check, Meet-link parsing, calendar-suggestion
// building — all pure, no audio, no TCC.

private func segment(
    _ ord: Int, start: Double, end: Double, label: String, name: String? = nil,
    text: String = "t"
) -> TranscriptSegment {
    TranscriptSegment(
        meetingID: "01TESTMEETING0000000000000", ord: ord, startSeconds: start,
        endSeconds: end, speakerLabel: label, speakerName: name, text: text)
}

@Suite("C11 two-track interleave")
struct TwoTrackInterleaveTests {
    @Test("interleaves by start; ord re-sequenced globally")
    func basicInterleave() {
        let mic = [
            segment(0, start: 0.0, end: 2.0, label: "user", name: "Sam"),
            segment(1, start: 5.0, end: 6.0, label: "user", name: "Sam"),
        ]
        let system = [
            segment(0, start: 2.5, end: 4.5, label: "S0"),
            segment(1, start: 6.5, end: 8.0, label: "S1"),
        ]
        let result = TwoTrackInterleaver.interleave(mic: mic, system: system)
        #expect(result.map(\.speakerLabel) == ["user", "S0", "user", "S1"])
        #expect(result.map(\.ord) == [0, 1, 2, 3])
    }

    @Test("tie-break: equal start → mic first, then original ord")
    func tieBreak() {
        let mic = [segment(0, start: 1.0, end: 2.0, label: "user", name: "Sam")]
        let system = [
            segment(0, start: 1.0, end: 1.5, label: "S0"),
            segment(1, start: 1.0, end: 2.5, label: "S1"),
        ]
        let result = TwoTrackInterleaver.interleave(mic: mic, system: system)
        #expect(result.map(\.speakerLabel) == ["user", "S0", "S1"])
        #expect(result.map(\.ord) == [0, 1, 2])
    }

    @Test("cross-track overlap is legal and preserved (people talk over each other)")
    func crossTrackOverlap() {
        let mic = [segment(0, start: 0.0, end: 10.0, label: "user", name: "Sam")]
        let system = [segment(0, start: 2.0, end: 8.0, label: "S0")]
        let result = TwoTrackInterleaver.interleave(mic: mic, system: system)
        #expect(result.count == 2)
        // Timestamps untouched: the overlap survives interleaving.
        #expect(result[0].endSeconds > result[1].startSeconds)
    }

    @Test("empty tracks degrade gracefully")
    func emptyTracks() {
        let only = [segment(0, start: 0, end: 1, label: "user", name: "Sam")]
        #expect(TwoTrackInterleaver.interleave(mic: only, system: []).count == 1)
        #expect(TwoTrackInterleaver.interleave(mic: [], system: only).count == 1)
        #expect(TwoTrackInterleaver.interleave(mic: [], system: []).isEmpty)
    }
}

// C7 v3.8: cross-track echo dedup at RAW-ASR granularity (pre-merge: merge
// consolidation grows mixed user turns that a whole-segment similarity gate
// can never catch). Synthetic raw segments only; the conservative gates
// (overlap ±1.5 s, ≥ 5 tokens, ≥ 0.85 ordered-token similarity) are each
// exercised from both sides of the boundary.
@Suite("C11 cross-track echo suppression")
struct EchoSuppressionTests {
    // Raw ASR segments carry no ord or speaker label (pre-merge); the
    // helpers keep both parameters so each case still reads as a track
    // layout, but only the times and text feed the suppressor.
    private func mic(_ ord: Int, _ start: Double, _ end: Double, _ text: String)
        -> ASRSegment
    {
        ASRSegment(startSeconds: start, endSeconds: end, text: text)
    }

    private func sys(_ ord: Int, _ start: Double, _ end: Double, _ text: String, label: String = "S0")
        -> ASRSegment
    {
        ASRSegment(startSeconds: start, endSeconds: end, text: text)
    }

    @Test("causality: the user's ORIGINAL is kept when the other participant repeats it later")
    func userOriginalKeptWhenRepeatedLater() {
        // v1.1-wave audit H-1 probe, pinned: the user says a sentence first
        // (mic 0–4 s); the other participant reads it back starting 4.5 s
        // (system). The ±1.5 s overlap window touches, the texts match —
        // but an echo cannot PRECEDE its source: the mic copy is the
        // original and must survive. Read-backs of figures/commitments
        // have exactly this shape.
        let micTrack = [mic(0, 0.0, 4.0, "o orcamento fecha em quatro e oitenta no cenario base")]
        let systemTrack = [sys(0, 4.5, 8.5, "o orçamento fecha em quatro e oitenta no cenário base")]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.count == 1)
        #expect(result.droppedCount == 0)
    }

    @Test("causality jitter: genuine echo starting a fraction after its source is still dropped")
    func genuineEchoWithinJitterDropped() {
        let micTrack = [mic(0, 10.05, 13.0, "vamos fechar o orcamento do projeto amanha")]
        let systemTrack = [sys(0, 10.1, 13.2, "Vamos fechar o orçamento do projeto amanhã.")]
        // Mic starts 0.05 s BEFORE the system timestamp — inside the 0.5 s
        // ASR-jitter allowance; still an echo, still dropped.
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.isEmpty)
        #expect(result.droppedCount == 1)
    }

    @Test("exact duplicate dropped: case, diacritics, punctuation folded")
    func exactDuplicateDropped() {
        let micTrack = [mic(0, 10.0, 13.0, "vamos fechar o orcamento do projeto amanha")]
        let systemTrack = [sys(0, 10.1, 13.2, "Vamos fechar o orçamento do projeto amanhã.")]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.isEmpty)
        #expect(result.droppedCount == 1)
    }

    @Test("paraphrase kept: overlapping span, different words")
    func paraphraseKept() {
        let micTrack = [mic(0, 10.0, 13.0, "eu acho melhor esperar a resposta do cliente antes")]
        let systemTrack = [sys(0, 10.0, 13.0, "vamos fechar o orçamento do projeto amanhã cedo")]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.count == 1)
        #expect(result.droppedCount == 0)
    }

    @Test("short utterances NEVER dropped, even as exact overlapping duplicates")
    func shortUtteranceKept() {
        let micTrack = [
            mic(0, 1.0, 1.4, "Sim."),
            mic(1, 3.0, 3.5, "ok"),
            mic(2, 5.0, 6.5, "sim, vamos fazer isso"),  // 4 tokens < 5
        ]
        let systemTrack = [
            sys(0, 1.0, 1.4, "sim"),
            sys(1, 3.0, 3.5, "Ok."),
            sys(2, 5.0, 6.5, "Sim, vamos fazer isso."),
        ]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.count == 3)
        #expect(result.droppedCount == 0)
    }

    @Test("non-overlapping duplicate kept: same words said later are legitimate")
    func nonOverlappingDuplicateKept() {
        let micTrack = [mic(0, 60.0, 63.0, "vamos fechar o orçamento do projeto amanhã")]
        let systemTrack = [sys(0, 10.0, 13.0, "vamos fechar o orçamento do projeto amanhã")]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.count == 1)
        #expect(result.droppedCount == 0)
    }

    @Test("overlap tolerance boundary: gap ≤ 1.5 s matches, gap > 1.5 s does not")
    func overlapTolerance() {
        let text = "vamos fechar o orçamento do projeto amanhã"
        let systemTrack = [sys(0, 0.0, 4.0, text)]
        // Mic copy starting 1.0 s after the system segment ends: within
        // tolerance → dropped.
        let near = EchoSuppressor.suppress(mic: [mic(0, 5.0, 8.0, text)], system: systemTrack)
        #expect(near.droppedCount == 1)
        // 2.0 s after: outside tolerance → kept.
        let far = EchoSuppressor.suppress(mic: [mic(0, 6.0, 9.0, text)], system: systemTrack)
        #expect(far.droppedCount == 0)
        #expect(far.kept.count == 1)
    }

    @Test("the user's genuine speech is never dropped: overlap + different text")
    func genuineSpeechKept() {
        // The user talks over the other participant for the whole span.
        let micTrack = [
            mic(0, 0.0, 10.0, "deixa eu comentar uma coisa importante sobre esse ponto agora")
        ]
        let systemTrack = [
            sys(0, 2.0, 8.0, "a gente precisa alinhar o cronograma da entrega com o estúdio")
        ]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.count == 1)
        #expect(result.droppedCount == 0)
    }

    @Test("consolidated bleed spanning two system speaker turns is dropped (window concatenation)")
    func consolidatedBleedDropped() {
        // Mic bleed consolidates across system turns (gap ≤ 2 s merges in
        // the merger); neither single system segment contains it, the
        // ordered window does.
        let micTrack = [
            mic(0, 0.0, 9.0, "vamos revisar o contrato amanhã perfeito eu mando a minuta hoje")
        ]
        let systemTrack = [
            sys(0, 0.0, 4.0, "Vamos revisar o contrato amanhã.", label: "S0"),
            sys(1, 4.5, 9.0, "Perfeito, eu mando a minuta hoje.", label: "S1"),
        ]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.kept.isEmpty)
        #expect(result.droppedCount == 1)
    }

    @Test("similarity threshold: 1 substitution in 10 dropped, 2 in 10 kept")
    func similarityThresholdBoundary() {
        let systemTrack = [
            sys(0, 0.0, 6.0, "vamos revisar o contrato da empresa amanhã de manhã cedo")  // 10 tokens
        ]
        // One substituted token ("empresa" → ASR jitter "impresa"): 0.9 ≥ 0.85.
        let oneOff = EchoSuppressor.suppress(
            mic: [mic(0, 0.2, 6.1, "vamos revisar o contrato da impresa amanhã de manhã cedo")],
            system: systemTrack)
        #expect(oneOff.droppedCount == 1)
        // Two substituted tokens: 0.8 < 0.85 → kept (high bar: false-dropping
        // genuine words is far worse than keeping an echo).
        let twoOff = EchoSuppressor.suppress(
            mic: [mic(0, 0.2, 6.1, "vamos revisar o contrato da impresa ontem de manhã cedo")],
            system: systemTrack)
        #expect(twoOff.droppedCount == 0)
        #expect(twoOff.kept.count == 1)
    }

    @Test("mixed track: echoes dropped, genuine and short segments kept; counts pinned")
    func mixedTrackCountsPinned() {
        let micTrack = [
            mic(0, 0.2, 4.1, "vamos revisar o contrato da empresa amanhã"),  // echo → dropped
            mic(1, 6.5, 7.0, "tá bom"),  // short ack → kept
            mic(2, 9.0, 12.0, "eu prefiro fechar isso ainda essa semana se der"),  // genuine → kept
            mic(3, 14.2, 17.3, "o prazo final é sexta-feira sem falta pessoal"),  // echo → dropped
        ]
        let systemTrack = [
            sys(0, 0.0, 4.0, "Vamos revisar o contrato da empresa amanhã.", label: "S0"),
            sys(1, 6.4, 7.1, "Tá bom.", label: "S1"),
            sys(2, 9.5, 12.5, "concordo, melhor não deixar para depois", label: "S1"),
            sys(3, 14.0, 17.2, "O prazo final é sexta-feira, sem falta, pessoal!", label: "S0"),
        ]
        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.droppedCount == 2)
        #expect(result.kept.map(\.text) == [micTrack[1].text, micTrack[2].text])
        // The system track is never touched by construction: suppress()
        // returns only surviving MIC segments (mic-only direction, by
        // design — system attribution is diarization-grounded).
    }

    @Test("MIXED adjacency (v3.8 motivation): embedded echo between genuine raw segments dropped; merge consolidates only survivors")
    func mixedAdjacencyEmbeddedEchoDropped() {
        // The post-merge gate's blind spot: genuine_user_1 + echo_of_A +
        // genuine_user_2 sit < 2 s apart, so SpeakerMerger consolidates them
        // into ONE mixed user turn whose whole-segment similarity to the
        // system text stays far below 0.85 — the embedded echo survives a
        // post-merge gate. At raw granularity the echo is its own unit.
        let genuine1 = "deixa eu explicar o contexto desse projeto primeiro"
        let echoOfA = "precisamos aprovar o orçamento até sexta-feira"
        let genuine2 = "concordo, eu cuido da aprovação ainda essa semana"
        let micTrack = [
            mic(0, 0.0, 3.5, genuine1),
            mic(1, 3.7, 5.3, echoOfA),  // acoustic bleed of system A
            mic(2, 5.5, 9.0, genuine2),
        ]
        let systemTrack = [
            // A: overlaps the echo span (and brushes both genuine spans
            // within tolerance — overlap alone must not drop them).
            sys(0, 3.6, 5.4, "Precisamos aprovar o orçamento até sexta-feira.")
        ]

        let result = EchoSuppressor.suppress(mic: micTrack, system: systemTrack)
        #expect(result.droppedCount == 1)
        #expect(result.kept.map(\.text) == [genuine1, genuine2])

        // The REAL merger over the survivors (mic path: empty diarization),
        // exactly as the pipeline consolidates the mic track: the survivors'
        // 2.0 s gap still consolidates (≤ consolidation gap), and the
        // consolidated user turn carries ONLY genuine text.
        let merged = SpeakerMerger.merge(
            asr: result.kept, diarization: [], meetingID: "01TESTMEETING0000000000000")
        #expect(merged.segments.count == 1)
        let turn = merged.segments[0].text
        #expect(turn == genuine1 + " " + genuine2)
        #expect(!turn.contains("orçamento"))

        // Control — the post-merge shape: WITHOUT raw-granularity
        // suppression the merger consolidates all three into one mixed turn
        // (gaps ≤ 2 s), and that whole turn sits far below the similarity
        // threshold — the embedded echo would have survived.
        let unsuppressed = SpeakerMerger.merge(
            asr: micTrack, diarization: [], meetingID: "01TESTMEETING0000000000000")
        #expect(unsuppressed.segments.count == 1)
        #expect(unsuppressed.segments[0].text.contains("orçamento"))
        let mixedTurnSimilarity = EchoSuppressor.similarity(
            of: EchoSuppressor.tokens(unsuppressed.segments[0].text),
            in: EchoSuppressor.tokens(systemTrack[0].text))
        #expect(mixedTurnSimilarity < EchoSuppressor.similarityThreshold)
    }

    @Test("no system track or no mic track: no-op")
    func degenerateTracks() {
        let only = [mic(0, 0.0, 4.0, "vamos revisar o contrato da empresa amanhã")]
        let noSystem = EchoSuppressor.suppress(mic: only, system: [])
        #expect(noSystem.kept.count == 1)
        #expect(noSystem.droppedCount == 0)
        let noMic = EchoSuppressor.suppress(mic: [], system: only)
        #expect(noMic.kept.isEmpty)
        #expect(noMic.droppedCount == 0)
    }
}

@Suite("C11 indicator state machine")
struct IndicatorStateMachineTests {
    @Test("start → recording; stop (stopping→stopped) → processing; finished → idle")
    func happyPath() {
        var machine = IndicatorStateMachine()
        let start = msDate()
        #expect(machine.apply(.captureStarted(at: start)) == .recording(startedAt: start))
        #expect(machine.apply(.captureStopping) == .processing)
        #expect(machine.apply(.captureStopped(alarm: nil)) == .processing)
        #expect(machine.apply(.processingFinished) == .idle)
    }

    @Test("mic silence → warning while recording; restore → recording")
    func micSilenceWarning() {
        var machine = IndicatorStateMachine()
        let start = msDate()
        machine.apply(.captureStarted(at: start))
        let warned = machine.apply(.micSilence(active: true))
        guard case .warning(let at, let message) = warned else {
            Issue.record("expected warning, got \(warned)")
            return
        }
        #expect(at == start)
        #expect(message.contains("Mic"))
        #expect(machine.apply(.micSilence(active: false)) == .recording(startedAt: start))
    }

    @Test("long session: tick past 6 h → warning; recording continues underneath")
    func longSession() {
        var machine = IndicatorStateMachine()
        let start = msDate()
        machine.apply(.captureStarted(at: start))
        #expect(machine.apply(.tick(now: start.addingTimeInterval(3600))) == .recording(startedAt: start))
        let warned = machine.apply(.tick(now: start.addingTimeInterval(6 * 3600 + 1)))
        guard case .warning(_, let message) = warned else {
            Issue.record("expected warning, got \(warned)")
            return
        }
        #expect(message.contains("6 hours"))
        // Stop still works normally from the warning state.
        #expect(machine.apply(.captureStopping) == .processing)
        #expect(machine.apply(.captureStopped(alarm: nil)) == .processing)
    }

    @Test("write-failure stop carries the loud alarm; processingFinished keeps it visible")
    func alarmPath() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        let state = machine.apply(.captureStopped(alarm: "Recording stopped: disk full"))
        guard case .alarm(let message) = state else {
            Issue.record("expected alarm, got \(state)")
            return
        }
        #expect(message.contains("disk full"))
        // The salvage run finishing must NOT silently clear the alarm.
        if case .alarm = machine.apply(.processingFinished) {
        } else {
            Issue.record("alarm cleared by processingFinished")
        }
    }

    @Test("alarm is never terminal: a new capture starts from it (and clears it)")
    func alarmIsStartable() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        machine.apply(.captureStopped(alarm: "Recording produced no recoverable audio"))
        let newStart = msDate(1_770_000_100)
        #expect(machine.apply(.captureStarted(at: newStart)) == .recording(startedAt: newStart))
    }

    @Test("alarm dismissed by acknowledgement → idle; acknowledge elsewhere is a no-op")
    func alarmAcknowledged() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        machine.apply(.captureStopped(alarm: "disk full"))
        #expect(machine.apply(.alarmAcknowledged) == .idle)
        machine.apply(.captureStarted(at: msDate()))
        #expect(machine.apply(.alarmAcknowledged) == .recording(startedAt: msDate()))
    }

    @Test("stop reflects immediately: captureStopping → processing before the encode finishes")
    func stoppingIsImmediate() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        #expect(machine.apply(.captureStopping) == .processing)
        // The encode completing without alarm keeps processing.
        #expect(machine.apply(.captureStopped(alarm: nil)) == .processing)
        #expect(machine.apply(.processingFinished) == .idle)
    }

    @Test("a stop completing AFTER the next capture started never clobbers recording")
    func staleStopIgnoredWhileRecording() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        let newStart = msDate(1_770_000_100)
        machine.apply(.captureStarted(at: newStart))
        // The previous stop's encode finishes now — recording wins.
        #expect(machine.apply(.captureStopped(alarm: nil)) == .recording(startedAt: newStart))
        #expect(machine.apply(.captureStopped(alarm: "late alarm")) == .recording(startedAt: newStart))
    }

    @Test("processingFinished while a NEW capture is recording stays recording")
    func processingFinishedDuringNewCapture() {
        var machine = IndicatorStateMachine()
        machine.apply(.captureStarted(at: msDate()))
        machine.apply(.captureStopping)
        machine.apply(.captureStopped(alarm: nil))
        let newStart = msDate(1_770_000_100)
        machine.apply(.captureStarted(at: newStart))
        #expect(machine.apply(.processingFinished) == .recording(startedAt: newStart))
    }
}

@Suite("C11 mic-silence detector")
struct MicSilenceDetectorTests {
    @Test("60 s of all-zero mic while system active → one warning; signal restores it")
    func detectAndRestore() {
        var detector = MicSilenceDetector()
        var changes: [Bool] = []
        // 59 s: no warning yet.
        for _ in 0 ..< 59 {
            if let change = detector.observe(micAllZero: true, systemActive: true, windowSeconds: 1.0) {
                changes.append(change)
            }
        }
        #expect(changes.isEmpty)
        // crossing 60 s: exactly one warning, no repeats.
        for _ in 0 ..< 5 {
            if let change = detector.observe(micAllZero: true, systemActive: true, windowSeconds: 1.0) {
                changes.append(change)
            }
        }
        #expect(changes == [true])
        // Mic signal back → restored exactly once.
        if let change = detector.observe(micAllZero: false, systemActive: true, windowSeconds: 1.0) {
            changes.append(change)
        }
        #expect(changes == [true, false])
    }

    @Test("a quiet room (system also silent) never accumulates toward the warning")
    func quietRoomHolds() {
        var detector = MicSilenceDetector()
        for _ in 0 ..< 200 {
            let change = detector.observe(micAllZero: true, systemActive: false, windowSeconds: 1.0)
            #expect(change == nil)
        }
        #expect(!detector.warningActive)
    }
}

@Suite("C11 Meet link parsing")
struct MeetLinkParserTests {
    @Test("link forms and bare codes")
    func parsing() {
        #expect(MeetLinkParser.meetingCode(from: "https://meet.google.com/abc-defg-hij") == "abc-defg-hij")
        #expect(
            MeetLinkParser.meetingCode(from: "meet.google.com/xyz-qrst-uvw?authuser=0")
                == "xyz-qrst-uvw")
        #expect(
            MeetLinkParser.meetingCode(
                from: "Join: https://meet.google.com/abc-defg-hij\nAgenda: …") == "abc-defg-hij")
        #expect(MeetLinkParser.meetingCode(from: "  abc-defg-hij  ") == "abc-defg-hij")
        #expect(MeetLinkParser.meetingCode(from: "ABC-DEFG-HIJ") == "abc-defg-hij")
        #expect(MeetLinkParser.meetingCode(from: "https://zoom.us/j/123456") == nil)
        #expect(MeetLinkParser.meetingCode(from: "not a code") == nil)
        #expect(MeetLinkParser.meetingCode(from: "ab-cdef-ghi") == nil)  // wrong shape
        #expect(MeetLinkParser.meetingCode(from: "") == nil)
    }
}

@Suite("C11 calendar suggestions")
struct CalendarSuggestionTests {
    private let now = msDate()

    private func event(
        title: String = "Weekly sync", startOffset: TimeInterval, location: String? = nil,
        notes: String? = nil, url: String? = nil,
        attendees: [CalendarEventSnapshot.AttendeeSnapshot] = []
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            title: title, start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(startOffset + 1800), location: location, notes: notes,
            urlString: url, attendees: attendees)
    }

    @Test("look-back → 2h look-ahead window; needs attendees or a link; Meet code extracted")
    func windowAndCode() {
        let events = [
            event(title: "Soon", startOffset: 600, location: "https://meet.google.com/abc-defg-hij"),
            event(title: "Within 2h", startOffset: 90 * 60, location: "https://meet.google.com/qqq-qqqq-qqq"),
            event(title: "Beyond look-ahead", startOffset: 3 * 60 * 60, location: "https://meet.google.com/zzz-zzzz-zzz"),
            event(title: "Long past", startOffset: -3600, location: "https://meet.google.com/ppp-pppp-ppp"),
            event(title: "No link no attendees", startOffset: 0),
        ]
        let suggestions = CalendarSuggestionBuilder.suggestions(
            from: events, now: now, userEmail: "sam.rivera@vexatron.test")
        // Soon + Within-2h surface; beyond the look-ahead, before the look-back,
        // and the no-link/no-attendees event are all excluded.
        #expect(suggestions.map(\.title) == ["Soon", "Within 2h"])
        #expect(suggestions[0].meetingCode == "abc-defg-hij")
        #expect(suggestions[0].source == .meet)
    }

    @Test("source inference: zoom, teams, in-person-with-attendees")
    func sourceInference() {
        let events = [
            event(title: "Z", startOffset: 0, location: "https://acme.zoom.us/j/99"),
            event(title: "T", startOffset: 60, notes: "https://teams.microsoft.com/l/meetup/x"),
            event(
                title: "P", startOffset: 120,
                attendees: [.init(name: "Fábio Souza", email: "fabio@vexatron.test")]),
        ]
        let suggestions = CalendarSuggestionBuilder.suggestions(
            from: events, now: now, userEmail: "sam.rivera@vexatron.test")
        #expect(suggestions.map(\.source) == [.zoom, .teams, .inPerson])
    }

    @Test("The user is excluded from prefilled attendees (identifying email, case-insensitive)")
    func selfExclusion() {
        let events = [
            event(
                title: "Board", startOffset: 0,
                attendees: [
                    .init(name: "Sam Rivera", email: "sam.rivera@vexatron.test"),
                    .init(name: "Fábio Souza", email: "fabio@vexatron.test"),
                ])
        ]
        let suggestions = CalendarSuggestionBuilder.suggestions(
            from: events, now: now, userEmail: "sam.rivera@vexatron.test")
        #expect(suggestions.count == 1)
        #expect(suggestions[0].attendees.map(\.name) == ["Fábio Souza"])
        #expect(suggestions[0].attendees.allSatisfy { $0.source == .calendar })
    }

    @Test("G3 AC2: empty identity (pre-onboarding) → self-exclusion no-ops, keeps every attendee")
    func selfExclusionNoOpsWithEmptyIdentity() {
        // A pre-onboarding user has an empty identifying email. Self-exclusion
        // must NOT then drop every email-less attendee (nor anyone): with no
        // identity, there is no self to exclude.
        let events = [
            event(
                title: "Board", startOffset: 0,
                attendees: [
                    .init(name: "Sam Rivera", email: "sam.rivera@vexatron.test"),
                    .init(name: "Fábio Souza", email: "fabio@vexatron.test"),
                    .init(name: "Sem Email", email: nil),
                ])
        ]
        let suggestions = CalendarSuggestionBuilder.suggestions(
            from: events, now: now, userEmail: "")
        #expect(suggestions.count == 1)
        // Nobody excluded — including the user's own calendar name and the
        // email-less attendee.
        #expect(suggestions[0].attendees.map(\.name) == ["Sam Rivera", "Fábio Souza", "Sem Email"])
    }
}
