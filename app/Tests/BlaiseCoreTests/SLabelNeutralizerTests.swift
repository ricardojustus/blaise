import Foundation
import Testing
@testable import BlaiseCore

// G13 AC1 (pure function): the emphasis-aware detector, the two-layer
// neutralize, and the test-only no-S-label payload invariant over a forward
// mint value. All test data is fictional (Vexatron Labs / Quoll Harbor;
// Dana Okonkwo) — no real names, partners, meeting IDs, or content.

// MARK: - The detector pin list (AC1)

@Suite struct SLabelDetectorTests {
    private func matches(_ text: String) -> [String] {
        SLabelNeutralizer.labelRanges(in: text).map { String(text[$0]) }
    }

    @Test func detectsEveryRequiredForm() {
        // MUST match (the AC1 pin list).
        #expect(matches("S0") == ["S0"])
        #expect(matches("**S0**") == ["S0"])
        #expect(matches("`S0`") == ["S0"])
        #expect(matches("- **S0:**") == ["S0"])
        #expect(matches("S0/S1") == ["S0", "S1"])
        #expect(matches("(S0)") == ["S0"])
        #expect(matches("S1:") == ["S1"])
        // The one genuine blind spot of a bare \bS\d+\b: underscore italics.
        #expect(matches("_S0_") == ["S0"])
        // Any digit count is still a label.
        #expect(matches("S1000") == ["S1000"])
    }

    @Test func rejectsNonLabels() {
        // Case-sensitive: a lowercase prose s0 is NOT a label.
        #expect(matches("s0").isEmpty)
        // Identifier-embedded forms are not labels.
        #expect(matches("S0Helper").isEmpty)
        #expect(matches("AS0").isEmpty)
        #expect(matches("S0x").isEmpty)
        // No digits → not a label.
        #expect(matches("S").isEmpty)
        #expect(matches("Sx").isEmpty)
    }

    @Test func containsLabelPredicate() {
        #expect(SLabelNeutralizer.containsLabel("owner is **S0**"))
        #expect(SLabelNeutralizer.containsLabel("note _S1_ said"))
        #expect(!SLabelNeutralizer.containsLabel("owner is Dana Okonkwo"))
        #expect(!SLabelNeutralizer.containsLabel("the season was great"))  // "Season" embeds no label
    }
}

// MARK: - The fictional S-label-bearing fixture (Vexatron / Quoll Harbor)

enum SLabelFixture {
    /// A partner-call note where one speaker resolves to a fictional name and
    /// another stays unresolved, with S-labels in EVERY field kind incl. an
    /// owner, an underscore-italic prose label, and a two-unknowns-distinct case.
    static func notes() -> NotesStructured {
        NotesStructured(
            title: "Quoll Harbor sync",
            summary: "S0 walked through the Vexatron Labs migration; _S1_ raised the timeline.",
            detailedNotes: "**S0** owns the rollout. S1 flagged a budget gap; S2 deferred to S1.",
            decisions: ["S0 ships the Quoll Harbor build by Friday"],
            actionItems: [
                ActionItem(owner: "S0", text: "send the Vexatron Labs contract"),
                ActionItem(owner: "S1", text: "review the timeline"),
            ],
            userActionItems: [
                ActionItem(owner: "S2", text: "confirm the budget line"),
            ])
    }

    /// Resolves S0 → Dana Okonkwo (a resolved speaker mapping / rename);
    /// S1 and S2 stay unresolved.
    static let labelMap: [String: String] = ["S0": "Dana Okonkwo"]

    /// Every notes-content string of a structured-notes value, owners included.
    static func allFields(_ n: NotesStructured) -> [String] {
        var fields: [String] = []
        if let title = n.title { fields.append(title) }
        fields.append(n.summary)
        fields.append(n.detailedNotes)
        fields.append(contentsOf: n.decisions)
        for item in n.actionItems { fields.append(item.owner); fields.append(item.text) }
        for item in n.userActionItems { fields.append(item.owner); fields.append(item.text) }
        return fields
    }
}

// MARK: - Layer 1 + Layer 2 (AC1)

