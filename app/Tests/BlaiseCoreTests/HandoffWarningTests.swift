import Foundation
import Synchronization
import Testing
@testable import BlaiseCore

// Handoff persistent-failure warning (owner directive refining hard floor
// 8): the pure threshold, the episode policy in the status holder, and the
// worker-side snapshot/retry-now behavior.

// MARK: - Pure threshold

@Suite struct HandoffWarningThresholdTests {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    func makeItem(
        seq: Int64, meeting: MeetingID = "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        state: HandoffState = .failed, attempts: Int = 0, error: String? = nil,
        age: TimeInterval = 60, lastAttemptAge: TimeInterval? = nil
    ) -> HandoffItem {
        HandoffItem(
            id: "item-\(seq)", meetingID: meeting, payloadPath: "p", versionHash: "h",
            state: state, attempts: attempts, createdSeq: seq,
            createdAt: now.addingTimeInterval(-age),
            lastAttemptAt: lastAttemptAge.map { now.addingTimeInterval(-$0) },
            lastError: error)
    }

    func evaluate(_ items: [HandoffItem], configurationInvalid: Bool = false) -> HandoffWarning? {
        HandoffWarningThreshold.evaluate(
            items: items, configurationInvalid: configurationInvalid, now: now)
    }

    @Test func emptyQueueNeverWarns() {
        #expect(evaluate([]) == nil)
        #expect(evaluate([], configurationInvalid: true) == nil)
    }

    @Test func freshTransientFailuresStaySilentRegardlessOfAttempts() {
        // The hard-floor reading: the remote host offline must never nag. Even many
        // attempts with transient-shaped errors stay silent under the hour.
        let item = makeItem(seq: 1, attempts: 22, error: "transient: exit=timeout ", age: 30 * 60)
        #expect(evaluate([item]) == nil)
        let hostDown = makeItem(seq: 2, state: .pending, attempts: 0, age: 30 * 60)
        #expect(evaluate([hostDown]) == nil)
    }

    @Test func authShapeWarnsAtThreeAttemptsNotBefore() {
        let error = "auth: exit=255 Permission denied (publickey)."
        #expect(evaluate([makeItem(seq: 1, attempts: 2, error: error)]) == nil)
        let warning = evaluate([makeItem(seq: 1, attempts: 3, error: error)])
        #expect(warning != nil)
        #expect(warning?.shortReason == "SSH key rejected")
    }

    @Test func hostKeyAndDamagedShapesArePersistent() {
        let hostKey = makeItem(seq: 1, attempts: 3, error: "hostKeyMismatch: exit=255 Host key verification failed.")
        #expect(evaluate([hostKey])?.shortReason == "host key changed")
        let damaged = makeItem(seq: 1, attempts: 3, error: HandoffErrorClass.damaged("bytes do not match"))
        #expect(evaluate([damaged])?.shortReason == "payload damaged")
        // Persistent-shape classifier directly.
        #expect(HandoffWarningThreshold.isPersistentShaped("auth: exit=255 x"))
        #expect(HandoffWarningThreshold.isPersistentShaped("hostKeyMismatch: exit=255 x"))
        #expect(HandoffWarningThreshold.isPersistentShaped("damaged: planted"))
        #expect(!HandoffWarningThreshold.isPersistentShaped("hostTransient: exit=255 refused"))
        #expect(!HandoffWarningThreshold.isPersistentShaped("transient: exit=timeout"))
        #expect(!HandoffWarningThreshold.isPersistentShaped(nil))
    }

    @Test func oldQueueWarnsRegardlessOfErrorShape() {
        // The ~1 h staleness rule: hours of silent retrying is persistent by
        // definition, whatever the error looks like (or none at all).
        let stale = makeItem(seq: 1, state: .pending, attempts: 0, age: 61 * 60)
        let warning = evaluate([stale])
        #expect(warning != nil)
        #expect(warning?.shortReason == "remote destination unreachable")  // no error recorded
        #expect(warning?.since == stale.createdAt)
        // Oldest drives staleness even when newer items are fresh.
        let fresh = makeItem(seq: 2, attempts: 1, error: "transient: exit=65 ", age: 120)
        #expect(evaluate([stale, fresh]) != nil)
    }

