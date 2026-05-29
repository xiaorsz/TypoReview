
import SwiftUI
import SwiftData
import Observation
import AVFoundation
import AVKit
import WidgetKit
import UIKit

private struct HomeReviewItemProjection: Identifiable, Hashable {
    let id: UUID
    let type: ReviewItemType
    let content: String
    let prompt: String
    let stage: Int
    let createdAt: Date
    let nextReviewAt: Date
    let consecutiveWrongCount: Int

    init(_ item: ReviewItem) {
        id = item.id
        type = item.type
        content = item.content
        prompt = item.prompt
        stage = item.stage
        createdAt = item.createdAt
        nextReviewAt = item.nextReviewAt
        consecutiveWrongCount = item.consecutiveWrongCount
    }

    var isMastered: Bool {
        stage >= ReviewScheduler.intervals.count - 1 && consecutiveWrongCount == 0
    }
}

private struct HomeReviewRecordProjection {
    let itemID: UUID
    let reviewedAt: Date
    let result: ReviewResult

    init(_ record: ReviewRecord) {
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        result = record.result
    }
}

private struct HomeDictationSessionProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let type: ReviewItemType
    let createdAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        type = session.type
        createdAt = session.createdAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
    }

    var isFinished: Bool { finishedAt != nil }
    var isReviewed: Bool { reviewedAt != nil }
}

private struct HomeDictationEntryProjection: Identifiable, Hashable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let type: ReviewItemType
    let content: String
    let prompt: String
    let result: DictationResult

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        type = entry.type
        content = entry.content
        prompt = entry.prompt
        result = entry.result
    }
}

