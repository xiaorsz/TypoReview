import XCTest
@testable import TypoReview

@MainActor
final class ServerSyncCoordinatorTests: XCTestCase {
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
}