    @Test func configurationInvalidWarnsWithUndeliveredItems() {
        // Settings-validation pause: attempts never grow under it, so it is
        // persistent-shaped on its own (cannot self-heal without the user).
        let item = makeItem(seq: 1, state: .pending, age: 120)
        let warning = evaluate([item], configurationInvalid: true)
        #expect(warning != nil)
        #expect(warning?.shortReason == "handoff settings invalid")
    }

    @Test func deliveredAndSupersededRowsAreIgnored() {
        let delivered = makeItem(seq: 1, attempts: 9, error: "auth: exit=255 x", age: 90 * 60)
        var deliveredRow = delivered
        deliveredRow.state = .delivered
        let superseded = makeItem(
            seq: 2, attempts: 9, error: HandoffErrorClass.superseded(byNewerHash: "ff"), age: 90 * 60)
        #expect(evaluate([deliveredRow, superseded]) == nil)
    }

    @Test func episodeKeyStableAcrossAttemptsOnTheSameFailure() {
        let third = evaluate([makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x", lastAttemptAge: 600)])
        let fourth = evaluate([makeItem(seq: 1, attempts: 4, error: "auth: exit=255 x", lastAttemptAge: 60)])
        #expect(third?.episodeKey != nil)
        #expect(third?.episodeKey == fourth?.episodeKey)  // never re-arms per attempt
    }

    @Test func episodeKeyChangesOnDistinctErrorClass() {
        let auth = evaluate([makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x")])
        let hostKey = evaluate([makeItem(seq: 1, attempts: 3, error: "hostKeyMismatch: exit=255 y")])
        #expect(auth?.episodeKey != hostKey?.episodeKey)
    }

    @Test func episodeKeyChangesWhenANewItemArrives() {
        let one = makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x", lastAttemptAge: 60)
        let before = evaluate([one])
        let newItem = makeItem(seq: 2, meeting: "01BX5ZZKBKACTAV9WEVGEMMVRZ", state: .pending, age: 5)
        let after = evaluate([one, newItem])
        #expect(before?.episodeKey != after?.episodeKey)
    }

    @Test func sinceIsOldestEnqueueAndMeetingsCountDistinct() {
        // Two queued versions of ONE meeting + one other meeting = 2 waiting.
        let v1 = makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x", age: 50 * 60, lastAttemptAge: 60)
        let v2 = makeItem(seq: 2, state: .pending, age: 10 * 60)
        let other = makeItem(seq: 3, meeting: "01BX5ZZKBKACTAV9WEVGEMMVRZ", state: .pending, age: 5 * 60)
        let warning = evaluate([v1, v2, other])
        #expect(warning?.meetingsWaiting == 2)
        #expect(warning?.since == v1.createdAt)
    }

    @Test func latestErrorWinsTheShortReason() {
        let older = makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x", lastAttemptAge: 3_000)
        let newer = makeItem(
            seq: 2, meeting: "01BX5ZZKBKACTAV9WEVGEMMVRZ", attempts: 1,
            error: "remoteDisk: exit=1 No space left on device", lastAttemptAge: 30)
        #expect(evaluate([older, newer])?.shortReason == "remote destination disk full")
    }

    /// M-3: the disk-full and unreachable reasons derive from the DESTINATION
    /// kind, recognised by the local transport's stderr signature. A local
    /// folder must never read "the remote host"; an SSH install must never read
    /// "destination". Both renderings of both errors are pinned here.
    @Test func shortReasonNamesTheDestinationKind() {
        // Disk full.
        #expect(
            HandoffWarningThreshold.shortReason(
                latestError: "remoteDisk: exit=local local destination: No space left on device",
                configurationInvalid: false) == "destination disk full")
        #expect(
            HandoffWarningThreshold.shortReason(
                latestError: "remoteDisk: exit=1 No space left on device",
                configurationInvalid: false) == "remote destination disk full")
        // Unreachable / unavailable.
        #expect(
            HandoffWarningThreshold.shortReason(
                latestError: "transient: exit=local local folder error: NSCocoaErrorDomain#4 ...",
                configurationInvalid: false) == "destination folder unavailable")
        #expect(
            HandoffWarningThreshold.shortReason(
                latestError: "transient: exit=local local destination folder is missing or unavailable",
                configurationInvalid: false) == "destination folder unavailable")
        // SSH transient with no recorded error stays the remote host-framed.
        #expect(
            HandoffWarningThreshold.shortReason(latestError: nil, configurationInvalid: false)
                == "remote destination unreachable")
    }

    @Test func damagedRowIsPersistentImmediatelyWithoutAttemptsOrHour() {
        // M-2: a damaged payload NEVER self-heals; quarantine precedes the
        // delivering claim so attempts stay 0 — it must warn immediately, not
        // wait three attempts or one hour.
        let damaged = makeItem(
            seq: 1, attempts: 0, error: HandoffErrorClass.damaged("bytes do not match"), age: 60)
        let warning = evaluate([damaged])
        #expect(warning != nil)
        #expect(warning?.shortReason == "payload damaged")
    }

    @Test func episodeStaysArmedAcrossErrorClassDowngradeUntilDelivery() {
        // M-1 flap sequence: auth ×3 arms → a later TRANSIENT attempt on the
        // SAME undelivered row must NOT clear the warning (no delivery has
        // succeeded); the episode key is held stable so no fresh notification
        // mints. Clearing happens only when the armed row drains.
        let armed = evaluate([makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x")])
        let active = try! #require(armed)
        #expect(active.armedSeqs == [1])

        // The next attempt fails as transient (class downgrade, < 1 h): under
        // a memoryless threshold this would clear → re-arm flap. With episode
        // memory it STAYS warned with the SAME episode key.
        let downgraded = evaluate(
            [makeItem(seq: 1, attempts: 4, error: "transient: exit=timeout", age: 30 * 60)],
            previous: active)
        #expect(downgraded != nil)
        #expect(downgraded?.episodeKey == active.episodeKey)  // no re-arm, no repeat notification

        // Delivery succeeds → the armed row leaves the undelivered set → the
        // warning clears silently (nil), exactly the contract.
        let delivered = evaluate([], previous: downgraded)
        #expect(delivered == nil)
    }

    @Test func newEligibleRowReArmsTheEpisodeAndChangesTheKey() {
        // Round-2 M-1 (auditor probe P6): a NEW persistent failure must NOT be
        // masked behind an armed (and possibly dismissed) episode. A transient
        // episode armed stale over row 1 → a new row 2 failing auth ×3 RE-ARMS:
        // the key CHANGES (so the holder re-notifies + un-dismisses) and the
        // armed set unions in the newcomer.
        let staleRow1 = makeItem(
            seq: 1, state: .pending, attempts: 0, error: "transient: exit=timeout",
            age: 61 * 60, lastAttemptAge: 61 * 60)
        let armed = try! #require(evaluate([staleRow1]))
        #expect(armed.episodeKey == "transient|1")
        #expect(armed.armedSeqs == [1])

        // Row 2 fails auth ×3 while row 1 is still undelivered (stale). The
        // OLD code carried "transient|1" forever; the new code re-arms.
        let authRow2 = makeItem(
            seq: 2, meeting: "01BX5ZZKBKACTAV9WEVGEMMVRZ", attempts: 3,
            error: "auth: exit=255 Permission denied (publickey).", age: 5 * 60, lastAttemptAge: 30)
        let reArmed = try! #require(evaluate([staleRow1, authRow2], previous: armed))
        #expect(reArmed.episodeKey == "auth|2")           // key CHANGED → re-notify + un-dismiss
        #expect(reArmed.episodeKey != armed.episodeKey)
        #expect(reArmed.armedSeqs == [1, 2])              // union, not the old singleton

        // Drain everything → silent clear.
        #expect(evaluate([], previous: reArmed) == nil)
    }

    @Test func classEscalationOnTheArmedRowReArms() {
        // The FIFO-realistic shape: the armed row itself escalates from a
        // transient (silent-eligible only via staleness) to auth — that is a
        // newly persistent-eligible row, so it re-arms with a new key.
        let stale = makeItem(
            seq: 1, state: .pending, attempts: 0, error: "transient: exit=timeout",
            age: 61 * 60, lastAttemptAge: 61 * 60)
        let armed = try! #require(evaluate([stale]))
        #expect(armed.episodeKey == "transient|1")
        let escalated = makeItem(
            seq: 1, attempts: 3, error: "auth: exit=255 x", age: 61 * 60, lastAttemptAge: 30)
        let reArmed = try! #require(evaluate([escalated], previous: armed))
        #expect(reArmed.episodeKey == "auth|1")
        #expect(reArmed.episodeKey != armed.episodeKey)
    }

    @Test func freshTransientRowDoesNotReArmOrHoldAfterArmedSetDrains() {
        // Pinning gap 1 (`stickyActive = previous != nil` mutant): the warning
        // must clear on ARMED-SET DRAIN, not previous-existence. The armed row
        // delivers while an unrelated FRESH transient row (not eligible) sits
        // in the queue → the episode CLEARS (the fresh row is silent, it never
        // joined the armed set and never re-arms).
        let armedRow = makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x", lastAttemptAge: 60)
        let armed = try! #require(evaluate([armedRow]))
        #expect(armed.armedSeqs == [1])

        // Row 1 delivered (gone from undelivered); a fresh transient row 2 (5 s
        // old, 1 attempt) remains. previous still non-nil — the mutant would
        // keep warning. Correct semantics: armed set drained → nil.
        let freshTransient = makeItem(
            seq: 2, meeting: "01BX5ZZKBKACTAV9WEVGEMMVRZ", state: .pending,
            attempts: 1, error: "transient: exit=65 ", age: 5)
        #expect(evaluate([freshTransient], previous: armed) == nil)
    }

    @Test func stickyEpisodeClearsWhenArmedRowIsSuperseded() {
        // The armed set drains by SUPERSESSION too, not just delivery.
        let armed = evaluate([makeItem(seq: 1, attempts: 3, error: "auth: exit=255 x")])
        let active = try! #require(armed)
        let superseded = makeItem(
            seq: 1, attempts: 3, error: HandoffErrorClass.superseded(byNewerHash: "ff"))
        #expect(evaluate([superseded], previous: active) == nil)
    }

    func evaluate(_ items: [HandoffItem], previous: HandoffWarning?) -> HandoffWarning? {
        HandoffWarningThreshold.evaluate(
            items: items, configurationInvalid: false, now: now, previous: previous)
    }

    @Test func unknownErrorShapesFallBackToTruncatedRawText() {
        let long = "transient: exit=1 " + String(repeating: "x", count: 200)
        let warning = evaluate([makeItem(seq: 1, attempts: 1, error: long, age: 61 * 60)])
        #expect(warning?.shortReason == String(long.prefix(80)))
    }

    @Test func messageAndSinceLabelFollowLocaleConventions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let warning = HandoffWarning(
            since: now.addingTimeInterval(-2 * 3600), meetingsWaiting: 1,
            shortReason: "SSH key rejected", episodeKey: "auth|1")
        // 24 h time, no AM/PM; singular form for one meeting.
        let message = warning.message(now: now)
        #expect(message.contains("1 meeting waiting"))
        #expect(!message.contains("AM") && !message.contains("PM"))
        // Same day → time only; another day → DD/MM prefix.
        let sameDay = warning.sinceLabel(now: now, calendar: calendar)
        #expect(sameDay.wholeMatch(of: /\d{2}:\d{2}/) != nil)
        let crossDay = HandoffWarning(
            since: now.addingTimeInterval(-30 * 3600), meetingsWaiting: 2,
            shortReason: "x", episodeKey: "k")
        #expect(crossDay.sinceLabel(now: now, calendar: calendar)
            .wholeMatch(of: /\d{2}\/\d{2} \d{2}:\d{2}/) != nil)
    }
}

