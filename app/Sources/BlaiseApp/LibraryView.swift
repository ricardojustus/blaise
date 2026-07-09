import BlaiseCore
import SwiftUI

// D16 Direction A: NavigationSplitView — glass sidebar (three smart groups),
// day-grouped meeting list (C's grouping + B's row metadata), reading pane.
// Visual layer per PROPOSALS_V2: tokens come from `Design` (DesignSystem.swift).

@MainActor
enum Theme {
    /// Primary accent — selection, user-action box, search-match highlight,
    /// ready pulse. Resolved from the active design direction.
    static var accent: Color { Design.accent }
}

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(AppUIState.self) private var uiState
    @Environment(LibraryModel.self) private var library
    @Environment(PipelineActivityHolder.self) private var activity
    @State private var searchResults = SearchResults()
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        @Bindable var uiState = uiState
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            if let id = uiState.selectedMeetingID {
                MeetingDetailView(meetingID: id)
                    .id(id)
            } else {
                // The direction's field, even with nothing selected — the
                // bare window background read as unstyled in every direction.
                DirectionUnavailableView(
                    title: "No Meeting Selected", systemImage: "doc.text",
                    description: "Pick a meeting from the list to read its notes.")
                .background {
                    Design.paneBackdrop(tint: nil).ignoresSafeArea()
                }
            }
        }
        .searchable(text: $uiState.searchText, placement: .toolbar, prompt: "Search notes & transcripts")
        .searchFocused($searchFocused)
        .onChange(of: uiState.searchFocusRequest) {
            searchFocused = true  // ⌘F (accessibility floor)
        }
        .onChange(of: uiState.searchText) {
            runSearch(uiState.searchText)
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                RecordingIndicatorView()
            }
            // V3 chip fix, part 2: the system's shared toolbar glass for
            // a status item is an icon-sized blob the "Idle" text
            // overflowed. Hide it; the chip draws its own capsule whose
            // shape derives from the content.
            .sharedBackgroundVisibility(.hidden)
            // A GROUP, not a single ToolbarItem: macOS renders only the first
            // control in a ToolbarItem, which silently dropped the End & Process
            // button (leaving Pause as the only visible recording control).
            ToolbarItemGroup(placement: .primaryAction) {
                recordToolbarButtons
            }
        }
        // Window-level action-failure banner (rename, done toggle): the
        // split-view analog of the menu bar's `lastActionError` line —
        // visible wherever the failed action happened, dismissible, replaced
        // by the next success.
        .overlay(alignment: .bottom) {
            if let error = uiState.lastActionError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.system(size: 12))
                    Button {
                        uiState.lastActionError = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .modifier(GlassCapsule())
                .padding(.bottom, 18)
                .accessibilityLabel("Action failed: \(error)")
            }
        }
        // Handoff persistent-failure banner (owner directive refining hard
        // floor 8): calm and dismissible per failure episode, floating over
        // the top of the split view. Clears silently on delivery.
        .overlay(alignment: .top) {
            HandoffWarningBanner()
        }
    }

    /// Smart-group rows: title, symbol, icon tint per direction.
    /// Caderno keeps quiet warm icons; Estúdio runs bold monochrome cyan;
    /// Aquarela gives each group its semantic color (Reminders-style).
    private var sidebarItems: [(String, String, Color, LibraryModel.SmartGroup)] {
        switch Design.direction {
        case .caderno:
            return [
                ("All Meetings", "books.vertical", Design.accent.opacity(0.85), .all),
                ("This Week", "calendar", Design.accent.opacity(0.85), .thisWeek),
                ("My Action Items", "checklist", Design.accent.opacity(0.85), .myActionItems),
            ]
        case .estudio, .fluido:
            return [
                ("All Meetings", "rectangle.stack.fill", Design.accent, .all),
                ("This Week", "calendar", Design.accent, .thisWeek),
                ("My Action Items", "checklist.checked", Design.accent, .myActionItems),
            ]
        case .aquarela:
            return [
                ("All Meetings", "tray.full.fill", Color(red: 0.49, green: 0.60, blue: 0.80), .all),
                ("This Week", "calendar.badge.clock", Color(red: 0.80, green: 0.66, blue: 0.42), .thisWeek),
                ("My Action Items", "checkmark.circle.fill", Design.accent, .myActionItems),
            ]
        }
    }

    private var sidebar: some View {
        @Bindable var uiState = uiState
        return List(selection: $uiState.selectedGroup) {
            Section("Library") {
                ForEach(sidebarItems, id: \.3) { title, icon, tint, tag in
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: icon)
                            .foregroundStyle(tint)
                    }
                    .tag(tag)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var contentColumn: some View {
        if !uiState.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsList(results: searchResults)
        } else if uiState.selectedGroup == .myActionItems {
            UserActionItemsList()
        } else {
            meetingList
        }
    }

    /// All four directions: the day-grouped meeting list as a ScrollView +
    /// LazyVStack. Deliberately NOT a `List`: SwiftUI's List on macOS
    /// self-sizes variable-height rows through NSTableView's row-height
    /// cache, and when the library data lands while the window is still
    /// coming up (every real launch — the ValueObservation's first emission
    /// races window bring-up) the cache freezes at single-line height and
    /// never invalidates — the launch-time "squished cards" bug that only a
    /// manual window resize repaired. A LazyVStack has no height cache; rows
    /// are laid out by SwiftUI on every pass, so the first frame is always
    /// right. Fluido rows are physics cards; the other directions keep their
    /// plain rows with a quiet accent selection.
    ///
    /// Keyboard selection (a `List` affordance the ScrollView swap dropped —
    /// restored): the scroll area is focusable (clicking a row focuses it),
    /// ↑/↓ move the selection through the visible flat order across day
    /// groups (`ListKeySelection.moved`, core, unit-tested), and the
    /// selected row scrolls into view. The selection highlight carries the
    /// focus story; the default focus ring around the whole column is noise.
    private var meetingList: some View {
        let groups = LibraryModel.dayGroups(library.items(in: uiState.selectedGroup))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Design.direction == .fluido ? 9 : 2) {
                    if !appEnv.calendarSuggestions.upcomingRows.isEmpty {
                        UpcomingMeetingsSection(rows: appEnv.calendarSuggestions.upcomingRows)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                    }
                    ForEach(groups) { group in
                        DayGroupHeader(label: group.label, items: group.items)
                            .padding(.top, 16)
                            .padding(.horizontal, 6)
                        ForEach(group.items) { item in
                            meetingRow(item)
                                .id(item.id)  // ScrollViewReader target (↑/↓)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onMoveCommand { direction in
                let delta: Int
                switch direction {
                case .up: delta = -1
                case .down: delta = 1
                default: return
                }
                let order = groups.flatMap { $0.items.map(\.id) }
                guard
                    let target = ListKeySelection.moved(
                        from: uiState.selectedMeetingID, in: order, delta: delta)
                else { return }
                uiState.selectedMeetingID = target
                proxy.scrollTo(target)
            }
            .onChange(of: uiState.selectedMeetingID) {
                // The detail pane re-roots on every selection (`.id(id)`)
                // and grabs first responder in the same commit, silently
                // dropping list focus — the SECOND arrow press died
                // (verified against the demo app). Selection can only
                // change while this list is on screen from the list itself
                // (click or arrows), so keep it focused.
                listFocused = true
            }
        }
        .task {
            await appEnv.refreshCalendarSurfaces()
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Design.listColumn.ignoresSafeArea())
        .navigationTitle(uiState.selectedGroup == .thisWeek ? "This Week" : "All Meetings")
        .overlay {
            if library.items.isEmpty && appEnv.calendarSuggestions.upcomingRows.isEmpty {
                ContentUnavailableView(
                    "No Meetings Yet", systemImage: "rectangle.stack",
                    description: Text("Import audio via File → Import Meeting Audio…"))
            }
        }
    }

    /// One meeting row (fluido physics card or plain row). Selecting by
    /// click also focuses the list, so ↑/↓ work immediately after — how a
    /// native Mac list behaves.
    @ViewBuilder
    private func meetingRow(_ item: MeetingListItem) -> some View {
        if Design.direction == .fluido {
            FluidoMeetingCard(
                item: item,
                selected: uiState.selectedMeetingID == item.id,
                runningStage: activity.activeRuns[item.id]?.stage,
                justReady: library.recentlyReady.contains(item.id)
            ) {
                uiState.selectedMeetingID = item.id
                listFocused = true
            }
        } else {
            plainMeetingRow(item)
        }
    }

    /// Caderno / Estúdio / Aquarela row: the existing MeetingRowView as a
    /// plain button with the one-accent selection tint (c10 visual law).
    /// VoiceOver: the row reads its COMBINED children (title, time, summary,
    /// status, user action-item count) — a flat label here overrode them —
    /// and selection is the `.isSelected` trait, not label text.
    private func plainMeetingRow(_ item: MeetingListItem) -> some View {
        let selected = uiState.selectedMeetingID == item.id
        return Button {
            uiState.selectedMeetingID = item.id
            listFocused = true
        } label: {
            MeetingRowView(
                item: item,
                runningStage: activity.activeRuns[item.id]?.stage,
                justReady: library.recentlyReady.contains(item.id)
            )
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Design.accent.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func runSearch(_ query: String) {
        searchTask?.cancel()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = SearchResults()
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))  // debounce
            guard !Task.isCancelled else { return }
            let results = await library.search(query)
            guard !Task.isCancelled else { return }
            searchResults = results
        }
    }

    // MARK: Recording controls (V1.1 mirror of the menu bar / ⌥⌘R)

    /// The window-toolbar recording controls, routed through the SAME
    /// `AppEnvironment` actions as the menu bar. Three states: recording →
    /// Pause + End & Process; paused → Resume + End & Process; otherwise →
    /// Record (a start is allowed from alarm and while a previous meeting still
    /// processes — only a live session blocks it, enforced by the controller).
    /// MUST live in a `ToolbarItemGroup`: a single `ToolbarItem` renders only
    /// its first control, which silently hid End & Process.
    @ViewBuilder private var recordToolbarButtons: some View {
        let status = appEnv.captureStatus
        if status.isRecording {
            Button {
                Task { await appEnv.pauseRecording() }
            } label: {
                Label("Pause", systemImage: "pause.circle.fill")
            }
            .help("Pause recording (resume later, or end & process now)")
            .accessibilityLabel("Pause recording")
            Button {
                Task { await appEnv.stopRecording() }
            } label: {
                Label("End & Process", systemImage: "stop.circle.fill")
                    .foregroundStyle(Design.recording)
            }
            .help("End the recording and process the meeting")
            .accessibilityLabel("End and process the meeting")
        } else if status.isPaused {
            Button {
                Task { await appEnv.resumePausedRecording() }
            } label: {
                Label("Resume", systemImage: "record.circle")
            }
            // M-8: disabled until the launch orphan-CAF sweep reports done.
            .disabled(!appEnv.canResumePaused)
            .help("Resume the paused recording")
            .accessibilityLabel("Resume recording")
            Button {
                Task { await appEnv.endPausedRecording() }
            } label: {
                Label("End & Process", systemImage: "stop.circle.fill")
                    .foregroundStyle(Design.recording)
            }
            .help("End the paused meeting and process it")
            .accessibilityLabel("End and process the paused meeting")
        } else {
            Button {
                Task { await appEnv.toggleRecording() }
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .help(recordHelp(status.state))
            .accessibilityLabel("Start recording")
        }
    }

    private func recordHelp(_ state: IndicatorState) -> String {
        switch state {
        case .idle:
            return "Start recording (system audio + microphone)"
        case .recording, .warning:
            return "End the recording and process the meeting"
        case .alarm(let message):
            return "Start a new recording (previous capture failed: \(message))"
        case .processing:
            return "Start a new recording (the previous meeting is still processing)"
        case .grace(let title, _):
            return "Start a new recording (\(title) is waiting for rejoin)"
        case .paused(let title, _):
            return "Resume \(title), or end & process it"
        }
    }
}