@Suite struct SLabelNeutralizeTests {
    @Test func layer1ResolvedLabelBecomesTheName() {
        let (out, _) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "en")
        // S0 → Dana Okonkwo everywhere it appeared — prose AND owner.
        #expect(out.summary.contains("Dana Okonkwo walked through"))
        #expect(out.detailedNotes.contains("**Dana Okonkwo** owns the rollout"))
        #expect(out.decisions[0].contains("Dana Okonkwo ships"))
        #expect(out.actionItems[0].owner == "Dana Okonkwo")
        // No residual S0 anywhere.
        #expect(!SLabelNeutralizer.containsLabel(out.summary))
        #expect(!out.detailedNotes.contains("S0"))
    }

    @Test func layer2ResidualProseBecomesNeutralDescriptor() {
        let (out, _) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "en")
        // Unresolved S1/S2 are neutralized in prose — index-distinct so two
        // unknowns stay distinct. The descriptor is assigned by POSITION among
        // the distinct RESIDUAL labels (S0 is resolved, so S1 is the first
        // unknown → "a participant", S2 the second → "another participant").
        // The same label maps to the same descriptor across every field.
        // (The summary's S1 was underscore-italic `_S1_`, so the descriptor
        // lands inside the same emphasis run: `_a participant_`.)
        #expect(out.summary.contains("_a participant_ raised the timeline"))
        #expect(out.detailedNotes.contains("a participant flagged a budget gap"))
        #expect(out.detailedNotes.contains("another participant deferred to a participant"))
        // The underscore-italic _S1_ was caught (the blind-spot form).
        #expect(!out.summary.contains("S1"))
        // No label survives in ANY prose field.
        #expect(!SLabelNeutralizer.containsLabel(out.summary))
        #expect(!SLabelNeutralizer.containsLabel(out.detailedNotes))
        #expect(out.decisions.allSatisfy { !SLabelNeutralizer.containsLabel($0) })
    }

    @Test func layer2ResidualOwnerBecomesEmptyWithFlag() {
        let (out, residuals) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "en")
        // The S1 owner (action item) collapses to empty — the item keeps its
        // text; the residual is surfaced in the report.
        #expect(out.actionItems[1].owner.isEmpty)
        #expect(out.actionItems[1].text == "review the timeline")
        // The S2 user-action-item owner likewise.
        #expect(out.userActionItems[0].owner.isEmpty)
        #expect(out.userActionItems[0].text == "confirm the budget line")
        // The report names the field + the neutralized label, NEVER an identity.
        #expect(residuals.contains(SLabelNeutralizer.Residual(field: "action_items.owner", label: "S1")))
        #expect(residuals.contains(SLabelNeutralizer.Residual(field: "user_action_items.owner", label: "S2")))
        // No owner residual for the RESOLVED S0 owner.
        #expect(!residuals.contains { $0.label == "S0" })
    }

    @Test func neverInventsAnIdentity() {
        // The neutralizer surfaces ONLY "a participant" forms; it must not emit
        // any of the fixture's resolved name for an UNRESOLVED label, nor a role.
        let (out, _) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "en")
        // S1/S2 are unresolved → they never become "Dana Okonkwo".
        #expect(!out.userActionItems[0].owner.contains("Dana"))
        // The fully-neutralized notes carry no label on any surface.
        for field in SLabelFixture.allFields(out) {
            #expect(!SLabelNeutralizer.containsLabel(field))
        }
    }

    @Test func portugueseDescriptorsInPtNotes() {
        // S0 resolved, S1/S2 unknown → two Portuguese descriptors (first unknown
        // "um participante", second "outro participante").
        let (out, _) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "pt-BR")
        #expect(out.summary.contains("um participante"))
        #expect(out.detailedNotes.contains("outro participante"))
        #expect(!SLabelNeutralizer.containsLabel(out.detailedNotes))
    }

    @Test func threeDistinctUnknownsStayDistinct() {
        // With NOTHING resolved, S0/S1/S2 are three distinct unknowns → three
        // distinct descriptors, in label-index order.
        let (out, _) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: [:], language: "en")
        #expect(out.summary.hasPrefix("a participant walked"))           // S0
        #expect(out.summary.contains("_another participant_ raised"))     // S1 (underscore-italic)
        #expect(out.detailedNotes.contains("a third participant deferred to another participant")) // S2 → S1
        #expect(!SLabelNeutralizer.containsLabel(out.detailedNotes))
    }

    @Test func idempotent() {
        let once = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: SLabelFixture.labelMap, language: "en").notes
        let twice = SLabelNeutralizer.neutralize(
            notes: once, labelMap: SLabelFixture.labelMap, language: "en").notes
        #expect(once == twice)
    }

    @Test func emptyLabelMapStillNeutralizesEveryLabel() {
        // The engine-agnostic floor: with NOTHING resolved, every label is still
        // stripped (no name invented).
        let (out, residuals) = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: [:], language: "en")
        #expect(out.summary.contains("a participant walked through"))
        #expect(out.actionItems[0].owner.isEmpty)  // S0 owner now unresolved → empty
        #expect(residuals.contains { $0.label == "S0" && $0.field == "action_items.owner" })
        for field in SLabelFixture.allFields(out) {
            #expect(!SLabelNeutralizer.containsLabel(field))
        }
    }
}

