import AVFoundation
import AppKit
import BlaiseCore
import SwiftUI
import Testing

@testable import BlaiseApp

// Timecode marks in the notes pane (T-7): the block → anchor map, the hit
// area, the seek target, the playback-time mapping, the now-playing clear,
// VoiceOver, the block menu and the click. Off-screen, never shown; fictional
// notes only.

@MainActor
private final class MarkHost {
    let controller = NotesDocController()
    let window: NSWindow
    var activations: [(String, Double)] = []

    init(height: CGFloat = 1000) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 818, height: height), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The hover tests follow text the motion moves, whatever the host's Reduce Motion setting.
        controller.reduceMotionOverride = false
        window.contentView = controller.scrollView
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 818, height: height)
        controller.scrollView.tile()
    }

    func show(
        _ doc: NotesDocument, timecodes: NotesDocTimecodes?, attachments: [String: AnyView] = [:],
        composing: String? = nil
    ) {
        let spec = NotesDocumentView(
            document: doc, marks: [:], attachments: attachments, composingAnchor: composing, rail: [:], railLane: false,
            completedExpanded: false, aim: nil, bar: nil, scrollRequest: nil,
            callbacks: NotesDocCallbacks(
                onSelection: { _, _ in }, onPassage: { _ in }, onPick: { _ in }, onClear: {},
                onMenuAction: { _, _, _ in }, menuOffers: { (true, true) }, onToggle: { _, _ in },
                onToggleCompleted: {}, onScroll: {}),
            timecodes: timecodes)
        controller.update(spec)
        controller.update(spec)
    }

    func timecodes(_ targets: [String: NotesDocTimecode], playing: String? = nil) -> NotesDocTimecodes {
        NotesDocTimecodes(
            targets: targets, playbackSeconds: { seconds, _ in seconds }, mappingGeneration: 1,
            playing: playing, onActivate: { [unowned self] anchor, playback in activations.append((anchor, playback)) })
    }

    /// The centre of a block's mark: 18 left of the column, on its first line.
    func markPoint(_ block: NotesDocBlock, in doc: NotesDocument) throws -> NSPoint {
        let line = try #require(controller.markRects(
            NSRange(location: block.range.location, length: 1), visible: NSRange(location: 0, length: doc.text.length)).first)
        return NSPoint(x: controller.textView.textContainerOrigin.x - 18, y: line.midY)
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: controller.textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }

    /// Scrolls the notes so the text view's `y` is at the top of the view.
    func scroll(to y: CGFloat) {
        controller.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
    }

    /// Runs a motion to its end: waits out the spring, then one `frame`.
    func settle(wait: TimeInterval = 0.8, frame: String = "tick:") {
        Thread.sleep(forTimeInterval: wait)
        let link = controller.textView.displayLink(target: controller, selector: Selector((frame)))
        controller.perform(Selector((frame)), with: link)
        link.invalidate()
    }

    func close() { window.contentView = nil }
}

private let fictionalNotes = NotesStructured(
    title: "Quoll Harbor sync", summary: "The harbor crew met on Thursday.",
    detailedNotes: "## Frame rate\n\nThe console build drops to 41 fps on the harbor level.\n\nVexatron Labs ships the buoy firmware.\n\nVexatron Labs ships the buoy firmware.",
    decisions: ["Reefer upgrade approved for row C only."],
    actionItems: [ActionItem(owner: "Ilse", text: "re-run the harbor-level frame test")],
    userActionItems: [])

@MainActor
private func fictionalDocument() -> NotesDocument {
    NotesDocumentBuilder.build(NotesDocInput(
        structured: fictionalNotes, doneKeys: [], searchTerms: [], portuguese: false,
        userActionTitle: "Demo User — Action Items", direction: .aquarela))
}

private func row(_ section: MeetingCorrection.Section, _ text: String, _ seconds: Double) -> NotesTimecode {
    NotesTimecode(
        meetingID: "01JTC000000000000000000009", section: section, itemHash: TimecodeAnchoring.itemHash(text),
        startSeconds: seconds, segmentOrd: 0, track: .system)
}

