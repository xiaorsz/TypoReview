import CloudKit
import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SyncStatusStore {
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

    func configure(cloudKitEnabled: Bool, containerIdentifier: String? = nil, initializationError: String = "") {
        self.cloudKitEnabled = cloudKitEnabled
        self.containerIdentifier = containerIdentifier ?? fallbackContainerIdentifier
        self.cloudKitInitializationError = initializationError
        refreshBuildDiagnostics()
    }

    func refresh(using modelContext: ModelContext, trigger: Trigger) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        lastTrigger = trigger
        lastErrorMessage = ""
        localDataSummary = "检查中..."

        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }

            modelContext.processPendingChanges()
            let reviewItemCount = try modelContext.fetchCount(FetchDescriptor<ReviewItem>())
            let reviewRecordCount = try modelContext.fetchCount(FetchDescriptor<ReviewRecord>())
            let taskCount = try modelContext.fetchCount(FetchDescriptor<TaskItem>())
            let scheduleCount = try modelContext.fetchCount(FetchDescriptor<ScheduleItem>())
            let settingsCount = try modelContext.fetchCount(FetchDescriptor<AppSettings>())
            let dictationSessionCount = try modelContext.fetchCount(FetchDescriptor<DictationSession>())
            let dictationEntryCount = try modelContext.fetchCount(FetchDescriptor<DictationEntry>())

            localDataSummary = "题库 \(reviewItemCount) 条，记录 \(reviewRecordCount) 条，待办 \(taskCount) 条，日程 \(scheduleCount) 条，听写 \(dictationSessionCount) 组 / \(dictationEntryCount) 条，设置 \(settingsCount) 条"
            lastRefreshAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
            localDataSummary = "本地数据检查失败"
        }

        await refreshCloudAccountState()
        isRefreshing = false
    }

    private func refreshCloudAccountState() async {
        guard cloudKitEnabled else {
            cloudAccountState = .couldNotDetermine("当前运行的是本地存储模式，CloudKit 没有启用。")
            return
        }

        do {
            let status = try await CKContainer(identifier: containerIdentifier).accountStatus()
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
}
