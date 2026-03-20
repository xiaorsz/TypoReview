import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class SyncStatusStore {
    enum Trigger {
        case launch
        case foreground
        case manual
    }

    var isRefreshing = false
    var lastRefreshAt: Date?
    var lastErrorMessage = ""
    var lastTrigger: Trigger = .launch

    func refresh(using modelContext: ModelContext, trigger: Trigger) {
        guard !isRefreshing else { return }

        isRefreshing = true
        lastTrigger = trigger
        lastErrorMessage = ""

        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }

            modelContext.processPendingChanges()
            _ = try modelContext.fetchCount(FetchDescriptor<ReviewItem>())
            _ = try modelContext.fetchCount(FetchDescriptor<ReviewRecord>())
            _ = try modelContext.fetchCount(FetchDescriptor<TaskItem>())
            _ = try modelContext.fetchCount(FetchDescriptor<AppSettings>())
            lastRefreshAt = .now
        } catch {
            lastErrorMessage = error.localizedDescription
        }

        isRefreshing = false
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
}