@MainActor
@Suite struct TimecodeMarkMapTests {
    @Test func blocksMapToTheirRowsByAnchorID() throws {
        let doc = fictionalDocument()
        let rows = [
            row(.detailedNotes, "The console build drops to 41 fps on the harbor level.", 57),
            row(.detailedNotes, "Vexatron Labs ships the buoy firmware.", 90),
            row(.detailedNotes, "Frame rate", 12),
            row(.decision, "Reefer upgrade approved for row C only.", 130),
            row(.summary, "The harbor crew met on Thursday.", 5),
        ]
        let map = notesDocTimecodes(rows, document: doc)
        let paragraph = try #require(doc.blocks.first { $0.blockText.hasPrefix("The console build") })
        let decision = try #require(doc.blocks.first { $0.section == .decision })
        // The repeated paragraph, the heading and the summary get none.
        #expect(map == [
            paragraph.anchorID: NotesDocTimecode(seconds: 57, track: .system),
            decision.anchorID: NotesDocTimecode(seconds: 130, track: .system),
        ])
    }

    @Test func theHitAreaDependsOnlyOnTheColumnOrigin() {
        #expect(NotesDocController.timecodeHitRect(lineMidY: 100, originX: 36)
            == NSRect(x: 7, y: 89, width: 22, height: 22))
    }

    @Test func seekTargetHasThreeSecondsOfLeadInInsideTheAudio() {
        #expect(TimecodeLink.seekTarget(playback: 10, duration: 60) == 7)
        #expect(TimecodeLink.seekTarget(playback: 1, duration: 60) == 0)
        #expect(TimecodeLink.seekTarget(playback: 90, duration: 60) == 60)
    }
}

@Suite struct TimecodePlaybackMappingTests {
    private let url = { (name: String) in URL(fileURLWithPath: "/fictional/\(name).m4a") }

    private func part(
        _ index: Int, offset: Double?, wall: Double?, system: String?, mic: String? = nil
    ) -> CaptureStitcher.PlannedPart {
        CaptureStitcher.PlannedPart(
            index: index, offsetMs: offset.map { Int64($0 * 1000) }, wallSpanMs: wall.map { Int64($0 * 1000) },
            systemM4A: system.map(url), micM4A: mic.map(url))
    }

    private func map(
        _ t: Double, _ track: CaptureTrack = .system, parts: [CaptureStitcher.PlannedPart],
        durations: [String: Double], placements: [CaptureStitcher.PlaybackPlacement]? = nil
    ) -> Double? {
        let byURL = Dictionary(uniqueKeysWithValues: durations.map { (url($0.key), $0.value) })
        let placed = placements ?? CaptureStitcher.playbackPlacements(parts: parts, durations: byURL)
        return CaptureStitcher.playbackSeconds(
            transcriptSeconds: t, track: track, parts: parts, durations: byURL, placements: placed)
    }

    @Test func onePartAtWallClock() throws {
        let value = try #require(map(1200, parts: [part(1, offset: 0, wall: 3000, system: "s1")], durations: ["s1": 3000]))
        #expect(abs(value - 1200) < 1e-6)
    }

    @Test func aFileRunningFastOrSlowMapsToRealTime() throws {
        let fast = try #require(map(1305.6, parts: [part(1, offset: 0, wall: 2000, system: "s1")], durations: ["s1": 2176]))
        #expect(abs(fast - 1200) < 0.01)
        let slow = try #require(map(1102.8, parts: [part(1, offset: 0, wall: 2000, system: "s1")], durations: ["s1": 1838]))
        #expect(abs(slow - 1200) < 0.01)
    }

    @Test func aDriftedSecondPart() throws {
        let parts = [part(1, offset: 0, wall: 1000, system: "s1"), part(2, offset: 1000, wall: 1000, system: "s2")]
        let value = try #require(map(1326.4, parts: parts, durations: ["s1": 1000, "s2": 1088]))
        #expect(abs(value - 1300) < 0.01)
    }

    @Test func anOverrunningFirstPartPushesTheSecond() throws {
        let parts = [part(1, offset: 0, wall: 1000, system: "s1"), part(2, offset: 1000, wall: 1000, system: "s2")]
        let value = try #require(map(1488, parts: parts, durations: ["s1": 1088, "s2": 1000]))
        #expect(abs(value - 1400) < 0.01)
    }

