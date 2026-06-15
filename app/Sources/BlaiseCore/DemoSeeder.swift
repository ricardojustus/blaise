import Foundation

// C10 debug seed command (screenshot evidence + manual exploration):
// loads 12 mock meetings into a fresh DB for visual density. Invoked via
// `Blaise --seed-demo` (BlaiseApp) against a throwaway data root; never part
// of normal operation. Mock content is wholly invented — a fictional studio
// universe (Vexatron Labs / Quoll Harbor) with fictional people, products,
// and partners; no narrative attaches to any real person or company.
public enum DemoSeeder {
    public struct Summary: Sendable {
        public let meetingCount: Int
        public let segmentCount: Int
    }

    @discardableResult
    public static func seed(
        database: BlaiseDatabase, now: Date = Date()
    ) async throws -> Summary {
        let meetings = MeetingRepository(database: database)
        let transcripts = TranscriptRepository(database: database)
        let notesRepository = NotesRepository(database: database)
        let calendar = Calendar.current

        func date(daysAgo: Int, hour: Int, minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }

        // Twelve mock meetings (invented; C9 prototype dataset).
        var segmentCount = 0
        var readyMeetingIDs: [(id: MeetingID, started: Date)] = []
        for mock in Self.mockMeetings {
            let id = ULID.generate()
            let started = date(daysAgo: mock.daysAgo, hour: mock.hour, minute: mock.minute)
            let meeting = Meeting(
                id: id,
                title: mock.title,
                startedAt: started,
                endedAt: started.addingTimeInterval(Double(mock.durationMinutes) * 60),
                source: mock.source,
                status: mock.status,
                attendees: mock.attendees.map { Attendee(name: $0, source: .manual) },
                dominantLanguage: mock.language,
                asrProvenance: mock.status == .ready
                    ? ASRProvenance(
                        engine: "mlx-whisper-large-v3-turbo",
                        model: "mlx-community/whisper-large-v3-turbo",
                        runtime: "mlx-whisper/subprocess",
                        engineVersion: "0.4.3",
                        transcribedAt: started.addingTimeInterval(3600))
                    : nil,
                lastProcessingError: mock.lastProcessingError,
                createdAt: started,
                updatedAt: started.addingTimeInterval(3600))
            try await meetings.create(meeting)
            guard mock.status == .ready else { continue }
            readyMeetingIDs.append((id, started))
            if !mock.transcript.isEmpty {
                try await transcripts.replaceAllSegments(
                    meetingID: id,
                    with: mock.transcript.enumerated().map { index, line in
                        TranscriptSegment(
                            meetingID: id, ord: index, startSeconds: Double(index) * 12,
                            endSeconds: Double(index) * 12 + 10, speakerLabel: "S\(index % 3)",
                            speakerName: line.speaker, text: line.text)
                    })
                segmentCount += mock.transcript.count
            }
            let structured = NotesStructured(
                title: mock.title,
                summary: mock.summary,
                detailedNotes: mock.detailedNotes,
                decisions: mock.decisions,
                actionItems: mock.actionItems.map { ActionItem(owner: $0.owner, text: $0.text) },
                userActionItems: mock.userActions.map { ActionItem(owner: "Demo User", text: $0) })
            let provenance = NotesProvenance(
                engine: "claude-sonnet", model: "claude-sonnet-4-5", pipelineVersion: "1.0",
                runtime: "anthropic-api", rendererVersion: NotesRenderer.version, promptVersion: "c6-v1")
            let markdown =
                (try? NotesRenderer.render(
                    structured, language: mock.language, meetingTitle: mock.title,
                    userName: "Demo User"))
                ?? mock.summary
            try await notesRepository.upsert(
                MeetingNotes(
                    meetingID: id, markdown: markdown, structured: structured,
                    language: mock.language, generatedAt: started.addingTimeInterval(3600),
                    provenance: provenance))
        }

        // 3. G7 cloud-spend receipts for THIS month — the Settings → Cloud
        // Spend panel evidence. A few generation receipts on real seeded
        // meetings, one regeneration, plus a pre-receipts accumulator surplus
        // so the reconciliation line shows its "before receipts existed"
        // labeling honestly.
        try await seedDemoReceipts(database: database, readyMeetings: readyMeetingIDs, now: now)

        return Summary(
            meetingCount: Self.mockMeetings.count,
            segmentCount: segmentCount)
    }