// MARK: - Episode policy (status holder)

@MainActor
@Suite struct HandoffStatusHolderWarningTests {
    func snapshot(warning: HandoffWarning?) -> HandoffSnapshot {
        HandoffSnapshot(
            state: warning == nil ? .idle : .authFailure, activeEndpoint: nil,
            pendingCount: warning == nil ? 0 : 1, currentItem: nil, damagedItems: [],
            detail: nil, warning: warning)
    }

    func warning(key: String) -> HandoffWarning {
        HandoffWarning(since: Date(), meetingsWaiting: 1, shortReason: "SSH key rejected", episodeKey: key)
    }

    @Test func notifiesOncePerEpisodeNeverPerAttempt() {
        let holder = makeFirstSweepHolder()
        var posted: [String] = []
        holder.onWarningEpisode = { posted.append($0.episodeKey) }
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        holder.publish(snapshot(warning: warning(key: "auth|1")))  // another attempt
        #expect(posted == ["auth|1"])
        holder.publish(snapshot(warning: warning(key: "auth|2")))  // new item → new episode
        #expect(posted == ["auth|1", "auth|2"])
    }

    @Test func dismissalSilencesTheBannerForThisEpisodeOnly() {
        let holder = makeFirstSweepHolder()
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(holder.bannerWarning != nil)
        holder.dismissWarning()
        #expect(holder.bannerWarning == nil)            // banner silenced
        #expect(holder.snapshot.warning != nil)          // state still active (badge)
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(holder.bannerWarning == nil)             // attempts do not re-arm
        holder.publish(snapshot(warning: warning(key: "hostKeyMismatch|1")))
        #expect(holder.bannerWarning != nil)             // distinct error re-arms
    }

