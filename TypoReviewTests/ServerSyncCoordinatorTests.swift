import XCTest
import SwiftData
@testable import TypoReview

@MainActor
final class ServerSyncCoordinatorTests: XCTestCase {
    func testDictationSessionConflictNeverRegressesFinishedOrReviewedState() {
        let sessionID = UUID()
        let local = DictationSession(
            id: sessionID,
            title: "本机标题",
            type: .chineseCharacter,
            updatedAt: Date(timeIntervalSince1970: 300),
            finishedAt: Date(timeIntervalSince1970: 200),
            reviewedAt: Date(timeIntervalSince1970: 250)
        )
        let remoteModel = DictationSession(
            id: sessionID,
            title: "服务器旧标题",
            type: .chineseCharacter,
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        ServerSyncCoordinator.mergeDictationSession(
            DictationSessionSnapshot(remoteModel),
            into: local
        )

        XCTAssertEqual(local.title, "本机标题")
        XCTAssertEqual(local.finishedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(local.reviewedAt, Date(timeIntervalSince1970: 250))
        XCTAssertEqual(local.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testDictationEntryConflictKeepsJudgedResultOverPending() {
        let sessionID = UUID()
        let local = DictationEntry(
            sessionID: sessionID,
            sortOrder: 0,
            type: .chineseCharacter,
            content: "清澈",
            result: .correct,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let remoteModel = DictationEntry(
            id: local.id,
            sessionID: sessionID,
            sortOrder: 0,
            type: .chineseCharacter,
            content: "清澈",
            result: .pending,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        ServerSyncCoordinator.mergeDictationEntry(
            DictationEntrySnapshot(remoteModel),
            into: local
        )

        XCTAssertEqual(local.result, .correct)
        XCTAssertEqual(local.updatedAt, Date(timeIntervalSince1970: 300))
    }

    func testIncrementalChangeUpdatesExistingDictationSessionInPlace() throws {
        let container = try makeFullModelContainer()
        let context = ModelContext(container)
        let sessionID = UUID()
        let session = DictationSession(
            id: sessionID,
            title: "本机听写",
            type: .chineseCharacter,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(session)
        try context.save()

        let registeredSession = try XCTUnwrap(
            try context.fetch(FetchDescriptor<DictationSession>()).first
        )
        let remote = DictationSession(
            id: sessionID,
            title: "服务器听写",
            type: .chineseCharacter,
            updatedAt: Date(timeIntervalSince1970: 200),
            finishedAt: Date(timeIntervalSince1970: 180)
        )
        let change = try makeServerChange(
            entityType: "dictationSessions",
            recordID: sessionID,
            snapshot: DictationSessionSnapshot(remote)
        )

        try ServerSyncCoordinator.shared.applyIncrementalChanges(
            [change],
            to: container,
            settingsStore: AppSettingsStore()
        )

        // The long-lived caller keeps a valid registered object. A destructive
        // delete-and-reinsert would leave this object stale or invalid.
        XCTAssertEqual(registeredSession.id, sessionID)
        let verificationContext = ModelContext(container)
        let updated = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<DictationSession>()).first
        )
        XCTAssertEqual(updated.title, "服务器听写")
        XCTAssertEqual(updated.finishedAt, Date(timeIntervalSince1970: 180))
    }

    func testIncrementalChangeRestoresCalculationRoundSnapshot() throws {
        let container = try makeFullModelContainer()
        let questions = CalculationGenerator.generateInitialRound(dayKey: "2026-08-17")
        let answers = questions.map {
            CalculationAnswer(
                questionID: $0.id,
                value: "\($0.expectedValue)",
                remainder: $0.expectedRemainder.map(String.init) ?? "",
                isCorrect: true
            )
        }
        let submittedAt = Date(timeIntervalSince1970: 200)
        let remote = CalculationRound(
            id: CalculationGenerator.roundID(dayKey: "2026-08-17", roundIndex: 0),
            dayKey: "2026-08-17",
            roundIndex: 0,
            questions: questions,
            answers: answers,
            correctCount: 5,
            startedAt: Date(timeIntervalSince1970: 100),
            submittedAt: submittedAt,
            durationSeconds: 100,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: submittedAt
        )
        let change = try makeServerChange(
            entityType: "calculationRounds",
            recordID: remote.id,
            snapshot: CalculationRoundSnapshot(remote)
        )

        try ServerSyncCoordinator.shared.applyIncrementalChanges(
            [change],
            to: container,
            settingsStore: AppSettingsStore()
        )

        let context = ModelContext(container)
        let restored = try XCTUnwrap(
            try context.fetch(FetchDescriptor<CalculationRound>()).first
        )
        XCTAssertEqual(restored.dayKey, "2026-08-17")
        XCTAssertEqual(restored.questions, questions)
        XCTAssertEqual(restored.answers, answers)
        XCTAssertTrue(restored.isPerfect)
        XCTAssertEqual(restored.durationSeconds, 100)
    }

    func testUnchangedServerSnapshotDoesNotRequireDestructiveRestore() {
        let hashes = [
            "dictationSessions": ["session-id": "same-hash"],
            "settings": ["settings": "same-settings-hash"]
        ]

        XCTAssertFalse(
            ServerSyncCoordinator.requiresSnapshotRestore(
                remoteHashes: hashes,
                baseline: hashes
            )
        )
    }

    func testChangedOrMissingBaselineRequiresSnapshotRestore() {
        let remoteHashes = ["dictationSessions": ["session-id": "new-hash"]]
        let oldHashes = ["dictationSessions": ["session-id": "old-hash"]]

        XCTAssertTrue(
            ServerSyncCoordinator.requiresSnapshotRestore(
                remoteHashes: remoteHashes,
                baseline: oldHashes
            )
        )
        XCTAssertTrue(
            ServerSyncCoordinator.requiresSnapshotRestore(
                remoteHashes: remoteHashes,
                baseline: nil
            )
        )
    }

    func testSnapshotRestoreUsesFreshContextWhenCallerHasStaleModels() async throws {
        let container = try makeFullModelContainer()
        let itemID = UUID()
        let staleContext = ModelContext(container)
        staleContext.autosaveEnabled = false
        let localItem = ReviewItem(
            id: itemID,
            type: .chineseCharacter,
            content: "local",
            prompt: "local"
        )
        staleContext.insert(localItem)
        try staleContext.save()

        let registeredItem = try XCTUnwrap(
            try staleContext.fetch(FetchDescriptor<ReviewItem>()).first
        )
        XCTAssertEqual(registeredItem.content, "local")

        let writerContext = ModelContext(container)
        writerContext.autosaveEnabled = false
        let externallyUpdatedItem = try XCTUnwrap(
            try writerContext.fetch(FetchDescriptor<ReviewItem>()).first
        )
        externallyUpdatedItem.content = "external update"
        externallyUpdatedItem.updatedAt = Date(timeIntervalSince1970: 200)
        try writerContext.save()

        // Keep the caller's older registered generation alive. Reusing this
        // context for delete-and-reinsert is the sequence that crashed build 53.
        XCTAssertEqual(registeredItem.content, "local")

        let serverItem = ReviewItem(
            id: itemID,
            type: .chineseCharacter,
            content: "server snapshot",
            prompt: "server",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let payload = DataBackupPayload(
            settings: nil,
            reviewItems: [ReviewItemSnapshot(serverItem)],
            reviewRecords: [],
            taskItems: [],
            taskCompletions: [],
            taskSubitems: [],
            taskExecutionRecords: [],
            taskSubitemExecutionRecords: [],
            dictationSessions: [],
            dictationEntries: [],
            scheduleItems: []
        )

        try await DataBackupService.restoreStructuredDataInBatches(
            payload,
            into: staleContext,
            settingsStore: AppSettingsStore()
        )

        let refreshedCallerItems = try staleContext.fetch(FetchDescriptor<ReviewItem>())
        XCTAssertEqual(refreshedCallerItems.count, 1)
        XCTAssertEqual(refreshedCallerItems.first?.content, "server snapshot")

        let verificationContext = ModelContext(container)
        let restoredItems = try verificationContext.fetch(FetchDescriptor<ReviewItem>())
        XCTAssertEqual(restoredItems.count, 1)
        XCTAssertEqual(restoredItems.first?.id, itemID)
        XCTAssertEqual(restoredItems.first?.content, "server snapshot")
    }

    func testPersistentStoreAccessGateSerializesConcurrentWork() {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(
            label: "PersistentStoreAccessGateTests",
            attributes: .concurrent
        )

        queue.async(execute: DispatchWorkItem(qos: .default, flags: [], block: {
            PersistentStoreAccessGate.withAccess {
                _ = firstEntered.signal()
                _ = releaseFirst.wait(timeout: .now() + 2)
            }
        }))

        XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)

        queue.async(execute: DispatchWorkItem(qos: .default, flags: [], block: {
            PersistentStoreAccessGate.withAccess {
                _ = secondEntered.signal()
            }
        }))

        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    }

    func testServerSyncModeIsNotReportedAsLocalFallback() {
        let store = SyncStatusStore()
        store.configure(cloudKitEnabled: false, serverSyncEnabled: true)

        XCTAssertFalse(store.isUsingLocalFallback)
        XCTAssertEqual(store.storageModeTitle, "服务器同步存储")
        XCTAssertEqual(store.syncNoticeKind, .ready)
        XCTAssertEqual(store.cloudKitModeText, "上海服务器同步已启用")
    }

    func testStructuredSnapshotDeduplicatesRepeatedRecordIDsUsingNewestRecord() throws {
        let recordID = UUID()
        let itemID = UUID()
        let older = ReviewRecord(
            id: recordID,
            itemID: itemID,
            reviewedAt: Date(timeIntervalSince1970: 100),
            result: .wrong,
            mode: .scheduled,
            oldStage: 1,
            newStage: 1,
            note: "older"
        )
        let newer = ReviewRecord(
            id: recordID,
            itemID: itemID,
            reviewedAt: Date(timeIntervalSince1970: 200),
            result: .correct,
            mode: .scheduled,
            oldStage: 1,
            newStage: 2,
            note: "newer"
        )
        let payload = DataBackupPayload(
            settings: nil,
            reviewItems: [],
            reviewRecords: [ReviewRecordSnapshot(newer), ReviewRecordSnapshot(older)],
            taskItems: [],
            taskCompletions: [],
            taskSubitems: [],
            taskExecutionRecords: [],
            taskSubitemExecutionRecords: [],
            dictationSessions: [],
            dictationEntries: [],
            scheduleItems: []
        )

        let snapshot = try ServerSyncCoordinator.StructuredSnapshot(payload: payload)
        let records = try XCTUnwrap(snapshot.records["reviewRecords"])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[recordID.uuidString]?["note"] as? String, "newer")
    }

    func testStructuredSnapshotDoesNotInferDeletesFromMissingLocalRecords() throws {
        let payload = DataBackupPayload(
            settings: nil,
            reviewItems: [],
            reviewRecords: [],
            taskItems: [],
            taskCompletions: [],
            taskSubitems: [],
            taskExecutionRecords: [],
            taskSubitemExecutionRecords: [],
            dictationSessions: [],
            dictationEntries: [],
            scheduleItems: []
        )
        let snapshot = try ServerSyncCoordinator.StructuredSnapshot(payload: payload)
        let missingID = UUID().uuidString
        let baseline = ["reviewItems": [missingID: "previous-hash"]]

        let mutations = try snapshot.mutations(comparedWith: baseline)

        XCTAssertTrue(mutations.isEmpty)
    }

    func testCanonicalPointEntriesKeepOneRecordPerIdempotencyKey() {
        let sharedKey = "dictation-entry-shared"
        let earlier = PointLedgerEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100),
            amount: 1,
            kind: .reward,
            sourceType: .dictationEntry,
            sourceIDRawValue: "entry",
            idempotencyKey: sharedKey,
            note: "earlier"
        )
        let later = PointLedgerEntry(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 200),
            amount: 1,
            kind: .reward,
            sourceType: .dictationEntry,
            sourceIDRawValue: "entry",
            idempotencyKey: sharedKey,
            note: "later"
        )

        let entries = PointLedgerService.canonicalEntries([later, earlier])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, earlier.id)
    }

