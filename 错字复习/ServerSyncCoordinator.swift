import CryptoKit
import Foundation
import Observation
import SwiftData
import WidgetKit

private struct SyncRecordKey: Hashable {
    let entityType: String
    let recordID: String

    init(entityType: String, recordID: String) {
        self.entityType = entityType
        self.recordID = recordID
    }

    init(_ change: ServerChange) {
        entityType = change.entityType
        recordID = change.recordID.uuidString
    }
}

private enum IncrementalConflictResolution {
    case acceptRemote
    case keepLocal
    case mergeDictationSession
    case mergeDictationEntry
}

@MainActor
@Observable
final class ServerSyncCoordinator {
    static let shared = ServerSyncCoordinator()

    private static let baselineDefaultsKey = "typo_review_server_sync_baseline_v1"
    private static let bootstrapInProgressDefaultsKey = "typo_review_server_bootstrap_in_progress_v1"
    private static let changeCursorDefaultsKey = "typo_review_server_change_cursor_v1"
    nonisolated private static let entityOrder = [
        "reviewRecords",
        "reviewItems",
        "taskItems",
        "taskCompletions",
        "taskSubitems",
        "taskExecutionRecords",
        "taskSubitemExecutionRecords",
        "dictationSessions",
        "dictationEntries",
        "scheduleItems",
        "calculationRounds",
        "pointLedgerEntries",
        "pointRewardStates",
        "settings",
    ]

    @ObservationIgnored private var uploadTask: Task<Void, Never>?
    private var isPulling = false
    private var isUploading = false
    private var activeSyncPhase: String?
    private(set) var isApplyingRemoteSnapshot = false
    private(set) var lastErrorDescription: String?
    private(set) var lastSuccessfulConnectionAt: Date?
    private(set) var lastSuccessfulPullAt: Date?
    private(set) var lastSuccessfulUploadAt: Date?
    private(set) var lastPulledDataSummary = "尚未完成服务器下载"

    var isEnabled: Bool { ServerAPIConfiguration.current != nil }
    var isSynchronizing: Bool { isPulling || isUploading || isApplyingRemoteSnapshot }
    var serverStatusText: String {
        if let activeSyncPhase {
            return activeSyncPhase
        }
        return lastErrorDescription == nil ? "正常" : "等待重试"
    }

    func synchronize(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async {
        guard isEnabled else { return }
        if loadBaseline() == nil {
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: Self.bootstrapInProgressDefaultsKey) else {
                lastErrorDescription = "上次首次同步被系统中断，已暂停自动导入。请在设置中手动同步。"
                return
            }
            defaults.set(true, forKey: Self.bootstrapInProgressDefaultsKey)
            defer {
                defaults.removeObject(forKey: Self.bootstrapInProgressDefaultsKey)
            }
            _ = await pull(into: modelContext, settingsStore: settingsStore)
            return
        }

        if let cursor = loadChangeCursor() {
            // Merge server changes against the last shared baseline before
            // uploading. This prevents an offline device from blindly replacing
            // a newer server value for the same record.
            let pullSucceeded = await pullIncremental(
                after: cursor,
                into: modelContext,
                settingsStore: settingsStore
            )
            guard pullSucceeded else { return }
            _ = await uploadChanges(
                from: modelContext,
                settingsStore: settingsStore
            )
        } else {
            // Builds upgrading from the snapshot-only protocol do not have a
            // change cursor yet. Preserve their local work before establishing
            // the first cursor.
            let uploadSucceeded = await uploadChanges(
                from: modelContext,
                settingsStore: settingsStore
            )
            guard uploadSucceeded else {
                // Preserve locally completed work when the server rejects an
                // upload. Pulling the older server snapshot here would replace
                // the local store and make a successful submission appear undone.
                return
            }
            await pull(into: modelContext, settingsStore: settingsStore)
        }
    }