    @Test func clearingIsSilentAndResetsEpisodeBookkeeping() {
        let holder = makeFirstSweepHolder()
        var posted = 0
        var cleared = 0
        holder.onWarningEpisode = { _ in posted += 1 }
        holder.onWarningCleared = { cleared += 1 }
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        holder.dismissWarning()
        holder.publish(snapshot(warning: nil))  // delivery succeeded
        #expect(posted == 1 && cleared == 1)
        #expect(holder.bannerWarning == nil && holder.dismissedEpisodeKey == nil)
        holder.publish(snapshot(warning: nil))  // idle republishs never re-fire
        #expect(cleared == 1)
        // A later failure with the SAME key is a NEW episode: notify + banner.
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(posted == 2)
        #expect(holder.bannerWarning != nil)
    }

    func makeFirstSweepHolder() -> HandoffStatusHolder {
        let holder = HandoffStatusHolder()
        holder.markFirstSweepComplete()  // most tests run past the launch grace
        return holder
    }

    @Test func reArmKeyChangeReNotifiesAndUnDismissesTheBanner() {
        // Round-2 M-1 end-to-end through the holder: an armed episode is
        // DISMISSED, then a re-arm (new eligible row → new episodeKey) must
        // bring the banner back AND fire a fresh notification — the masking the
        // auditor proved is gone. Mirrors the worker's evaluate() re-arm.
        let holder = makeFirstSweepHolder()
        var posted: [String] = []
        holder.onWarningEpisode = { posted.append($0.episodeKey) }

        holder.publish(snapshot(warning: warning(key: "transient|1")))
        #expect(posted == ["transient|1"])
        holder.dismissWarning()
        #expect(holder.bannerWarning == nil)             // dismissed → hidden

        // Re-arm: a distinct key from the new eligible row.
        holder.publish(snapshot(warning: warning(key: "auth|2")))
        #expect(posted == ["transient|1", "auth|2"])     // re-notified
        #expect(holder.bannerWarning != nil)             // banner BACK (not the dismissed key)

        // Drain → silent clear.
        holder.publish(snapshot(warning: nil))
        #expect(holder.bannerWarning == nil)
    }