// MARK: - Upcoming meetings

struct UpcomingMeetingsSection: View {
    @Environment(AppEnvironment.self) private var appEnv
    @AppStorage("calendar.upcoming.collapsed") private var collapsed = false
    let rows: [UpcomingMeetingRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Upcoming")
                        .font(.system(size: 11, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(rows.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(rows.count) upcoming meetings, \(collapsed ? "collapsed" : "expanded")")
            .accessibilityHint(collapsed ? "Expand" : "Collapse")

            if !collapsed {
                ForEach(Array(rows.prefix(5))) { row in
                    UpcomingMeetingRowView(row: row)
                }
            }
        }
    }
}

private struct UpcomingMeetingRowView: View {
    @Environment(AppEnvironment.self) private var appEnv
    let row: UpcomingMeetingRow

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: sourceIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title.isEmpty ? "Meeting" : row.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.time(row.start))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                }
                Text(detailLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Button {
                Task { await appEnv.startRecording(upcoming: row) }
            } label: {
                Image(systemName: "record.circle")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help("Record")
            .accessibilityLabel("Record \(row.title)")

            if row.offersLaunchAndRecord {
                Button {
                    Task { await appEnv.launchAndRecord(upcoming: row) }
                } label: {
                    Image(systemName: "play.circle")
                        .font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Launch and record")
                .accessibilityLabel("Launch and record \(row.title)")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.accent.opacity(0.16), lineWidth: 1)
        )
    }

    private var sourceIcon: String {
        switch row.source {
        case .meet: return "video"
        case .zoom, .teams: return "person.2.wave.2"
        case .inPerson: return "person.2"
        case .imported: return "waveform"
        }
    }

    private var detailLine: String {
        let attendees = row.attendeeCount == 1 ? "1 attendee" : "\(row.attendeeCount) attendees"
        if let code = row.meetingCode {
            return "\(attendees) · \(code)"
        }
        return attendees
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Day-group header (per-direction personality)

/// Caderno: a serif-italic chapter heading with a fading hairline rule.
/// Estúdio: a gradient tick, wide-tracked caps, meeting count in mono.
/// Aquarela: the label plus a dot cluster of that day's meeting hues.
struct DayGroupHeader: View {
    let label: String
    let items: [MeetingListItem]

    var body: some View {
        switch Design.direction {
        case .caderno:
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .serif).italic())
                    .foregroundStyle(Design.accent.opacity(0.85))
                LinearGradient(
                    colors: [Design.accent.opacity(0.35), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1)
                .offset(y: 1)
                .accessibilityHidden(true)
            }
        case .estudio, .fluido:
            HStack(spacing: 8) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Design.accent, Design.support],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 3, height: 11)
                    .accessibilityHidden(true)
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Design.support)
                    .accessibilityLabel("\(items.count) meetings")
            }
        case .aquarela:
            HStack(spacing: 8) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                        Circle()
                            .fill(Design.meetingHue(item.meeting.title))
                            .frame(width: 5, height: 5)
                    }
                }
                .accessibilityHidden(true)
                Spacer()
            }
        }
    }
}