private struct HomeScheduleProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let startTime: Date
    let endTime: Date
    let repeatRule: ScheduleRepeatRule
    let weekdays: [Int]
    let effectiveStartDate: Date
    let effectiveEndDate: Date?
    let isArchived: Bool

    init(_ schedule: ScheduleItem) {
        id = schedule.id
        title = schedule.title
        startTime = schedule.startTime
        endTime = schedule.endTime
        repeatRule = schedule.repeatRule
        weekdays = schedule.weekdays
        effectiveStartDate = schedule.effectiveStartDate
        effectiveEndDate = schedule.effectiveEndDate
        isArchived = schedule.isArchived
    }

    func shouldAppear(on date: Date) -> Bool {
        guard !isArchived else { return false }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let startDay = calendar.startOfDay(for: startTime)
        let effectiveStartDay = calendar.startOfDay(for: effectiveStartDate)
        let effectiveEndDay = effectiveEndDate.map { calendar.startOfDay(for: $0) }

        switch repeatRule {
        case .once:
            return calendar.isDate(targetDay, inSameDayAs: startDay)
        case .daily:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            return true
        case .weekly:
            guard targetDay >= effectiveStartDay else { return false }
            if let effectiveEndDay, targetDay > effectiveEndDay { return false }
            let weekday = calendar.component(.weekday, from: date)
            return weekdays.contains(weekday)
        }
    }

    func timeRangeText(on date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"

        let startComponents = calendar.dateComponents([.hour, .minute], from: startTime)
        let endComponents = calendar.dateComponents([.hour, .minute], from: endTime)
        let displayStart = calendar.date(
            bySettingHour: startComponents.hour ?? 0,
            minute: startComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? startTime
        let displayEnd = calendar.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? endTime

        return "\(formatter.string(from: displayStart)) - \(formatter.string(from: displayEnd))"
    }

    func hasEnded(on date: Date, reference: Date = .now) -> Bool {
        reference > endDateTime(on: date)
    }

    var startTimeMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    var repeatRuleLabel: String {
        switch repeatRule {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var effectiveDateRangeLabel: String? {
        guard repeatRule != .once, let effectiveEndDate else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: effectiveStartDate)
        let endDay = calendar.startOfDay(for: effectiveEndDate)
        if calendar.isDate(startDay, equalTo: endDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(endDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(endDay.formatted(.dateTime.year().month().day()))"
    }

    private func endDateTime(on date: Date) -> Date {
        guard repeatRule != .once else { return endTime }

        let endComponents = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        return Calendar.current.date(
            bySettingHour: endComponents.hour ?? 0,
            minute: endComponents.minute ?? 0,
            second: 0,
            of: date
        ) ?? endTime
    }
}

private struct HomeTaskDisplayItem: Identifiable {
    let task: TaskProjection
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let historicalPendingCount: Int
    let totalPendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    init(task: TaskProjection, projection: TodayTaskProjectionResult) {
        self.task = task
        section = projection.section
        occurrenceDate = projection.occurrenceDate
        isCompleted = projection.isCompleted
        pendingOccurrenceCount = projection.pendingOccurrenceCount
        historicalPendingCount = projection.historicalPendingCount
        totalPendingOccurrenceCount = projection.totalPendingOccurrenceCount
        overdueOriginText = projection.overdueOriginText
        totalSubtaskCount = projection.totalSubtaskCount
        completedSubtaskCount = projection.completedSubtaskCount
    }

    init(
        task: TaskProjection,
        section: TodayTaskDisplaySection,
        occurrenceDate: Date,
        isCompleted: Bool,
        pendingOccurrenceCount: Int,
        historicalPendingCount: Int,
        totalPendingOccurrenceCount: Int,
        overdueOriginText: String?,
        totalSubtaskCount: Int,
        completedSubtaskCount: Int
    ) {
        self.task = task
        self.section = section
        self.occurrenceDate = occurrenceDate
        self.isCompleted = isCompleted
        self.pendingOccurrenceCount = pendingOccurrenceCount
        self.historicalPendingCount = historicalPendingCount
        self.totalPendingOccurrenceCount = totalPendingOccurrenceCount
        self.overdueOriginText = overdueOriginText
        self.totalSubtaskCount = totalSubtaskCount
        self.completedSubtaskCount = completedSubtaskCount
    }

    var id: String {
        "\(task.id.uuidString)-\(occurrenceDate.timeIntervalSince1970)"
    }

    var hasSubtasks: Bool { totalSubtaskCount > 0 }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

private struct HomeCalendarTaskProjection: Sendable {
    let task: TaskProjection
    let isArchived: Bool

    init(_ task: TaskItem) {
        self.task = TaskProjection(task)
        self.isArchived = task.isArchived
    }
}

private struct HomeCalendarWeekSummary: Identifiable, Hashable {
    let title: String
    let days: [HomeCalendarDaySummary]

    var id: String { title }
}

private struct HomeCalendarDaySummary: Identifiable, Hashable {
    let date: Date
    let taskCompletedCount: Int
    let taskTotalCount: Int
    let reviewCompletedCount: Int
    let dictationReviewedCount: Int
    let isToday: Bool

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
    var hasIncompleteTasks: Bool { taskCompletedCount < taskTotalCount }
    var hasTasks: Bool { taskTotalCount > 0 }
    var hasActivity: Bool {
        hasTasks || reviewCompletedCount > 0 || dictationReviewedCount > 0
    }
}

private struct HomeReviewRoute: Identifiable, Hashable {
    let itemIDs: [UUID]
    let style: ReviewInteractionStyle

    var id: String {
        "\(style.rawValue)-\(itemIDs.map(\.uuidString).joined(separator: ","))"
    }
}

private struct HomeDailyReviewRecordRoute: Identifiable, Hashable {
    let id = UUID()
    let title: String

    init(title: String = "复习记录") {
        self.title = title
    }
}

private struct HomeDictationSessionRoute: Identifiable, Hashable {
    let id: UUID
    let title: String
}

private struct HomeDashboardBoardRoute: Identifiable, Hashable {
    let id = UUID()
}

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore: SyncStatusStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    
    @State private var showingReviewPreview = false
    @State private var activeReviewRoute: HomeReviewRoute?
    @State private var activeDailyReviewRecordRoute: HomeDailyReviewRecordRoute?
    @State private var previewSession: HomeDictationSessionProjection?
    @State private var activeDictationRoute: HomeDictationSessionRoute?
    @State private var isDictationHomeActive = false
    @State private var isAddReviewActive = false
    @State private var activeDashboardBoardRoute: HomeDashboardBoardRoute?
    @State private var showQuickEntryHint = false
    @State private var dashboardSnapshot: DashboardSnapshot?
    @State private var dashboardSnapshotTask: Task<Void, Never>?
    @State private var deferredSaveTask: Task<Void, Never>?
    @State private var isViewVisible = false
    @State private var isDashboardRefreshInFlight = false
    @State private var needsDashboardRefreshAfterCurrent = false
    @State private var dailySummaryPresentation: DailySummaryPresentation?
    @State private var dailySummaryTask: Task<Void, Never>?
    @AppStorage(DailySummaryAISettings.isEnabledKey) private var aiSummaryEnabled = false
    @AppStorage(DailySummaryAISettings.modelKey) private var aiSummaryModelRawValue = DailySummaryAISettings.defaultModel

    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var dailyLimit: Int {
        appSettingsStore.dailyLimit
    }

    private var reviewStyle: ReviewInteractionStyle {
        appSettingsStore.reviewInteractionStyle
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active && isViewVisible
    }

    private var initialDashboardSnapshotDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 0.08
        }
        return dashboardSnapshot == nil ? 2.5 : 0.35
    }

    private var foregroundDashboardSnapshotDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 0.12
        }
        return dashboardSnapshot == nil ? 1.5 : 0.5
    }

    private var refreshDashboardSnapshotDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 0.08
        }
        return dashboardSnapshot == nil ? 1.0 : 0.2
    }

    private struct HomeTaskDetailRoute: Hashable {
        let taskID: UUID
        let title: String
    }

    private struct DailySummaryPresentation {
        let inputHash: String
        let modelRawValue: String
        let result: DailySummaryResult
        let isAIResult: Bool
        let isLoading: Bool
    }

    private struct DashboardSnapshot {
        let childName: String
        let dueItems: [HomeReviewItemProjection]
        let allDueCount: Int
        let masteredReviewCount: Int
        let todayCompletedCount: Int
        let todayWrongCount: Int
        let todayCorrectCount: Int
        let todayAccuracyText: String
        let todayDictationReviewedEntryCount: Int
        let pendingDictationCount: Int
        let pendingDictationSessionCount: Int
        let latestDictationSession: HomeDictationSessionProjection?
        let latestDictationEntryCount: Int
        let dictationEntriesBySessionID: [UUID: [HomeDictationEntryProjection]]
        let todaySchedules: [HomeScheduleProjection]
        let todayPendingTasks: [HomeTaskDisplayItem]
        let historicalPendingTasks: [HomeTaskDisplayItem]
        let historicalPendingTaskCount: Int
        let todayCompletedTasks: [HomeTaskDisplayItem]
        let todayCompletedTaskCount: Int
        let totalPendingTaskCount: Int
        let calendarWeeks: [HomeCalendarWeekSummary]
        let activeTaskCount: Int
        let pointBalance: Int
        let pointsEarnedToday: Int
        let currentPointStreak: Int
        let wrongReviewSamples: [String]
        let heroIconName: String
        let heroMessage: String
        let heroSubtitle: String
        let heroGradientColors: [Color]

        var dueItemIDs: [UUID] {
            var seenIDs = Set<UUID>()
            return dueItems.compactMap { item in
                seenIDs.insert(item.id).inserted ? item.id : nil
            }
        }

        func dictationEntries(for session: HomeDictationSessionProjection) -> [HomeDictationEntryProjection] {
            dictationEntriesBySessionID[session.id] ?? []
        }

        static func make(
            childName: String,
            dailyLimit: Int,
            reviewItems: [HomeReviewItemProjection],
            reviewRecords: [HomeReviewRecordProjection],
            dictationSessions: [HomeDictationSessionProjection],
            dictationEntries: [HomeDictationEntryProjection],
            schedules: [HomeScheduleProjection],
            taskItems: [HomeTaskDisplayItem],
            calendarTasks: [HomeCalendarTaskProjection],
            taskExecutions: [TaskExecutionRecordProjection],
            taskSubtasks: [TaskSubitemProjection],
            activeTaskCount: Int,
            pointBalance: Int,
            pointsEarnedToday: Int,
            currentPointStreak: Int,
            referenceDate: Date = .now
        ) -> DashboardSnapshot {
            let name = childName.isEmpty ? "小朋友" : childName
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: referenceDate)

            let sortedDue = reviewItems
                .filter { ReviewScheduler.isDue($0.nextReviewAt, on: referenceDate, calendar: calendar) }
                .sorted { lhs, rhs in
                    let lhsDay = ReviewScheduler.normalizedReviewDate(lhs.nextReviewAt, calendar: calendar)
                    let rhsDay = ReviewScheduler.normalizedReviewDate(rhs.nextReviewAt, calendar: calendar)

                    if lhsDay != rhsDay {
                        return lhsDay < rhsDay
                    }
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            var seenDueItemIDs = Set<UUID>()
            let allDue = sortedDue.filter { item in
                seenDueItemIDs.insert(item.id).inserted
            }
            let cappedDueContent = Array(allDue.prefix(dailyLimit))
            let masteredReviewCount = reviewItems.filter(\.isMastered).count

            let todayRecs = reviewRecords.filter { calendar.isDate($0.reviewedAt, inSameDayAs: referenceDate) }
            let tCompleted = todayRecs.count
            let tWrong = todayRecs.filter { $0.result == .wrong }.count
            let tCorrect = todayRecs.filter { $0.result == .correct }.count
            let tAccuracy = tCompleted > 0 ? "\(Int((Double(tCorrect) / Double(tCompleted) * 100).rounded()))%" : "--"
            let reviewContentByID = Dictionary(
                reviewItems.map { ($0.id, $0.content) },
                uniquingKeysWith: { first, _ in first }
            )
            let wrongSamples = Array(
                todayRecs
                    .filter { $0.result == .wrong }
                    .compactMap { reviewContentByID[$0.itemID] }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .prefix(5)
            )
            let calendarWeeks = buildCalendarWeeks(
                tasks: calendarTasks,
                taskExecutions: taskExecutions,
                taskSubtasks: taskSubtasks,
                reviewRecords: reviewRecords,
                dictationSessions: dictationSessions,
                dictationEntries: dictationEntries,
                referenceDate: referenceDate,
                calendar: calendar
            )

            let pendingSessions = dictationSessions.filter {
                !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
            }
            let pendingDictationSessionCount = pendingSessions.count
            let latestDS: HomeDictationSessionProjection? = {
                if let firstPending = pendingSessions.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
                    return firstPending
                }
                return dictationSessions.filter {
                    calendar.startOfDay(for: $0.scheduledDate) <= todayStart
                }.min(by: { $0.scheduledDate > $1.scheduledDate })
            }()

            let entriesBySessionID = Dictionary(grouping: dictationEntries, by: \.sessionID)
                .mapValues { entries in entries.sorted { $0.sortOrder < $1.sortOrder } }
            let pendingSessionIDs = Set(pendingSessions.map(\.id))
            let latestSessionID = latestDS?.id
            let todayReviewedSessionIDs = Set(
                dictationSessions.compactMap { session -> UUID? in
                    guard let reviewedAt = session.reviewedAt,
                          calendar.isDate(reviewedAt, inSameDayAs: referenceDate) else {
                        return nil
                    }
                    return session.id
                }
            )
            var pendingDictationEntryCount = 0
            var latestDictationEntryCount = 0
            var todayDictationReviewedEntryCount = 0

            for entry in dictationEntries {
                if pendingSessionIDs.contains(entry.sessionID) {
                    pendingDictationEntryCount += 1
                }
                if entry.sessionID == latestSessionID {
                    latestDictationEntryCount += 1
                }
                if todayReviewedSessionIDs.contains(entry.sessionID), entry.result != .pending {
                    todayDictationReviewedEntryCount += 1
                }
            }

            let tSchedules = schedules
                .filter { $0.shouldAppear(on: referenceDate) && !$0.hasEnded(on: referenceDate, reference: referenceDate) }
                .sorted { $0.startTimeMinutes < $1.startTimeMinutes }

            let todayTaskItems = taskItems.filter { $0.section == .todayPending }
            let historicalTaskItems = taskItems.filter { $0.section == .historicalPending }
                .sorted { lhs, rhs in
                    if lhs.occurrenceDate == rhs.occurrenceDate {
                        return lhs.task.createdAt < rhs.task.createdAt
                    }
                    return lhs.occurrenceDate < rhs.occurrenceDate
                }
            let orderedTaskItems = todayTaskItems + historicalTaskItems + taskItems.filter { $0.section == .todayDone }
            let taskSections = TodayTaskSectionSnapshotBuilder.build(
                from: orderedTaskItems,
                taskID: { $0.task.id },
                section: { $0.section },
                collapseTodayDone: false
            )
            let tPendingTasks = taskSections.todayPendingItems
            let hPendingTasks = taskSections.historicalPendingItems
            let historicalPendingTaskCount = taskSections.historicalPendingTotalCount
            let tCompletedTasks = taskSections.todayDoneItems
            let tCompletedTaskCount = tCompletedTasks.count
            let totPendingTaskCount = todayTaskItems.count + historicalPendingTaskCount

            let tasksDone = totPendingTaskCount == 0 && (tCompletedTaskCount > 0 || activeTaskCount == 0)
            let reviewDone = cappedDueContent.isEmpty
            let dictationDone = latestDS?.isReviewed ?? true
            let scheduleDone = tSchedules.isEmpty

            let hIcon: String = {
                if tasksDone && reviewDone && dictationDone && scheduleDone { return "checkmark.seal.fill" }
                if reviewDone && dictationDone { return "sparkles" }
                if totPendingTaskCount == 0 { return "book.fill" }
                return "figure.run"
            }()

            let hMessage: String = {
                if tasksDone && reviewDone && dictationDone { return "今天的任务、复习和听写全部完成了！" }
                var parts: [String] = []
                if totPendingTaskCount > 0 { parts.append("\(totPendingTaskCount) 项任务") }
                if !tSchedules.isEmpty { parts.append("\(tSchedules.count) 项日程") }
                if !cappedDueContent.isEmpty { parts.append("\(cappedDueContent.count) 项复习") }
                if pendingDictationEntryCount > 0 { parts.append("\(pendingDictationEntryCount) 条听写") }
                if parts.isEmpty { return "\(name)，今天没有待办事项" }
                return "\(name) 今天还有 \(parts.joined(separator: "、"))"
            }()

            let hSubtitle: String = {
                if tasksDone && reviewDone && dictationDone { return "表现太棒了！录入新错题或休息一下吧。明天见！" }
                if let session = latestDS, !session.isReviewed {
                    if session.isFinished {
                        return "今天听写已完成，快让家长点击「复习听写」吧！"
                    }
                    if pendingDictationEntryCount > 0 {
                        return "当前共有 \(pendingDictationEntryCount) 条待听写内容，先从「\(session.title)」开始。"
                    }
                    return "别忘了还有一场「\(session.title)」听写在进行中。"
                }
                if historicalPendingTaskCount > 0 && tPendingTasks.isEmpty {
                    return "还有 \(historicalPendingTaskCount) 次历史待办，先清一清积压吧。"
                }
                if totPendingTaskCount > 0 && !cappedDueContent.isEmpty { return "先完成今天的任务，再做错题复习。加油！" }
                if totPendingTaskCount > 0 { return "先把今天的任务完成吧！" }
                if allDue.count > dailyLimit { return "今天共有 \(allDue.count) 项到期，推荐先练 \(dailyLimit) 项。" }
                return "孩子在纸上写，家长判定对错，同一题当天只练一次。"
            }()

            let hGradient: [Color] = {
                if tasksDone && reviewDone && dictationDone { return [.green.opacity(0.85), .mint.opacity(0.65)] }
                if totPendingTaskCount > 0 || !cappedDueContent.isEmpty || !(latestDS?.isReviewed ?? true) {
                    if totPendingTaskCount > 0 && !cappedDueContent.isEmpty { return [.orange.opacity(0.9), .yellow.opacity(0.65)] }
                    return [.blue.opacity(0.8), .cyan.opacity(0.6)]
                }
                return [.blue.opacity(0.8), .cyan.opacity(0.6)]
            }()

            return DashboardSnapshot(
                childName: name,
                dueItems: cappedDueContent,
                allDueCount: allDue.count,
                masteredReviewCount: masteredReviewCount,
                todayCompletedCount: tCompleted,
                todayWrongCount: tWrong,
                todayCorrectCount: tCorrect,
                todayAccuracyText: tAccuracy,
                todayDictationReviewedEntryCount: todayDictationReviewedEntryCount,
                pendingDictationCount: pendingDictationEntryCount,
                pendingDictationSessionCount: pendingDictationSessionCount,
                latestDictationSession: latestDS,
                latestDictationEntryCount: latestDictationEntryCount,
                dictationEntriesBySessionID: entriesBySessionID,
                todaySchedules: tSchedules,
                todayPendingTasks: tPendingTasks,
                historicalPendingTasks: hPendingTasks,
                historicalPendingTaskCount: historicalPendingTaskCount,
                todayCompletedTasks: tCompletedTasks,
                todayCompletedTaskCount: tCompletedTaskCount,
                totalPendingTaskCount: totPendingTaskCount,
                calendarWeeks: calendarWeeks,
                activeTaskCount: activeTaskCount,
                pointBalance: pointBalance,
                pointsEarnedToday: pointsEarnedToday,
                currentPointStreak: currentPointStreak,
                wrongReviewSamples: wrongSamples,
                heroIconName: hIcon,
                heroMessage: hMessage,
                heroSubtitle: hSubtitle,
                heroGradientColors: hGradient
            )
        }

        private static func buildCalendarWeeks(
            tasks: [HomeCalendarTaskProjection],
            taskExecutions: [TaskExecutionRecordProjection],
            taskSubtasks: [TaskSubitemProjection],
            reviewRecords: [HomeReviewRecordProjection],
            dictationSessions: [HomeDictationSessionProjection],
            dictationEntries: [HomeDictationEntryProjection],
            referenceDate: Date,
            calendar: Calendar
        ) -> [HomeCalendarWeekSummary] {
            let today = calendar.startOfDay(for: referenceDate)
            let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            return [
                HomeCalendarWeekSummary(
                    title: "本周",
                    days: buildCalendarDays(
                        startingAt: currentWeekStart,
                        tasks: tasks,
                        taskExecutions: taskExecutions,
                        taskSubtasks: taskSubtasks,
                        reviewRecords: reviewRecords,
                        dictationSessions: dictationSessions,
                        dictationEntries: dictationEntries,
                        today: today,
                        calendar: calendar
                    )
                )
            ]
        }

        private static func buildCalendarDays(
            startingAt weekStart: Date,
            tasks: [HomeCalendarTaskProjection],
            taskExecutions: [TaskExecutionRecordProjection],
            taskSubtasks: [TaskSubitemProjection],
            reviewRecords: [HomeReviewRecordProjection],
            dictationSessions: [HomeDictationSessionProjection],
            dictationEntries: [HomeDictationEntryProjection],
            today: Date,
            calendar: Calendar
        ) -> [HomeCalendarDaySummary] {
            let executionsByTask = Dictionary(grouping: taskExecutions, by: \.taskID)
            let subtasksByExecutionID = Dictionary(
                grouping: taskSubtasks.filter { !$0.isArchived && $0.taskExecutionID != nil },
                by: { $0.taskExecutionID! }
            )

            return (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart) else { return nil }
                let day = calendar.startOfDay(for: date)
                let taskCounts = taskCompletionCounts(
                    on: day,
                    tasks: tasks,
                    executionsByTask: executionsByTask,
                    subtasksByExecutionID: subtasksByExecutionID,
                    calendar: calendar
                )
                let reviewCount = reviewRecords.filter {
                    calendar.isDate($0.reviewedAt, inSameDayAs: day)
                }.count
                let reviewedSessionIDs = Set(
                    dictationSessions.compactMap { session -> UUID? in
                        guard let reviewedAt = session.reviewedAt,
                              calendar.isDate(reviewedAt, inSameDayAs: day) else {
                            return nil
                        }
                        return session.id
                    }
                )
                let dictationReviewedCount = dictationEntries.filter {
                    reviewedSessionIDs.contains($0.sessionID)
                }.count

                return HomeCalendarDaySummary(
                    date: day,
                    taskCompletedCount: taskCounts.completed,
                    taskTotalCount: taskCounts.total,
                    reviewCompletedCount: reviewCount,
                    dictationReviewedCount: dictationReviewedCount,
                    isToday: calendar.isDate(day, inSameDayAs: today)
                )
            }
        }

        private static func taskCompletionCounts(
            on day: Date,
            tasks: [HomeCalendarTaskProjection],
            executionsByTask: [UUID: [TaskExecutionRecordProjection]],
            subtasksByExecutionID: [UUID: [TaskSubitemProjection]],
            calendar: Calendar
        ) -> (completed: Int, total: Int) {
            var completed = 0
            var total = 0

            for calendarTask in tasks {
                let occurrenceDay = calendar.startOfDay(for: day)
                guard taskOccurs(calendarTask.task, on: occurrenceDay, calendar: calendar) else { continue }

                let execution = preferredExecutionRecord(
                    for: calendarTask.task.id,
                    on: occurrenceDay,
                    in: executionsByTask[calendarTask.task.id] ?? [],
                    calendar: calendar
                )
                guard !calendarTask.isArchived || execution != nil else { continue }

                total += 1
                if isTaskCompleted(execution: execution, subtasksByExecutionID: subtasksByExecutionID) {
                    completed += 1
                }
            }

            return (completed, total)
        }

        private static func taskOccurs(
            _ task: TaskProjection,
            on day: Date,
            calendar: Calendar
        ) -> Bool {
            let start = calendar.startOfDay(for: task.startDate)
            guard day >= start else { return false }

            if let endDate = task.endDate, day > calendar.startOfDay(for: endDate) {
                return false
            }

            switch task.recurrence.kind {
            case .once:
                return calendar.isDate(day, inSameDayAs: start)
            case .daily:
                return true
            case .weekly:
                return task.recurrence.weekdays.contains(calendar.component(.weekday, from: day))
            }
        }

        private static func preferredExecutionRecord(
            for taskID: UUID,
            on day: Date,
            in records: [TaskExecutionRecordProjection],
            calendar: Calendar
        ) -> TaskExecutionRecordProjection? {
            records
                .filter { $0.taskID == taskID && calendar.isDate($0.occurrenceDate, inSameDayAs: day) }
                .max { lhs, rhs in
                    executionRecordSortKey(for: lhs) < executionRecordSortKey(for: rhs)
                }
        }

        private static func isTaskCompleted(
            execution: TaskExecutionRecordProjection?,
            subtasksByExecutionID: [UUID: [TaskSubitemProjection]]
        ) -> Bool {
            guard let execution else { return false }
            let subtasks = subtasksByExecutionID[execution.id] ?? []

            if subtasks.isEmpty {
                return execution.status == .completed
            }

            return subtasks.allSatisfy { $0.status == .completed }
        }

        private static func executionRecordSortKey(
            for record: TaskExecutionRecordProjection
        ) -> (Int, Date, Date, UUID) {
            (
                executionStatusSortPriority(record.status),
                record.completedAt ?? .distantPast,
                record.updatedAt,
                record.id
            )
        }

        private static func executionStatusSortPriority(_ status: TaskExecutionStatus) -> Int {
            switch status {
            case .pending:
                return 0
            case .completed:
                return 1
            case .skipped:
                return 2
            }
        }
    }

    private func makeDailySummaryInput(from snapshot: DashboardSnapshot) -> DailySummaryInput {
        DailySummaryInput(
            date: DailySummaryInput.dateKey(),
            locale: "zh-Hans",
            tone: "parent_encouraging",
            childName: snapshot.childName,
            metrics: DailySummaryInput.Metrics(
                reviewCompleted: snapshot.todayCompletedCount,
                reviewCorrect: snapshot.todayCorrectCount,
                reviewWrong: snapshot.todayWrongCount,
                reviewAccuracyText: snapshot.todayAccuracyText,
                dictationReviewedEntries: snapshot.todayDictationReviewedEntryCount,
                tasksCompleted: snapshot.todayCompletedTaskCount,
                tasksPending: snapshot.totalPendingTaskCount,
                pointsEarnedToday: snapshot.pointsEarnedToday,
                currentStreak: snapshot.currentPointStreak
            ),
            highlights: DailySummaryInput.Highlights(
                completedTaskTitles: Array(snapshot.todayCompletedTasks.map(\.task.title).prefix(5)),
                wrongReviewSamples: snapshot.wrongReviewSamples
            )
        )
    }

    private func refreshDailySummary(for snapshot: DashboardSnapshot, force: Bool) {
        let input = makeDailySummaryInput(from: snapshot)
        let inputHash = input.stableHash()
        let model = DeepSeekSummaryModel(rawValue: aiSummaryModelRawValue) ?? .flash
        let fallbackResult = input.localFallbackResult()

        guard aiSummaryEnabled else {
            dailySummaryTask?.cancel()
            dailySummaryPresentation = DailySummaryPresentation(
                inputHash: inputHash,
                modelRawValue: model.rawValue,
                result: fallbackResult,
                isAIResult: false,
                isLoading: false
            )
            return
        }

        guard let apiKey = try? DeepSeekAPIKeyStore.loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dailySummaryTask?.cancel()
            dailySummaryPresentation = DailySummaryPresentation(
                inputHash: inputHash,
                modelRawValue: model.rawValue,
                result: fallbackResult,
                isAIResult: false,
                isLoading: false
            )
            return
        }

        if !force,
           let cachedResult = DailySummaryCache.load(inputHash: inputHash, model: model.rawValue) {
            dailySummaryTask?.cancel()
            dailySummaryPresentation = DailySummaryPresentation(
                inputHash: inputHash,
                modelRawValue: model.rawValue,
                result: cachedResult,
                isAIResult: true,
                isLoading: false
            )
            return
        }

        dailySummaryTask?.cancel()
        dailySummaryPresentation = DailySummaryPresentation(
            inputHash: inputHash,
            modelRawValue: model.rawValue,
            result: fallbackResult,
            isAIResult: false,
            isLoading: true
        )

        dailySummaryTask = Task {
            do {
                let result = try await DeepSeekSummaryClient(apiKey: apiKey, model: model.rawValue)
                    .generateSummary(for: input)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    DailySummaryCache.save(result, inputHash: inputHash, model: model.rawValue)
                    dailySummaryPresentation = DailySummaryPresentation(
                        inputHash: inputHash,
                        modelRawValue: model.rawValue,
                        result: result,
                        isAIResult: true,
                        isLoading: false
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    dailySummaryPresentation = DailySummaryPresentation(
                        inputHash: inputHash,
                        modelRawValue: model.rawValue,
                        result: fallbackResult,
                        isAIResult: false,
                        isLoading: false
                    )
                }
            }
        }
    }

    private func heroCard(_ snapshot: DashboardSnapshot) -> some View {
        let summaryInput = makeDailySummaryInput(from: snapshot)
        let summaryHash = summaryInput.stableHash()
        let summaryResult = dailySummaryPresentation?.inputHash == summaryHash
            ? dailySummaryPresentation?.result
            : summaryInput.localFallbackResult()
        let isSummaryLoading = dailySummaryPresentation?.inputHash == summaryHash
            ? dailySummaryPresentation?.isLoading == true
            : false

        return HStack(alignment: .center, spacing: 16) {
            Image(systemName: snapshot.heroIconName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.heroMessage)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.semibold))
                        Text("今日小结")
                            .font(.caption2.weight(.semibold))

                        if isSummaryLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }

                        if aiSummaryEnabled {
                            Button {
                                refreshDailySummary(for: snapshot, force: true)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(isSummaryLoading)
                            .accessibilityLabel("重新生成今日小结")
                        }
                    }
                    .foregroundStyle(.white.opacity(0.9))

                    Text(summaryResult?.displayText ?? snapshot.heroSubtitle)
                        .font(.subheadline)
                        .lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                }
                
                syncStatusBadge
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: snapshot.heroGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var syncStatusBadge: some View {
        HStack(spacing: 8) {
            SyncStatusIconView(isRefreshing: syncStatusStore.isRefreshing)
            Text(syncStatusStore.statusText)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.white.opacity(0.15), in: Capsule())
    }

    private func pointsSummaryCard(_ snapshot: DashboardSnapshot) -> some View {
        NavigationLink {
            PointsDashboardView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "star.circle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(Color.orange.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("积分")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.caption2)
                            .foregroundStyle(snapshot.currentPointStreak >= 7 ? .orange : .secondary)
                        Text("连续 \(snapshot.currentPointStreak) 天")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(snapshot.currentPointStreak >= 7 ? .orange : .secondary)
                    }
                }

                Spacer()

                Text("\(snapshot.pointBalance)")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.orange)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private func learningCalendarCard(_ snapshot: DashboardSnapshot) -> some View {
        let weekDays = snapshot.calendarWeeks.first?.days ?? []
        let daysWithTasks = weekDays.filter { $0.hasTasks }.count
        let daysCompleted = weekDays.filter { $0.hasTasks && !$0.hasIncompleteTasks }.count

        return VStack(alignment: .leading, spacing: isPad ? 20 : 14) {
            HStack {
                Image(systemName: "calendar.badge.checkmark")
                    .font(isPad ? .title2 : .title3)
                    .foregroundStyle(.blue)
                Text("学习日历")
                    .font(isPad ? .title3.weight(.bold) : .headline)
                Spacer()
                if daysWithTasks > 0 {
                    Text("\(daysCompleted)/\(daysWithTasks) 天完成")
                        .font(isPad ? Font.subheadline.weight(.bold) : Font.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, isPad ? 14 : 10)
                        .padding(.vertical, isPad ? 6 : 4)
                        .background(
                            daysCompleted == daysWithTasks ? Color.green : Color.blue,
                            in: Capsule()
                        )
                } else {
                    Text("本周")
                        .font(isPad ? Font.subheadline.weight(.semibold) : Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: isPad ? 12 : 8) {
                calendarWeekdayHeader

                ForEach(snapshot.calendarWeeks) { week in
                    HStack(spacing: isPad ? 8 : 4) {
                        ForEach(week.days) { day in
                            calendarDayCell(day)
                        }
                    }
                }
            }

            // 底部颜色图例
            HStack(spacing: isPad ? 24 : 16) {
                calendarLegendItem(color: .green, label: "已完成")
                calendarLegendItem(color: .orange, label: "进行中")
                calendarLegendItem(color: .purple, label: "复习")
                calendarLegendItem(color: .cyan, label: "听写")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private var calendarWeekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(calendarWeekdayHeaderTexts, id: \.self) { weekday in
                Text(weekday)
                    .font(.system(size: isPad ? 14 : 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 1)
    }

    private var calendarWeekdayHeaderTexts: [String] {
        let shortSymbols = Calendar.current.veryShortWeekdaySymbols
        let firstWeekday = Calendar.current.firstWeekday
        return (0..<7).map { offset in
            let index = (firstWeekday - 1 + offset) % 7
            return shortSymbols[index]
        }
    }

    private func calendarDayCell(_ day: HomeCalendarDaySummary) -> some View {
        VStack(spacing: isPad ? 10 : 6) {
            // 日期数字 + 今天圆点指示器
            VStack(spacing: isPad ? 4 : 2) {
                Text(calendarDayText(for: day.date))
                    .font(.system(size: isPad ? 22 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(day.isToday ? .white : calendarDayTint(day))
                    .frame(maxWidth: .infinity)

                Circle()
                    .fill(day.isToday ? .white : .clear)
                    .frame(width: isPad ? 6 : 4, height: isPad ? 6 : 4)
            }

            // 任务进度环
            if day.hasTasks {
                ZStack {
                    Circle()
                        .stroke(calendarDayTint(day).opacity(0.25), lineWidth: isPad ? 3.5 : 2.5)
                    Circle()
                        .trim(from: 0, to: CGFloat(day.taskCompletedCount) / CGFloat(max(day.taskTotalCount, 1)))
                        .stroke(calendarDayTint(day), style: StrokeStyle(lineWidth: isPad ? 3.5 : 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    if !day.hasIncompleteTasks {
                        Image(systemName: "checkmark")
                            .font(.system(size: isPad ? 12 : 8, weight: .bold))
                            .foregroundStyle(calendarDayTint(day))
                    } else {
                        Text("\(day.taskCompletedCount)")
                            .font(.system(size: isPad ? 13 : 9, weight: .bold, design: .rounded))
                            .foregroundStyle(calendarDayTint(day))
                    }
                }
                .frame(width: isPad ? 32 : 22, height: isPad ? 32 : 22)

                Text("\(day.taskCompletedCount)/\(day.taskTotalCount)")
                    .font(.system(size: isPad ? 12 : 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(day.isToday ? .white.opacity(0.85) : calendarDayTint(day).opacity(0.8))
            } else {
                Text("—")
                    .font(.system(size: isPad ? 16 : 11, weight: .medium))
                    .foregroundStyle(.quaternary)
                    .frame(width: isPad ? 32 : 22, height: isPad ? 32 : 22)

                Text("无")
                    .font(.system(size: isPad ? 12 : 9, weight: .semibold))
                    .foregroundStyle(day.isToday ? .white.opacity(0.6) : .secondary.opacity(0.5))
            }

            // 底部复习/听写小药丸
            HStack(spacing: isPad ? 4 : 2) {
                if day.reviewCompletedCount > 0 {
                    calendarMiniPill(color: .purple, value: day.reviewCompletedCount)
                }
                if day.dictationReviewedCount > 0 {
                    calendarMiniPill(color: .cyan, value: day.dictationReviewedCount)
                }
            }
            .frame(height: isPad ? 20 : 14)
        }
        .frame(maxWidth: .infinity, minHeight: isPad ? 120 : 80)
        .padding(.vertical, isPad ? 12 : 6)
        .padding(.horizontal, isPad ? 6 : 2)
        .background(calendarDayBackground(day), in: RoundedRectangle(cornerRadius: isPad ? 18 : 12))
        .overlay {
            if day.isToday {
                RoundedRectangle(cornerRadius: isPad ? 18 : 12)
                    .stroke(.blue, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(calendarAccessibilityText(for: day))
    }

    private func calendarMiniPill(color: Color, value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: isPad ? 11 : 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, isPad ? 6 : 4)
            .padding(.vertical, isPad ? 2 : 1)
            .background(color, in: Capsule())
    }

    private func calendarLegendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: isPad ? 8 : 6, height: isPad ? 8 : 6)
            Text(label)
                .font(.system(size: isPad ? 13 : 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func calendarDayBackground(_ day: HomeCalendarDaySummary) -> Color {
        if day.isToday {
            return .blue
        }
        if !day.hasTasks {
            return Color(uiColor: .tertiarySystemGroupedBackground)
        }
        return day.hasIncompleteTasks ? .orange.opacity(0.12) : .green.opacity(0.15)
    }

    private func calendarDayTint(_ day: HomeCalendarDaySummary) -> Color {
        if day.isToday {
            return .white
        }
        if !day.hasTasks {
            return .secondary
        }
        return day.hasIncompleteTasks ? .orange : .green
    }

    private func calendarDayText(for date: Date) -> String {
        "\(Calendar.current.component(.day, from: date))"
    }

    private func calendarAccessibilityText(for day: HomeCalendarDaySummary) -> String {
        let dateText = day.date.formatted(.dateTime.month().day().weekday())
        let taskText = day.hasTasks
            ? "任务完成 \(day.taskCompletedCount) 项，共 \(day.taskTotalCount) 项"
            : "无任务"
        return "\(dateText)，\(taskText)，复习 \(day.reviewCompletedCount) 项，听写 \(day.dictationReviewedCount) 条"
    }

    var body: some View {
        Group {
            if let snapshot = dashboardSnapshot {
                mainContentView(snapshot)
            } else {
                lightweightLoadingHomeView
            }
        }
        .onAppear {
            isViewVisible = true
            #if DEBUG
            DebugPerf.mark("HomeView onAppear")
            #endif
            requestDashboardSnapshotRefresh(
                reason: "onAppear",
                delay: dashboardSnapshot == nil ? initialDashboardSnapshotDelay : refreshDashboardSnapshotDelay
            )
        }
        .modifier(HomeViewDataReconstructor(
            scenePhase: scenePhase,
            appRevision: appSettingsStore.revision,
            onRefresh: { reason in
                requestDashboardSnapshotRefresh(reason: reason, delay: refreshDashboardSnapshotDelay)
            },
            onSceneChange: { newPhase in
                if newPhase == .active {
                    requestDashboardSnapshotRefresh(reason: "scenePhase active", delay: foregroundDashboardSnapshotDelay)
                } else {
                    dashboardSnapshotTask?.cancel()
                }
            }
        ))
        .onChange(of: aiSummaryEnabled) { _, _ in
            if let dashboardSnapshot {
                refreshDailySummary(for: dashboardSnapshot, force: true)
            }
        }
        .onChange(of: aiSummaryModelRawValue) { _, _ in
            if let dashboardSnapshot {
                refreshDailySummary(for: dashboardSnapshot, force: true)
            }
        }
        .onDisappear {
            isViewVisible = false
            #if DEBUG
            DebugPerf.mark("HomeView onDisappear")
            #endif
            dashboardSnapshotTask?.cancel()
            dailySummaryTask?.cancel()
        }
        .sheet(item: $previewSession) { session in
            if let snapshot = dashboardSnapshot {
                HomeDictationPreviewView(
                    session: session,
                    entries: snapshot.dictationEntries(for: session),
                    onStartSession: {
                        #if DEBUG
                        DebugPerf.mark("Home dictation preview onStartSession title=\(session.title)")
                        #endif
                        activeDictationRoute = HomeDictationSessionRoute(id: session.id, title: session.title)
                    }
                )
                .onAppear {
                    #if DEBUG
                    DebugPerf.mark("Home dictation preview sheet appear title=\(session.title)")
                    #endif
                }
            } else {
                ProgressView("正在准备听写内容...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationDestination(item: $activeDictationRoute) { route in
            HomeDeferredDictationSessionView(route: route)
        }
        .navigationDestination(isPresented: $isDictationHomeActive) {
            DeferredDictationHomeView()
        }
        .navigationDestination(isPresented: $isAddReviewActive) {
            DeferredAddReviewItemView()
        }
        .navigationDestination(for: HomeTaskDetailRoute.self) { route in
            HomeDeferredTaskDetailView(route: route)
        }
        .navigationDestination(item: $activeReviewRoute) { route in
            HomeDeferredReviewSessionView(route: route)
        }
        .navigationDestination(item: $activeDailyReviewRecordRoute) { route in
            HomeDeferredDailyReviewRecordsView(route: route)
        }
        .sheet(isPresented: $showingReviewPreview) {
            if let snapshot = dashboardSnapshot {
                ReviewPreviewView(
                    items: snapshot.dueItems,
                    onStartReview: {
                        activeReviewRoute = HomeReviewRoute(itemIDs: snapshot.dueItemIDs, style: reviewStyle)
                    }
                )
            } else {
                ProgressView("正在准备复习内容...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .fullScreenCover(item: $activeDashboardBoardRoute) { _ in
            DeferredDashboardBoardView()
        }
        .toolbar {
            if isPad {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("看板", systemImage: "rectangle.inset.filled.and.person.filled") {
                        openDashboardBoard()
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu("新增", systemImage: "plus") {
                    Button {
                        openAddReview(source: "home toolbar menu")
                    } label: {
                        Label("单条录入", systemImage: "square.and.pencil")
                    }

                    NavigationLink {
                        BatchAddReviewItemsView()
                    } label: {
                        Label("批量录入", systemImage: "text.badge.plus")
                    }
                }
            }
        }
    }

    private struct HomeViewDataReconstructor: ViewModifier {
        let scenePhase: ScenePhase
        let appRevision: Int
        
        let onRefresh: (String) -> Void
        let onSceneChange: (ScenePhase) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: scenePhase) { _, newPhase in onSceneChange(newPhase) }
                .onChange(of: appRevision) { _, _ in onRefresh("appRevision") }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
                    onRefresh("appDataDidMutate")
                }
        }
    }

    private func requestDashboardSnapshotRefresh(reason: String, delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("HomeView requestDashboardSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        guard canRenderLiveContent else { return }

        if isDashboardRefreshInFlight {
            needsDashboardRefreshAfterCurrent = true
            #if DEBUG
            DebugPerf.mark("HomeView refresh queued reason=\(reason)")
            #endif
            return
        }

        scheduleDashboardSnapshotUpdate(delay: delay)
    }

    private func openDashboardBoard() {
        #if DEBUG
        DebugPerf.mark("Home openDashboardBoard")
        #endif
        dashboardSnapshotTask?.cancel()
        isDashboardRefreshInFlight = false
        needsDashboardRefreshAfterCurrent = false
        activeDashboardBoardRoute = HomeDashboardBoardRoute()
    }

    private func scheduleDashboardSnapshotUpdate(delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("HomeView scheduleDashboardSnapshotUpdate delay=\(delay)")
        #endif
        dashboardSnapshotTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let childName = appSettingsStore.childName
        let dailyLimit = appSettingsStore.dailyLimit
        let container = modelContext.container

        dashboardSnapshotTask = Task(priority: .utility) {
            defer {
                Task { @MainActor in
                    let shouldScheduleCoalescedRefresh = needsDashboardRefreshAfterCurrent
                    isDashboardRefreshInFlight = false
                    needsDashboardRefreshAfterCurrent = false

                    guard shouldScheduleCoalescedRefresh, canRenderLiveContent else { return }
                    requestDashboardSnapshotRefresh(reason: "coalesced", delay: refreshDashboardSnapshotDelay)
                }
            }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            await MainActor.run {
                isDashboardRefreshInFlight = true
            }

            #if DEBUG
            DebugPerf.mark("HomeView background snapshot fetch begin")
            #endif
            let referenceDate = Date()
            let snapshot = await Task.detached(priority: .utility) {
                let backgroundContext = ModelContext(container)
                let calendar = Calendar.current

                let reviewModels = (try? backgroundContext.fetch(FetchDescriptor<ReviewItem>())) ?? []
                let reviewRecordModels = (try? backgroundContext.fetch(FetchDescriptor<ReviewRecord>())) ?? []
                let sessionModels = (try? backgroundContext.fetch(FetchDescriptor<DictationSession>())) ?? []
                let entryModels = (try? backgroundContext.fetch(FetchDescriptor<DictationEntry>())) ?? []
                let scheduleModels = (try? backgroundContext.fetch(
                    FetchDescriptor<ScheduleItem>(predicate: #Predicate<ScheduleItem> { !$0.isArchived })
                )) ?? []
                let allTaskModels = (try? backgroundContext.fetch(FetchDescriptor<TaskItem>())) ?? []
                let executionModels = (try? backgroundContext.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? []
                let subtaskModels = (try? backgroundContext.fetch(
                    FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
                )) ?? []
                let pointSnapshot = PointLedgerService.currentSnapshot(in: backgroundContext)
                let pointEntryModels = (try? backgroundContext.fetch(FetchDescriptor<PointLedgerEntry>())) ?? []
                let pointsEarnedToday = pointEntryModels
                    .filter { $0.amount > 0 && calendar.isDate($0.createdAt, inSameDayAs: referenceDate) }
                    .reduce(0) { $0 + $1.amount }

                let autoArchivedCompletedAtByTaskID = Dictionary(
                    executionModels.compactMap { record -> (UUID, Date)? in
                        guard record.status == .completed,
                              let completedAt = record.completedAt,
                              calendar.isDate(completedAt, inSameDayAs: referenceDate) else {
                            return nil
                        }
                        return (record.taskID, completedAt)
                    },
                    uniquingKeysWith: max
                )
                let visibleTaskModels = allTaskModels.filter { task in
                    guard task.isArchived else { return true }
                    guard task.recurrence.kind == .once,
                          let completedAt = autoArchivedCompletedAtByTaskID[task.id] else {
                        return false
                    }
                    return task.updatedAt <= completedAt
                }
                let deduplicatedTaskModels = TaskDedupSupport.deduplicatedTasks(allTaskModels)
                let deduplicatedVisibleTaskModels = TaskDedupSupport.deduplicatedTasks(visibleTaskModels)
                let activeTaskModels = deduplicatedTaskModels.filter { !$0.isArchived }

                let taskProjections = deduplicatedVisibleTaskModels.map(TaskProjection.init)
                let taskExecutionProjections = executionModels.map(TaskExecutionRecordProjection.init)
                let taskSubitemProjections = subtaskModels.map(TaskSubitemProjection.init)
                let taskProjectionResults = TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: taskExecutionProjections,
                    subtasks: taskSubitemProjections,
                    on: referenceDate
                )
                let tasksByID = Dictionary(
                    taskProjections.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let taskDisplayItems = TaskDedupSupport.deduplicatedDisplayItems(
                    taskProjectionResults.compactMap { result -> HomeTaskDisplayItem? in
                        guard let task = tasksByID[result.taskID] else { return nil }
                        return HomeTaskDisplayItem(task: task, projection: result)
                    },
                    title: { $0.task.title },
                    taskID: { $0.task.id },
                    section: { $0.section },
                    occurrenceDate: { $0.occurrenceDate },
                    sortKey: { item in
                        TaskDisplayDedupSortKey(
                            unskippablePriority: item.task.skipPolicy == .unskippable ? 1 : 0,
                            totalSubtaskCount: item.totalSubtaskCount,
                            completedSubtaskCount: item.completedSubtaskCount,
                            createdAt: item.task.createdAt,
                            stableID: item.task.id.uuidString
                        )
                    }
                )

                #if DEBUG
                let todayPendingSummaries = taskDisplayItems
                    .filter { $0.section == .todayPending }
                    .map { "\($0.task.title)#\($0.task.id.uuidString.prefix(6))@\($0.occurrenceDate.formatted(.dateTime.month().day()))" }
                    .joined(separator: ",")
                let todayDoneSummaries = taskDisplayItems
                    .filter { $0.section == .todayDone }
                    .map { "\($0.task.title)#\($0.task.id.uuidString.prefix(6))@\($0.occurrenceDate.formatted(.dateTime.month().day()))" }
                    .joined(separator: ",")
                DebugPerf.mark("HomeView background snapshot fetch end reviews=\(reviewModels.count) records=\(reviewRecordModels.count) sessions=\(sessionModels.count) entries=\(entryModels.count) schedules=\(scheduleModels.count) tasks=\(deduplicatedVisibleTaskModels.count) todayPending=\(todayPendingSummaries) todayDone=\(todayDoneSummaries)")
                #endif

                return DashboardSnapshot.make(
                    childName: childName,
                    dailyLimit: dailyLimit,
                    reviewItems: reviewModels.map(HomeReviewItemProjection.init),
                    reviewRecords: reviewRecordModels.map(HomeReviewRecordProjection.init),
                    dictationSessions: sessionModels.map(HomeDictationSessionProjection.init),
                    dictationEntries: entryModels.map(HomeDictationEntryProjection.init),
                    schedules: scheduleModels.map(HomeScheduleProjection.init),
                    taskItems: taskDisplayItems,
                    calendarTasks: deduplicatedTaskModels.map(HomeCalendarTaskProjection.init),
                    taskExecutions: taskExecutionProjections,
                    taskSubtasks: taskSubitemProjections,
                    activeTaskCount: activeTaskModels.count,
                    pointBalance: pointSnapshot.balance,
                    pointsEarnedToday: pointsEarnedToday,
                    currentPointStreak: pointSnapshot.currentStreak,
                    referenceDate: referenceDate
                )
            }.value

            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            dashboardSnapshot = snapshot
            refreshDailySummary(for: snapshot, force: false)
            #if DEBUG
            DebugPerf.mark("HomeView dashboardSnapshot applied")
            #endif
        }
    }

    private func mainContentView(_ snapshot: DashboardSnapshot) -> some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= 700

                VStack(spacing: 20) {
                    heroCard(snapshot)

                    if !AppStorePreviewMode.isEnabled && syncStatusStore.syncNoticeKind != .ready {
                        syncStatusSummaryCard
                    }

                    todayScheduleCard(snapshot)

                    todayTasksCard(snapshot)

                    learningCalendarCard(snapshot)

                    pointsSummaryCard(snapshot)

                    // Stat grid
                    statGridSection(snapshot)

                    if isWide {
                        HStack(spacing: 16) {
                            reviewEntryButton(snapshot)
                            dictationEntryButton(snapshot)
                        }
                    } else {
                        VStack(spacing: 12) {
                            reviewEntryButton(snapshot)
                            dictationEntryButton(snapshot)
                        }
                    }

                    quickEntryCard
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: 960, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var lightweightLoadingHomeView: some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= 700

                VStack(spacing: 20) {
                    loadingHeroCard

                    if isWide {
                        HStack(spacing: 16) {
                            lightweightReviewPlaceholderCard
                            lightweightDictationEntryButton
                        }
                    } else {
                        VStack(spacing: 12) {
                            lightweightReviewPlaceholderCard
                            lightweightDictationEntryButton
                        }
                    }

                    quickEntryCard

                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在准备首页数据，听写和单条录入已经可以先进入。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: 960, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("首页")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var loadingHeroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("首页正在轻量加载")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("旧 iPad 上会先把可点击入口放出来，再慢慢补齐统计和任务列表。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.8), .cyan.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var lightweightReviewPlaceholderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "book.closed")
                Text("复习数据加载中")
            }
            .font(.title3.weight(.semibold))

            Text("先把今日听写或新增错题打开，复习统计稍后补齐。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var lightweightDictationEntryButton: some View {
        Button {
            openDictationHome(source: "home lightweight loading card")
        } label: {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "text.book.closed.fill")
                        Text("进入今日听写")
                    }
                    .font(.title3.weight(.semibold))

                    Text("首页统计还在整理中，也可以先直接进入听写安排。")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding()
            .background(Color.teal)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statGridSection(_ snapshot: DashboardSnapshot) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

        LazyVGrid(columns: columns, spacing: 12) {
            Button {
                activeReviewRoute = HomeReviewRoute(itemIDs: snapshot.dueItemIDs, style: reviewStyle)
            } label: {
                StatGridCard(icon: "book.closed", title: "今日复习", value: "\(snapshot.dueItems.count)", tint: .orange)
            }
            .buttonStyle(.plain)
            .disabled(snapshot.dueItems.isEmpty)
            
            Button {
                openDictationHome(source: "home stat grid")
            } label: {
                StatGridCard(icon: "text.book.closed", title: "待听写", value: "\(snapshot.pendingDictationCount)", tint: .teal)
            }
            .buttonStyle(.plain)

            dailyReviewRecordButton(
                icon: "checkmark.circle",
                title: "今日完成",
                value: "\(snapshot.todayCompletedCount)",
                tint: .green
            )
            dailyReviewRecordButton(
                icon: "xmark.circle",
                title: "今日答错",
                value: "\(snapshot.todayWrongCount)",
                tint: .red
            )
            dailyReviewRecordButton(
                icon: "percent",
                title: "正确率",
                value: snapshot.todayAccuracyText,
                tint: .blue
            )
            StatGridCard(icon: "star.fill", title: "已掌握", value: "\(snapshot.masteredReviewCount)", tint: .mint)
        }
    }

    private func dailyReviewRecordButton(
        icon: String,
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        Button {
            openDailyReviewRecords(source: "home stat grid \(title)")
        } label: {
            StatGridCard(icon: icon, title: title, value: value, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private var quickEntryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "pencil.tip.crop.circle.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("快速录入")
                    .font(.headline)
                Spacer()
                Button {
                    showQuickEntryHint = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                }
            }
            .alert("提示", isPresented: $showQuickEntryHint) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("把当天写错的词句或英语录进来，保存后会从明天开始进入正式复习。")
            }

            Button {
                openAddReview(source: "home quick entry card")
            } label: {
                Label("新增一条错题", systemImage: "square.and.pencil")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)

            NavigationLink {
                BatchAddReviewItemsView()
            } label: {
                Label("批量录入多条", systemImage: "text.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue.opacity(0.15))
            .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func reviewEntryButton(_ snapshot: DashboardSnapshot) -> some View {
        Button {
            activeReviewRoute = HomeReviewRoute(itemIDs: snapshot.dueItemIDs, style: reviewStyle)
        } label: {
            reviewEntryLabel(snapshot)
        }
        .buttonStyle(.plain)
        .disabled(snapshot.dueItems.isEmpty)
    }

    private func reviewEntryLabel(_ snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始今天复习")
                }
                .font(.title3.weight(.semibold))

                Text(reviewStatusText(snapshot))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            
            Spacer()
            
            if !snapshot.dueItems.isEmpty {
                Button {
                    showingReviewPreview = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                        Text("预习内容")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: snapshot.dueItems.isEmpty
                    ? [.gray, .gray.opacity(0.8)]
                    : [.accentColor, .accentColor.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: (snapshot.dueItems.isEmpty ? Color.gray : Color.accentColor).opacity(0.3), radius: 12, y: 6)
    }

    private func dictationEntryButton(_ snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                openDictationHome(source: "home dictation card")
            } label: {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "text.book.closed.fill")
                            Text("进入今日听写")
                        }
                        .font(.title3.weight(.semibold))

                        Text(dictationStatusText(snapshot))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let session = snapshot.latestDictationSession, !session.isFinished && !session.isReviewed {
                Button {
                    #if DEBUG
                    DebugPerf.mark("Home dictation preview tap title=\(session.title)")
                    #endif
                    previewSession = session
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                        Text("预习内容")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.25), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: [.teal, .teal.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .teal.opacity(0.3), radius: 12, y: 6)
    }

    private func openDictationHome(source: String) {
        #if DEBUG
        DebugPerf.mark("Home openDictationHome source=\(source)")
        #endif
        isDictationHomeActive = true
    }

    private func openAddReview(source: String) {
        #if DEBUG
        DebugPerf.mark("Home openAddReview source=\(source)")
        #endif
        isAddReviewActive = true
    }

    private func openDailyReviewRecords(source: String) {
        #if DEBUG
        DebugPerf.mark("Home openDailyReviewRecords source=\(source)")
        #endif
        activeDailyReviewRecordRoute = HomeDailyReviewRecordRoute()
    }

    private func reviewStatusText(_ snapshot: DashboardSnapshot) -> String {
        guard !snapshot.dueItems.isEmpty else {
            return "今天复习已经全部完成了"
        }

        if snapshot.allDueCount > snapshot.dueItems.count {
            return "今天到期 \(snapshot.allDueCount) 项，当前先练 \(snapshot.dueItems.count) 项"
        }

        return "还有 \(snapshot.dueItems.count) 项待复习"
    }

    private func dictationStatusText(_ snapshot: DashboardSnapshot) -> String {
        guard let latestDictationSession = snapshot.latestDictationSession else {
            return "今天还没有新增听写内容"
        }

        let count = snapshot.latestDictationEntryCount
        let status: String
        if latestDictationSession.isReviewed {
            status = "已判定"
        } else if latestDictationSession.isFinished {
            status = "待判定"
        } else {
            status = "进行中"
        }

        if snapshot.pendingDictationCount > 0, !latestDictationSession.isReviewed {
            return "待听写共 \(snapshot.pendingDictationCount) 条 · 共 \(snapshot.pendingDictationSessionCount) 组 · 当前「\(latestDictationSession.title)」\(count) 条 · \(status)"
        }

        return "\(latestDictationSession.title) · \(count) 条 · \(status)"
    }

    // MARK: - Today Schedule

    @ViewBuilder
    private func todayScheduleCard(_ snapshot: DashboardSnapshot) -> some View {
        let schedules = snapshot.todaySchedules

        if !schedules.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                    Text("今日日程")
                        .font(.headline)
                    Spacer()
                    Text("\(schedules.count) 项")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.indigo)
                }

                ForEach(schedules) { schedule in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.indigo)
                            .frame(width: 4, height: 32)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(schedule.title)
                                .fontWeight(.medium)

                            HStack(spacing: 6) {
                                Text(schedule.timeRangeText(on: .now))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.indigo)

                                Text(schedule.repeatRuleLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
                                    Text(effectiveDateRangeLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    // MARK: - Today Tasks

    @ViewBuilder
    private func todayTasksCard(_ snapshot: DashboardSnapshot) -> some View {
        let pendingItems = snapshot.todayPendingTasks
        let historicalItems = snapshot.historicalPendingTasks
        let doneCount = snapshot.todayCompletedTaskCount
        let todayTaskCount = pendingItems.count + doneCount
        let historyCount = snapshot.historicalPendingTaskCount
        
        if !pendingItems.isEmpty || doneCount > 0 || !historicalItems.isEmpty || snapshot.activeTaskCount > 0 {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    Text("今日任务")
                        .font(.headline)
                    Spacer()

                    HStack(spacing: 6) {
                        if historyCount > 0 {
                            Text("历史 \(historyCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.orange, in: Capsule())
                        }

                        if todayTaskCount > 0 {
                            Text("\(doneCount)/\(todayTaskCount) 完成")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    doneCount == todayTaskCount ? Color.green : Color.purple,
                                    in: Capsule()
                                )
                        }
                    }
                }

                if pendingItems.isEmpty &&
                    historicalItems.isEmpty &&
                    doneCount == 0 &&
                    snapshot.activeTaskCount > 0 {
                    Text("今天没有待完成的任务。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(pendingItems) { item in
                        todayTaskRow(item)
                    }
                    
                    if !historicalItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("历史待完成")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.orange, in: Capsule())
                                Text("\(historicalItems.count) 项")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 8)
                            
                            ForEach(historicalItems) { item in
                                todayTaskRow(item)
                            }
                        }
                    }
                    
                    if !snapshot.todayCompletedTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("今日已完成")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.green, in: Capsule())
                                Text("\(snapshot.todayCompletedTasks.count) 项")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.top, 8)
                            
                            ForEach(snapshot.todayCompletedTasks) { item in
                                todayTaskRow(item)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func todayTaskRow(_ item: HomeTaskDisplayItem) -> some View {
        let task = item.task
        let isDone = item.isCompleted
        let occurrenceLabel = item.overdueOriginText
        let hasSubtasks = item.hasSubtasks

        return HStack(spacing: 10) {
            if hasSubtasks {
                Image(systemName: isDone ? "checkmark.circle.fill" : "list.bullet.circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? .green : .secondary)
            } else {
                Button {
                    if !isDone {
                        completeTask(task, occurrenceDate: item.occurrenceDate)
                    }
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDone)
            }

            NavigationLink(value: HomeTaskDetailRoute(taskID: task.id, title: task.title)) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .fontWeight(.medium)
                            .foregroundStyle(isDone ? .secondary : .primary)
                            .strikethrough(isDone)

                        HStack(spacing: 3) {
                            Text(task.recurrenceShortLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let _ = task.effectiveDateRangeLabel {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                
                                Text(task.effectiveDateRangeLabel!)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if task.skipPolicy == .unskippable {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }

                            if let _ = occurrenceLabel, !isDone {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text(task.originShortText(for: item.occurrenceDate))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            if let progressText = item.simpleProgressText {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text(progressText)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isDone ? .green : .blue)
                            }

                            if item.historicalPendingCount > 0 {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text("历史 \(item.historicalPendingCount) 次")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .opacity(isDone ? 0.6 : 1.0)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private func completeTask(_ task: TaskProjection, occurrenceDate: Date) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        
        let tid = task.id
        
        // 1. 立即乐观更新 UI
        optimisticCompleteHomeTask(taskID: tid, occurrenceDate: occurrenceDate)
        
        // 2. 主线程同步更新数据库，避免后台 Context 跨线程读写导致瞬时回闪（Flash back）
        do {
            let descriptor = FetchDescriptor<TaskExecutionRecord>(
                predicate: #Predicate<TaskExecutionRecord> { $0.taskID == tid }
            )
            let relevantExecutions = (try? modelContext.fetch(descriptor)) ?? []
            
            // 直接在主线程获取对象
            if let validTask = (try? modelContext.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid }))).flatMap({ $0.first }) {
                TaskExecutionSupport.markTaskCompleted(
                    task: validTask,
                    occurrenceDate: occurrenceDate,
                    existingExecutions: relevantExecutions,
                    modelContext: modelContext
                )
                
                try? modelContext.save()
                
                // 告知全应用数据已变动，刷新必要 UI
                NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
            }
        }
    }

    private func optimisticCompleteHomeTask(taskID: UUID, occurrenceDate: Date) {
        withAnimation {
            guard let snapshot = dashboardSnapshot else { return }
            let allTaskItems = snapshot.todayPendingTasks + snapshot.historicalPendingTasks + snapshot.todayCompletedTasks
            guard let oldItem = allTaskItems.first(where: { $0.task.id == taskID && $0.occurrenceDate == occurrenceDate }) else { return }

            let newItem = HomeTaskDisplayItem(
                task: oldItem.task,
                section: .todayDone,
                occurrenceDate: oldItem.occurrenceDate,
                isCompleted: true,
                pendingOccurrenceCount: oldItem.pendingOccurrenceCount,
                historicalPendingCount: oldItem.historicalPendingCount,
                totalPendingOccurrenceCount: max(oldItem.totalPendingOccurrenceCount - 1, 0),
                overdueOriginText: oldItem.overdueOriginText,
                totalSubtaskCount: oldItem.totalSubtaskCount,
                completedSubtaskCount: oldItem.totalSubtaskCount
            )
            let completedTodayPending = oldItem.section == .todayPending
            let completedHistoricalPending = oldItem.section == .historicalPending

            dashboardSnapshot = DashboardSnapshot(
                childName: snapshot.childName,
                dueItems: snapshot.dueItems,
                allDueCount: snapshot.allDueCount,
                masteredReviewCount: snapshot.masteredReviewCount,
                todayCompletedCount: snapshot.todayCompletedCount,
                todayWrongCount: snapshot.todayWrongCount,
                todayCorrectCount: snapshot.todayCorrectCount,
                todayAccuracyText: snapshot.todayAccuracyText,
                todayDictationReviewedEntryCount: snapshot.todayDictationReviewedEntryCount,
                pendingDictationCount: snapshot.pendingDictationCount,
                pendingDictationSessionCount: snapshot.pendingDictationSessionCount,
                latestDictationSession: snapshot.latestDictationSession,
                latestDictationEntryCount: snapshot.latestDictationEntryCount,
                dictationEntriesBySessionID: snapshot.dictationEntriesBySessionID,
                todaySchedules: snapshot.todaySchedules,
                todayPendingTasks: snapshot.todayPendingTasks.filter { !($0.task.id == taskID && $0.occurrenceDate == occurrenceDate) },
                historicalPendingTasks: snapshot.historicalPendingTasks.filter { !($0.task.id == taskID && $0.occurrenceDate == occurrenceDate) },
                historicalPendingTaskCount: max(snapshot.historicalPendingTaskCount - (completedHistoricalPending ? 1 : 0), 0),
                todayCompletedTasks: completedTodayPending ? snapshot.todayCompletedTasks + [newItem] : snapshot.todayCompletedTasks,
                todayCompletedTaskCount: snapshot.todayCompletedTaskCount + (completedTodayPending ? 1 : 0),
                totalPendingTaskCount: max(snapshot.totalPendingTaskCount - 1, 0),
                calendarWeeks: snapshot.calendarWeeks,
                activeTaskCount: snapshot.activeTaskCount,
                pointBalance: snapshot.pointBalance + PointLedgerService.taskRewardAmount,
                pointsEarnedToday: snapshot.pointsEarnedToday + PointLedgerService.taskRewardAmount,
                currentPointStreak: snapshot.currentPointStreak,
                wrongReviewSamples: snapshot.wrongReviewSamples,
                heroIconName: snapshot.heroIconName,
                heroMessage: snapshot.heroMessage,
                heroSubtitle: snapshot.heroSubtitle,
                heroGradientColors: snapshot.heroGradientColors
            )
        }

        if let dashboardSnapshot {
            refreshDailySummary(for: dashboardSnapshot, force: false)
        }
    }

    private func saveAndReloadWidgetsDeferred() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            try? modelContext.save()
            WidgetCenter.shared.reloadAllTimelinesInBackground()
        }
    }

    private struct DeferredDashboardBoardView: View {
        @Environment(\.scenePhase) private var scenePhase

        @State private var isReady = false
        @State private var loadTask: Task<Void, Never>?

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if isReady {
                    DashboardBoardView()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.12, blue: 0.22),
                                Color(red: 0.04, green: 0.33, blue: 0.47),
                                Color(red: 0.05, green: 0.52, blue: 0.48)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .ignoresSafeArea()

                        VStack(spacing: 12) {
                            ProgressView()
                                .tint(.white)
                            Text("正在打开看板...")
                                .font(.headline)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
            }
            .onAppear {
                DashboardBoardWakeCoordinator.shared.activate(reason: "DeferredDashboardBoardView onAppear")
                loadAfterPresentationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    DashboardBoardWakeCoordinator.shared.activate(reason: "DeferredDashboardBoardView scenePhase active")
                    loadAfterPresentationSettles()
                } else if newPhase == .background {
                    DashboardBoardWakeCoordinator.shared.deactivate(reason: "DeferredDashboardBoardView scenePhase background")
                    loadTask?.cancel()
                } else {
                    DashboardBoardWakeCoordinator.shared.reinforceIfNeeded(reason: "DeferredDashboardBoardView scenePhase \(newPhase)")
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                loadTask?.cancel()
                DashboardBoardWakeCoordinator.shared.deactivate(reason: "DeferredDashboardBoardView onDisappear")
            }
        }

        private func loadAfterPresentationSettles() {
            loadTask?.cancel()
            guard !isReady else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }
                isReady = true
            }
        }
    }

    private struct HomeDeferredTaskDetailView: View {
        @Environment(\.scenePhase) private var scenePhase

        let route: HomeTaskDetailRoute

        @State private var loadTask: Task<Void, Never>?
        @State private var isReady = false

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if isReady {
                    TaskDetailView(taskID: route.taskID, initialTitle: route.title)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打开 \(route.title)…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadTaskAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadTaskAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }

        private func loadTaskAfterNavigationSettles() {
            loadTask?.cancel()
            guard !isReady else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }
                isReady = true
            }
        }
    }

    private struct HomeDeferredReviewSessionView: View {
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.modelContext) private var modelContext

        let route: HomeReviewRoute

        @State private var items: [ReviewItem]?
        @State private var loadTask: Task<Void, Never>?
        @State private var loadFailed = false

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if let items {
                    if route.style == .batch {
                        BatchReviewSessionView(items: items)
                    } else {
                        ReviewSessionView(items: items)
                    }
                } else if loadFailed {
                    ContentUnavailableView("没有可复习内容", systemImage: "checkmark.seal")
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在准备复习...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(route.style == .batch ? "复习听写" : "复习")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }

        private func loadAfterNavigationSettles() {
            loadTask?.cancel()
            guard items == nil else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }

                let container = modelContext.container
                let pids = await Task.detached(priority: .userInitiated) {
                    let ctx = ModelContext(container)
                    let ids = route.itemIDs
                    let order = Dictionary(
                        ids.enumerated().map { ($0.element, $0.offset) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let fetched = (try? ctx.fetch(FetchDescriptor<ReviewItem>())) ?? []
                    let filtered = fetched
                        .filter { order[$0.id] != nil }
                        .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
                    var seenIDs = Set<UUID>()
                    let deduplicated = filtered.filter { item in
                        seenIDs.insert(item.id).inserted
                    }
                    return deduplicated.map { $0.persistentModelID }
                }.value

                guard !Task.isCancelled else { return }
                guard canLoad else { return }

                let resolvedItems: [ReviewItem] = pids.compactMap { pid in
                    let registered: ReviewItem? = modelContext.registeredModel(for: pid)
                    if let registered { return registered }
                    
                    return modelContext.model(for: pid) as? ReviewItem
                }

                items = resolvedItems
                loadFailed = resolvedItems.isEmpty
            }
        }
    }

    private struct HomeDeferredDailyReviewRecordsView: View {
        @Environment(\.scenePhase) private var scenePhase

        let route: HomeDailyReviewRecordRoute

        @State private var isReady = false
        @State private var loadTask: Task<Void, Never>?

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if isReady {
                    DailyReviewRecordHistoryView()
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打开 \(route.title)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }

        private func loadAfterNavigationSettles() {
            loadTask?.cancel()
            guard !isReady else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }
                isReady = true
            }
        }
    }

    private struct HomeDeferredDictationSessionView: View {
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.modelContext) private var modelContext

        let route: HomeDictationSessionRoute

        @State private var session: DictationSession?
        @State private var entries: [DictationEntry] = []
        @State private var loadTask: Task<Void, Never>?
        @State private var loadFailed = false

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if let session {
                    DictationSessionView(session: session, entries: entries)
                } else if loadFailed {
                    ContentUnavailableView("听写不存在", systemImage: "exclamationmark.triangle")
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在打开 \(route.title)...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle(route.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                loadAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    loadAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }

        private func loadAfterNavigationSettles() {
            loadTask?.cancel()
            guard session == nil else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }

                do {
                    let sessionID = route.id
                    var sessionDescriptor = FetchDescriptor<DictationSession>(
                        predicate: #Predicate<DictationSession> { $0.id == sessionID }
                    )
                    sessionDescriptor.fetchLimit = 1
                    let loadedSession = try modelContext.fetch(sessionDescriptor).first
                    let loadedEntries = try modelContext.fetch(
                        FetchDescriptor<DictationEntry>(
                            predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID },
                            sortBy: [SortDescriptor(\.sortOrder)]
                        )
                    )

                    session = loadedSession
                    entries = loadedEntries
                    loadFailed = loadedSession == nil
                } catch {
                    loadFailed = true
                }
            }
        }
    }

    private var syncStatusSummaryCard: some View {
        let style = syncSummaryStyle

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.tint)
                Text(syncStatusStore.syncNoticeTitle)
                    .font(.headline)
                    .foregroundStyle(style.tint)
            }

            Text(syncStatusStore.syncNoticeMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: syncStatusStore.isUsingLocalFallback ? "externaldrive.fill.badge.xmark" : "externaldrive.fill.badge.checkmark")
                    .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
                Text(syncStatusStore.storageModeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(syncStatusStore.isUsingLocalFallback ? .red : .green)
            }

            if !syncStatusStore.cloudKitInitializationError.isEmpty {
                Text(syncStatusStore.cloudKitInitializationError)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.red.opacity(0.82))
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private var syncSummaryStyle: (symbol: String, tint: Color, background: Color) {
        switch syncStatusStore.syncNoticeKind {
        case .checking:
            return ("arrow.triangle.2.circlepath", .cyan, .cyan.opacity(0.08))
        case .ready:
            return ("checkmark.icloud.fill", .green, .green.opacity(0.08))
        case .caution:
            return ("exclamationmark.icloud.fill", .orange, .orange.opacity(0.08))
        case .blocked:
            return ("icloud.slash.fill", .red, .red.opacity(0.08))
        }
    }
}

private struct DailyReviewRecordSnapshot: Identifiable {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let reviewedAtText: String
    let itemType: ReviewItemType?
    let content: String
    let prompt: String?
    let source: String?
    let result: ReviewResult
    let resultText: String
    let resultIconName: String
    let resultColor: Color
    let modeText: String?
    let stageTransitionText: String
    let detailText: String?

    init(record: ReviewRecord, item: ReviewItem?) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        reviewedAtText = record.reviewedAt.formatted(date: .omitted, time: .shortened)
        itemType = item?.type
        content = item?.content ?? "题目已删除"

        let trimmedPrompt = item?.prompt.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        prompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt

        let trimmedSource = item?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        source = trimmedSource.isEmpty ? nil : trimmedSource

        result = record.result
        resultText = record.resultDisplayText
        resultIconName = record.resultIconName
        resultColor = record.resultColor
        modeText = record.modeDisplayText
        stageTransitionText = record.stageTransitionText
        detailText = record.condensedDisplayDetailText
    }
}

private struct DailyReviewRecordSection: Identifiable {
    let date: Date
    let records: [DailyReviewRecordSnapshot]

    var id: Date { date }

    var title: String {
        date.formatted(.dateTime.year().month().day().weekday(.abbreviated))
    }

    var reviewedWordCount: Int {
        Set(records.map(\.itemID)).count
    }

    var totalCount: Int { records.count }

    var correctCount: Int {
        records.filter { $0.result == .correct }.count
    }

    var wrongCount: Int {
        records.filter { $0.result == .wrong }.count
    }

    var accuracyText: String {
        guard totalCount > 0 else { return "--" }
        let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
        return "\(accuracy)%"
    }

    var summaryLine: String {
        "复习词量 \(reviewedWordCount) 个 · 答对 \(correctCount) 次 · 答错 \(wrongCount) 次 · 正确率 \(accuracyText)"
    }
}

private enum DailyReviewRecordBuilder {
    static func itemsByID(from reviewItems: [ReviewItem]) -> [UUID: ReviewItem] {
        reviewItems.reduce(into: [UUID: ReviewItem]()) { result, item in
            // Imported historical data may contain duplicated UUIDs; keep the first
            // item from the reverse-sorted query so the newest copy wins.
            guard result[item.id] == nil else { return }
            result[item.id] = item
        }
    }

    static func sections(reviewRecords: [ReviewRecord], reviewItems: [ReviewItem]) -> [DailyReviewRecordSection] {
        let itemsByID = itemsByID(from: reviewItems)
        let snapshots = reviewRecords.map { record in
            DailyReviewRecordSnapshot(record: record, item: itemsByID[record.itemID])
        }

        let grouped = Dictionary(grouping: snapshots) {
            Calendar.current.startOfDay(for: $0.reviewedAt)
        }

        return grouped
            .map { date, records in
                DailyReviewRecordSection(
                    date: date,
                    records: records.sorted { $0.reviewedAt > $1.reviewedAt }
                )
            }
            .sorted { $0.date > $1.date }
    }

    static func section(
        for date: Date,
        reviewRecords: [ReviewRecord],
        reviewItems: [ReviewItem]
    ) -> DailyReviewRecordSection? {
        let targetDay = Calendar.current.startOfDay(for: date)
        return sections(reviewRecords: reviewRecords, reviewItems: reviewItems)
            .first(where: { Calendar.current.isDate($0.date, inSameDayAs: targetDay) })
    }
}

private struct DailyReviewRecordHistoryView: View {
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]

    private var sections: [DailyReviewRecordSection] {
        DailyReviewRecordBuilder.sections(
            reviewRecords: reviewRecords,
            reviewItems: reviewItems
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView(showsIndicators: false) {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "还没有复习记录",
                        systemImage: "calendar.badge.clock",
                        description: Text("做过一次正式复习后，这里会按日期自动整理每天的复习情况。")
                    )
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                } else {
                    VStack(spacing: 16) {
                        ForEach(sections) { section in
                            NavigationLink {
                                DailyReviewRecordDayDetailView(date: section.date)
                            } label: {
                                HStack(alignment: .center, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(section.title)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)

                                        Text(section.summaryLine)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    Spacer(minLength: 12)

                                    Image(systemName: "chevron.right")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(20)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(isWide ? 32 : 20)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

private struct DailyReviewRecordDayDetailView: View {
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]

    let date: Date

    private var section: DailyReviewRecordSection? {
        DailyReviewRecordBuilder.section(
            for: date,
            reviewRecords: reviewRecords,
            reviewItems: reviewItems
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: isWide ? 4 : 2
            )

            ScrollView(showsIndicators: false) {
                if let section {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.system(.title3, design: .rounded, weight: .bold))
                                Text("当天共复习 \(section.reviewedWordCount) 个词")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            LazyVGrid(columns: columns, spacing: 12) {
                                StatGridCard(icon: "character.book.closed", title: "复习词量", value: "\(section.reviewedWordCount)", tint: .blue)
                                StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(section.correctCount)", tint: .green)
                                StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(section.wrongCount)", tint: .red)
                                StatGridCard(icon: "percent", title: "正确率", value: section.accuracyText, tint: .orange)
                            }

                            VStack(spacing: 12) {
                                ForEach(section.records.indices, id: \.self) { index in
                                    let record = section.records[index]
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: record.resultIconName)
                                                .font(.title3)
                                                .foregroundStyle(record.resultColor)

                                            VStack(alignment: .leading, spacing: 8) {
                                                HStack(spacing: 8) {
                                                    Text(record.reviewedAtText)
                                                        .font(.subheadline.weight(.semibold))

                                                    Spacer(minLength: 8)

                                                    Text(record.resultText)
                                                        .font(.caption.weight(.bold))
                                                        .foregroundStyle(record.resultColor)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(record.resultColor.opacity(0.12), in: Capsule())

                                                    if let modeText = record.modeText {
                                                        Text(modeText)
                                                            .font(.caption.weight(.semibold))
                                                            .foregroundStyle(.secondary)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 4)
                                                            .background(Color.secondary.opacity(0.12), in: Capsule())
                                                    }
                                                }

                                                HStack(spacing: 8) {
                                                    if let itemType = record.itemType {
                                                        TypeBadge(type: itemType)
                                                    }

                                                    Text(record.content)
                                                        .font(.headline)
                                                        .foregroundStyle(.primary)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }

                                                Text(record.stageTransitionText)
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundStyle(.secondary)

                                                if let detailText = record.detailText {
                                                    Text(detailText)
                                                        .font(.subheadline)
                                                        .foregroundStyle(.primary)
                                                }

                                                if let prompt = record.prompt {
                                                    Text(prompt)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }

                                                if let source = record.source {
                                                    Label(source, systemImage: "bookmark.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.tertiary)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                    }
                    .padding(isWide ? 24 : 16)
                } else {
                    ContentUnavailableView(
                        "这一天没有复习记录",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("这一天的记录可能已经被撤销或删除。")
                    )
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height * 0.7)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .navigationTitle(date.formatted(.dateTime.month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Home Dictation Preview

private struct HomeDictationPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()

    let session: HomeDictationSessionProjection
    let entries: [HomeDictationEntryProjection]
    var onStartSession: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))

                        Text("共 \(entries.count) 条内容 · \(session.type.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    VStack(spacing: 12) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 22, height: 22)
                                            .background(Color.blue.opacity(0.1), in: Circle())

                                        TypeBadge(type: entry.type)

                                        Spacer()
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)

                                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(entry.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.blue)
                                        }

                                        if let phonetic = phoneticText(for: entry) {
                                            Text(phonetic)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                Button {
                                    speaker.speak(content: entry.content, type: entry.type, prompt: entry.prompt)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle("听写预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        dismiss()
                        onStartSession()
                    } label: {
                        Text("开始听写")
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                    .padding()
                }
                .background(.bar)
            }
        }
    }

    private func phoneticText(for entry: HomeDictationEntryProjection) -> String? {
        guard entry.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: entry.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

// MARK: - Review Preview View

private struct ReviewPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()
    
    let items: [HomeReviewItemProjection]
    var onStartReview: () -> Void
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("今日待复习")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        
                        Text("共 \(items.count) 项错题内容")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    
                    VStack(spacing: 12) {
                        ForEach(items.indices, id: \.self) { index in
                            let item = items[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.orange)
                                            .frame(width: 22, height: 22)
                                            .background(Color.orange.opacity(0.1), in: Circle())
                                        
                                        TypeBadge(type: item.type)
                                        
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)
                                        
                                        if !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(item.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.orange)
                                        }

                                        if let phonetic = phoneticText(for: item) {
                                            Text(phonetic)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    speaker.speak(content: item.content, type: item.type, prompt: item.prompt)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.orange.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle("复习预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .onDisappear {
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        dismiss()
                        onStartReview()
                    } label: {
                        Text("开始复习")
                    }
                    .buttonStyle(ResultButtonStyle(color: .orange))
                    .padding()
                }
                .background(.bar)
            }
        }
    }

    private func phoneticText(for item: HomeReviewItemProjection) -> String? {
        guard item.type == .englishWord,
              let gloss = EnglishGlossService.shared.lookup(text: item.content),
              !gloss.displayPhonetic.isEmpty else {
            return nil
        }
        return gloss.displayPhonetic
    }
}

private struct SyncStatusIconView: View {
    let isRefreshing: Bool

    var body: some View {
        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
            .symbolVariant(isRefreshing ? .circle : .none)
    }
}