    @Test func theSingleTrackFallbackMapsSystemAndDropsMic() throws {
        let parts = [part(1, offset: 0, wall: nil, system: "s1", mic: "m1")]
        let fallback = [CaptureStitcher.PlaybackPlacement(track: .system, url: url("s1"), startSeconds: 0)]
        let system = try #require(map(1305.6, parts: parts, durations: ["s1": 2176, "m1": 2000], placements: fallback))
        #expect(abs(system - 1305.6) < 1e-6)
        #expect(map(40, .mic, parts: parts, durations: ["s1": 2176, "m1": 2000], placements: fallback) == nil)
    }

    @Test func aMeetingWithNoPartsMapsSystemUnchanged() {
        #expect(map(75, parts: [], durations: [:], placements: []) == 75)
        #expect(map(75, .mic, parts: [], durations: [:], placements: []) == nil)
    }

    @Test func aNegativeOffsetPlaysFromZero() throws {
        let parts = [part(1, offset: 0, wall: 100, system: "s1"), part(2, offset: -120, wall: 200, system: "s2")]
        let value = try #require(map(250, parts: parts, durations: ["s1": 100, "s2": 200]))
        #expect(abs(value - 150) < 1e-6)
    }

    @Test func aScaleWithinTheNoStretchBandIsUnity() throws {
        let placements = [CaptureStitcher.PlaybackPlacement(
            track: .system, url: url("s1"), startSeconds: 0, timeScale: 1.0004, scaleKnown: true)]
        let value = try #require(map(
            3000, parts: [part(1, offset: 0, wall: 4001.6, system: "s1")], durations: ["s1": 4000],
            placements: placements))
        #expect(value == 3000)
    }

    @Test func anAnchorInASkippedFileHasNoPlaybackTime() {
        let parts = [part(1, offset: 0, wall: 100, system: "s1"), part(2, offset: 100, wall: 200, system: "s2")]
        let onlyFirst = [CaptureStitcher.PlaybackPlacement(track: .system, url: url("s1"), startSeconds: 0)]
        #expect(map(250, parts: parts, durations: ["s1": 100, "s2": 200], placements: onlyFirst) == nil)
        #expect(map(50, parts: parts, durations: ["s1": 100, "s2": 200], placements: onlyFirst) == 50)
    }
}

@MainActor
@Suite struct TimecodePlayerLinkTests {
    /// A one-second fictional silence.
    private func silence() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("timecode-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        try file.write(from: buffer)
        return url
    }

    @Test func theEndOfTheItemClearsTheNowPlayingBlock() async throws {
        let url = try silence()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = AudioPlayerController()
        let link = TimecodeLink()
        controller.link = link
        controller.play(from: 0, asset: AVURLAsset(url: url))
        controller.pause()
        controller.play(from: 0.5, asset: AVURLAsset(url: url))
        link.playingAnchor = "notes-decision-0"
        let item = try #require(controller.player?.currentItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        for _ in 0..<200 where link.playingAnchor != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!controller.isPlaying)
        #expect(link.playingAnchor == nil)
        controller.teardown()
    }

    /// While the recording's duration is still loading there are no marks
    /// to click; once they appear, the seek has its upper bound.
    @MainActor
    @Test func marksAppearOnlyOnceTheDurationIsKnown() async throws {
        let link = TimecodeLink()
        var duration = 0.0
        var loading = false
        let (held, release) = AsyncStream<Double>.makeStream()
        let player = Task { @MainActor in
            await AudioPlayerView.loadDurationThenPublish(
                {
                    loading = true
                    for await seconds in held { return seconds }
                    return nil
                },
                store: { duration = $0 }
            ) { link.setMapping { seconds, _ in seconds } }
        }
        for _ in 0..<1000 where !loading { await Task.yield() }
        #expect(loading)
        #expect(link.mapping == nil)
        release.yield(300)
        await player.value
        let mapping = try #require(link.mapping)
        let playback = try #require(mapping(57, .system))
        #expect(TimecodeLink.seekTarget(playback: playback, duration: duration) == 54)
    }

