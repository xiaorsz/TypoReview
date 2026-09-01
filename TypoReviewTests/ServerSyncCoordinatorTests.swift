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

    private func makeFullModelContainer() throws -> ModelContainer {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
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