// MARK: - The test-only payload invariant (AC1)

@Suite struct SLabelPayloadInvariantTests {
    private func makeMeeting() -> Meeting {
        Meeting(
            id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            title: "Quoll Harbor sync",
            startedAt: Date(timeIntervalSince1970: 1_770_000_000),
            endedAt: Date(timeIntervalSince1970: 1_770_000_300),
            source: .zoom,
            status: .ready,
            attendees: [Attendee(name: "Dana Okonkwo", email: nil, source: .manual)],
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_770_000_200))
    }

    private func makeNotes(_ structured: NotesStructured, markdown: String) -> MeetingNotes {
        MeetingNotes(
            meetingID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            markdown: markdown,
            structured: structured,
            language: "en",
            generatedAt: Date(timeIntervalSince1970: 1_770_000_250),
            provenance: NotesProvenance(
                engine: "mock", model: "mock", pipelineVersion: "1.0",
                runtime: "mock", rendererVersion: NotesRenderer.version,
                promptVersion: "test-v1",
                // A truthful audit entry that LEGITIMATELY records "S0" → name:
                // the invariant must NOT false-positive on it.
                nameSubstitutions: [NameSubstitution.ReportEntry(
                    field: "action_items.owner", original: "S0", replacement: "Dana Okonkwo", rule: 1)]))
    }

    /// Recursively collects every string under a JSON value (notes-content
    /// surfaces are scanned in full).
    private func collectStrings(_ value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let arr as [Any]: return arr.flatMap(collectStrings)
        case let obj as [String: Any]: return obj.values.flatMap(collectStrings)
        default: return []
        }
    }

    @Test func forwardMintCarriesNoLabelOnEitherNotesContentSurface() throws {
        // The forward mint: neutralize → render → build. The invariant is a
        // TEST-ONLY assertion over the minted payload, NOT a build() throw.
        let meeting = makeMeeting()
        let segments = [
            TranscriptSegment(
                meetingID: meeting.id, ord: 0, startSeconds: 0, endSeconds: 1,
                speakerLabel: "S0", speakerName: "Dana Okonkwo", text: "hello"),
            TranscriptSegment(
                meetingID: meeting.id, ord: 1, startSeconds: 1, endSeconds: 2,
                speakerLabel: "S1", speakerName: nil, text: "world"),
        ]
        let labelMap = ["S0": "Dana Okonkwo"]
        let neutralized = SLabelNeutralizer.neutralize(
            notes: SLabelFixture.notes(), labelMap: labelMap, language: "en").notes
        let markdown = try NotesRenderer.render(
            neutralized, language: "en", meetingTitle: meeting.title, userName: "")
        var notes = makeNotes(neutralized, markdown: markdown)
        notes.markdown = markdown
        let payload = EvidencePayloadBuilder.build(
            meeting: meeting, segments: segments, notes: notes,
            user: UserIdentity(name: "", aliases: [], email: ""))

        let json = try #require(
            try JSONSerialization.jsonObject(with: payload.bytes) as? [String: Any])

        // notes_structured — scan ALL fields incl. owners.
        let structured = try #require(json["notes_structured"] as? [String: Any])
        for s in collectStrings(structured) {
            #expect(!SLabelNeutralizer.containsLabel(s), "notes_structured leaked a label: \(s)")
        }
        // summary_markdown — the SECOND, MORE-exposed notes surface. Asserting
        // only notes_structured would pass a payload whose markdown leaked.
        let summaryMarkdown = try #require(json["summary_markdown"] as? String)
        #expect(!SLabelNeutralizer.containsLabel(summaryMarkdown))
        // summary_text.
        let summaryText = try #require(json["summary_text"] as? String)
        #expect(!SLabelNeutralizer.containsLabel(summaryText))

        // EXCLUDED surfaces still legitimately carry labels:
        //  (a) transcript[].diarization_label — S-labels are required there.
        let transcript = try #require(json["transcript"] as? [[String: Any]])
        let diarLabels = transcript.compactMap {
            ($0["speaker"] as? [String: Any])?["diarization_label"] as? String
        }
        #expect(diarLabels.contains("S0") && diarLabels.contains("S1"))
        //  (b) provenance.notes.name_substitutions — a truthful "S0" → name row.
        let provenance = try #require(json["provenance"] as? [String: Any])
        let notesProv = try #require(provenance["notes"] as? [String: Any])
        let subs = try #require(notesProv["name_substitutions"] as? [[String: Any]])
        #expect(subs.contains { $0["original"] as? String == "S0" })
    }
}