    func testRefreshWaitsForActiveUploadAndReadsLatestCursor() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "新题", prompt: "新题")
        fixture.context.insert(item)
        try fixture.context.save()
        let uploadEntered = expectation(description: "upload entered")
        var resumeUpload: CheckedContinuation<Void, Never>?
        fixture.api.onPush = { _ in
            uploadEntered.fulfill()
            await withCheckedContinuation { resumeUpload = $0 }
        }
        let upload = Task { await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings) }
        await fulfillment(of: [uploadEntered], timeout: 5)

        var refreshFinished = false
        let refresh = Task {
            await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)
            refreshFinished = true
        }
        await Task.yield()
        XCTAssertFalse(refreshFinished, "Pull-to-refresh must wait instead of silently returning while uploading")
        let readsBeforeRelease = fixture.api.requestedCursors.count
        resumeUpload?.resume()
        let uploadSucceeded = await upload.value
        await refresh.value
        XCTAssertTrue(uploadSucceeded)
        XCTAssertTrue(refreshFinished)
        XCTAssertGreaterThan(fixture.api.requestedCursors.count, readsBeforeRelease)
    }

    func testAutomaticUploadMergesAndRetriesConflictWithoutManualRefresh() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "已复习", prompt: "已复习")
        fixture.context.insert(item)
        try fixture.context.save()
        fixture.api.onPush = { [api = fixture.api] _ in
            if api.uploadBodies.count == 1 {
                throw ServerAPIError.rejected(statusCode: 409, message: "sync_record_changed")
            }
        }

        let succeeded = await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(fixture.api.uploadBodies.count, 2)
        XCTAssertEqual(fixture.api.events.prefix(4), ["pull", "push", "pull", "push"])
        XCTAssertNil(fixture.sync.lastErrorDescription)
    }

    func testSaveDuringScheduledUploadIsSentInAnotherPassWithoutCancellation() async throws {
        let fixture = try makeSyncFixture()
        let first = ReviewItem(type: .chineseCharacter, content: "第一题", prompt: "第一题")
        fixture.context.insert(first)
        try fixture.context.save()
        let entered = expectation(description: "first upload entered")
        let secondUploaded = expectation(description: "second answer uploaded")
        var resumeFirst: CheckedContinuation<Void, Never>?
        let second = ReviewItem(type: .chineseCharacter, content: "第二题", prompt: "第二题")
        fixture.api.onPush = { [api = fixture.api] body in
            if api.uploadBodies.count == 1 {
                entered.fulfill()
                await withCheckedContinuation { resumeFirst = $0 }
                XCTAssertFalse(Task.isCancelled)
            } else if String(decoding: body, as: UTF8.self).contains(second.id.uuidString) {
                secondUploaded.fulfill()
            }
        }
        fixture.sync.scheduleUpload(from: fixture.context, settingsStore: fixture.settings, delayNanoseconds: 0)
        await fulfillment(of: [entered], timeout: 5)
        fixture.context.insert(second)
        try fixture.context.save()
        fixture.sync.scheduleUpload(from: fixture.context, settingsStore: fixture.settings, delayNanoseconds: 0)
        resumeFirst?.resume()
        await fulfillment(of: [secondUploaded], timeout: 5)
        // Drain the queue before the in-memory store leaves this test.
        _ = await fixture.sync.synchronize(modelContext: fixture.context, settingsStore: fixture.settings)
        XCTAssertEqual(fixture.api.uploadBodies.count, 2)
    }

    func testConflictRetriesAreBoundedAndKeepUnsentWork() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "保留", prompt: "保留")
        fixture.context.insert(item)
        try fixture.context.save()
        fixture.api.onPush = { _ in
            throw ServerAPIError.rejected(statusCode: 409, message: "sync_record_changed")
        }
        let succeeded = await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(fixture.api.uploadBodies.count, 3)
        XCTAssertNotNil(fixture.sync.lastErrorDescription)
        XCTAssertEqual(try fixture.context.fetchCount(FetchDescriptor<ReviewItem>()), 1)
        fixture.api.onPush = nil
        let retrySucceeded = await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings)
        XCTAssertTrue(retrySucceeded)
        XCTAssertEqual(fixture.api.uploadBodies.count, 4, "Failed work must still be pending")
    }

    func testRefreshDownloadsReviewedStateFromOtherDevice() async throws {
        let fixture = try makeSyncFixture()
        let remote = ReviewItem(type: .chineseCharacter, content: "完成", prompt: "完成")
        remote.lastReviewedAt = Date(timeIntervalSince1970: 200)
        remote.nextReviewAt = Date(timeIntervalSince1970: 1000)
        remote.stage = 2
        let change = try makeServerChange(entityType: "reviewItems", recordID: remote.id, snapshot: ReviewItemSnapshot(remote))
        fixture.api.remoteChanges = [change]

        await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)

        let freshContext = ModelContext(fixture.context.container)
        let restored = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<ReviewItem>()).first)
        XCTAssertEqual(restored.lastReviewedAt, remote.lastReviewedAt)
        XCTAssertEqual(restored.nextReviewAt, remote.nextReviewAt)
        XCTAssertEqual(restored.stage, 2)
        XCTAssertEqual(fixture.defaults.integer(forKey: "typo_review_server_change_cursor_v1"), 1)
    }

    func testFractionalHistoryConvergesWithoutUploadingServerEchoes() async throws {
        let fixture = try makeSyncFixture()
        let reviewedAt = Date(timeIntervalSince1970: 1_751_456_999)
        let item = ReviewItem(type: .chineseCharacter, content: "已掌握", prompt: "已掌握",
                              stage: 7, nextReviewAt: .distantFuture, lastReviewedAt: reviewedAt,
                              createdAt: reviewedAt, updatedAt: reviewedAt)
        let itemChange = try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(item))
        let record = ReviewRecord(itemID: item.id, reviewedAt: reviewedAt, result: .correct,
                                  mode: .scheduled, oldStage: 6, newStage: 7)
        let recordChange = try makeServerChange(entityType: "reviewRecords", recordID: record.id, snapshot: ReviewRecordSnapshot(record))
        guard case .object(var payload) = recordChange.payload else {
            XCTFail("Expected record object")
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        payload["reviewedAt"] = .string(formatter.string(from: reviewedAt.addingTimeInterval(0.370)))
        fixture.api.remoteChanges = [
            itemChange,
            ServerChange(entityType: "reviewRecords", recordID: record.id, payload: .object(payload),
                         updatedAt: reviewedAt, serverVersion: 2, deletedAt: nil)
        ]

        for _ in 0..<3 {
            let succeeded = await fixture.sync.synchronize(modelContext: fixture.context, settingsStore: fixture.settings)
            XCTAssertTrue(succeeded)
            // Mirror the persistent-store notification handler after a pull.
            let repairContext = ModelContext(fixture.context.container)
            repairContext.autosaveEnabled = false
            XCTAssertEqual(try ReviewScheduler.reconcileStandardReviewProgress(in: repairContext), 0)
            XCTAssertFalse(repairContext.hasChanges)
        }
        XCTAssertTrue(fixture.api.uploadBodies.isEmpty, "Downloaded history must converge without producing new mutations")
        XCTAssertFalse(fixture.sync.isSynchronizing)
        XCTAssertNil(fixture.sync.lastErrorDescription)
    }

    func testServerChangeRefreshesViewsWithoutRequestingUpload() {
        let center = NotificationCenter()
        var sourcesRequiringUpload: [Bool] = []
        let token = center.addObserver(forName: .appDataDidChange, object: nil, queue: nil) { notification in
            sourcesRequiringUpload.append(AppDataChangeCenter.requiresUpload(notification))
        }
        defer { center.removeObserver(token) }
        AppDataChangeCenter.post(source: .server, using: center)
        AppDataChangeCenter.post(using: center)
        XCTAssertEqual(sourcesRequiringUpload, [false, true])
    }

    func testManualRefreshRepairsMissedReviewEvenWhenCursorIsAlreadyCurrent() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "漏同步", prompt: "漏同步", stage: 1)
        fixture.context.insert(item)
        try fixture.context.save()
        try saveFixtureBaseline(fixture.context, settings: fixture.settings, defaults: fixture.defaults)
        let remote = ReviewItem(type: .chineseCharacter, content: item.content, prompt: item.prompt,
                                stage: 2, nextReviewAt: .distantFuture, lastReviewedAt: .now)
        remote.id = item.id
        fixture.api.remoteChanges = [try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(remote))]
        fixture.defaults.set(1, forKey: "typo_review_server_change_cursor_v1")

        await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)

        let freshContext = ModelContext(fixture.context.container)
        let updated = try XCTUnwrap(try freshContext.fetch(FetchDescriptor<ReviewItem>()).first)
        XCTAssertEqual(updated.stage, 2)
        XCTAssertEqual(updated.nextReviewAt, .distantFuture)
        XCTAssertNotNil(updated.lastReviewedAt)
        XCTAssertEqual(fixture.api.requestedCursors.first, 0, "Manual refresh must check existing rows as well as new versions")
    }

    func testManualRefreshRepairsMissedDictationWithoutLosingUnsentLocalWork() async throws {
        let fixture = try makeSyncFixture()
        let session = DictationSession(title: "待听写", type: .chineseCharacter)
        fixture.context.insert(session)
        try fixture.context.save()
        try saveFixtureBaseline(fixture.context, settings: fixture.settings, defaults: fixture.defaults)
        let unsent = ReviewItem(type: .chineseCharacter, content: "手机新增", prompt: "手机新增")
        fixture.context.insert(unsent)
        try fixture.context.save()
        let remote = DictationSession(id: session.id, title: session.title, type: .chineseCharacter,
                                      finishedAt: .now, reviewedAt: .now)
        fixture.api.remoteChanges = [try makeServerChange(entityType: "dictationSessions", recordID: session.id, snapshot: DictationSessionSnapshot(remote))]
        fixture.defaults.set(1, forKey: "typo_review_server_change_cursor_v1")

        await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)

        let context = ModelContext(fixture.context.container)
        let updated = try XCTUnwrap(try context.fetch(FetchDescriptor<DictationSession>()).first)
        XCTAssertNotNil(updated.reviewedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ReviewItem>()).first?.id, unsent.id)
        let succeeded = await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings)
        XCTAssertTrue(succeeded)
        XCTAssertTrue(fixture.api.uploadBodies.contains { String(decoding: $0, as: UTF8.self).contains(unsent.id.uuidString) })
    }

    func testRepeatedManualRefreshDoesNotRewriteUnchangedRows() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "一致", prompt: "一致")
        fixture.context.insert(item)
        try fixture.context.save()
        try saveFixtureBaseline(fixture.context, settings: fixture.settings, defaults: fixture.defaults)
        fixture.api.remoteChanges = [try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(item))]
        // Install the daily plan first; later identical refreshes should be quiet.
        await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)
        let unexpectedChange = expectation(description: "unchanged rows must not post a data change")
        unexpectedChange.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: .appDataDidChange, object: nil, queue: nil) { _ in
            unexpectedChange.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for _ in 0..<3 {
            let succeeded = await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)
            XCTAssertTrue(succeeded)
        }
        await fulfillment(of: [unexpectedChange], timeout: 0.1)
        XCTAssertTrue(fixture.api.uploadBodies.isEmpty)
    }

    func testManualRefreshPreservesNewerLocalEditOfSameRecord() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "本地", prompt: "本地",
                              updatedAt: Date(timeIntervalSince1970: 100))
        fixture.context.insert(item)
        try fixture.context.save()
        try saveFixtureBaseline(fixture.context, settings: fixture.settings, defaults: fixture.defaults)
        item.note = "手机尚未上传的修改"
        item.updatedAt = Date(timeIntervalSince1970: 300)
        try fixture.context.save()
        let remote = ReviewItem(id: item.id, type: .chineseCharacter, content: "本地", prompt: "本地",
                                updatedAt: Date(timeIntervalSince1970: 200))
        fixture.api.remoteChanges = [try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(remote))]
        fixture.defaults.set(1, forKey: "typo_review_server_change_cursor_v1")

        let succeeded = await fixture.sync.refreshFromServer(modelContext: fixture.context, settingsStore: fixture.settings)
        XCTAssertTrue(succeeded)
        let fresh = ModelContext(fixture.context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ReviewItem>()).first?.note, item.note)
        _ = await fixture.sync.uploadChanges(from: fixture.context, settingsStore: fixture.settings)
        XCTAssertFalse(fixture.api.uploadBodies.isEmpty)
    }

    func testBoardReadUsesFreshContextAfterRemoteReviewAndDictationComplete() async throws {
        let fixture = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "看板", prompt: "看板", stage: 1)
        let session = DictationSession(title: "看板听写", type: .chineseCharacter)
        fixture.context.insert(item)
        fixture.context.insert(session)
        try fixture.context.save()
        try saveFixtureBaseline(fixture.context, settings: fixture.settings, defaults: fixture.defaults)
        let staleBoard = try BoardDataSource.load(from: fixture.context.container)
        XCTAssertEqual(staleBoard.reviewItems.first?.stage, 1)
        XCTAssertEqual(staleBoard.sessions.count, 1)
        let reviewed = ReviewItem(id: item.id, type: .chineseCharacter, content: item.content, prompt: item.prompt,
                                 stage: 7, nextReviewAt: .distantFuture, lastReviewedAt: .now)
        let finished = DictationSession(id: session.id, title: session.title, type: .chineseCharacter, reviewedAt: .now)
        let sessionChange = try makeServerChange(entityType: "dictationSessions", recordID: session.id, snapshot: DictationSessionSnapshot(finished))
        fixture.api.remoteChanges = [
            try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(reviewed)),
            ServerChange(entityType: sessionChange.entityType, recordID: sessionChange.recordID, payload: sessionChange.payload,
                         updatedAt: sessionChange.updatedAt, serverVersion: 2, deletedAt: nil)
        ]
        let succeeded = await fixture.sync.checkForServerUpdates(modelContext: fixture.context, settingsStore: fixture.settings)
        XCTAssertTrue(succeeded)
        let freshBoard = try BoardDataSource.load(from: fixture.context.container)
        XCTAssertEqual(freshBoard.reviewItems.first?.stage, 7)
        XCTAssertEqual(freshBoard.reviewItems.first?.nextReviewAt, .distantFuture)
        XCTAssertTrue(freshBoard.sessions.isEmpty)
        XCTAssertFalse(staleBoard.context === freshBoard.context)
        XCTAssertTrue(fixture.api.uploadBodies.isEmpty, "Idle board polling must not upload")
    }

    func testBoardPollingIsSerialAndStopsWhenCancelled() async {
        var checks: [Bool] = []
        var resumeFirst: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first poll starts immediately")
        let second = expectation(description: "second incremental poll")
        let polling = Task {
            await BoardSyncPolling.run(intervalNanoseconds: 1_000_000) { isFirst in
                checks.append(isFirst)
                if isFirst {
                    started.fulfill()
                    await withCheckedContinuation { resumeFirst = $0 }
                } else if checks.count == 2 {
                    second.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(checks, [true], "A slow request must not overlap another poll")
        resumeFirst?.resume()
        await fulfillment(of: [second], timeout: 2)
        polling.cancel()
        await polling.value
        let count = checks.count
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(checks.count, count)
        XCTAssertFalse(checks.dropFirst().contains(true))
    }

    func testSettingsPullPreservesOfflineItem() async throws {
        let f = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "离线", prompt: "离线")
        f.context.insert(item)
        try f.context.save()
        let result = await f.sync.pull(into: f.context, settingsStore: f.settings)
        XCTAssertTrue(result)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<ReviewItem>()), 1)
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
    }

    func testBootstrapPreservesExistingLocalWork() async throws {
        let f = try makeSyncFixture()
        f.defaults.removeObject(forKey: "typo_review_server_sync_baseline_v1")
        let item = ReviewItem(type: .chineseCharacter, content: "首次离线", prompt: "首次离线")
        f.context.insert(item)
        try f.context.save()
        let result = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertTrue(result)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<ReviewItem>()), 1)
        XCTAssertTrue(f.api.uploadBodies.contains { String(decoding: $0, as: UTF8.self).contains(item.id.uuidString) })
    }

    func testOutboxSurvivesCoordinatorRestartWithSameMutationIDs() async throws {
        let f = try makeSyncFixture()
        f.context.insert(ReviewItem(type: .chineseCharacter, content: "重试", prompt: "重试"))
        try f.context.save()
        f.api.onPush = { _ in throw URLError(.networkConnectionLost) }
        let first = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertFalse(first)
        let original = try XCTUnwrap(f.api.uploadBodies.first)
        f.api.onPush = nil
        let restarted = ServerSyncCoordinator(client: f.api, defaults: f.defaults, enabled: { true })
        let result = await restarted.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertTrue(result)
        XCTAssertEqual(f.api.uploadBodies.last, original)
        XCTAssertNil(f.defaults.data(forKey: "typo_review_sync_outbox_v2"))
    }

    func testExplicitDeletionSurvivesPullAndIsRetriedAfterFailure() async throws {
        let f = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "删除", prompt: "删除")
        f.context.insert(item)
        try f.context.save()
        let change = try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(item))
        try saveFixtureBaseline(f.context, settings: f.settings, defaults: f.defaults)
        SyncDeletionStore.delete(item, in: f.context)
        try f.context.save()
        f.api.remoteChanges = [change]
        f.api.onPush = { _ in throw URLError(.notConnectedToInternet) }
        let first = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertFalse(first)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<ReviewItem>()), 0)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<SyncDeletion>()), 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(f.api.uploadBodies.first), as: UTF8.self).contains("explicit"))
        f.api.onPush = nil
        let retry = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertTrue(retry)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<SyncDeletion>()), 0)
    }

    func testSuccessfulPollDoesNotHideUploadFailure() async throws {
        let f = try makeSyncFixture()
        f.context.insert(ReviewItem(type: .chineseCharacter, content: "失败", prompt: "失败"))
        try f.context.save()
        f.api.onPush = { _ in throw URLError(.notConnectedToInternet) }
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        _ = await f.sync.checkForServerUpdates(modelContext: f.context, settingsStore: f.settings)
        XCTAssertNotNil(f.sync.lastErrorDescription)
    }

    func testManifestUsesIncrementalOnceReceiptsAreVerified() async throws {
        let f = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "清单", prompt: "清单")
        let change = try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(item))
        f.api.remoteChanges = [change]
        _ = await f.sync.checkForServerUpdates(modelContext: f.context, settingsStore: f.settings)
        f.api.manifest = ServerSyncManifest(protocolVersion: 2, cursor: change.serverVersion, records: [
            .init(entityType: change.entityType, recordID: change.recordID, serverVersion: change.serverVersion, deleted: false)
        ])
        let start = f.api.requestedCursors.count
        _ = await f.sync.refreshFromServer(modelContext: f.context, settingsStore: f.settings)
        XCTAssertEqual(f.api.requestedCursors[start], change.serverVersion)
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
    }

    func testRejectedRecordDoesNotBlockOtherUploadsOrLoseLocalData() async throws {
        let f = try makeSyncFixture()
        let held = ReviewItem(type: .chineseCharacter, content: "冲突", prompt: "冲突")
        let accepted = ReviewItem(type: .chineseCharacter, content: "通过", prompt: "通过")
        f.context.insert(held)
        f.context.insert(accepted)
        try f.context.save()
        f.api.reply = { mutations in
            let rejected = mutations.first { ($0["recordID"] as? String) == held.id.uuidString }!
            let ids = mutations.filter { ($0["recordID"] as? String) != held.id.uuidString }
                .map { UUID(uuidString: $0["mutationID"] as! String)! }
            return ServerMutationResponse(appliedMutationIDs: ids, conflicts: [
                .init(mutationID: UUID(uuidString: rejected["mutationID"] as! String)!, entityType: "reviewItems",
                      recordID: held.id, statusCode: 409, reason: .string("conflicting review"))
            ])
        }
        let first = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertTrue(first)
        XCTAssertNotNil(f.sync.lastErrorDescription)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<ReviewItem>()), 2)
        let count = f.api.uploadBodies.count
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertEqual(f.api.uploadBodies.count, count, "Unchanged conflicting data must not loop")
        f.api.reply = nil
        held.content = "修正后"
        held.updatedAt = .now
        try f.context.save()
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
        XCTAssertEqual(f.api.uploadBodies.count, count + 1)
        XCTAssertNil(f.sync.lastErrorDescription)
    }

    func testManifestRepairsMissingLocalRowDespiteKnownReceipt() async throws {
        let f = try makeSyncFixture()
        let item = ReviewItem(type: .chineseCharacter, content: "补漏", prompt: "补漏")
        let change = try makeServerChange(entityType: "reviewItems", recordID: item.id, snapshot: ReviewItemSnapshot(item))
        f.api.remoteChanges = [change]
        _ = await f.sync.checkForServerUpdates(modelContext: f.context, settingsStore: f.settings)
        let context = ModelContext(f.context.container)
        for row in try context.fetch(FetchDescriptor<ReviewItem>()) { context.delete(row) }
        try context.save()
        f.api.manifest = ServerSyncManifest(protocolVersion: 2, cursor: change.serverVersion, records: [
            .init(entityType: change.entityType, recordID: change.recordID, serverVersion: change.serverVersion, deleted: false)
        ])
        let start = f.api.requestedCursors.count
        _ = await f.sync.refreshFromServer(modelContext: f.context, settingsStore: f.settings)
        XCTAssertEqual(f.api.requestedCursors[start], 0)
        XCTAssertEqual(try ModelContext(f.context.container).fetchCount(FetchDescriptor<ReviewItem>()), 1)
        _ = await f.sync.synchronize(modelContext: f.context, settingsStore: f.settings)
    }

    private func saveFixtureBaseline(_ context: ModelContext, settings: AppSettingsStore, defaults: UserDefaults) throws {
        let snapshot = try ServerSyncCoordinator.StructuredSnapshot(
            payload: DataBackupPayload.capture(from: context, settings: settings.snapshot, mediaAssets: [])
        )
        defaults.set(try JSONEncoder().encode(snapshot.hashes), forKey: "typo_review_server_sync_baseline_v1")
    }

    private func makeSyncFixture() throws -> (
        sync: ServerSyncCoordinator, api: StubServerSyncAPI, context: ModelContext,
        settings: AppSettingsStore, defaults: UserDefaults
    ) {
        let container = try makeFullModelContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let settings = AppSettingsStore()
        let suite = "ServerSyncTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let baseline = try ServerSyncCoordinator.StructuredSnapshot(
            payload: DataBackupPayload.capture(from: context, settings: settings.snapshot, mediaAssets: [])
        )
        defaults.set(try JSONEncoder().encode(baseline.hashes), forKey: "typo_review_server_sync_baseline_v1")
        defaults.set(0, forKey: "typo_review_server_change_cursor_v1")
        let api = StubServerSyncAPI()
        let sync = ServerSyncCoordinator(client: api, defaults: defaults, enabled: { true })
        return (sync, api, context, settings, defaults)
    }

    private func makeFullModelContainer() throws -> ModelContainer {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            SyncDeletion.self,
            ReviewDailyPlan.self,
            TaskItem.self,
            TaskCompletion.self,
            TaskSubitem.self,
            TaskExecutionRecord.self,
            TaskSubitemExecutionRecord.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self,
            MediaAsset.self,
            PointLedgerEntry.self,
            PointRewardState.self,
            CalculationRound.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    private func makeServerChange<Snapshot: Encodable>(
        entityType: String,
        recordID: UUID,
        snapshot: Snapshot
    ) throws -> ServerChange {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try JSONDecoder().decode(
            ServerJSONValue.self,
            from: encoder.encode(snapshot)
        )
        return ServerChange(
            entityType: entityType,
            recordID: recordID,
            payload: payload,
            updatedAt: Date(timeIntervalSince1970: 200),
            serverVersion: 1,
            deletedAt: nil
        )
    }
}