    /// User-initiated refresh returns as soon as remote changes are merged.
    /// Local upload is deliberately delayed so SwiftUI can finish the pull-to-
    /// refresh animation and redraw the visible list before scanning the store.
    func refreshFromServer(
        modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async {
        guard isEnabled else { return }
        guard loadBaseline() != nil, let cursor = loadChangeCursor() else {
            await synchronize(modelContext: modelContext, settingsStore: settingsStore)
            return
        }

        let pullSucceeded = await pullIncremental(
            after: cursor,
            into: modelContext,
            settingsStore: settingsStore
        )
        guard pullSucceeded else { return }
        scheduleUpload(
            from: modelContext,
            settingsStore: settingsStore,
            delayNanoseconds: 450_000_000
        )
    }

    @discardableResult
    func pull(
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled, !isApplyingRemoteSnapshot, !isPulling else { return false }

        // A delayed upload may already have started. Stop it and wait for its
        // cancellation to finish before replacing local data with the server
        // snapshot, otherwise its cancellation error can overwrite pull status.
        let pendingUpload = uploadTask
        uploadTask = nil
        pendingUpload?.cancel()
        if let pendingUpload {
            await pendingUpload.value
        }
        guard !isUploading else { return false }

        isPulling = true
        lastErrorDescription = nil
        activeSyncPhase = "正在检查连接"
        defer {
            activeSyncPhase = nil
            isPulling = false
        }
        do {
            try await ServerAPIClient.shared.health()
            lastSuccessfulConnectionAt = .now
            let snapshotCursor = try await latestServerChangeCursor()
            activeSyncPhase = "正在下载数据"
            let payload = try await ServerAPIClient.shared.exportSnapshot()
            activeSyncPhase = "正在核对数据"
            let remoteSnapshot = try StructuredSnapshot(payload: payload)
            let shouldRestore = Self.requiresSnapshotRestore(
                remoteHashes: remoteSnapshot.hashes,
                baseline: loadBaseline()
            )

            if shouldRestore {
                activeSyncPhase = "正在写入本机"
                isApplyingRemoteSnapshot = true

                // Give SwiftUI one update cycle to unmount data-heavy views and
                // cancel their snapshot tasks before the exclusive store rewrite.
                await Task.yield()

                do {
                    try await DataBackupService.restoreStructuredDataInBatches(
                        payload,
                        into: modelContext,
                        settingsStore: settingsStore
                    )
                } catch {
                    isApplyingRemoteSnapshot = false
                    throw error
                }
                isApplyingRemoteSnapshot = false
            }

            activeSyncPhase = "正在更新今日计划"
            let dailyPlanChanged = try await installServerDailyPlan(
                in: modelContext.container,
                dailyLimit: settingsStore.dailyLimit
            )
            saveBaseline(remoteSnapshot.hashes)
            saveChangeCursor(snapshotCursor)
            UserDefaults.standard.removeObject(forKey: Self.bootstrapInProgressDefaultsKey)
            lastErrorDescription = nil
            lastSuccessfulPullAt = .now
            lastPulledDataSummary = Self.dataSummary(for: payload)
            await synchronizeDeepSeekAPIKey()
            if shouldRestore || dailyPlanChanged {
                AppDataChangeCenter.post()
                WidgetCenter.shared.reloadAllTimelinesInBackground()
            }
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            lastErrorDescription = Self.userFacingDescription(
                for: error,
                phase: activeSyncPhase
            )
            #if DEBUG
            print("Server pull failed: \(error)")
            #endif
            return false
        }
    }

    @discardableResult
    private func pullIncremental(
        after initialCursor: Int64,
        into modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled, !isPulling, !isUploading, !isApplyingRemoteSnapshot else { return false }

        isPulling = true
        lastErrorDescription = nil
        activeSyncPhase = "正在检查更新"
        defer {
            activeSyncPhase = nil
            isPulling = false
        }

        do {
            guard let baseline = loadBaseline() else { return false }
            var cursor = initialCursor
            var receivedChanges: [ServerChange] = []
            var dataChanged = false
            while true {
                let batch = try await ServerAPIClient.shared.changes(after: cursor)
                receivedChanges.append(contentsOf: batch.changes)
                cursor = batch.cursor
                if batch.changes.count < 1_000 { break }
            }

            let changes = Self.latestChangesByRecord(receivedChanges)
            if !changes.isEmpty {
                activeSyncPhase = "正在合并更新"
                let container = modelContext.container
                let settings = settingsStore.snapshot
                let localSnapshot = try await Task.detached(priority: .utility) {
                    try Self.captureStructuredSnapshot(
                        from: container,
                        settings: settings
                    )
                }.value
                let resolutions = try Self.conflictResolutions(
                    for: changes,
                    localSnapshot: localSnapshot,
                    baseline: baseline
                )
                dataChanged = try applyIncrementalChanges(
                    changes,
                    to: modelContext.container,
                    settingsStore: settingsStore,
                    resolutions: resolutions
                )

                let mergedSettings = settingsStore.snapshot
                let mergedSnapshot = try await Task.detached(priority: .utility) {
                    try Self.captureStructuredSnapshot(
                        from: container,
                        settings: mergedSettings
                    )
                }.value
                let pendingLocalKeys = Self.pendingLocalKeys(
                    localSnapshot: localSnapshot,
                    baseline: baseline,
                    resolutions: resolutions
                )
                saveBaseline(
                    Self.baselineForPendingUpload(
                        original: baseline,
                        mergedSnapshot: mergedSnapshot,
                        pendingLocalKeys: pendingLocalKeys,
                        changes: changes,
                        resolutions: resolutions
                    )
                )
            }

            // Daily plans are server-owned and are not part of the incremental
            // record stream. Refresh them even when there were no record changes;
            // otherwise an upgraded client can keep syncing successfully while
            // the server's plan remains stuck on an earlier day.
            activeSyncPhase = "正在更新今日计划"
            let dailyPlanChanged = try await installServerDailyPlan(
                in: modelContext.container,
                dailyLimit: settingsStore.dailyLimit
            )
            saveChangeCursor(cursor)
            lastErrorDescription = nil
            lastSuccessfulPullAt = .now
            if dataChanged || dailyPlanChanged {
                AppDataChangeCenter.post()
                WidgetCenter.shared.reloadAllTimelinesInBackground()
            }
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            lastErrorDescription = Self.userFacingDescription(for: error, phase: activeSyncPhase)
            #if DEBUG
            print("Incremental server pull failed: \(error)")
            #endif
            return false
        }
    }

    private func latestServerChangeCursor() async throws -> Int64 {
        var cursor: Int64 = 0
        while true {
            let batch = try await ServerAPIClient.shared.changes(after: cursor, limit: 5_000)
            cursor = batch.cursor
            if batch.changes.count < 5_000 { return cursor }
        }
    }

    func applyIncrementalChanges(
        _ changes: [ServerChange],
        to container: ModelContainer,
        settingsStore: AppSettingsStore
    ) throws {
        _ = try applyIncrementalChanges(
            changes,
            to: container,
            settingsStore: settingsStore,
            resolutions: [:]
        )
    }

    @discardableResult
    private func applyIncrementalChanges(
        _ changes: [ServerChange],
        to container: ModelContainer,
        settingsStore: AppSettingsStore,
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) throws -> Bool {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false

            // Populate only the caches needed by this change batch. A dictation-
            // only pull should not fetch every review, task, schedule and points
            // row merely to update one visible session.
            var loadedEntities: Set<String> = []
            var reviewItems: [UUID: ReviewItem] = [:]
            var reviewRecords: [UUID: ReviewRecord] = [:]
            var taskItems: [UUID: TaskItem] = [:]
            var taskCompletions: [UUID: TaskCompletion] = [:]
            var taskSubitems: [UUID: TaskSubitem] = [:]
            var taskExecutions: [UUID: TaskExecutionRecord] = [:]
            var taskSubitemExecutions: [UUID: TaskSubitemExecutionRecord] = [:]
            var dictationSessions: [UUID: DictationSession] = [:]
            var dictationEntries: [UUID: DictationEntry] = [:]
            var scheduleItems: [UUID: ScheduleItem] = [:]
            var calculationRounds: [UUID: CalculationRound] = [:]
            var pointEntries: [UUID: PointLedgerEntry] = [:]
            var pointStates: [UUID: PointRewardState] = [:]
            var settingsSnapshot: AppSettingsSnapshot?

            for change in changes {
                let key = SyncRecordKey(change)
                let resolution = resolutions[key] ?? .acceptRemote
                guard resolution != .keepLocal else { continue }
                let isDeletion = change.deletedAt != nil
                switch change.entityType {
                case "reviewItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        reviewItems = modelsByID(try context.fetch(FetchDescriptor<ReviewItem>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: ReviewItemSnapshot.self, in: context, cache: &reviewItems, makeModel: { $0.makeModel() }) { value, model in
                        model.typeRawValue = value.typeRawValue
                        model.content = value.content
                        model.prompt = value.prompt
                        model.note = value.note
                        model.source = value.source
                        model.stage = value.stage
                        model.nextReviewAt = value.nextReviewAt
                        model.lastReviewedAt = value.lastReviewedAt
                        model.consecutiveCorrectCount = value.consecutiveCorrectCount
                        model.consecutiveWrongCount = value.consecutiveWrongCount
                        model.isPriority = value.isPriority
                        model.reviewTrackRawValue = value.reviewTrackRawValue ?? ReviewTrack.standard.rawValue
                        model.dictationFollowUpStep = value.dictationFollowUpStep ?? 0
                        model.isDictationPassRaw = value.isDictationPassRaw
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "reviewRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        reviewRecords = modelsByID(try context.fetch(FetchDescriptor<ReviewRecord>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: ReviewRecordSnapshot.self, in: context, cache: &reviewRecords, makeModel: { $0.makeModel() }) { value, model in
                        model.itemID = value.itemID
                        model.reviewedAt = value.reviewedAt
                        model.resultRawValue = value.resultRawValue
                        model.modeRawValue = value.modeRawValue
                        model.oldStage = value.oldStage
                        model.newStage = value.newStage
                        model.note = value.note
                    }
                case "taskItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskItems = modelsByID(try context.fetch(FetchDescriptor<TaskItem>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: TaskItemSnapshot.self, in: context, cache: &taskItems, makeModel: { $0.makeModel() }) { value, model in
                        model.title = value.title
                        model.note = value.note
                        model.recurrenceJSON = value.recurrenceJSON
                        model.skipPolicyRawValue = value.skipPolicyRawValue
                        model.timingModeRawValue = value.timingModeRawValue
                        model.startDate = value.startDate
                        model.endDate = value.endDate
                        model.deadline = value.deadline
                        model.pauseIntervalsJSON = value.pauseIntervalsJSON
                        model.pauseStartedAt = value.pauseStartedAt
                        model.isArchived = value.isArchived
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskCompletions":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskCompletions = modelsByID(try context.fetch(FetchDescriptor<TaskCompletion>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: TaskCompletionSnapshot.self, in: context, cache: &taskCompletions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskID = value.taskID
                        model.completedDate = value.completedDate
                        model.completedAt = value.completedAt
                    }
                case "taskSubitems":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskSubitems = modelsByID(try context.fetch(FetchDescriptor<TaskSubitem>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: TaskSubitemSnapshot.self, in: context, cache: &taskSubitems, makeModel: { $0.makeModel() }) { value, model in
                        model.parentTaskID = value.parentTaskID
                        model.taskExecutionIDRawValue = value.taskExecutionIDRawValue
                        model.title = value.title
                        model.note = value.note
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.sortOrder = value.sortOrder
                        model.isArchived = value.isArchived
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskExecutionRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskExecutions = modelsByID(try context.fetch(FetchDescriptor<TaskExecutionRecord>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: TaskExecutionRecordSnapshot.self, in: context, cache: &taskExecutions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskID = value.taskID
                        model.occurrenceDate = value.occurrenceDate
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "taskSubitemExecutionRecords":
                    if loadedEntities.insert(change.entityType).inserted {
                        taskSubitemExecutions = modelsByID(try context.fetch(FetchDescriptor<TaskSubitemExecutionRecord>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: TaskSubitemExecutionRecordSnapshot.self, in: context, cache: &taskSubitemExecutions, makeModel: { $0.makeModel() }) { value, model in
                        model.taskExecutionID = value.taskExecutionID
                        model.subtaskID = value.subtaskID
                        model.detail = value.detail
                        model.statusRawValue = value.statusRawValue
                        model.completedAt = value.completedAt
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "dictationSessions":
                    if loadedEntities.insert(change.entityType).inserted {
                        dictationSessions = modelsByID(try context.fetch(FetchDescriptor<DictationSession>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: DictationSessionSnapshot.self, in: context, cache: &dictationSessions, makeModel: { $0.makeModel() }) { value, model in
                        if resolution == .mergeDictationSession {
                            Self.mergeDictationSession(value, into: model)
                        } else {
                            model.title = value.title
                            model.typeRawValue = value.typeRawValue
                            model.createdAt = value.createdAt
                            model.updatedAt = value.updatedAt
                            model.scheduledDate = value.scheduledDate
                            model.finishedAt = value.finishedAt
                            model.reviewedAt = value.reviewedAt
                        }
                    }
                case "dictationEntries":
                    if loadedEntities.insert(change.entityType).inserted {
                        dictationEntries = modelsByID(try context.fetch(FetchDescriptor<DictationEntry>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: DictationEntrySnapshot.self, in: context, cache: &dictationEntries, makeModel: { $0.makeModel() }) { value, model in
                        if resolution == .mergeDictationEntry {
                            Self.mergeDictationEntry(value, into: model)
                        } else {
                            model.sessionID = value.sessionID
                            model.sortOrder = value.sortOrder
                            model.typeRawValue = value.typeRawValue
                            model.content = value.content
                            model.prompt = value.prompt
                            model.note = value.note
                            model.source = value.source
                            model.resultRawValue = value.resultRawValue
                            model.createdAt = value.createdAt
                            model.updatedAt = value.updatedAt
                        }
                    }
                case "scheduleItems":
                    if loadedEntities.insert(change.entityType).inserted {
                        scheduleItems = modelsByID(try context.fetch(FetchDescriptor<ScheduleItem>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: ScheduleItemSnapshot.self, in: context, cache: &scheduleItems, makeModel: { $0.makeModel() }) { value, model in
                        model.title = value.title
                        model.note = value.note
                        model.startTime = value.startTime
                        model.endTime = value.endTime
                        model.repeatRuleRawValue = value.repeatRuleRawValue
                        model.weekdaysJSON = value.weekdaysJSON
                        model.effectiveStartDate = value.effectiveStartDate
                        model.effectiveEndDate = value.effectiveEndDate
                        model.isArchived = value.isArchived
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "calculationRounds":
                    if loadedEntities.insert(change.entityType).inserted {
                        calculationRounds = modelsByID(
                            try context.fetch(FetchDescriptor<CalculationRound>()),
                            id: \.id
                        )
                    }
                    try apply(
                        change,
                        deleting: isDeletion,
                        as: CalculationRoundSnapshot.self,
                        in: context,
                        cache: &calculationRounds,
                        makeModel: { $0.makeModel() }
                    ) { value, model in
                        model.dayKey = value.dayKey
                        model.roundIndex = value.roundIndex
                        model.generatorVersion = value.generatorVersion
                        model.questionsRawValue = value.questionsRawValue
                        model.answersRawValue = value.answersRawValue
                        model.correctCount = value.correctCount
                        model.startedAt = value.startedAt
                        model.submittedAt = value.submittedAt
                        model.durationSeconds = value.durationSeconds
                        model.createdAt = value.createdAt
                        model.updatedAt = value.updatedAt
                    }
                case "pointLedgerEntries":
                    if loadedEntities.insert(change.entityType).inserted {
                        pointEntries = modelsByID(try context.fetch(FetchDescriptor<PointLedgerEntry>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: PointLedgerEntrySnapshot.self, in: context, cache: &pointEntries, makeModel: { $0.makeModel() }) { value, model in
                        model.createdAt = value.createdAt
                        model.amount = value.amount
                        model.kindRawValue = value.kindRawValue
                        model.sourceTypeRawValue = value.sourceTypeRawValue
                        model.sourceIDRawValue = value.sourceIDRawValue
                        model.idempotencyKey = value.idempotencyKey
                        model.note = value.note
                        model.isReversal = value.isReversal
                        model.reversesEntryIDRawValue = value.reversesEntryIDRawValue
                    }
                case "pointRewardStates":
                    if loadedEntities.insert(change.entityType).inserted {
                        pointStates = modelsByID(try context.fetch(FetchDescriptor<PointRewardState>()), id: \.id)
                    }
                    try apply(change, deleting: isDeletion, as: PointRewardStateSnapshot.self, in: context, cache: &pointStates, makeModel: { $0.makeModel() }) { value, model in
                        model.currentStreak = value.currentStreak
                        model.lastActiveDay = value.lastActiveDay
                        model.longestStreak = value.longestStreak
                        model.updatedAt = value.updatedAt
                    }
                case "settings":
                    if !isDeletion {
                        settingsSnapshot = try change.decodePayload(AppSettingsSnapshot.self)
                    }
                default:
                    continue
                }
            }

            let modelDataChanged = context.hasChanges
            if modelDataChanged {
                try context.save()
            }
            if let settingsSnapshot {
                settingsStore.restore(from: settingsSnapshot, using: context)
            }
            return modelDataChanged || settingsSnapshot != nil
        }
    }

    nonisolated private static func captureStructuredSnapshot(
        from container: ModelContainer,
        settings: AppSettingsSnapshot
    ) throws -> StructuredSnapshot {
        try PersistentStoreAccessGate.withAccess {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let payload = try DataBackupPayload.capture(
                from: context,
                settings: settings,
                mediaAssets: []
            )
            return try StructuredSnapshot(payload: payload)
        }
    }

    private static func latestChangesByRecord(_ changes: [ServerChange]) -> [ServerChange] {
        var latest: [SyncRecordKey: ServerChange] = [:]
        for change in changes {
            let key = SyncRecordKey(change)
            if let existing = latest[key], existing.serverVersion >= change.serverVersion {
                continue
            }
            latest[key] = change
        }
        return latest.values.sorted { $0.serverVersion < $1.serverVersion }
    }

    private static func conflictResolutions(
        for changes: [ServerChange],
        localSnapshot: StructuredSnapshot,
        baseline: [String: [String: String]]
    ) throws -> [SyncRecordKey: IncrementalConflictResolution] {
        var result: [SyncRecordKey: IncrementalConflictResolution] = [:]
        for change in changes {
            let key = SyncRecordKey(change)
            guard let localRecord = localSnapshot.records[key.entityType]?[key.recordID] else {
                result[key] = .acceptRemote
                continue
            }
            let localHash = localSnapshot.hashes[key.entityType]?[key.recordID]
            let baselineHash = baseline[key.entityType]?[key.recordID]
            guard localHash != baselineHash else {
                result[key] = .acceptRemote
                continue
            }

            if change.deletedAt != nil {
                let localTimestamp = StructuredSnapshot.timestamp(
                    in: localRecord,
                    entityType: key.entityType
                )
                result[key] = change.deletedAt! >= (localTimestamp ?? .distantPast)
                    ? .acceptRemote
                    : .keepLocal
            } else if key.entityType == "dictationSessions" {
                result[key] = .mergeDictationSession
            } else if key.entityType == "dictationEntries" {
                result[key] = .mergeDictationEntry
            } else {
                let remoteRecord = try change.payloadDictionary()
                result[key] = StructuredSnapshot.remoteRecordWinsConflict(
                    entityType: key.entityType,
                    local: localRecord,
                    remote: remoteRecord
                ) ? .acceptRemote : .keepLocal
            }
        }
        return result
    }

    private static func pendingLocalKeys(
        localSnapshot: StructuredSnapshot,
        baseline: [String: [String: String]],
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) -> Set<SyncRecordKey> {
        var pending: Set<SyncRecordKey> = []
        for (entityType, records) in localSnapshot.hashes {
            for (recordID, hash) in records where hash != baseline[entityType]?[recordID] {
                pending.insert(SyncRecordKey(entityType: entityType, recordID: recordID))
            }
        }
        for (key, resolution) in resolutions where resolution == .acceptRemote {
            pending.remove(key)
        }
        return pending
    }

    private static func baselineForPendingUpload(
        original: [String: [String: String]],
        mergedSnapshot: StructuredSnapshot,
        pendingLocalKeys: Set<SyncRecordKey>,
        changes: [ServerChange],
        resolutions: [SyncRecordKey: IncrementalConflictResolution]
    ) -> [String: [String: String]] {
        var result = original
        for (entityType, records) in mergedSnapshot.hashes {
            for (recordID, hash) in records {
                let key = SyncRecordKey(entityType: entityType, recordID: recordID)
                if !pendingLocalKeys.contains(key) {
                    result[entityType, default: [:]][recordID] = hash
                }
            }
        }
        for change in changes where change.deletedAt != nil {
            let key = SyncRecordKey(change)
            if resolutions[key] == .acceptRemote {
                result[key.entityType]?.removeValue(forKey: key.recordID)
            }
        }
        return result
    }

    static func mergeDictationSession(
        _ remote: DictationSessionSnapshot,
        into local: DictationSession
    ) {
        let localUpdatedAt = local.updatedAt
        if remote.updatedAt >= localUpdatedAt {
            local.title = remote.title
            local.typeRawValue = remote.typeRawValue
            local.createdAt = remote.createdAt
            local.scheduledDate = remote.scheduledDate
        }
        local.finishedAt = latest(local.finishedAt, remote.finishedAt)
        local.reviewedAt = latest(local.reviewedAt, remote.reviewedAt)
        local.updatedAt = max(localUpdatedAt, remote.updatedAt)
    }

    static func mergeDictationEntry(
        _ remote: DictationEntrySnapshot,
        into local: DictationEntry
    ) {
        let localUpdatedAt = local.updatedAt
        let localResult = DictationResult(rawValue: local.resultRawValue) ?? .pending
        let remoteResult = DictationResult(rawValue: remote.resultRawValue) ?? .pending
        let resolvedResult: DictationResult
        switch (localResult, remoteResult) {
        case (.pending, let remoteValue) where remoteValue != .pending:
            resolvedResult = remoteValue
        case (let localValue, .pending) where localValue != .pending:
            resolvedResult = localValue
        default:
            if remote.updatedAt != localUpdatedAt {
                resolvedResult = remote.updatedAt > localUpdatedAt ? remoteResult : localResult
            } else {
                resolvedResult = remote.resultRawValue > local.resultRawValue ? remoteResult : localResult
            }
        }

        if remote.updatedAt >= localUpdatedAt {
            local.sessionID = remote.sessionID
            local.sortOrder = remote.sortOrder
            local.typeRawValue = remote.typeRawValue
            local.content = remote.content
            local.prompt = remote.prompt
            local.note = remote.note
            local.source = remote.source
            local.createdAt = remote.createdAt
        }
        local.resultRawValue = resolvedResult.rawValue
        local.updatedAt = max(localUpdatedAt, remote.updatedAt)
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case (.some(let value), .none), (.none, .some(let value)): return value
        case (.some(let lhs), .some(let rhs)): return max(lhs, rhs)
        }
    }

    private func modelsByID<Model: PersistentModel>(
        _ models: [Model],
        id: KeyPath<Model, UUID>
    ) -> [UUID: Model] {
        var result: [UUID: Model] = [:]
        for model in models {
            result[model[keyPath: id]] = model
        }
        return result
    }

    private func apply<Snapshot: Decodable, Model: PersistentModel>(
        _ change: ServerChange,
        deleting: Bool,
        as type: Snapshot.Type,
        in context: ModelContext,
        cache: inout [UUID: Model],
        makeModel: (Snapshot) -> Model,
        updateModel: (Snapshot, Model) -> Void
    ) throws {
        if deleting {
            if let existing = cache.removeValue(forKey: change.recordID) {
                context.delete(existing)
            }
            return
        }

        let value = try change.decodePayload(type)
        if let existing = cache[change.recordID] {
            updateModel(value, existing)
            return
        }

        let model = makeModel(value)
        context.insert(model)
        cache[change.recordID] = model
    }

    func scheduleUpload(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore,
        delayNanoseconds: UInt64 = 700_000_000
    ) {
        guard isEnabled, !isApplyingRemoteSnapshot else { return }
        uploadTask?.cancel()
        uploadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.uploadChanges(from: modelContext, settingsStore: settingsStore)
        }
    }

    @discardableResult
    func uploadChanges(
        from modelContext: ModelContext,
        settingsStore: AppSettingsStore
    ) async -> Bool {
        guard isEnabled, !isApplyingRemoteSnapshot, !isPulling, !isUploading else { return false }
        guard let baseline = loadBaseline() else { return false }
        isUploading = true
        activeSyncPhase = "正在上传数据"
        defer {
            activeSyncPhase = nil
            isUploading = false
        }
        do {
            let container = modelContext.container
            let settings = settingsStore.snapshot
            let baseCursor = loadChangeCursor()
            let preparedUpload = try await Task.detached(priority: .utility) {
                try Self.prepareUpload(
                    from: container,
                    settings: settings,
                    baseline: baseline,
                    baseCursor: baseCursor
                )
            }.value
            guard !preparedUpload.bodies.isEmpty else {
                lastErrorDescription = nil
                return true
            }

            for body in preparedUpload.bodies {
                try Task.checkCancellation()
                try await ServerAPIClient.shared.pushMutations(body)
            }
            saveBaseline(preparedUpload.hashes)
            lastErrorDescription = nil
            lastSuccessfulUploadAt = .now
            return true
        } catch where Self.isCancellation(error) {
            return false
        } catch {
            if case ServerAPIError.rejected(let statusCode, let message) = error,
               statusCode == 409,
               message.contains("sync_record_changed") {
                lastErrorDescription = "检测到其他设备刚刚更新了同一条数据，本机记录已保留。请再次下拉刷新完成合并。"
            } else {
                lastErrorDescription = error.localizedDescription
            }
            #if DEBUG
            print("Server upload failed: \(error)")
            #endif
            return false
        }
    }

    nonisolated private static func prepareUpload(
        from container: ModelContainer,
        settings: AppSettingsSnapshot,
        baseline: [String: [String: String]],
        baseCursor: Int64?
    ) throws -> PreparedServerUpload {
        let context = ModelContext(container)
        let payload = try DataBackupPayload.capture(
            from: context,
            settings: settings,
            mediaAssets: []
        )
        let snapshot = try StructuredSnapshot(payload: payload)
        let mutations = try snapshot.mutations(comparedWith: baseline)
        var bodies: [Data] = []
        bodies.reserveCapacity((mutations.count + 499) / 500)
        for batchStart in stride(from: 0, to: mutations.count, by: 500) {
            let batchEnd = min(batchStart + 500, mutations.count)
            var body: [String: Any] = [
                "mutations": Array(mutations[batchStart..<batchEnd])
            ]
            if let baseCursor {
                body["baseCursor"] = baseCursor
            }
            bodies.append(
                try JSONSerialization.data(
                    withJSONObject: body,
                    options: [.sortedKeys]
                )
            )
        }
        return PreparedServerUpload(bodies: bodies, hashes: snapshot.hashes)
    }

    nonisolated static func requiresSnapshotRestore(
        remoteHashes: [String: [String: String]],
        baseline: [String: [String: String]]?
    ) -> Bool {
        guard let baseline else { return true }
        return remoteHashes != baseline
    }

    private static func dataSummary(for payload: DataBackupPayload) -> String {
        "题库 \(payload.reviewItems.count) 条，复习记录 \(payload.reviewRecords.count) 条，听写 \(payload.dictationSessions.count) 组 / \(payload.dictationEntries.count) 条，计算 \(payload.calculationRounds.count) 轮"
    }

    private func synchronizeDeepSeekAPIKey() async {
        do {
            let remote = try await ServerAPIClient.shared.deepSeekAPIKey()
            if let value = remote.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                try DeepSeekAPIKeyStore.saveAPIKey(value)
                return
            }

            let local = try DeepSeekAPIKeyStore.loadAPIKey()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !local.isEmpty {
                _ = try await ServerAPIClient.shared.saveDeepSeekAPIKey(local)
            }
        } catch {
            #if DEBUG
            print("DeepSeek API Key sync failed: \(error)")
            #endif
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private static func userFacingDescription(for error: Error, phase: String?) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return "\(phase ?? "服务器请求")超时。请切换 Wi‑Fi/蜂窝网络后重试；本机数据不会因此丢失。"
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            return "当前网络不可用，请恢复网络后重试。"
        }
        return error.localizedDescription
    }

    private func installServerDailyPlan(
        in container: ModelContainer,
        dailyLimit: Int
    ) async throws -> Bool {
        let dayKey = ReviewDailyPlan.dayKey(for: .now)
        let serverPlan = try await ServerAPIClient.shared.dailyPlan(
            day: dayKey,
            dailyLimit: dailyLimit
        )
        return try PersistentStoreAccessGate.withAccess {
            // The restore context must not be kept alive across the network
            // request above. Use another fresh context so its store generation
            // includes the completed snapshot replacement.
            let modelContext = ModelContext(container)
            modelContext.autosaveEnabled = false
            let plans = try modelContext.fetch(
                FetchDescriptor<ReviewDailyPlan>(
                    predicate: #Predicate<ReviewDailyPlan> { $0.dayKey == dayKey }
                )
            )
            if plans.count == 1,
               let existingPlan = plans.first,
               existingPlan.id == serverPlan.id,
               existingPlan.itemIDs == serverPlan.items.map(\.itemID),
               existingPlan.createdAt == serverPlan.createdAt,
               existingPlan.updatedAt == serverPlan.updatedAt {
                return false
            }

            if let existingPlan = plans.first {
                existingPlan.id = serverPlan.id
                existingPlan.dayKey = serverPlan.day
                existingPlan.itemIDs = serverPlan.items.map(\.itemID)
                existingPlan.createdAt = serverPlan.createdAt
                existingPlan.updatedAt = serverPlan.updatedAt
                plans.dropFirst().forEach(modelContext.delete)
            } else {
                modelContext.insert(
                    ReviewDailyPlan(
                    id: serverPlan.id,
                    dayKey: serverPlan.day,
                    itemIDs: serverPlan.items.map(\.itemID),
                    createdAt: serverPlan.createdAt,
                    updatedAt: serverPlan.updatedAt
                    )
                )
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
            return true
        }
    }

    private func loadBaseline() -> [String: [String: String]]? {
        guard let data = UserDefaults.standard.data(forKey: Self.baselineDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    private func loadChangeCursor() -> Int64? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.changeCursorDefaultsKey) != nil else { return nil }
        return defaults.object(forKey: Self.changeCursorDefaultsKey) as? Int64
            ?? Int64(defaults.integer(forKey: Self.changeCursorDefaultsKey))
    }

    private func saveChangeCursor(_ cursor: Int64) {
        UserDefaults.standard.set(cursor, forKey: Self.changeCursorDefaultsKey)
    }

    private func saveBaseline(_ baseline: [String: [String: String]]) {
        if let data = try? JSONEncoder().encode(baseline) {
            UserDefaults.standard.set(data, forKey: Self.baselineDefaultsKey)
        }
    }

    struct StructuredSnapshot {
        private static let timestampFields: [String: String] = [
            "reviewItems": "updatedAt",
            "reviewRecords": "reviewedAt",
            "taskItems": "updatedAt",
            "taskCompletions": "completedAt",
            "taskSubitems": "updatedAt",
            "taskExecutionRecords": "updatedAt",
            "taskSubitemExecutionRecords": "updatedAt",
            "dictationSessions": "updatedAt",
            "dictationEntries": "updatedAt",
            "scheduleItems": "updatedAt",
            "calculationRounds": "updatedAt",
            "pointLedgerEntries": "createdAt",
            "pointRewardStates": "updatedAt",
            "settings": "updatedAt",
        ]

        let records: [String: [String: [String: Any]]]
        let hashes: [String: [String: String]]

        static func timestamp(
            in record: [String: Any],
            entityType: String
        ) -> Date? {
            guard let field = timestampFields[entityType],
                  let value = record[field] as? String,
                  let data = try? JSONEncoder().encode(value) else {
                return nil
            }
            return try? JSONDecoder.typoReviewISO8601.decode(Date.self, from: data)
        }

        static func remoteRecordWinsConflict(
            entityType: String,
            local: [String: Any],
            remote: [String: Any]
        ) -> Bool {
            let localTimestamp = timestamp(in: local, entityType: entityType)
            let remoteTimestamp = timestamp(in: remote, entityType: entityType)
            if localTimestamp != remoteTimestamp {
                return (remoteTimestamp ?? .distantPast) > (localTimestamp ?? .distantPast)
            }

            // Equal edit times still need a deterministic winner so all devices
            // converge on the same payload after reconnecting.
            guard let localData = try? JSONSerialization.data(
                withJSONObject: local,
                options: [.sortedKeys]
            ), let remoteData = try? JSONSerialization.data(
                withJSONObject: remote,
                options: [.sortedKeys]
            ) else {
                return false
            }
            return localData.lexicographicallyPrecedes(remoteData)
        }

        init(payload: DataBackupPayload) throws {
            let data = try payload.encodedData()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ServerAPIError.invalidResponse
            }
            var records: [String: [String: [String: Any]]] = [:]
            for entity in ServerSyncCoordinator.entityOrder {
                let values: [[String: Any]]
                if entity == "settings" {
                    values = (root["settings"] as? [String: Any]).map { [$0] } ?? []
                } else {
                    values = root[entity] as? [[String: Any]] ?? []
                }
                records[entity] = try Self.deduplicated(
                    values,
                    timestampField: Self.timestampFields[entity]
                )
            }
            self.records = records
            hashes = try records.mapValues { values in
                try values.mapValues { value in
                    let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
                }
            }
        }

        func mutations(comparedWith baseline: [String: [String: String]]) throws -> [[String: Any]] {
            let timestamp = ISO8601DateFormatter().string(from: .now)
            var mutations: [[String: Any]] = []
            for entity in ServerSyncCoordinator.entityOrder {
                let currentRecords = records[entity] ?? [:]
                let currentHashes = hashes[entity] ?? [:]
                let previousHashes = baseline[entity] ?? [:]

                for id in currentRecords.keys.sorted() where currentHashes[id] != previousHashes[id] {
                    mutations.append([
                        "mutationID": UUID().uuidString,
                        "entityType": entity,
                        "recordID": id,
                        "operation": "upsert",
                        "updatedAt": timestamp,
                        "payload": currentRecords[id]!,
                    ])
                }
                // A missing local record is not proof that the user explicitly
                // deleted it. The local store can be incomplete during a schema
                // migration, restore, reinstall, or multi-device bootstrap. The
                // previous implementation inferred deletes here and could erase
                // a complete server snapshot from one partial device. Explicit
                // deletion tombstones must use a separate protocol instead.
            }
            return mutations
        }

        private static func deduplicated(
            _ values: [[String: Any]],
            timestampField: String?
        ) throws -> [String: [String: Any]] {
            var result: [String: [String: Any]] = [:]
            for value in values {
                guard let id = value["id"] as? String else { continue }
                guard let existing = result[id] else {
                    result[id] = value
                    continue
                }

                let existingTimestamp = timestampField.flatMap { existing[$0] as? String } ?? ""
                let candidateTimestamp = timestampField.flatMap { value[$0] as? String } ?? ""
                if candidateTimestamp != existingTimestamp {
                    if candidateTimestamp > existingTimestamp {
                        result[id] = value
                    }
                    continue
                }

                // Equal timestamps still need a stable winner so every device hashes
                // the same physical duplicates in the same way.
                let existingData = try JSONSerialization.data(
                    withJSONObject: existing,
                    options: [.sortedKeys]
                )
                let candidateData = try JSONSerialization.data(
                    withJSONObject: value,
                    options: [.sortedKeys]
                )
                if existingData.lexicographicallyPrecedes(candidateData) {
                    result[id] = value
                }
            }
            return result
        }
    }
}

private extension ServerChange {
    func payloadDictionary() throws -> [String: Any] {
        guard let payload else { throw ServerAPIError.invalidResponse }
        let data = try JSONEncoder().encode(payload)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServerAPIError.invalidResponse
        }
        return value
    }
}

private struct PreparedServerUpload: Sendable {
    let bodies: [Data]
    let hashes: [String: [String: String]]
}