    /// Inserts fixture receipts + a deliberately larger accumulator (the
    /// pre-receipts history) for the current month, so the Cloud Spend panel
    /// renders a populated table, per-purpose subtotals, and a non-trivial
    /// reconciliation line. Demo-only.
    private static func seedDemoReceipts(
        database: BlaiseDatabase, readyMeetings: [(id: MeetingID, started: Date)], now: Date
    ) async throws {
        let monthKey = CloudSpendLedger.monthKey(for: now)
        // (purpose, input, output, cost, meetingIndex?) — a believable month.
        let rows: [(CloudSpendPurpose, Int, Int, Double, Int?)] = [
            (.generation, 41_000, 1_900, 0.1515, 0),
            (.generation, 28_500, 1_400, 0.1065, 1),
            (.generation, 33_200, 1_650, 0.1243, 2),
            (.regeneration, 30_100, 1_500, 0.1128, 0),
            (.validation, 5_000, 300, 0.0195, nil),
        ]
        let receiptsSum = rows.reduce(0.0) { $0 + $1.3 }
        try await database.pool.write { db in
            for (index, row) in rows.enumerated() {
                let (purpose, input, output, cost, meetingIndex) = row
                let meetingID = meetingIndex.flatMap {
                    $0 < readyMeetings.count ? readyMeetings[$0].id : nil
                }
                // Spread timestamps across recent days of the current month.
                let timestamp = now.addingTimeInterval(-Double(index) * 7_200)
                try db.execute(
                    sql: """
                        INSERT INTO cloud_spend_receipt
                            (id, timestamp, month_key, engine_id, model, purpose,
                             meeting_id, input_tokens, output_tokens, cost_usd, note)
                        VALUES (?, ?, ?, 'claude-sonnet', 'claude-sonnet-4-6', ?, ?, ?, ?, ?, NULL)
                        """,
                    arguments: [
                        ULID.generate(), timestamp, monthKey, purpose.rawValue,
                        meetingID, input, output, cost,
                    ])
            }
            // The accumulator is LARGER than the receipts sum — the surplus is
            // pre-receipts spend (the permanent initial reconciliation delta).
            let accumulator = receiptsSum + 0.49
            try db.execute(
                sql: """
                    INSERT INTO cloud_spend (month_key, accumulated_usd) VALUES (?, ?)
                    ON CONFLICT(month_key) DO UPDATE SET accumulated_usd = excluded.accumulated_usd
                    """,
                arguments: [monthKey, accumulator])
        }
    }

    // MARK: - Mock dataset (wholly invented — a fictional studio universe;
    // all people, products, and partner companies are fictional)

    struct MockLine {
        let speaker: String
        let text: String
    }

    struct Mock {
        let title: String
        let daysAgo: Int
        let hour: Int
        var minute: Int = 0
        let durationMinutes: Int
        let attendees: [String]
        let language: String
        var source: MeetingSource = .meet
        var status: MeetingStatus = .ready
        var lastProcessingError: String?
        let summary: String
        var detailedNotes: String = ""
        var decisions: [String] = []
        var actionItems: [(owner: String, text: String)] = []
        var userActions: [String] = []
        var transcript: [MockLine] = []
    }

