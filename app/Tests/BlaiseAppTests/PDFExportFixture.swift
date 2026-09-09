import BlaiseCore
import CoreGraphics
import Foundation

@testable import BlaiseApp

// The real-size fixture the PDF-export render tests print. Fictional
// throughout (Vexatron Labs / Quoll Harbor), and the markdown is produced by
// `NotesRenderer.render` rather than hand-authored, so it is shaped exactly
// like a stored notes row.

enum PDFExportFixture {
    static let title = "Kickoff Quoll Harbor"
    static let date = "21/08/2026"
    static let colophonEnglish = "Made with Blaise"
    /// The last text block of the document — the tail the pagination test
    /// looks for to prove nothing was clipped off the final page.
    static let lastBlock = "Ship the Quoll Harbor handover brief to the field team by Friday."

    static func front() -> FrontBlock {
        FrontBlock(
            title: title,
            dateText: date,
            timeText: "14:00–15:10",
            attendeesText: "Marina Solano, Dev Okafor, Tomás Ferreira, Iara Beltrão",
            kicker: "Meeting notes")
    }

    static func markdown() throws -> String {
        try NotesRenderer.render(
            structured(), language: "en", meetingTitle: title, userName: "Marina Solano")
    }

    static func html(style: PDFStyle) throws -> String {
        try NotesPDFDocument.html(
            markdown: try markdown(), front: front(), style: style, colophon: true, language: "en")
    }

    private static func structured() -> NotesStructured {
        NotesStructured(
            title: title,
            summary: """
                Vexatron Labs committed to a November closed beta for Quoll Harbor, accepted \
                the offline-sync design as the central engineering risk, and agreed to hold \
                the pricing conversation until the field trial returns numbers.
                """,
            detailedNotes: detailedNotes(),
            decisions: [
                "Closed beta opens on 20/10/2026 with the four pilot harbours only",
                "Offline sync ships behind a per-account switch, default off",
                "Pricing stays unpublished until the field trial closes",
                "The Quoll Harbor name is kept; the trademark search came back clean",
                "Hardware refresh is deferred to the 2027 planning round",
            ],
            actionItems: [
                ActionItem(owner: "Dev Okafor", text: "Prototype the conflict merge and time it against the 4,000-record sample"),
                ActionItem(owner: "Iara Beltrão", text: "Rewrite the pilot onboarding script around the two-tap pairing flow"),
                ActionItem(owner: "Tomás Ferreira", text: "Publish the revised schedule with the November dates and circulate it"),
                ActionItem(owner: "", text: "Book the load test window with the platform team"),
                ActionItem(owner: "Dev Okafor", text: "Instrument the sync queue so the field trial produces a latency histogram"),
            ],
            userActionItems: [
                ActionItem(owner: "", text: "Open the QA role and get it approved before the beta"),
                ActionItem(owner: "", text: "Review the trademark file and countersign it"),
                ActionItem(owner: "", text: lastBlock),
            ])
    }