    /// A player torn down while its duration loads publishes nothing: the
    /// link keeps what its replacement set.
    @MainActor
    @Test func aCancelledLoadPublishesNothing() async throws {
        let link = TimecodeLink()
        var duration = 0.0
        var loading = false
        let (held, release) = AsyncStream<Double>.makeStream()
        let player = Task { @MainActor in
            await AudioPlayerView.loadDurationThenPublish(
                {
                    loading = true
                    for await seconds in held { return seconds }
                    return nil
                },
                store: { duration = $0 }
            ) { link.setMapping { seconds, _ in seconds } }
        }
        for _ in 0..<1000 where !loading { await Task.yield() }
        #expect(loading)
        player.cancel()
        link.setMapping { seconds, _ in seconds * 2 }
        release.yield(300)
        await player.value
        let mapping = try #require(link.mapping)
        #expect(mapping(57, .system) == 114)
        #expect(duration == 0)
    }

    @Test func aClickOnThePlayingItemRequestsAPause() {
        let link = TimecodeLink()
        link.activate("a", playbackSeconds: 40)
        #expect(link.request?.playbackSeconds == 40)
        link.playingAnchor = "a"
        link.activate("a", playbackSeconds: 40)
        #expect(link.request?.playbackSeconds == nil)
        link.activate("b", playbackSeconds: 12)
        #expect(link.request?.playbackSeconds == 12)
        #expect(link.request?.anchorID == "b")
    }
}

@MainActor
@Suite struct TimecodeMarkViewTests {
    private func setUp() throws -> (MarkHost, NotesDocument, NotesDocBlock) {
        let doc = fictionalDocument()
        let host = MarkHost()
        let paragraph = try #require(doc.blocks.first { $0.blockText.hasPrefix("The console build") })
        host.show(doc, timecodes: host.timecodes([paragraph.anchorID: NotesDocTimecode(seconds: 57, track: .system)]))
        return (host, doc, paragraph)
    }

    @Test func voiceOverReadsAPlayButtonBeforeTheMarkedBlock() throws {
        let (host, _, paragraph) = try setUp()
        defer { host.close() }
        let children = try #require(host.controller.textView.accessibilityChildren())
        let buttons = children.compactMap { $0 as? NotesDocAccessibilityTimecode }
        #expect(buttons.count == 1)
        let button = try #require(buttons.first)
        #expect(button.accessibilityLabel() == "Play from 0:57")
        #expect(button.accessibilityRole() == .button)
        let index = try #require(children.firstIndex { ($0 as AnyObject) === button })
        let next = try #require(children[index + 1] as? NotesDocAccessibilityText)
        #expect(next.words == paragraph.blockText)
        #expect(button.accessibilityPerformPress())
        #expect(host.activations.map(\.0) == [paragraph.anchorID])
    }