    @Test func relaunchWithSameEpisodeDoesNotRenotifyButNewEpisodeDoes() {
        // L-2: persisted episode bookkeeping survives relaunch — the same
        // ongoing episode stays silent (no repeat notification, dismissed
        // banner stays dismissed); a NEW episode after relaunch notifies.
        var saved: [HandoffStatusHolder.EpisodeState] = []
        let first = HandoffStatusHolder()
        first.markFirstSweepComplete()
        first.persistEpisodeState = { saved.append($0) }
        var posted = 0
        first.onWarningEpisode = { _ in posted += 1 }
        first.publish(snapshot(warning: warning(key: "auth|7")))
        first.dismissWarning()
        #expect(posted == 1)
        let persisted = try! #require(saved.last)
        #expect(persisted.notifiedEpisodeKey == "auth|7")
        #expect(persisted.dismissedEpisodeKey == "auth|7")

        // Relaunch: a fresh holder restores the persisted state, then the
        // worker re-publishes the SAME ongoing episode.
        let relaunched = HandoffStatusHolder()
        relaunched.markFirstSweepComplete()
        relaunched.restore(persisted)
        var rePosted = 0
        relaunched.onWarningEpisode = { _ in rePosted += 1 }
        relaunched.publish(snapshot(warning: warning(key: "auth|7")))
        #expect(rePosted == 0)                       // same episode: no re-notify
        #expect(relaunched.bannerWarning == nil)     // dismissal survived relaunch

        // A genuinely NEW episode after relaunch still notifies.
        relaunched.publish(snapshot(warning: warning(key: "hostKeyMismatch|9")))
        #expect(rePosted == 1)
        #expect(relaunched.bannerWarning != nil)
    }