// MARK: - Meeting row (C's content + B's metadata borrow)

struct MeetingRowView: View {
    let item: MeetingListItem
    let runningStage: PipelineStage?
    let justReady: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if Design.direction == .aquarela {
                    // The meeting's own hue — the row's quiet identity mark.
                    Circle()
                        .fill(Design.meetingHue(item.meeting.title))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
                Text(item.meeting.title)
                    .font(Design.rowTitleFont)
                    .lineLimit(1)
                Spacer(minLength: 4)
                statusGlyph
                Text(timeLine)
                    .font(Design.metaFont)
                    .foregroundStyle(
                        Design.direction == .estudio || Design.direction == .fluido
                            ? AnyShapeStyle(Design.accent.opacity(0.7)) : AnyShapeStyle(.tertiary))
            }
            if let summary = item.summary, !summary.isEmpty {
                Text(summary)
                    .font(Design.direction == .caderno ? .system(size: 12.5, design: .serif) : .system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 9))
                    .accessibilityHidden(true)
                Text(attendeeLine)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if justReady {
                    Text("Ready")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.22), in: Capsule())
                        .foregroundStyle(Theme.accent)
                        .scaleEffect(pulse ? 1.08 : 1.0)
                        .shadow(color: Theme.accent.opacity(pulse ? 0.55 : 0.15), radius: pulse ? 7 : 2)
                        .onAppear {
                            guard !reduceMotion else { return }  // pulse suppressed
                            withAnimation(.easeInOut(duration: 0.5).repeatCount(4, autoreverses: true)) {
                                pulse = true
                            }
                        }
                        .accessibilityLabel("Notes ready")
                }
                if item.userActionItemCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checklist")
                            .font(.system(size: 8, weight: .semibold))
                        Text("\(item.userActionItemCount)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.16), in: Capsule())
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("\(item.userActionItemCount) action items for you")
                }
            }
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Design.direction == .estudio ? 4 : 0)
        // Estúdio hover lift: the row rises slightly under the pointer.
        .background(
            Design.direction == .estudio && hovering ? Color.white.opacity(0.045) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .scaleEffect(Design.direction == .estudio && hovering && !reduceMotion ? 1.012 : 1.0)
        .animation(.spring(duration: 0.25), value: hovering)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if let stage = runningStage {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing: \(stage.rawValue)")
        } else {
            switch item.meeting.status {
            case .processing, .recording:
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Processing pending")
            case .paused:
                // G9: a held-open meeting — calm pause glyph (not a failure,
                // not yet processing).
                Image(systemName: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Paused")
            case .cancelled:
                // G10: processing cancelled by the user — calm glyph (a
                // sanctioned state, not a failure). The detail view offers
                // Process to re-run.
                Image(systemName: "xmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Processing cancelled")
            case .failed:
                // Notes-pending (D17) is NOT a failure: transcript ready,
                // notes complete automatically — calm glyph, no orange.
                if NotesPendingClass.isPending(item.meeting.lastProcessingError) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Notes pending")
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Processing failed")
                }
            case .ready:
                EmptyView()
            }
        }
    }

    private var timeLine: String {
        var line = item.meeting.startedAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "en_GB")))
        if let ended = item.meeting.endedAt {
            let minutes = max(1, Int(ended.timeIntervalSince(item.meeting.startedAt) / 60))
            line += " · \(minutes) min"
        }
        return line
    }

    private var attendeeLine: String {
        item.meeting.attendees.isEmpty
            ? "No attendees" : item.meeting.attendees.map(\.name).joined(separator: ", ")
    }
}