    @Test func theBlockMenuOffersPlayFirst() throws {
        let (host, doc, paragraph) = try setUp()
        defer { host.close() }
        let line = try #require(host.controller.markRects(
            NSRange(location: paragraph.range.location + 3, length: 2), visible: NSRange(location: 0, length: doc.text.length)).first)
        let menu = try #require(host.controller.menu(for: try host.event(.rightMouseDown, at: NSPoint(x: line.midX, y: line.midY))) { NSMenu() })
        #expect(menu.items.first?.title == "Play from 0:57")
        let other = try #require(doc.blocks.first { $0.section == .decision })
        let otherLine = try #require(host.controller.markRects(
            NSRange(location: other.range.location + 3, length: 2), visible: NSRange(location: 0, length: doc.text.length)).first)
        let otherMenu = try #require(host.controller.menu(for: try host.event(.rightMouseDown, at: NSPoint(x: otherLine.midX, y: otherLine.midY))) { NSMenu() })
        #expect(otherMenu.items.first?.title != "Play from 0:57")
        #expect(!otherMenu.items.contains { $0.title.hasPrefix("Play from") })
    }

    @Test func aDoubleClickOnAMarkDoesNotUndoTheFirstClick() throws {
        let (host, doc, paragraph) = try setUp()
        defer { host.close() }
        let point = try host.markPoint(paragraph, in: doc)
        #expect(host.controller.timecodeHit(at: point) == paragraph.anchorID)
        host.controller.textView.mouseDown(with: try host.event(.leftMouseDown, at: point, clickCount: 1))
        #expect(host.activations.count == 1)
        host.controller.textView.mouseDown(with: try host.event(.leftMouseDown, at: point, clickCount: 2))
        #expect(host.activations.count == 1)
        // The click never started a selection.
        #expect(host.controller.textView.selectedRange().length == 0)
    }

    /// A scroll under a pointer that does not move hovers the block that is
    /// now under it.
    @Test func aScrollUnderAStillPointerMovesTheHover() throws {
        let doc = fictionalDocument()
        let host = MarkHost(height: 120)
        defer { host.close() }
        host.show(doc, timecodes: host.timecodes(Dictionary(uniqueKeysWithValues: doc.blocks.map {
            ($0.anchorID, NotesDocTimecode(seconds: 57, track: .system))
        })))
        let first = try #require(doc.blocks.first { $0.section == .decision })
        let firstY = try host.markPoint(first, in: doc).y
        let later = try #require(doc.blocks.first { $0.blockText.hasPrefix("The console build") })
        let laterY = try host.markPoint(later, in: doc).y
        #expect(laterY > firstY + 40)
        host.scroll(to: firstY - 40)
        let point = try host.markPoint(first, in: doc)
        host.controller.textView.mouseMoved(with: try host.event(.mouseMoved, at: point))
        #expect(host.controller.hoveredBlock == first.anchorID)
        host.scroll(to: firstY - 40 + (laterY - firstY))
        #expect(host.controller.hoveredBlock == later.anchorID)
    }

    /// A piece sliding open and shut above a pointer that does not move
    /// hovers the block that is under it once the slide has moved the text.
    @Test func aSlideUnderAStillPointerMovesTheHover() throws {
        let doc = fictionalDocument()
        let host = MarkHost()
        defer { host.close() }
        let timecodes = host.timecodes(Dictionary(uniqueKeysWithValues: doc.blocks.map {
            ($0.anchorID, NotesDocTimecode(seconds: 57, track: .system))
        }))
        host.show(doc, timecodes: timecodes)
        let above = try #require(doc.blocks.firstIndex { $0.blockText.hasPrefix("The console build") })
        let piece = doc.blocks[above]
        let below = doc.blocks[above + 1]
        host.controller.textView.mouseMoved(with: try host.event(.mouseMoved, at: try host.markPoint(below, in: doc)))
        #expect(host.controller.hoveredBlock == below.anchorID)
        let composer = AnyView(Text("Composer for Quoll Harbor").frame(height: 120))
        host.show(doc, timecodes: timecodes, attachments: [piece.anchorID: composer], composing: piece.anchorID)
        // The slide has not moved anything yet.
        #expect(host.controller.hoveredBlock == below.anchorID)
        host.settle()
        #expect(host.controller.hoveredBlock == piece.anchorID)
        host.show(doc, timecodes: timecodes)
        #expect(host.controller.hoveredBlock == piece.anchorID)
        host.settle()
        #expect(host.controller.hoveredBlock == below.anchorID)
    }

    /// New notes landing under a pointer that does not move hover the block
    /// now under it, not the old block's position.
    @Test func newNotesUnderAStillPointerMoveTheHover() throws {
        let doc = fictionalDocument()
        var longer = fictionalNotes
        longer.summary = String(repeating: "The harbor crew met on Thursday to walk the Quoll Harbor jetty. ", count: 30)
        let relaid = NotesDocumentBuilder.build(NotesDocInput(
            structured: longer, doneKeys: [], searchTerms: [], portuguese: false,
            userActionTitle: "Demo User — Action Items", direction: .aquarela))
        let host = MarkHost()
        defer { host.close() }
        let all = { (doc: NotesDocument) in
            host.timecodes(Dictionary(uniqueKeysWithValues: doc.blocks.map {
                ($0.anchorID, NotesDocTimecode(seconds: 57, track: .system))
            }))
        }
        host.show(doc, timecodes: all(doc))
        let paragraph = try #require(doc.blocks.first { $0.blockText.hasPrefix("The console build") })
        let point = try host.markPoint(paragraph, in: doc)
        host.controller.textView.mouseMoved(with: try host.event(.mouseMoved, at: point))
        #expect(host.controller.hoveredBlock == paragraph.anchorID)
        host.show(relaid, timecodes: all(relaid))
        let summary = try #require(relaid.blocks.first { $0.blockText.hasPrefix("The harbor crew met") })
        let moved = try #require(relaid.blocks.first { $0.anchorID == paragraph.anchorID })
        #expect(try host.markPoint(summary, in: relaid).y < point.y)
        #expect(try host.markPoint(moved, in: relaid).y > point.y)
        #expect(host.controller.hoveredBlock == summary.anchorID)
    }

    /// An item ticked done or back settles on its own spring; the text that
    /// moves under a pointer that stays put takes the hover with it.
    @Test func aTickSettlingUnderAStillPointerMovesTheHover() throws {
        let items = ["Send the tide table to Quoll Harbor.", "Book the jetty crane for Vexatron Labs."]
        func doc(_ done: [String]) -> NotesDocument {
            NotesDocumentBuilder.build(NotesDocInput(
                structured: NotesStructured(
                    summary: "The harbor crew met on Thursday.", detailedNotes: "One closing line.", decisions: [],
                    actionItems: [], userActionItems: items.map { ActionItem(owner: "Demo User", text: $0) }),
                doneKeys: Set(done.map { ActionItemKey.key(for: $0) }), searchTerms: [], portuguese: false,
                userActionTitle: "Demo User — Action Items", direction: .fluido))
        }
        func all(_ doc: NotesDocument) -> NotesDocTimecodes {
            host.timecodes(Dictionary(uniqueKeysWithValues: doc.blocks.map {
                ($0.anchorID, NotesDocTimecode(seconds: 57, track: .system))
            }))
        }
        /// What a fresh pointer move at the same place hovers.
        func underPointer(_ point: NSPoint) -> String? {
            let hovered = host.controller.hoveredBlock
            host.controller.pointerMoved(to: point)
            let fresh = host.controller.hoveredBlock
            host.controller.pointerMoved(to: point)
            #expect(hovered == fresh, "the hover is not the block under the pointer")
            return fresh
        }
        let host = MarkHost()
        defer { host.close() }
        let open = doc([])
        host.show(open, timecodes: all(open))
        let second = try #require(open.blocks.first { $0.blockText == items[1] })
        let point = try host.markPoint(second, in: open)
        host.controller.textView.mouseMoved(with: try host.event(.mouseMoved, at: point))
        #expect(host.controller.hoveredBlock == second.anchorID)
        // Done: the first row leaves and the second rises into its place.
        let done = doc([items[0]])
        host.show(done, timecodes: all(done))
        let hoveredMidMotion = host.controller.hoveredBlock
        host.settle(wait: NotesDocController.settleDuration + 0.05, frame: "motionTick:")
        let afterDone = underPointer(point)
        #expect(afterDone != hoveredMidMotion)
        // Back: the first row arrives and the second is pushed down again.
        host.show(open, timecodes: all(open))
        host.settle(wait: NotesDocController.settleDuration + 0.05, frame: "motionTick:")
        #expect(underPointer(point) == second.anchorID)
    }

    @Test func switchedOffThereAreNoMarksButtonsOrMenuItems() throws {
        let doc = fictionalDocument()
        let host = MarkHost()
        defer { host.close() }
        host.show(doc, timecodes: nil)
        let paragraph = try #require(doc.blocks.first { $0.blockText.hasPrefix("The console build") })
        let point = try host.markPoint(paragraph, in: doc)
        #expect(host.controller.timecodeHit(at: point) == nil)
        host.controller.textView.mouseMoved(with: try host.event(.mouseMoved, at: point))
        #expect(host.controller.hoveredBlock == nil)
        let children = try #require(host.controller.textView.accessibilityChildren())
        #expect(!children.contains { $0 is NotesDocAccessibilityTimecode })
        let line = try #require(host.controller.markRects(
            NSRange(location: paragraph.range.location + 3, length: 2), visible: NSRange(location: 0, length: doc.text.length)).first)
        let menu = try #require(host.controller.menu(for: try host.event(.rightMouseDown, at: NSPoint(x: line.midX, y: line.midY))) { NSMenu() })
        #expect(!menu.items.contains { $0.title.hasPrefix("Play from") })
    }
}