    @Test func notificationSuppressedUntilFirstSweepThenDrainsSilently() {
        // L-4: a launch-stale queue that drains right away must NEVER notify.
        let holder = HandoffStatusHolder()           // firstSweepComplete == false
        var posted = 0
        var cleared = 0
        holder.onWarningEpisode = { _ in posted += 1 }
        holder.onWarningCleared = { cleared += 1 }
        // Launch publish arms a warning (banner shows), but the notification
        // is held during the startup grace.
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(posted == 0)
        #expect(holder.bannerWarning != nil)         // banner/menu show immediately
        // The first sweep delivers → warning clears before the grace lifts:
        // no notification ever fires.
        holder.publish(snapshot(warning: nil))
        holder.markFirstSweepComplete()
        #expect(posted == 0)
        #expect(cleared == 1)
    }

    @Test func notificationFiresAfterFirstSweepIfStillFailing() {
        // L-4: a queue that is STILL failing after the first sweep notifies
        // once, when the grace lifts.
        let holder = HandoffStatusHolder()
        var posted: [String] = []
        holder.onWarningEpisode = { posted.append($0.episodeKey) }
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(posted.isEmpty)                       // held during grace
        holder.markFirstSweepComplete()               // sweep done, still failing
        #expect(posted == ["auth|1"])                 // fires once, now
        holder.publish(snapshot(warning: warning(key: "auth|1")))
        #expect(posted == ["auth|1"])                 // no double-fire
    }
}

// MARK: - Worker-side behavior (warning in the published snapshot; retry now)