// MARK: - Fluido meeting card (physics)

/// One meeting as a floating card: material surface, scroll-edge lift/fade,
/// hover tilt toward the cursor, pressed spring. Rows that are still
/// transcribing shimmer quietly.
struct FluidoMeetingCard: View {
    let item: MeetingListItem
    let selected: Bool
    let runningStage: PipelineStage?
    let justReady: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var working: Bool {
        runningStage != nil || item.meeting.status == .processing
    }

    var body: some View {
        Button(action: action) {
            MeetingRowView(item: item, runningStage: runningStage, justReady: justReady)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? AnyShapeStyle(Design.accent.opacity(0.13)) : AnyShapeStyle(.white.opacity(0.035)),
                    in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            selected ? Design.accent.opacity(0.45) : Color.white.opacity(0.06),
                            lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .modifier(FluidoShimmer(active: working))
        }
        .buttonStyle(FluidoCardButtonStyle())
        .modifier(FluidoCardPhysics())
        // Scroll-edge lift/fade is movement: identity under Reduce Motion.
        .scrollTransition(.interactive) { content, phase in
            content
                .opacity(reduceMotion || phase.isIdentity ? 1 : 0.45)
                .scaleEffect(reduceMotion || phase.isIdentity ? 1 : 0.965)
                .offset(y: reduceMotion ? 0 : phase.value * 9)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: selected)
        // VoiceOver: combined children (title, time, summary, status, the user
        // count) — a flat label here overrode them; selection is a trait.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - My Action Items (load-bearing)

struct UserActionItemsList: View {
    @Environment(AppUIState.self) private var uiState
    @Environment(LibraryModel.self) private var library
    @Environment(AppEnvironment.self) private var appEnv

    /// Open (not-done) entries grouped by meeting, recency-ordered.
    private var groups: [(meetingID: MeetingID, title: String, startedAt: Date, items: [UserActionEntry])] {
        var seen: [MeetingID: Int] = [:]
        var result: [(MeetingID, String, Date, [UserActionEntry])] = []
        for entry in library.userEntries where !entry.done {  // recency-ordered by construction
            if let index = seen[entry.meetingID] {
                result[index].3.append(entry)
            } else {
                seen[entry.meetingID] = result.count
                result.append((entry.meetingID, entry.meetingTitle, entry.startedAt, [entry]))
            }
        }
        return result.map { (meetingID: $0.0, title: $0.1, startedAt: $0.2, items: $0.3) }
    }

    private var completed: [UserActionEntry] {
        library.userEntries.filter(\.done)
    }

    /// V1.1 done toggle (`action_item_state`, local-only; the library
    /// observation refreshes the list). Failures surface in the window
    /// banner (`AppUIState.lastActionError`) — never swallowed.
    private func setDone(_ entry: UserActionEntry, done: Bool) {
        let database = appEnv.database
        let uiState = uiState
        Task {
            let repo = ActionItemStateRepository(database: database)
            do {
                if done {
                    try await repo.markDone(meetingID: entry.meetingID, itemText: entry.text)
                } else {
                    try await repo.clearDone(meetingID: entry.meetingID, itemText: entry.text)
                }
                uiState.lastActionError = nil
            } catch {
                uiState.lastActionError = "Could not update the action item: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: UserActionEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                setDone(entry, done: !entry.done)
            } label: {
                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(entry.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.done ? "Mark not done: \(entry.text)" : "Mark done: \(entry.text)")
            .help(entry.done ? "Mark as not done" : "Mark as done")
            Button {
                uiState.selectedMeetingID = entry.meetingID
                uiState.detailRequest = .init(meetingID: entry.meetingID, target: .userActions)
            } label: {
                Text(entry.text)
                    .font(.system(size: 13, weight: entry.done ? .regular : .medium))
                    .strikethrough(entry.done)
                    .foregroundStyle(entry.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.meetingID) { group in
                Section {
                    ForEach(group.items) { entry in
                        entryRow(entry)
                    }
                } header: {
                    HStack {
                        Text(group.title).lineLimit(1)
                        Spacer()
                        Text(BlaiseDateFormat.dayMonthYear(group.startedAt))  // pinned DD/MM/YYYY (M-1)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
            }
            // V1.1: done items archive into one collapsed group.
            if !completed.isEmpty {
                Section {
                    DisclosureGroup("Completed (\(completed.count))") {
                        ForEach(completed) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                entryRow(entry)
                                Text(entry.meetingTitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
        }
        .listStyle(.inset)
        .designListBackground()
        .navigationTitle("My Action Items")
        .overlay {
            if library.userEntries.isEmpty {
                ContentUnavailableView("No Action Items", systemImage: "checklist")
            }
        }
    }
}

// MARK: - Search results

struct SearchResultsList: View {
    @Environment(AppUIState.self) private var uiState
    let results: SearchResults

    var body: some View {
        List {
            // Notes first: notes are for humans (Floor 5) and carry the most
            // valuable output. bm25 is not comparable across the two FTS tables,
            // so the surfaces are separate sections, each internally ranked.
            if !results.notes.isEmpty {
                Section("Notes") {
                    ForEach(results.notes) { result in
                        Button {
                            uiState.selectedMeetingID = result.hit.meetingID
                            uiState.detailRequest = .init(
                                meetingID: result.hit.meetingID, target: .notes)
                        } label: {
                            resultRow(
                                title: result.meetingTitle, startedAt: result.startedAt,
                                segments: result.segments)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !results.transcripts.isEmpty {
                Section("Transcript") {
                    ForEach(results.transcripts) { result in
                        Button {
                            uiState.selectedMeetingID = result.hit.meetingID
                            uiState.detailRequest = .init(
                                meetingID: result.hit.meetingID,
                                target: .transcript(segmentID: result.hit.segmentID))
                        } label: {
                            resultRow(
                                title: result.meetingTitle, startedAt: result.startedAt,
                                segments: result.segments)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.inset)
        .designListBackground()
        .navigationTitle("Search")
        .overlay {
            if results.isEmpty {
                ContentUnavailableView.search
            }
        }
    }

    private func resultRow(
        title: String, startedAt: Date, segments: [SearchSnippetFormatter.Segment]
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(BlaiseDateFormat.dayMonthYear(startedAt))  // pinned DD/MM/YYYY (M-1)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            snippetText(segments)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    /// The pinned delimiters rendered as bold accent runs.
    private func snippetText(_ segments: [SearchSnippetFormatter.Segment]) -> Text {
        segments.reduce(Text("")) { accumulated, segment in
            accumulated
                + Text(segment.text)
                .fontWeight(segment.isMatch ? .bold : .regular)
                .foregroundColor(segment.isMatch ? Theme.accent : nil)
        }
    }
}

// MARK: - In-window recording indicator (C11: live, fills the C10 slot)

struct RecordingIndicatorView: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        let state = appEnv.captureStatus.state
        let recording = appEnv.captureStatus.isRecording
        HStack(spacing: 5) {
            Image(systemName: glyph(state))
                .font(.system(size: 11))
                .foregroundStyle(tint(state))
                // Live pulse: while recording the dot breathes — a soft
                // glow swelling and settling, never blinking.
                .shadow(
                    color: recording ? Design.recording.opacity(breathing ? 0.9 : 0.25) : .clear,
                    radius: breathing ? 6 : 2
                )
                .scaleEffect(recording && breathing ? 1.12 : 1.0)
            Text(label(state))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
            // G12 §2: while recording, the two-channel level meter replaces the
            // static "is it hearing me?" guesswork — its holder is read inside
            // the LevelMeterView leaf, so a ≤ 10 Hz publish invalidates only
            // that subview.
            if recording {
                LevelMeterView(holder: appEnv.levelMeter)
            }
        }
        // V3 fix (the user: "the Idle text doesn't fit the circle it's in"): the
        // macOS 26 toolbar wrapped this status item in an icon-sized glass
        // blob the text overflowed, and the old nested GlassCapsule stacked
        // a second glass inside it. Now the toolbar's shared background is
        // hidden (sharedBackgroundVisibility, at the ToolbarItem) and the
        // chip draws exactly ONE capsule whose shape derives from content.
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .modifier(GlassCapsule())
        .accessibilityLabel("Recording indicator: \(label(state))")
        .onChange(of: recording, initial: true) {
            guard recording, !reduceMotion else {
                breathing = false
                return
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    private func glyph(_ state: IndicatorState) -> String {
        switch state {
        case .idle: return "record.circle"
        case .recording: return "record.circle.fill"
        case .warning: return "exclamationmark.circle"
        case .alarm: return "exclamationmark.triangle.fill"
        case .processing: return "arrow.triangle.2.circlepath.circle"
        case .grace: return "pause.circle"
        case .paused: return "pause.circle.fill"
        }
    }

    private func tint(_ state: IndicatorState) -> AnyShapeStyle {
        switch state {
        case .idle: return AnyShapeStyle(.tertiary)
        case .recording: return AnyShapeStyle(Design.recording)
        case .warning, .alarm: return AnyShapeStyle(Color.orange)
        case .processing: return AnyShapeStyle(.secondary)
        case .grace: return AnyShapeStyle(.secondary)
        // G9: static accent (calm, not the loud recording red).
        case .paused: return AnyShapeStyle(Theme.accent)
        }
    }

    private func label(_ state: IndicatorState) -> String {
        switch state {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .warning(_, let message): return message
        case .alarm(let message): return message
        case .processing: return "Processing"
        case .grace: return "Waiting for rejoin"
        // G9: accumulated recorded time with "paused".
        case .paused(_, let seconds):
            return "Paused — \(RecordingMenuView.duration(seconds)) recorded"
        }
    }
}

/// Main-window surface of the handoff persistent-failure warning:
/// "Evidence Store unreachable since <time> — <n> meeting(s) waiting. Last
/// error: <reason>" with Retry Now / Open Settings, dismissible PER EPISODE
/// (`HandoffStatusHolder.dismissWarning`; a distinct error or a new queued
/// item re-arms it). Renders nothing when the warning is inactive or the
/// current episode was dismissed — clearing is silent by design.
private struct HandoffWarningBanner: View {
    @Environment(AppEnvironment.self) private var appEnv
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let warning = appEnv.handoffStatus.bannerWarning {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(warning.message())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry Now") {
                    Task { await appEnv.retryHandoffNow() }
                }
                .controlSize(.small)
                Button("Open Settings") {
                    openSettings()
                }
                .controlSize(.small)
                Button {
                    appEnv.handoffStatus.dismissWarning()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss Evidence Store warning")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .modifier(GlassCapsule())
            .padding(.top, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Evidence Store warning: \(warning.message())")
        }
    }
}

/// Liquid Glass capsule that swaps to a solid fill under Reduce Transparency
/// (accessibility floor).
struct GlassCapsule: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        } else if Design.direction == .estudio || Design.direction == .fluido {
            // Estúdio (and Fluido) run their glass tinted — confident, not timid.
            content.glassEffect(.regular.tint(Design.accent.opacity(0.13)), in: Capsule())
        } else {
            content.glassEffect(.regular, in: Capsule())
        }
    }
}
