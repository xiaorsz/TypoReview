import CloudKit
import CoreData
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SyncStatusStore {
    private enum RefreshError: Error {
        case cloudAccountStatusTimeout
    }

    private struct LocalDataCounts {
        let reviewItemCount: Int
        let reviewRecordCount: Int
        let taskCount: Int
        let scheduleCount: Int
        let dictationSessionCount: Int
        let dictationEntryCount: Int

        var summaryText: String {
            "题库 \(reviewItemCount) 条，记录 \(reviewRecordCount) 条，待办 \(taskCount) 条，日程 \(scheduleCount) 条，听写 \(dictationSessionCount) 组 / \(dictationEntryCount) 条"
        }
    }

    private struct LocalDataSummaryResult {
        let counts: LocalDataCounts?
        let errorDescription: String?
    }

    enum SyncNoticeKind {
        case checking
        case ready
        case caution
        case blocked
    }

    enum CloudAccountState {
        case unknown
        case available
        case noAccount
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine(String)

        var title: String {
            switch self {
            case .unknown:
                return "未检查"
            case .available:
                return "可用"
            case .noAccount:
                return "未登录 iCloud"
            case .restricted:
                return "受限"
            case .temporarilyUnavailable:
                return "暂时不可用"
            case .couldNotDetermine:
                return "检查失败"
            }
        }

        var detail: String {
            switch self {
            case .unknown:
                return "还没有进行 CloudKit 账户检查。"
            case .available:
                return "当前 Apple ID 可以访问 CloudKit。"
            case .noAccount:
                return "这台设备没有登录 iCloud，或当前账号未启用 iCloud。"
            case .restricted:
                return "系统限制了 CloudKit 访问，常见于家长控制或企业设备策略。"
            case .temporarilyUnavailable:
                return "CloudKit 当前暂时不可用，可以稍后再试一次。"
            case .couldNotDetermine(let message):
                return message
            }
        }
    }

    enum Trigger {
        case launch
        case foreground
        case manual
    }

    private let fallbackContainerIdentifier = "iCloud.cc.xiaorsz.typo-review"

    struct CloudKitSyncEvent: Identifiable {
        let id = UUID()
        let timestamp: Date
        let typeName: String
        let succeeded: Bool
        let errorDescription: String?
    }

    private struct CloudKitWriteProbe {
        let label: String
        let recordType: String
        let populateRecord: (CKRecord, UUID) -> Void
    }

    private struct CloudKitWriteProbeResult {
        let label: String
        let recordType: String
        let succeeded: Bool
        let detail: String
    }

    var isRefreshing = false
    var lastRefreshAt: Date?
    var lastErrorMessage = ""
    var lastTrigger: Trigger = .launch
    var cloudKitEnabled = false
    var containerIdentifier = "iCloud.cc.xiaorsz.typo-review"
    var cloudAccountState: CloudAccountState = .unknown
    var localDataSummary = "尚未检查本地数据"
    var cloudKitInitializationError = ""
    var cloudKitEnvironment = "未检查"
    var apsEnvironment = "未检查"
    var recentCloudKitEvents: [CloudKitSyncEvent] = []
    var cloudKitDirectTestResult = ""
    var isTestingCloudKit = false
    private var cloudKitEventObserver: NSObjectProtocol?

    func configure(cloudKitEnabled: Bool, containerIdentifier: String? = nil, initializationError: String = "") {
        self.cloudKitEnabled = cloudKitEnabled
        self.containerIdentifier = containerIdentifier ?? fallbackContainerIdentifier
        self.cloudKitInitializationError = initializationError
        refreshBuildDiagnostics()
        startMonitoringCloudKitEvents()
    }

    func refresh(using modelContext: ModelContext, trigger: Trigger) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        lastTrigger = trigger
        lastErrorMessage = ""
        localDataSummary = "检查中..."

        #if DEBUG
        DebugPerf.mark("SyncStatusStore refresh begin trigger=\(trigger)")
        DebugPerf.watchMainThread("SyncStatusStore refresh \(trigger)")
        #endif

        let summaryResult = await fetchLocalDataSummary(using: modelContext.container)
        if let counts = summaryResult.counts {
            localDataSummary = counts.summaryText
            lastRefreshAt = .now
        } else {
            lastErrorMessage = summaryResult.errorDescription ?? "未知错误"
            localDataSummary = "本地数据检查失败"
        }

        await refreshCloudAccountState()

        #if DEBUG
        DebugPerf.mark("SyncStatusStore refresh end trigger=\(trigger) localSummary=\(localDataSummary)")
        #endif
    }

    private func fetchLocalDataSummary(using container: ModelContainer) async -> LocalDataSummaryResult {
        #if DEBUG
        DebugPerf.mark("SyncStatusStore local summary fetch begin")
        #endif

        let result = await Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)

            do {
                let counts = LocalDataCounts(
                    reviewItemCount: try backgroundContext.fetchCount(FetchDescriptor<ReviewItem>()),
                    reviewRecordCount: try backgroundContext.fetchCount(FetchDescriptor<ReviewRecord>()),
                    taskCount: try backgroundContext.fetchCount(FetchDescriptor<TaskItem>()),
                    scheduleCount: try backgroundContext.fetchCount(FetchDescriptor<ScheduleItem>()),
                    dictationSessionCount: try backgroundContext.fetchCount(FetchDescriptor<DictationSession>()),
                    dictationEntryCount: try backgroundContext.fetchCount(FetchDescriptor<DictationEntry>())
                )
                return LocalDataSummaryResult(counts: counts, errorDescription: nil)
            } catch {
                return LocalDataSummaryResult(counts: nil, errorDescription: error.localizedDescription)
            }
        }.value

        #if DEBUG
        if let counts = result.counts {
            DebugPerf.mark("SyncStatusStore local summary fetch end success reviews=\(counts.reviewItemCount) records=\(counts.reviewRecordCount) tasks=\(counts.taskCount) schedules=\(counts.scheduleCount) sessions=\(counts.dictationSessionCount) entries=\(counts.dictationEntryCount)")
        } else {
            DebugPerf.mark("SyncStatusStore local summary fetch end failed error=\(result.errorDescription ?? "unknown")")
        }
        #endif

        return result
    }

    private func refreshCloudAccountState() async {
        guard cloudKitEnabled else {
            cloudAccountState = .couldNotDetermine("当前运行的是本地存储模式，CloudKit 没有启用。")
            return
        }

        do {
            let containerIdentifier = containerIdentifier
            let status = try await withThrowingTaskGroup(of: CKAccountStatus.self) { group in
                group.addTask {
                    try await CKContainer(identifier: containerIdentifier).accountStatus()
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw RefreshError.cloudAccountStatusTimeout
                }

                guard let status = try await group.next() else {
                    throw RefreshError.cloudAccountStatusTimeout
                }
                group.cancelAll()
                return status
            }

            switch status {
            case .available:
                cloudAccountState = .available
            case .noAccount:
                cloudAccountState = .noAccount
            case .restricted:
                cloudAccountState = .restricted
            case .temporarilyUnavailable:
                cloudAccountState = .temporarilyUnavailable
            case .couldNotDetermine:
                cloudAccountState = .couldNotDetermine("系统无法确定 CloudKit 账户状态。")
            @unknown default:
                cloudAccountState = .couldNotDetermine("遇到了未知的 CloudKit 账户状态。")
            }
        } catch RefreshError.cloudAccountStatusTimeout {
            cloudAccountState = .couldNotDetermine("CloudKit 账户检查超过 5 秒，已停止等待。")
        } catch {
            cloudAccountState = .couldNotDetermine(error.localizedDescription)
        }
    }

    var statusText: String {
        if isRefreshing {
            return "同步中..."
        }

        if !lastErrorMessage.isEmpty {
            return "同步检查失败"
        }

        guard let lastRefreshAt else {
            return "等待首次同步检查"
        }

        return "最近同步检查 \(lastRefreshAt.formatted(date: .omitted, time: .shortened))"
    }

    var detailText: String {
        if !lastErrorMessage.isEmpty {
            return lastErrorMessage
        }

        switch lastTrigger {
        case .launch:
            return "App 启动后会自动检查一次同步状态。"
        case .foreground:
            return "每次回到前台都会自动检查一次同步状态。"
        case .manual:
            return "这是你刚刚手动触发的一次同步检查。"
        }
    }

    var cloudKitModeText: String {
        cloudKitEnabled ? "CloudKit 已启用" : "CloudKit 未启用"
    }

    var cloudAccountTitle: String {
        cloudAccountState.title
    }

    var cloudAccountDetail: String {
        cloudAccountState.detail
    }

    var isUsingLocalFallback: Bool {
        !cloudKitEnabled
    }

    var storageModeTitle: String {
        isUsingLocalFallback ? "已退回本地存储" : "CloudKit 同步存储"
    }

    var storageModeDetail: String {
        if isUsingLocalFallback {
            return "这台设备当前只保存在本机，不会把改动同步到其他设备。"
        }
        return "这台设备当前使用 CloudKit 存储，具备参与多设备同步的前提。"
    }

    var syncNoticeKind: SyncNoticeKind {
        if isRefreshing || lastRefreshAt == nil {
            return .checking
        }

        if !cloudKitEnabled {
            return .blocked
        }

        switch cloudAccountState {
        case .available:
            return .ready
        case .temporarilyUnavailable, .unknown:
            return .caution
        case .noAccount, .restricted, .couldNotDetermine:
            return .blocked
        }
    }

    var syncNoticeTitle: String {
        switch syncNoticeKind {
        case .checking:
            return "这台设备的同步状态还在检查中"
        case .ready:
            return "这台设备的同步前提看起来正常"
        case .caution:
            return "这台设备的同步现在不太稳定"
        case .blocked:
            return "这台设备当前不会和别的设备同步"
        }
    }

    var syncNoticeMessage: String {
        if !cloudKitEnabled {
            return "当前已经退回本地存储模式。除非 CloudKit 初始化恢复成功，否则这台设备上的改动不会同步到 iPad 或 iPhone。"
        }

        switch cloudAccountState {
        case .unknown:
            return "请点一次“立即检查”，确认这台设备有没有真正连上 iCloud。"
        case .available:
            return "CloudKit 已启用，iCloud 账户也可用。这只说明同步前提正常，不代表最近的云端上传、下载已经成功完成。"
        case .noAccount:
            return "这台设备没有登录 iCloud，或者当前 Apple ID 没有开启 iCloud，所以它不会收到别的设备的数据。"
        case .restricted:
            return "系统限制了这台设备访问 iCloud，常见于家长控制、企业设备策略，或者系统层面的云服务限制。"
        case .temporarilyUnavailable:
            return "iCloud 当前暂时不可用。通常等一会儿、切一下网络，或者把 App 重新拉到前台后会恢复。"
        case .couldNotDetermine(let message):
            return "系统没能确认这台设备的 CloudKit 状态。\(message)"
        }
    }

    // MARK: - CloudKit Event Monitoring

    private func startMonitoringCloudKitEvents() {
        guard cloudKitEnabled else { return }
        guard cloudKitEventObserver == nil else { return }

        cloudKitEventObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSPersistentCloudKitContainerEventChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleCloudKitEvent(notification)
            }
        }
    }

    private func handleCloudKitEvent(_ notification: Notification) {
        guard let event = notification.userInfo?["event"] as? NSObject else { return }

        let endDate = event.value(forKey: "endDate") as? Date
        guard endDate != nil else { return }

        let typeRawValue = (event.value(forKey: "type") as? Int) ?? -1
        let typeName: String
        switch typeRawValue {
        case 0: typeName = "初始化"
        case 1: typeName = "下载"
        case 2: typeName = "上传"
        default: typeName = "未知(\(typeRawValue))"
        }

        let succeeded = (event.value(forKey: "succeeded") as? Bool) ?? false
        let error = event.value(forKey: "error") as? NSError

        let errorDetail: String? = error.map { Self.deepErrorDescription($0) }

        let syncEvent = CloudKitSyncEvent(
            timestamp: endDate ?? Date(),
            typeName: typeName,
            succeeded: succeeded,
            errorDescription: errorDetail
        )

        recentCloudKitEvents.insert(syncEvent, at: 0)
        if recentCloudKitEvents.count > 50 {
            recentCloudKitEvents = Array(recentCloudKitEvents.prefix(50))
        }
    }

    private static func deepErrorDescription(_ error: NSError, depth: Int = 0) -> String {
        let prefix = depth > 0 ? String(repeating: "  ", count: depth) + "↳ " : ""
        var parts: [String] = []

        // Main error info
        parts.append("\(prefix)[\(error.domain) \(error.code)] \(error.localizedDescription)")

        // CKError specific info
        if error.domain == "CKErrorDomain" || error.domain == CKError.errorDomain {
            // Retry after hint
            if let retryAfter = error.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
                parts.append("\(prefix)  重试等待: \(Int(retryAfter))秒")
            }

            // Partial errors (CKError.partialFailure contains per-item errors)
            if let partialErrors = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: NSError] {
                let sample = partialErrors.prefix(3)
                for (key, subError) in sample {
                    parts.append("\(prefix)  子错误[\(key)]: [\(subError.domain) \(subError.code)] \(subError.localizedDescription)")
                }
                if partialErrors.count > 3 {
                    parts.append("\(prefix)  ...还有 \(partialErrors.count - 3) 个子错误")
                }
            }
        }

        // Underlying error chain
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(deepErrorDescription(underlying, depth: depth + 1))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - CloudKit Direct Test

    func testCloudKitDirectly() async {
        isTestingCloudKit = true
        cloudKitDirectTestResult = "检查中..."
        defer { isTestingCloudKit = false }

        guard cloudKitEnabled else {
            cloudKitDirectTestResult = "❌ CloudKit 未启用"
            return
        }

        do {
            let ckContainer = CKContainer(identifier: containerIdentifier)
            let database = ckContainer.privateCloudDatabase

            // 1. Check account status
            let accountStatus = try await ckContainer.accountStatus()
            let accountLabel: String
            switch accountStatus {
            case .available: accountLabel = "✅ 可用"
            case .noAccount: accountLabel = "❌ 未登录 iCloud"
            case .restricted: accountLabel = "⚠️ 受限"
            case .temporarilyUnavailable: accountLabel = "⚠️ 暂时不可用"
            case .couldNotDetermine: accountLabel = "⚠️ 无法确定"
            @unknown default: accountLabel = "⚠️ 未知(\(accountStatus.rawValue))"
            }

            var lines: [String] = ["iCloud 账户: \(accountLabel)"]

            // 2. Check zones
            let zones = try await database.allRecordZones()
            let cdZone = zones.first(where: {
                $0.zoneID.zoneName == "com.apple.coredata.cloudkit.zone"
            })

            if let cdZone = cdZone {
                lines.append("✅ CoreData 同步区域存在")
                let baseResults = await Self.runCloudKitWriteProbes(
                    Self.baseCloudKitWriteProbes(),
                    database: database,
                    zoneID: cdZone.zoneID
                )
                let taskResults = await Self.runCloudKitWriteProbes(
                    Self.taskCloudKitWriteProbes(),
                    database: database,
                    zoneID: cdZone.zoneID
                )

                lines.insert(
                    Self.cloudKitDirectTestSummary(
                        accountStatus: accountStatus,
                        baseResults: baseResults,
                        taskResults: taskResults
                    ),
                    at: 0
                )
                lines.append("")
                lines.append("基础模型检查")
                lines.append(contentsOf: Self.formattedProbeLines(for: baseResults))
                lines.append("")
                lines.append("任务系统新模型检查")
                lines.append(contentsOf: Self.formattedProbeLines(for: taskResults))
            } else {
                let zoneNames = zones.map(\.zoneID.zoneName).joined(separator: ", ")
                lines.insert("❌ 找不到 CoreData 同步区域，当前无法判断具体是哪类模型上传失败。", at: 0)
                lines.append("可用区域: \(zoneNames)")
            }

            cloudKitDirectTestResult = lines.joined(separator: "\n")
        } catch {
            let nsError = error as NSError
            cloudKitDirectTestResult = "❌ 连接失败: [\(nsError.domain) \(nsError.code)] \(nsError.localizedDescription)"
        }
    }

    // MARK: - Force Sync

    func triggerForcePush(using modelContext: ModelContext) {
        let dummyRecord = ReviewRecord(
            itemID: UUID(),
            reviewedAt: .distantPast,
            result: .correct,
            mode: .scheduled,
            oldStage: 0,
            newStage: 0,
            note: "__sync_test__"
        )
        modelContext.insert(dummyRecord)
        try? modelContext.save()
        modelContext.delete(dummyRecord)
        try? modelContext.save()
    }

    func purgePersistentHistoryAndReset(using modelContext: ModelContext) -> String {
        let container = modelContext.container
        let purgeRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: Date())

        do {
            let bgContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            // Access the underlying CoreData coordinator through the container
            let mirror = Mirror(reflecting: container)
            for child in mirror.children {
                if let coordinator = child.value as? NSPersistentStoreCoordinator {
                    bgContext.persistentStoreCoordinator = coordinator
                    try bgContext.execute(purgeRequest)
                    return "✅ 同步历史已清除。请完全退出 App（从后台滑掉），然后重新打开。"
                }
            }

            // Fallback: try to find a .sqlite file and use its store
            let storeURL = container.configurations.first?.url
            if let url = storeURL {
                return "⚠️ 无法直接访问 coordinator。请手动删除 App 重装来重置同步状态。\n存储路径: \(url.lastPathComponent)"
            }
            return "⚠️ 无法获取 store coordinator。请手动删除 App 并从 TestFlight 重装。"
        } catch {
            return "❌ 清除失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Build Diagnostics

    private func refreshBuildDiagnostics() {
        if let receiptName = Bundle.main.appStoreReceiptURL?.lastPathComponent {
            switch receiptName {
            case "sandboxReceipt":
                cloudKitEnvironment = "sandboxReceipt（TestFlight 或开发安装都可能出现）"
            case "receipt":
                cloudKitEnvironment = "receipt（更像正式分发）"
            default:
                cloudKitEnvironment = receiptName
            }
        } else {
            cloudKitEnvironment = "未知"
        }

#if DEBUG
        apsEnvironment = "Debug 构建"
#else
        apsEnvironment = "Release 构建"
#endif
    }

    private static func baseCloudKitWriteProbes() -> [CloudKitWriteProbe] {
        [
            CloudKitWriteProbe(label: "复习记录", recordType: "CD_ReviewRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_itemID"] = UUID().uuidString as CKRecordValue
                record["CD_reviewedAt"] = Date() as CKRecordValue
                record["CD_resultRawValue"] = ReviewResult.correct.rawValue as CKRecordValue
                record["CD_modeRawValue"] = ReviewMode.scheduled.rawValue as CKRecordValue
                record["CD_oldStage"] = NSNumber(value: 0)
                record["CD_newStage"] = NSNumber(value: 0)
                record["CD_note"] = "__cloudkit_probe__" as CKRecordValue
            }
        ]
    }

    private static func taskCloudKitWriteProbes() -> [CloudKitWriteProbe] {
        [
            CloudKitWriteProbe(label: "任务执行记录", recordType: "CD_TaskExecutionRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_taskID"] = UUID().uuidString as CKRecordValue
                record["CD_occurrenceDate"] = Date() as CKRecordValue
                record["CD_detail"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "任务子项", recordType: "CD_TaskSubitem") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_parentTaskID"] = UUID().uuidString as CKRecordValue
                record["CD_taskExecutionIDRawValue"] = "" as CKRecordValue
                record["CD_title"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_note"] = "" as CKRecordValue
                record["CD_detail"] = "" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_sortOrder"] = NSNumber(value: 0)
                record["CD_isArchived"] = NSNumber(value: false)
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            },
            CloudKitWriteProbe(label: "任务子项执行记录", recordType: "CD_TaskSubitemExecutionRecord") { record, testID in
                record["CD_id"] = testID.uuidString as CKRecordValue
                record["CD_taskExecutionID"] = UUID().uuidString as CKRecordValue
                record["CD_subtaskID"] = UUID().uuidString as CKRecordValue
                record["CD_detail"] = "__cloudkit_probe__" as CKRecordValue
                record["CD_statusRawValue"] = TaskExecutionStatus.pending.rawValue as CKRecordValue
                record["CD_createdAt"] = Date() as CKRecordValue
                record["CD_updatedAt"] = Date() as CKRecordValue
            }
        ]
    }

    private static func runCloudKitWriteProbes(
        _ probes: [CloudKitWriteProbe],
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async -> [CloudKitWriteProbeResult] {
        var results: [CloudKitWriteProbeResult] = []
        for probe in probes {
            let result = await runCloudKitWriteProbe(probe, database: database, zoneID: zoneID)
            results.append(result)
        }
        return results
    }

    private static func runCloudKitWriteProbe(
        _ probe: CloudKitWriteProbe,
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async -> CloudKitWriteProbeResult {
        let testID = UUID()
        let recordID = CKRecord.ID(
            recordName: "diag.\(probe.recordType).\(testID.uuidString)",
            zoneID: zoneID
        )
        let record = CKRecord(recordType: probe.recordType, recordID: recordID)
        probe.populateRecord(record, testID)

        do {
            let savedRecord = try await database.save(record)
            do {
                try await database.deleteRecord(withID: savedRecord.recordID)
                return CloudKitWriteProbeResult(
                    label: probe.label,
                    recordType: probe.recordType,
                    succeeded: true,
                    detail: "写入和删除测试记录都成功。"
                )
            } catch {
                return CloudKitWriteProbeResult(
                    label: probe.label,
                    recordType: probe.recordType,
                    succeeded: true,
                    detail: "写入成功，但清理测试记录失败：\((error as NSError).localizedDescription)"
                )
            }
        } catch {
            let nsError = error as NSError
            return CloudKitWriteProbeResult(
                label: probe.label,
                recordType: probe.recordType,
                succeeded: false,
                detail: deepErrorDescription(nsError)
            )
        }
    }

    private static func cloudKitDirectTestSummary(
        accountStatus: CKAccountStatus,
        baseResults: [CloudKitWriteProbeResult],
        taskResults: [CloudKitWriteProbeResult]
    ) -> String {
        let accountAvailable = accountStatus == .available
        let baseFailures = baseResults.filter { !$0.succeeded }
        let taskFailures = taskResults.filter { !$0.succeeded }

        guard accountAvailable else {
            return "❌ iCloud 账户当前不可用，先解决账号或系统层限制。"
        }

        if !baseFailures.isEmpty {
            return "❌ 基础 CloudKit 模型也不可写，问题不只在新 schema。"
        }

        if !taskFailures.isEmpty {
            return "⚠️ 基础模型可写，但任务系统新模型检查失败，优先检查 CloudKit Production Schema 是否已部署完整。"
        }

        return "✅ 基础模型和任务系统新模型都可写。"
    }

    private static func formattedProbeLines(for results: [CloudKitWriteProbeResult]) -> [String] {
        results.flatMap { result in
            let statusPrefix = result.succeeded ? "✅" : "❌"
            var lines = ["\(statusPrefix) \(result.label)（\(result.recordType)）"]
            if !result.detail.isEmpty {
                lines.append(indentedDetailLines(result.detail))
            }
            return lines
        }
    }

    private static func indentedDetailLines(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}