    static let mockMeetings: [Mock] = [
        Mock(
            title: "Aurora Drift — post-launch sync",
            daysAgo: 0, hour: 10, durationMinutes: 45,
            attendees: ["Demo User", "Paula Costa", "Marcos Lima", "Sofia Almeida"], language: "en",
            summary:
                "Patch 1.4 ships Thursday with the stealth-AI fixes. NovaDeck review velocity is healthy; the OrbitVR port plan needs a staffing answer before the Lumen check-in.",
            detailedNotes: """
                **Patch 1.4**

                - Stealth-AI detection cone fix verified by QA on NovaDeck.
                - Paula Costa: crash-free sessions at 99.4% on the release candidate.
                - Marcos Lima wants the new takedown animation held for 1.5 — polish, not blocker.

                **OrbitVR port**

                - Engine branch is ready; the open question is who leads the port team.
                - Sofia Almeida: creative review can be light-touch, the content is locked.
                """,
            decisions: [
                "Patch 1.4 locked for Thursday; no new scope after code freeze on Wednesday.",
                "OrbitVR port staffing proposal goes to Carlos Mendes before the Lumen call.",
            ],
            actionItems: [
                (owner: "Paula Costa", text: "Send the release-candidate crash report to the leads."),
                (owner: "Marcos Lima", text: "File the takedown animation for the 1.5 cycle."),
            ],
            userActions: [
                "Confirm OrbitVR staffing with Carlos Mendes by Friday.",
                "Reply to Lumen on the marketing beat for patch 1.4.",
            ],
            transcript: [
                MockLine(speaker: "Paula Costa", text: "Crash-free sessions are at ninety-nine point four on the release candidate, so patch one point four is good for Thursday."),
                MockLine(speaker: "Demo User", text: "Then let's lock it. No new scope after the code freeze on Wednesday."),
                MockLine(speaker: "Marcos Lima", text: "The new takedown animation still needs polish — I'd hold it for one point five."),
                MockLine(speaker: "Sofia Almeida", text: "Creative review on the OrbitVR port can be light-touch, the content is locked."),
            ]),
        Mock(
            title: "Reunião de heads — semanal",
            daysAgo: 1, hour: 9, durationMinutes: 60,
            attendees: ["Demo User", "Carlos Mendes", "Beatriz Ramos", "Julia Castro", "Daniel Nunes"], language: "pt",
            summary:
                "Pipeline de produção segue no plano. Contratação do tech lead de MR avançou para a fase final; decisão de headcount do Q3 ficou para a próxima semana com dados do Renato.",
            detailedNotes: """
                **Produção**

                - Carlos Mendes: todos os marcos do mês entregues; Vexatron com folga de uma semana.
                - Beatriz Ramos levantou risco de dependência do pipeline de build no time de Aurora Drift.

                **Pessoas**

                - Candidato final de tech lead MR: referências fortes, espera resposta até sexta.
                - Daniel Nunes apresentou o draft do plano de headcount do Q3 — R$ 480.000,00/mês no cenário base.
                """,
            decisions: [
                "Headcount do Q3 só fecha depois do fechamento mensal de finanças.",
                "Julia Castro conduz a oferta para o candidato de tech lead MR ainda esta semana.",
            ],
            actionItems: [
                (owner: "Julia Castro", text: "Conduzir a oferta do tech lead MR."),
                (owner: "Daniel Nunes", text: "Revisar o plano de headcount com os dados do Renato."),
            ],
            userActions: [
                "Revisar a proposta de headcount do Daniel Nunes antes de quinta.",
                "Dar retorno à Julia Castro sobre a faixa salarial do tech lead MR.",
            ],
            transcript: [
                MockLine(speaker: "Carlos Mendes", text: "Todos os marcos do mês foram entregues, Vexatron está com uma semana de folga no cronograma."),
                MockLine(speaker: "Beatriz Ramos", text: "Tem um risco de dependência do pipeline de build no time de Aurora Drift que eu quero mapear."),
                MockLine(speaker: "Demo User", text: "O headcount do Q3 só fecha depois do fechamento mensal, combinado?"),
            ]),
        Mock(
            title: "Nimbus partner sync — NovaDeck roadmap",
            daysAgo: 1, hour: 14, durationMinutes: 30,
            attendees: ["Demo User", "Sam Taylor", "Pedro Rocha"], language: "en",
            summary:
                "Nimbus confirmed the NovaDeck store featuring slot for Vexatron's season update. Sam flagged an MR content investment window opening in Q3 worth preparing a pitch for.",
            detailedNotes: """
                - Vexatron season update featured the week of 29/06 on the NovaDeck store; assets due ten days before the slot.
                - Sam: the MR budget envelope is mid-six-figures US$, decisions in early Q3.
                """,
            decisions: ["Vexatron Labs will prepare an MR concept one-pager for the Q3 investment window."],
            actionItems: [(owner: "Pedro Rocha", text: "Keep the relationship warm with the content strategy team.")],
            userActions: [
                "Send Sam the Vexatron season-update trailer by 19/06.",
                "Brief Clara Souza's New Ventures team on the MR pitch window.",
            ]),
        Mock(
            title: "1:1 Daniel Nunes — planejamento estratégico",
            daysAgo: 2, hour: 11, durationMinutes: 45,
            attendees: ["Demo User", "Daniel Nunes"], language: "pt",
            summary:
                "Revisão do modelo de portfólio 2027: o cenário multi-plataforma depende de duas apostas fora de VR. Daniel Nunes traz a versão revisada com sensibilidade de receita na sexta.",
            detailedNotes: """
                - Cenário base: 60% da receita ainda em NovaDeck; meta é cair para 45% até 2028.
                - Daniel Nunes: spatial cinema precisa de um case âncora antes de virar linha de negócio.
                """,
            decisions: ["O modelo de portfólio passa a separar VR, mobile e spatial cinema em linhas próprias."],
            userActions: ["Mandar para o Daniel Nunes os números de wishlist do Tidewatch."]),
        Mock(
            title: "Vexatron live ops weekly",
            daysAgo: 3, hour: 15, durationMinutes: 30,
            attendees: ["Demo User", "Maria Silva", "Felipe Torres"], language: "en",
            summary:
                "Season 4 retention is up 11% week over week. The new arena ships with the season update; monetization experiment on cosmetic bundles starts Monday.",
            detailedNotes: """
                - D7 retention 24% (+11% WoW); concurrents peak at 19:00 BRT.
                - New arena 'Rooftop Garden' locked; trailer cut by Thursday.
                """,
            decisions: ["Cosmetic bundle A/B test runs two weeks before any pricing change."],
            userActions: ["Approve the season 4 key art for the Nimbus featuring slot."]),
        Mock(
            title: "Tidewatch — prototype review",
            daysAgo: 4, hour: 10, durationMinutes: 60,
            attendees: ["Demo User", "Maria Silva", "Clara Souza", "Sofia Almeida"], language: "en",
            summary:
                "The co-op diving prototype is approved to move to production with one cut: the third biome moves to a stretch goal. Target platforms stay PC-first with console evaluation after the prototype.",
            detailedNotes: """
                - Maria: the two-player tether mechanic is what makes the exploration loop sing.
                - Sofia Almeida: the bioluminescent lighting must hold up at depth — art test first.
                """,
            decisions: [
                "Prototype covers two biomes, not three; the third is stretch.",
                "PC-first; console decision deferred until the prototype review.",
            ],
            userActions: [
                "Align with Renato on the prototype budget — R$ 1.200.000,00 ceiling.",
                "Set the prototype review date with Clara Souza (target: semana de 20/07).",
            ]),
        Mock(
            title: "Fechamento mensal — finanças",
            daysAgo: 7, hour: 9, minute: 30, durationMinutes: 45,
            attendees: ["Demo User", "Renato Dias", "Sergio Prado"], language: "pt",
            summary:
                "Maio fechou 4% abaixo do orçado em despesas; receita em linha. Caixa cobre 14 meses no ritmo atual. Renato recomenda travar o câmbio dos recebíveis de junho.",
            detailedNotes: """
                - Despesas: R$ 2.870.000,00 (orçado R$ 2.990.000,00); variação concentrada em outsourcing.
                - Runway de 14 meses sem novas receitas de publishing.
                """,
            decisions: ["Travar câmbio de 70% dos recebíveis em US$ de junho."],
            userActions: ["Assinar a instrução de hedge até quarta-feira."]),
        Mock(
            title: "Lumen check-in — OrbitVR port",
            daysAgo: 8, hour: 16, durationMinutes: 30,
            attendees: ["Demo User", "Paula Costa"], language: "en",
            summary:
                "Lumen confirmed interest in a Q4 OrbitVR launch window. They want a port schedule and cert plan within two weeks; marketing wants alignment with the show's next season.",
            detailedNotes: """
                - Paula Costa: core port is 10–12 weeks once staffed; cert adds 4.
                - Foveated rendering pass is the main OrbitVR-specific work item.
                """,
            decisions: ["Target OrbitVR launch window: Q4 2026, aligned with the show's season marketing."],
            userActions: ["Deliver port schedule + cert plan to Lumen by 24/06."]),
        Mock(
            title: "Tech all-hands — engine strategy",
            daysAgo: 10, hour: 14, durationMinutes: 60,
            attendees: ["Demo User", "Beatriz Ramos", "João Pereira"], language: "pt",
            summary:
                "Beatriz Ramos apresentou a estratégia de engine para 2027: Forge continua como base, com uma trilha de avaliação de ferramentas de IA no pipeline de conteúdo. Sem migração de engine no horizonte.",
            detailedNotes: """
                - Custo de migração estimado em 9 meses de produtividade — não se paga.
                - João: ferramentas de IA generativa no pipeline de assets mostram ganho real em prototipagem.
                """,
            decisions: [
                "Forge permanece engine padrão até pelo menos o fim de 2027.",
                "Trilha de avaliação de IA no pipeline ganha um eng dedicado por um quarter.",
            ],
            userActions: ["Comunicar a decisão de engine no próximo all-hands geral."]),
        Mock(
            title: "Quoll Harbor Café — live ops monthly",
            daysAgo: 14, hour: 11, durationMinutes: 30,
            attendees: ["Demo User", "Tiago Pinto", "Jordan Hayes"], language: "en",
            summary:
                "Nimbus Worlds traffic to Quoll Harbor Café grew 8% after the events feature. Nimbus wants a holiday-themed update; Tiago Pinto's team can deliver it within the current envelope.",
            detailedNotes: """
                - MAU up 8% MoM; session length flat.
                - Jordan: featuring on the Worlds hub renewed through August.
                """,
            decisions: ["Holiday update confirmed for December within the existing budget."],
            userActions: ["Sign off the holiday update one-pager when Tiago Pinto sends it."]),
        Mock(
            title: "Imported: bootcamp retro (audio)",
            daysAgo: 5, hour: 17, durationMinutes: 40,
            attendees: ["Demo User", "Marcos Lima", "Vitor Faria"], language: "pt",
            source: .imported, status: .processing,
            summary: ""),
        Mock(
            title: "1:1 Sofia Almeida — pipeline criativo",
            daysAgo: 6, hour: 17, durationMinutes: 45,
            attendees: ["Demo User", "Sofia Almeida"], language: "pt",
            status: .failed,
            lastProcessingError: "asr: engine 'mlx-whisper-large-v3-turbo' unavailable: python venv not provisioned",
            summary: ""),
    ]
}