@Suite struct HandoffWorkerWarningTests {
    @Test func persistentAuthFailureArmsWarningAndDeliveryClearsIt() async throws {
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let authFail = HandoffTransportOutcome(
            exitStatus: 255, stderrTail: "Permission denied (publickey).", timedOut: false)
        let transport = MockTransport(script: [authFail, authFail, authFail])
        let worker = makeWorker(database, transport: transport)

        // Attempts 1 and 2 (each external wake clears the auth floor): the
        // warning stays SILENT below the persistence threshold.
        for _ in 0..<2 {
            await worker.kick()
            await worker.waitUntilSettled()
        }
        await #expect(worker.currentSnapshot().warning == nil)

        // Attempt 3: threshold trips — visible, with the field shape.
        await worker.kick()
        await worker.waitUntilSettled()
        let warning = try #require(await worker.currentSnapshot().warning)
        #expect(warning.shortReason == "SSH key rejected")
        #expect(warning.meetingsWaiting == 1)

        // The fixed key delivers on the next wake → the warning clears
        // silently in the same publish.
        await worker.kick()
        await worker.waitUntilSettled()
        await #expect(worker.currentSnapshot().warning == nil)
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }

    @Test func retryNowReentersFailedRowsAndDeliversImmediately() async throws {
        // The relaunch-to-retry gap: after a failure floored the item (auth
        // = 1 h), retryNow() must re-enter the row AND clear the floor — the
        // delivery happens NOW, with no timer wait and no relaunch.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let transport = MockTransport(script: [
            HandoffTransportOutcome(
                exitStatus: 255, stderrTail: "Permission denied (publickey).", timedOut: false)
        ])
        let worker = makeWorker(database, transport: transport)
        await worker.kick()
        await worker.waitUntilSettled()
        var rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.state == .failed)
        #expect(transport.callCount == 1)

        await worker.retryNow()
        await worker.waitUntilSettled()
        await worker.stop()
        rows = try await HandoffRepository(database: database).allItems()
        #expect(rows.first?.id == item.id && rows.first?.state == .delivered)
        #expect(transport.callCount == 2)
    }

    @Test func retryNowNeverReentersSupersededRows() async throws {
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let repo = HandoffRepository(database: database)
        _ = try await repo.transition(
            item.id, to: .failed, error: HandoffErrorClass.superseded(byNewerHash: "feed"))
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)
        await worker.retryNow()
        await worker.waitUntilSettled()
        await worker.stop()
        #expect(transport.callCount == 0)  // terminal per D12 stays closed
        #expect(try await repo.allItems().first?.state == .failed)
    }

    @Test func warningStaysArmedThroughClassDowngradeAndClearsOnlyOnDelivery() async throws {
        // M-1 flap sequence pinned end-to-end on the real worker: auth ×3 →
        // warn → a transient attempt on the same undelivered row → MUST STAY
        // WARNED (no clear-without-delivery, no fresh episode) → delivery →
        // clears silently in the same publish.
        let database = try makeDatabase()
        _ = try await seedDeliverable(database)
        let auth = HandoffTransportOutcome(
            exitStatus: 255, stderrTail: "Permission denied (publickey).", timedOut: false)
        let transferTransient = HandoffTransportOutcome(
            exitStatus: 65, stderrTail: "scp: partial transfer", timedOut: false)
        let transport = MockTransport(script: [auth, auth, auth, transferTransient])
        let worker = makeWorker(database, transport: transport)

        // Attempts 1–2: silent below the threshold.
        for _ in 0..<2 { await worker.kick(); await worker.waitUntilSettled() }
        await #expect(worker.currentSnapshot().warning == nil)

        // Attempt 3: auth shape trips the threshold.
        await worker.kick()
        await worker.waitUntilSettled()
        let armed = try #require(await worker.currentSnapshot().warning)
        #expect(armed.shortReason == "SSH key rejected")

        // Attempt 4: the SAME row fails as a transient (class downgrade, <1 h).
        // A memoryless threshold would clear here and re-arm a fresh episode on
        // the next auth failure (the warn→clear→warn flap). It must STAY
        // warned with the SAME episode key.
        await worker.kick()
        await worker.waitUntilSettled()
        let stillArmed = try #require(await worker.currentSnapshot().warning)
        #expect(stillArmed.episodeKey == armed.episodeKey)

        // The fixed key delivers (script exhausted → success) → clears.
        await worker.kick()
        await worker.waitUntilSettled()
        await worker.stop()
        await #expect(worker.currentSnapshot().warning == nil)
        #expect(try await HandoffRepository(database: database).allItems().first?.state == .delivered)
    }

    @Test func staleReevaluationTimerFiresAndRepublishesTheWarning() async throws {
        // Round-2 pinning gap 2: the stale-reevaluation timer
        // (scheduleStaleReevaluationIfNeeded) was entirely unpinned — neutering
        // it stayed green. Its load-bearing case (auditor L-2): a row stuck
        // `delivering` after a failed markDelivered write never closes, so
        // nextDeliverable() is nil and the loop parks; only the armed timer
        // re-evaluates the 1-hour staleness arm. Here a delivering-stuck row
        // parks BELOW the staleness threshold (no warning yet), the timer fires
        // at the boundary, and the wake re-publishes WITH the warning — no
        // unrelated kick. A controllable clock puts the boundary ~0.3 s away so
        // the real Task.sleep timer is fast and deterministic.
        let database = try makeDatabase()
        let item = try await seedDeliverable(database)
        let repo = HandoffRepository(database: database)
        // Stick the row in `delivering` (the failed-markDelivered shape): it is
        // undelivered but NOT deliverable, so the loop parks and arms the timer.
        _ = try await repo.transition(item.id, to: .delivering)

        let boundary = item.createdAt.addingTimeInterval(HandoffWarningThreshold.staleAge)
        // Start the clock 0.3 s BEFORE the staleness boundary: at park the row
        // is not yet stale (no warning), and the timer is armed for ~0.3 s.
        let clock = Mutex<Date>(boundary.addingTimeInterval(-0.3))
        let holder = await MainActor.run { HandoffStatusHolder() }
        let worker = makeWorker(
            database, holder: holder, now: { clock.withLock { $0 } })

        await worker.kick()
        await worker.waitUntilSettled()
        // Parked below the boundary: no warning yet (the timer must do it).
        await #expect(worker.currentSnapshot().warning == nil)

        // Advance the clock PAST the boundary, then let the armed timer fire.
        clock.withLock { $0 = boundary.addingTimeInterval(60) }
        // Poll for the timer wake to re-publish the warning (timer ≈ 0.3 s).
        var warning: HandoffWarning?
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(20))
            if let w = await worker.currentSnapshot().warning { warning = w; break }
        }
        await worker.stop()
        let armed = try #require(warning, "stale-reevaluation timer never re-published the warning")
        #expect(armed.shortReason == "remote destination unreachable")  // no error recorded, stale-only
    }

    @Test func damagedOnlyQueueWarnsWithoutUnrelatedWakes() async throws {
        // M-2: a damaged-only queue parks idle with no timer; with the
        // damaged-immediate threshold the warning trips on the quarantine
        // publish itself — no second meeting, network change, or relaunch
        // needed. attempts stays 0 (quarantine precedes the delivering claim).
        let database = try makeDatabase()
        let damaged = try await seedDeliverable(database, title: "vai quebrar")
        let url = database.rootURL.appendingPathComponent(damaged.payloadPath)
        try Data("not the payload".utf8).write(to: url)
        try await NotesRepository(database: database)
            .upsert(makeNotes(meetingID: damaged.meetingID, markdown: "# conteúdo divergente"))
        let transport = MockTransport()
        let worker = makeWorker(database, transport: transport)

        await worker.kick()  // the ONLY wake
        await worker.waitUntilSettled()
        await worker.stop()

        let warning = try #require(await worker.currentSnapshot().warning)
        #expect(warning.shortReason == "payload damaged")
        let row = try #require(try await HandoffRepository(database: database).allItems().first)
        #expect(HandoffErrorClass.isDamaged(row.lastError) && row.attempts == 0)
        #expect(transport.callCount == 0)  // never delivered, never re-attempted
    }
}