@MainActor
private final class StubServerSyncAPI: ServerSyncAPI {
    var remoteChanges: [ServerChange] = []
    var requestedCursors: [Int64] = []
    var uploadBodies: [Data] = []
    var events: [String] = []
    var reply: (([[String: Any]]) -> ServerMutationResponse)?
    var manifest: ServerSyncManifest?
    func syncManifest() async throws -> ServerSyncManifest? { manifest }
    var onPush: ((Data) async throws -> Void)?
    private let planID = UUID()

    func health() async throws {}
    func exportSnapshot() async throws -> DataBackupPayload { throw ServerAPIError.invalidResponse }
    func deepSeekAPIKey() async throws -> ServerSecretValueResponse { throw ServerAPIError.notConfigured }
    func saveDeepSeekAPIKey(_ value: String) async throws -> ServerSecretValueResponse { throw ServerAPIError.notConfigured }

    func changes(after cursor: Int64, limit: Int) async throws -> ServerChangeBatch {
        requestedCursors.append(cursor)
        events.append("pull")
        let changes = Array(remoteChanges.filter { $0.serverVersion > cursor }.prefix(limit))
        return ServerChangeBatch(changes: changes, cursor: changes.last?.serverVersion ?? cursor)
    }

    func dailyPlan(day: String, dailyLimit: Int) async throws -> ServerDailyPlan {
        ServerDailyPlan(id: planID, day: day, dailyLimit: dailyLimit,
                        createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100), items: [])
    }

    func pushMutations(_ body: Data) async throws -> ServerMutationResponse {
        uploadBodies.append(body)
        events.append("push")
        try await onPush?(body)
        let root = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let mutations = root["mutations"] as! [[String: Any]]
        if let reply { return reply(mutations) }
        return ServerMutationResponse(appliedMutationIDs: mutations.compactMap { UUID(uuidString: $0["mutationID"] as! String) })
    }
}