    private static func detailedNotes() -> String {
        var lines: [String] = []
        for topic in topics {
            lines.append("#### " + topic.heading)
            lines.append("")
            for paragraph in topic.paragraphs {
                lines.append(paragraph)
                lines.append("")
            }
            if let bullets = topic.bullets {
                for bullet in bullets { lines.append("- " + bullet) }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Topic {
        let heading: String
        let paragraphs: [String]
        var bullets: [String]?
    }

    private static let topics: [Topic] = [
        Topic(
            heading: "Launch window",
            paragraphs: [
                """
                The closed beta opens on 20/10/2026 and runs for six weeks. Four harbours were \
                picked because each one exercises a different connectivity profile: two have \
                reliable fibre, one runs on a shared satellite uplink that drops for minutes at \
                a time, and the fourth has no uplink at all inside the cold store. The point of \
                the shape is to make offline sync fail early rather than at scale.
                """,
                """
                November was chosen over September for one reason only: the conflict merge is \
                not written yet, and shipping a beta whose first visible behaviour is silently \
                losing a shift record would cost more trust than the extra six weeks cost in \
                schedule. Nobody in the room argued for the earlier date once the failure mode \
                was spelled out.
                """,
                """
                The end of the beta is a hard stop, not a rolling window. The team writes the \
                report in the week after it closes and the pricing conversation happens against \
                that report, so the beta cannot be quietly extended to keep a feature alive.
                """,
            ],
            bullets: [
                "Two fibre harbours, one satellite, one cold store with no uplink",
                "Six weeks, hard stop, report in the following week",
            ]),
        Topic(
            heading: "Offline sync",
            paragraphs: [
                """
                Offline sync is the whole product on the harbour floor and it is also the piece \
                least ready. The current design queues every mutation locally with a monotonic \
                sequence number and replays it on reconnect. That works until two devices edit \
                the same manifest line while both are offline, which is the ordinary case rather \
                than the exotic one.
                """,
                """
                Dev walked through three merge strategies. Last-writer-wins is cheap and wrong: \
                it deletes a supervisor's correction whenever a handset reconnects later. A \
                per-field merge keeps both edits but needs the schema to declare which fields \
                are mergeable, and roughly a third of the manifest fields are free text where \
                merging produces nonsense. The third option, and the one the room preferred, is \
                to merge per field where the schema allows it and to surface the rest as an \
                explicit conflict the supervisor resolves in a queue.
                """,
                """
                The cost of the third option is a new surface — the conflict queue — and the \
                team agreed to build the smallest possible version: a list, the two values, and \
                a pick-one control. No three-way diff, no merge editor, no history browser.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Field trial instrumentation",
            paragraphs: [
                """
                The trial is worthless if it returns anecdotes. The queue gets a latency \
                histogram, the reconnect path gets a counter per outcome, and the conflict queue \
                records how long a conflict waits before a human resolves it. Those three \
                numbers are what the pricing conversation will actually rest on.
                """,
                """
                Instrumentation stays local to the device and is uploaded as an aggregate. No \
                manifest content leaves the harbour, because two of the pilot sites handle \
                consignments under a confidentiality clause that would make raw upload a \
                contract problem rather than an engineering one.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Onboarding and pairing",
            paragraphs: [
                """
                Iara demonstrated the current onboarding: eleven screens, two of which ask for \
                information the operator cannot possibly have on day one. The new flow is two \
                taps — scan the harbour code, confirm the device name — and everything else is \
                deferred to the first time it is actually needed.
                """,
                """
                The pairing code is short-lived and single-use. A longer-lived code was rejected \
                because harbour offices print things and pin them to walls, and a pinned pairing \
                code is a permanent open door into the manifest.
                """,
                """
                The onboarding script is being rewritten around the new flow, and the old one is \
                deleted rather than kept as a fallback. Two scripts means the field team reads \
                whichever one is nearest.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Pricing",
            paragraphs: [
                """
                Pricing stays unpublished. The team has a per-seat number and a per-harbour \
                number in circulation, and publishing either before the trial would anchor the \
                first three conversations against a model nobody has evidence for yet.
                """,
                """
                The trial report is expected to say something about how many seats a harbour \
                actually uses in a week, which is the input both models need and the one nobody \
                currently has.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Hardware",
            paragraphs: [
                """
                The handset refresh is deferred to the 2027 planning round. The current units \
                are slow but the profiling showed the slowness is in the sync path, not the \
                hardware, so replacing them now would buy a smaller improvement than finishing \
                the merge work.
                """,
                """
                Two harbours asked about rugged cases. That is a purchasing question, not a \
                product one, and it goes to the field team with a recommendation rather than \
                into the roadmap.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Naming and trademark",
            paragraphs: [
                """
                The trademark search on Quoll Harbor came back clean in every market the trial \
                touches. The file is ready to countersign and the name is settled — the \
                alternatives list is closed rather than parked.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Support model",
            paragraphs: [
                """
                During the beta, support is the engineering team directly, with a shared inbox \
                and a two-working-day response commitment. That is deliberately unscalable: it \
                keeps the people who wrote the merge code reading the reports of it failing.
                """,
                """
                After the beta the model is revisited. Nobody committed to a tiered structure \
                and nobody should, because the volume of support the product needs is one of the \
                things the trial is meant to measure.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Security review",
            paragraphs: [
                """
                The manifest store is encrypted at rest on the handset and the pairing secret \
                lives in the platform keystore rather than the application container. The review \
                flagged one real issue: the export path writes a plaintext temporary file that \
                is not cleaned up if the process dies mid-export.
                """,
                """
                The fix is to write into a per-export directory and let the operating system \
                own the sweep, which is what the desktop side already does. Tomás took the \
                ticket.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Documentation",
            paragraphs: [
                """
                The harbour handbook is out of date in three places, all of them about the old \
                eleven-screen onboarding. Rather than patch it, the onboarding chapter is \
                rewritten alongside the flow, and the rest of the handbook is left alone.
                """,
                """
                A short conflict-resolution page is added, aimed at a supervisor with no context \
                and thirty seconds, because that is exactly who will read it.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Risks carried",
            paragraphs: [
                """
                The merge work is the schedule. If the conflict queue is not usable by the end \
                of September the beta slips rather than ships without it, and everyone in the \
                room said so out loud so the decision is not re-argued in October.
                """,
                """
                The satellite harbour is the second risk. If its uplink turns out to drop for \
                hours rather than minutes, the queue's memory budget needs revisiting, and \
                nobody has measured that yet.
                """,
                """
                The third risk is quieter: the team has no QA seat, and the beta is the first \
                time the product meets a user who did not build it. The role is open but not \
                yet approved.
                """,
            ],
            bullets: [
                "Merge work is the critical path — slip the beta rather than ship without it",
                "Satellite uplink duration is unmeasured",
                "No QA seat approved yet",
            ]),
        Topic(
            heading: "Conflict queue shape",
            paragraphs: [
                """
                The queue is a single list ordered by age, because a supervisor resolving \
                conflicts at the end of a shift wants the oldest first and nothing else. Each row \
                shows the field, the two competing values with the device and the time each came \
                from, and a pick-one control. There is no free-text merge box: if the right answer \
                is neither value, the supervisor edits the manifest afterwards like any other day.
                """,
                """
                Resolutions are themselves mutations and go through the same queue on the way \
                back out, which means a resolution can in principle conflict with a later edit. \
                That case is rare enough, and recoverable enough, that the team agreed to leave it \
                to the same mechanism rather than build a second one for it.
                """,
                """
                The queue is capped at two hundred rows in the interface. Past that the harbour \
                has a systemic problem the queue cannot fix, and the right response is a banner \
                telling someone to call support rather than an infinite scroll.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Data retention",
            paragraphs: [
                """
                Manifest history is kept for ninety days on the device and indefinitely on the \
                harbour server. The device figure is a storage decision rather than a policy one: \
                the oldest handsets have limited room and a full disk is the failure mode that \
                takes a unit out of service on a shift.
                """,
                """
                Diagnostics are kept for fourteen days. Nobody has ever asked for an older \
                diagnostic and the shorter window keeps the upload aggregate small enough to \
                cross the satellite link without competing with the manifest queue.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Localisation",
            paragraphs: [
                """
                The interface ships in English and Portuguese for the beta. Two of the pilot \
                harbours operate in Portuguese, and running them in English would turn a usability \
                trial into a translation exercise with the results confounded.
                """,
                """
                Dates and numbers follow the harbour's locale rather than the account's, because \
                the person reading a manifest is standing in the harbour and not in the office \
                that opened the account. That distinction cost an afternoon to agree and is worth \
                writing down so it is not re-argued.
                """,
                """
                The conflict-resolution page is translated by a person, not by the string \
                pipeline. It is thirty seconds of a supervisor's attention at the worst moment of \
                their day and it has to read like something a human wrote.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Accessibility",
            paragraphs: [
                """
                The manifest list is the one surface people use all day and it is currently the \
                worst for contrast: grey on grey at the smallest supported text size. That is \
                fixed before the beta rather than after, because a pilot user who cannot read the \
                list will report everything else through that lens.
                """,
                """
                Every control on the pairing and conflict surfaces gets a label, and the two \
                icon-only buttons in the toolbar get text alternatives. The rest of the audit is \
                queued behind the beta.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Rollback plan",
            paragraphs: [
                """
                If offline sync has to be withdrawn mid-beta, the switch is per account and \
                turning it off leaves the queued mutations on the device rather than discarding \
                them. They replay when it is turned back on. Discarding was considered and \
                rejected: a withdrawal is already a bad day and losing a shift of work on top of \
                it is how a pilot becomes a former customer.
                """,
                """
                The rollback is rehearsed once before the beta opens, on the internal harbour, \
                with someone timing it. A plan nobody has executed is a paragraph, not a plan.
                """,
            ],
            bullets: [
                "Per-account switch, queued mutations preserved",
                "Rehearsed once on the internal harbour before the beta opens",
            ]),
        Topic(
            heading: "What the team is not doing",
            paragraphs: [
                """
                No multi-tenant harbour groups, no reporting module, no public interface. Each \
                came up and each was pushed past the beta, because the beta exists to answer one \
                question — does offline sync hold on a real harbour floor — and every feature \
                added to it makes the answer harder to read.
                """,
                """
                The reporting request in particular has three separate people asking for three \
                different reports, which is the clearest possible sign that nobody knows what the \
                report is yet.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Open questions",
            paragraphs: [
                """
                Whether the satellite harbour needs a different queue budget is unanswered and \
                needs a measurement rather than a discussion. Whether the conflict queue belongs \
                to the supervisor or to whoever is nearest is a product question the pilot should \
                settle by observation.
                """,
                """
                The last one is commercial rather than technical: whether a harbour that runs \
                entirely offline for a week is a customer the product wants, or an edge the \
                product should decline politely. Nobody had an answer and nobody pretended to.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Support tooling",
            paragraphs: [
                """
                Support needs to see a device's queue state without asking the operator to read \
                numbers off a screen over a bad phone line. The smallest version of that is a \
                diagnostic bundle the operator exports with two taps and sends by whatever \
                channel the harbour has, which is usually a messaging app rather than email.
                """,
                """
                The bundle carries counts and timings, never manifest content, for the same \
                confidentiality reason the aggregate upload does. That constraint was checked \
                with the two harbours under the clause rather than assumed, and both confirmed \
                counts are fine.
                """,
                """
                A support console that reads the bundle is explicitly out of scope. Support is \
                three engineers during the beta and they can read a text file.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Training the field team",
            paragraphs: [
                """
                The field team gets a half-day session in the week before the beta opens, run by \
                the people who wrote the sync path rather than by a slide deck. The session is \
                built around the three things that will actually go wrong: a device that will not \
                pair, a queue that will not drain, and a conflict nobody understands.
                """,
                """
                Each of those has a one-page card the team can carry. Cards, not a handbook \
                chapter, because a harbour floor is not a place where anyone opens a handbook.
                """,
                """
                The session is recorded once so a new field team member in week four does not \
                need it run again, and so the team can hear what questions came up.
                """,
            ],
            bullets: nil),
        Topic(
            heading: "Measuring success",
            paragraphs: [
                """
                The beta succeeds if three things hold: no harbour loses a manifest record, the \
                conflict queue drains within a shift at every site, and the field team stops \
                being the first line of support by week four. Anything else the trial produces is \
                information rather than a verdict.
                """,
                """
                Those three were written down in the meeting rather than after it, so the report \
                is written against them and not against whatever the data happens to make easy \
                to say. Everyone agreed that is the point of writing them down.
                """,
                """
                A fourth candidate — that pilot harbours choose to keep paying — was rejected as \
                a success measure for the beta, since pricing is unpublished and a free pilot \
                cannot answer it.
                """,
            ],
            bullets: [
                "No manifest record lost at any site",
                "Conflict queue drains within a shift",
                "Field team out of first-line support by week four",
            ]),
        Topic(
            heading: "Next check-in",
            paragraphs: [
                """
                The next review is in three weeks against the merge prototype and the timing \
                run on the four-thousand-record sample. If the prototype is not running by then \
                the conversation is about scope, not about schedule.
                """,
            ],
            bullets: nil),
    ]
}

/// A minimal valid multi-page PDF, so the stamp stage can be exercised without
/// WebKit.
func writeStubPDF(at url: URL, paper: PDFPaper, pages: Int) throws {
    var box = CGRect(origin: .zero, size: paper.pointSize)
    guard let consumer = CGDataConsumer(url: url as CFURL),
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    for _ in 0 ..< pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 100, y: 400, width: 50, height: 50))
        context.endPDFPage()
    }
    context.closePDF()
}