// MARK: - The grep-guard structural test (AC1)

@Suite struct SLabelGrepGuardTests {
    private static let pipelineSource: String = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 { url.deleteLastPathComponent() } // file → BlaiseCoreTests → Tests → app → repo
        url.appendPathComponent("app/Sources/BlaiseCore/ProcessingPipeline.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    /// No forward-path `NotesRenderer.render(` / `EvidencePayloadBuilder.build(`
    /// in ProcessingPipeline.swift may consume a `notes` surface that did not
    /// pass through a `SLabelNeutralizer` neutralize. Mechanically: scan in line
    /// order and require a neutralize-family call to precede every `render`/
    /// `build` site. A NEW forward flow that renders/builds from a non-neutralized
    /// surface fails THIS test — cleanliness does not rely on the new author
    /// voluntarily adding a per-site pin.
    ///
    /// G14: the neutralize family now includes `SLabelNeutralizer.neutralizeText`
    /// — the flat-string entry point that cleans the produced memory-DIGEST
    /// string. The digest-only resume's build (`digestOnlyBody`) is preceded by
    /// `generateMemoryDigest`'s `neutralizeText` (its own window's neutralize),
    /// so the build count is 5; the neutralize-family count is 8 — the digest
    /// path neutralizes the synthesis DRAFT, the md-v6 COMBINED-AUDIT output, AND
    /// (md-v5 rollback branch) the verify/repair output + the notes-RECONCILED
    /// output (FOUR `neutralizeText` calls present in `generateMemoryDigest`: the
    /// md-v6 path runs synth→combined-audit, the md-v5 path runs
    /// synth→verify→reconcile, and both branches' neutralizes live in the source
    /// the grep counts); renders stay 4 (the digest resume re-mints WITHOUT
    /// re-rendering the notes markdown).
    @Test func everyForwardRenderAndBuildFollowsANeutralize() {
        let source = Self.pipelineSource
        #expect(!source.isEmpty, "could not read ProcessingPipeline.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        func indices(of needle: String) -> [Int] {
            lines.enumerated().filter { $0.element.contains(needle) }.map(\.offset)
        }
        let renderSites = indices(of: "NotesRenderer.render(").sorted()
        let buildSites = indices(of: "EvidencePayloadBuilder.build(").sorted()
        // Neutralize FAMILY: the struct-shaped notes neutralizer AND the G14
        // flat-string digest neutralizer. Either cleans the surface its window's
        // render/build then consumes.
        let neutralizeSites = (
            indices(of: "SLabelNeutralizer.neutralize(")
            + indices(of: "SLabelNeutralizer.neutralizeText(")
        ).sorted()

        // The forward mint seams: title rename, speaker rename, notes-correction,
        // finalize, AND the G14 digest-only resume (build only — it does not
        // re-render the notes markdown). Pinning the counts is load-bearing: a
        // NEW unguarded forward flow shifts a count and fails here.
        #expect(renderSites.count == 4, "expected 4 forward render sites, found \(renderSites.count)")
        #expect(buildSites.count == 5, "expected 5 forward build sites, found \(buildSites.count)")
        #expect(neutralizeSites.count == 8, "expected 8 neutralize-family calls, found \(neutralizeSites.count)")

        // Mint-window discipline: pair the neutralize-family sites to the render
        // and build sites in line order; each render and each build must follow
        // its paired window's neutralize.
        for (i, render) in renderSites.enumerated() {
            #expect(
                neutralizeSites[i] < render,
                "forward render at line \(render + 1) is not preceded by a neutralize")
        }
        for (i, build) in buildSites.enumerated() {
            #expect(
                neutralizeSites[i] < build,
                "forward build at line \(build + 1) is not preceded by a neutralize")
        }
    }
}
