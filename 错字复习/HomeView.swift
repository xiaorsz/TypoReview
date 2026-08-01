
import SwiftUI
import SwiftData
import Observation
import AVFoundation
import AVKit
import WidgetKit
import UIKit

struct HomeReviewItemProjection: Identifiable, Hashable {
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
        ReviewScheduler.isMastered(stage: stage, consecutiveWrongCount: consecutiveWrongCount)
            && nextReviewAt == .distantFuture
    }

    var contentIdentityKey: String {
        ReviewContentIdentity.key(type: type, content: content)
    }
}

struct HomeReviewRecordProjection {
    let id: UUID
    let itemID: UUID
    let reviewedAt: Date
    let result: ReviewResult
    let mode: ReviewMode
    let oldStage: Int
    let newStage: Int

    init(_ record: ReviewRecord) {
        id = record.id
        itemID = record.itemID
        reviewedAt = record.reviewedAt
        result = record.result
        mode = record.mode
        oldStage = record.oldStage
        newStage = record.newStage
    }

    static func canonicalRecords(_ records: [HomeReviewRecordProjection]) -> [HomeReviewRecordProjection] {
        Dictionary(grouping: records, by: \.itemID).values
            .flatMap { itemRecords -> [HomeReviewRecordProjection] in
                let ordered = itemRecords.sorted {
                    if $0.reviewedAt != $1.reviewedAt {
                        return $0.reviewedAt < $1.reviewedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                var seenCycleIDs = Set<UUID>()
                var resolvedStage: Int?
                var result: [HomeReviewRecordProjection] = []

                for record in ordered {
                    guard seenCycleIDs.insert(record.id).inserted else { continue }
                    if let resolvedStage,
                       record.result == .correct,
                       record.oldStage < resolvedStage,
                       record.newStage <= resolvedStage {
                        continue
                    }
                    result.append(record)
                    resolvedStage = record.newStage
                }
                return result
            }
    }
}

struct HomeReviewDailyPlanProjection: Sendable {
    let id: UUID
    let dayKey: String
    let itemIDs: [UUID]
    let createdAt: Date

    init(_ plan: ReviewDailyPlan) {
        id = plan.id
        dayKey = plan.dayKey
        itemIDs = plan.itemIDs
        createdAt = plan.createdAt
    }
}

struct HomeDictationSessionProjection: Identifiable, Hashable {
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

struct HomeDictationEntryProjection: Identifiable, Hashable {
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

struct HomeScheduleProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let note: String
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
        note = schedule.note
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

    init(_ task: HomeTaskModelProjection) {
        self.task = task.task
        self.isArchived = task.isArchived
    }
}

struct HomeTaskModelProjection: Sendable {
    let task: TaskProjection
    let isArchived: Bool
    let updatedAt: Date

    init(_ task: TaskItem) {
        self.task = TaskProjection(task)
        isArchived = task.isArchived
        updatedAt = task.updatedAt
    }
}

struct HomeDashboardSourceSnapshot {
    let reviewItems: [HomeReviewItemProjection]
    let reviewRecords: [HomeReviewRecordProjection]
    let reviewDailyPlans: [HomeReviewDailyPlanProjection]
    let dictationSessions: [HomeDictationSessionProjection]
    let dictationEntries: [HomeDictationEntryProjection]
    let schedules: [HomeScheduleProjection]
    let tasks: [HomeTaskModelProjection]
    let taskExecutions: [TaskExecutionRecordProjection]
    let taskSubtasks: [TaskSubitemProjection]
    let pointBalance: Int
    let pointsEarnedToday: Int
    let currentPointStreak: Int

    static let empty = HomeDashboardSourceSnapshot(
        reviewItems: [],
        reviewRecords: [],
        reviewDailyPlans: [],
        dictationSessions: [],
        dictationEntries: [],
        schedules: [],
        tasks: [],
        taskExecutions: [],
        taskSubtasks: [],
        pointBalance: 0,
        pointsEarnedToday: 0,
        currentPointStreak: 0
    )
}

private func deduplicatedHomeTasks(_ tasks: [HomeTaskModelProjection]) -> [HomeTaskModelProjection] {
    var preferredTaskByKey: [String: HomeTaskModelProjection] = [:]
    var keyOrder: [String] = []

    for task in tasks {
        let normalizedTitle = task.task.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let key = normalizedTitle.isEmpty
            ? "id:\(task.task.id.uuidString.lowercased())"
            : "title:\(normalizedTitle)"
        let sortKey = TaskModelDedupSortKey(
            archivedPriority: task.isArchived ? 0 : 1,
            updatedAt: task.updatedAt,
            createdAt: task.task.createdAt,
            stableID: task.task.id.uuidString
        )

        if let current = preferredTaskByKey[key] {
            let currentSortKey = TaskModelDedupSortKey(
                archivedPriority: current.isArchived ? 0 : 1,
                updatedAt: current.updatedAt,
                createdAt: current.task.createdAt,
                stableID: current.task.id.uuidString
            )
            if currentSortKey < sortKey {
                preferredTaskByKey[key] = task
            }
        } else {
            preferredTaskByKey[key] = task
            keyOrder.append(key)
        }
    }

    return keyOrder.compactMap { preferredTaskByKey[$0] }
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

private enum DailyQuotePresentationState: Equatable {
    case loading
    case available(DailyQuote)
    case exhausted
    case unavailable
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
    @State private var dailyQuoteState: DailyQuotePresentationState = .loading
    @State private var dailyQuoteDetail: DailyQuote?
    @State private var dailyQuoteTask: Task<Void, Never>?

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
        let aiErrorMessage: String?
    }

    private struct DashboardSnapshot {
        let childName: String
        let dueItems: [HomeReviewItemProjection]
        let allDueCount: Int
        let hasReachedDailyReviewLimit: Bool
        let dailyReviewPlanItemIDs: [UUID]
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
        let recentPlans: [RecentPlanProjection]
        let calendarWeeks: [HomeCalendarWeekSummary]
        let activeTaskCount: Int
        let pointBalance: Int
        let pointsEarnedToday: Int
        let currentPointStreak: Int
        let wrongReviewSamples: [String]
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
            dailyPlanItemIDs: [UUID]?,
            reviewItems: [HomeReviewItemProjection],
            reviewRecords: [HomeReviewRecordProjection],
            dictationSessions: [HomeDictationSessionProjection],
            dictationEntries: [HomeDictationEntryProjection],
            schedules: [HomeScheduleProjection],
            taskItems: [HomeTaskDisplayItem],
            calendarTasks: [HomeCalendarTaskProjection],
            taskExecutions: [TaskExecutionRecordProjection],
            taskSubtasks: [TaskSubitemProjection],
            recentPlans: [RecentPlanProjection],
            activeTaskCount: Int,
            pointBalance: Int,
            pointsEarnedToday: Int,
            currentPointStreak: Int,
            referenceDate: Date = .now
        ) -> DashboardSnapshot {
            let name = childName.isEmpty ? "小朋友" : childName
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: referenceDate)
            let reviewRecords = HomeReviewRecordProjection.canonicalRecords(reviewRecords)

            let canonicalReviewItems = canonicalItems(from: reviewItems)
            let sortedDue = canonicalReviewItems
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
            let todayRecs = reviewRecords.filter { calendar.isDate($0.reviewedAt, inSameDayAs: referenceDate) }
            var seenReviewedTodayItemIDs = Set<UUID>()
            let reviewedTodayItemIDsInOrder = todayRecs
                .filter { $0.mode != .dictation }
                .sorted {
                    if $0.reviewedAt != $1.reviewedAt {
                        return $0.reviewedAt < $1.reviewedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .compactMap { record in
                    seenReviewedTodayItemIDs.insert(record.itemID).inserted ? record.itemID : nil
                }
            let reviewedTodayItemIDs = Set(reviewedTodayItemIDsInOrder)
            var seenDueItemIDs = Set<UUID>()
            let allDue = sortedDue.filter { item in
                guard !reviewedTodayItemIDs.contains(item.id) else { return false }
                return seenDueItemIDs.insert(item.id).inserted
            }
            let plannedItemIDs: [UUID]
            if let dailyPlanItemIDs {
                plannedItemIDs = ReviewDailyPlan.reconciledItemIDs(
                    existingItemIDs: dailyPlanItemIDs,
                    reviewedTodayItemIDs: reviewedTodayItemIDsInOrder,
                    availableDueItemIDs: allDue.map(\.id),
                    dailyLimit: dailyLimit
                )
            } else {
                plannedItemIDs = ReviewDailyPlan.reconciledItemIDs(
                    existingItemIDs: [],
                    reviewedTodayItemIDs: reviewedTodayItemIDsInOrder,
                    availableDueItemIDs: allDue.map(\.id),
                    dailyLimit: dailyLimit
                )
            }
            let dueByID = Dictionary(uniqueKeysWithValues: allDue.map { ($0.id, $0) })
            let cappedDueContent: [HomeReviewItemProjection] = plannedItemIDs.compactMap { itemID in
                guard !reviewedTodayItemIDs.contains(itemID) else { return nil }
                return dueByID[itemID]
            }
            let completedPlannedItemCount = plannedItemIDs.filter(reviewedTodayItemIDs.contains).count
            let hasReachedDailyReviewLimit = !plannedItemIDs.isEmpty
                && completedPlannedItemCount >= plannedItemIDs.count
                && !allDue.isEmpty
            let masteredReviewCount = canonicalReviewItems.filter(\.isMastered).count

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

            let sortedVisibleSchedules = schedules
                .filter { $0.shouldAppear(on: referenceDate) && !$0.hasEnded(on: referenceDate, reference: referenceDate) }
                .sorted { lhs, rhs in
                    if lhs.startTimeMinutes != rhs.startTimeMinutes {
                        return lhs.startTimeMinutes < rhs.startTimeMinutes
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            let tSchedules = ScheduleDedupSupport.deduplicated(sortedVisibleSchedules) { schedule in
                ScheduleDisplayIdentity(
                    title: schedule.title,
                    note: schedule.note,
                    startTime: schedule.startTime,
                    endTime: schedule.endTime,
                    repeatRule: schedule.repeatRule,
                    weekdays: schedule.weekdays,
                    effectiveStartDate: schedule.effectiveStartDate,
                    effectiveEndDate: schedule.effectiveEndDate,
                    calendar: calendar
                )
            }

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
                    if totPendingTaskCount > 0 && !cappedDueContent.isEmpty { return [.orange.opacity(0.95), .pink.opacity(0.78)] }
                    return [.blue.opacity(0.8), .cyan.opacity(0.6)]
                }
                return [.blue.opacity(0.8), .cyan.opacity(0.6)]
            }()

            return DashboardSnapshot(
                childName: name,
                dueItems: cappedDueContent,
                allDueCount: allDue.count,
                hasReachedDailyReviewLimit: hasReachedDailyReviewLimit,
                dailyReviewPlanItemIDs: plannedItemIDs,
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
                recentPlans: recentPlans,
                calendarWeeks: calendarWeeks,
                activeTaskCount: activeTaskCount,
                pointBalance: pointBalance,
                pointsEarnedToday: pointsEarnedToday,
                currentPointStreak: currentPointStreak,
                wrongReviewSamples: wrongSamples,
                heroSubtitle: hSubtitle,
                heroGradientColors: hGradient
            )
        }

        private static func canonicalItems(from items: [HomeReviewItemProjection]) -> [HomeReviewItemProjection] {
            var canonicalByKey: [String: HomeReviewItemProjection] = [:]

            for item in items {
                guard !ReviewContentIdentity.normalizedContent(item.content, type: item.type).isEmpty else { continue }
                if let current = canonicalByKey[item.contentIdentityKey] {
                    if isPreferred(item, over: current) {
                        canonicalByKey[item.contentIdentityKey] = item
                    }
                } else {
                    canonicalByKey[item.contentIdentityKey] = item
                }
            }

            return Array(canonicalByKey.values)
        }

        private static func isPreferred(_ candidate: HomeReviewItemProjection, over current: HomeReviewItemProjection) -> Bool {
            let candidateFinished = candidate.nextReviewAt == .distantFuture
            let currentFinished = current.nextReviewAt == .distantFuture
            if candidateFinished != currentFinished {
                return candidateFinished
            }
            if candidate.stage != current.stage {
                return candidate.stage > current.stage
            }
            if candidate.consecutiveWrongCount != current.consecutiveWrongCount {
                return candidate.consecutiveWrongCount < current.consecutiveWrongCount
            }
            if candidate.nextReviewAt != current.nextReviewAt {
                return candidate.nextReviewAt > current.nextReviewAt
            }
            if candidate.createdAt != current.createdAt {
                return candidate.createdAt < current.createdAt
            }
            return candidate.id.uuidString < current.id.uuidString
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
            task.occurs(on: day, calendar: calendar)
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
        let model = DeepSeekSummaryModel(rawValue: appSettingsStore.aiSummaryModelRawValue) ?? .flash
        let fallbackResult = input.localFallbackResult()

        guard appSettingsStore.aiSummaryEnabled else {
            dailySummaryTask?.cancel()
            dailySummaryPresentation = DailySummaryPresentation(
                inputHash: inputHash,
                modelRawValue: model.rawValue,
                result: fallbackResult,
                isAIResult: false,
                isLoading: false,
                aiErrorMessage: nil
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
                isLoading: false,
                aiErrorMessage: "未填写 DeepSeek API Key"
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
                isLoading: false,
                aiErrorMessage: nil
            )
            return
        }

        dailySummaryTask?.cancel()
        dailySummaryPresentation = DailySummaryPresentation(
            inputHash: inputHash,
            modelRawValue: model.rawValue,
            result: fallbackResult,
            isAIResult: false,
            isLoading: true,
            aiErrorMessage: nil
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
                        isLoading: false,
                        aiErrorMessage: nil
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
                        isLoading: false,
                        aiErrorMessage: error.localizedDescription
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
        let isSummaryAIResult = dailySummaryPresentation?.inputHash == summaryHash
            ? dailySummaryPresentation?.isAIResult == true
            : false
        let summaryAIErrorMessage = dailySummaryPresentation?.inputHash == summaryHash
            ? dailySummaryPresentation?.aiErrorMessage
            : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(heroSummaryText(snapshot, result: summaryResult))
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                VStack(spacing: 4) {
                    if isSummaryLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .frame(width: 28, height: 28)
                    } else if appSettingsStore.aiSummaryEnabled {
                        Button {
                            refreshDailySummary(for: snapshot, force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(width: 28, height: 28)
                                .background(.white.opacity(0.14), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("重新生成今日小结")
                    }

                    dailySummarySourceBadge(
                        isAIResult: isSummaryAIResult,
                        isLoading: isSummaryLoading,
                        errorMessage: summaryAIErrorMessage
                    )
                }
            }

            heroMetricStrip(snapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: snapshot.heroGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .saturation(0.82)
        )
    }

    private func dailySummarySourceBadge(isAIResult: Bool, isLoading: Bool, errorMessage: String?) -> some View {
        let trimmedError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasError = !trimmedError.isEmpty
        let title = isLoading ? "AI 生成中" : (isAIResult ? "AI 小结" : "本地小结")
        let backgroundColor: Color = hasError
            ? .orange.opacity(0.62)
            : (isAIResult || isLoading ? .purple.opacity(0.58) : .white.opacity(0.16))

        return Group {
            if hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
            } else if isAIResult || isLoading {
                Text("AI")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            } else {
                Image(systemName: "iphone")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: 28, height: 28)
            .background(backgroundColor, in: Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .accessibilityLabel(hasError ? "AI 失败，已使用本地小结：\(trimmedError)" : title)
    }

    private func heroMetricStrip(_ snapshot: DashboardSnapshot) -> some View {
        HStack(spacing: 8) {
            heroMetricTile(
                icon: "checklist",
                title: "任务",
                value: "\(snapshot.totalPendingTaskCount)",
                caption: snapshot.historicalPendingTaskCount > 0
                    ? "含历史 \(snapshot.historicalPendingTaskCount)"
                    : "待完成"
            )

            Button {
                activeReviewRoute = HomeReviewRoute(itemIDs: snapshot.dueItemIDs, style: reviewStyle)
            } label: {
                heroMetricTile(
                    icon: "book.closed",
                    title: "复习",
                    value: "\(snapshot.dueItems.count)",
                    caption: snapshot.hasReachedDailyReviewLimit
                        ? "今日额度已完成"
                        : snapshot.allDueCount > snapshot.dueItems.count
                            ? "到期 \(snapshot.allDueCount)"
                            : "待复习",
                    showsDisclosureIndicator: true
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityHint("进入今日复习")

            Button {
                openDictationHome(source: "home hero metric")
            } label: {
                heroMetricTile(
                    icon: "text.book.closed",
                    title: "听写",
                    value: "\(snapshot.pendingDictationCount)",
                    caption: "待听写",
                    showsDisclosureIndicator: true
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityHint("进入听写页面")
        }
    }

    private func heroMetricTile(
        icon: String,
        title: String,
        value: String,
        caption: String,
        showsDisclosureIndicator: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 18, height: 18)
                    .background(.white.opacity(0.12), in: Circle())

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                if showsDisclosureIndicator {
                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .contentTransition(.numericText())

            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func heroSummaryText(_ snapshot: DashboardSnapshot, result: DailySummaryResult?) -> String {
        let summary = (result?.displayText ?? snapshot.heroSubtitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = snapshot.childName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return summary }
        guard !summary.isEmpty else { return name }

        if summary.hasPrefix(name) {
            let remainder = summary
                .dropFirst(name.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "，,。 ").union(.whitespacesAndNewlines))
            return remainder.isEmpty ? name : "\(name)，\(remainder)"
        }

        return "\(name)，\(summary)"
    }

    private func pointsSummaryCard(_ snapshot: DashboardSnapshot) -> some View {
        NavigationLink {
            PointsDashboardView(initialBalance: snapshot.pointBalance)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.opacity(0.09), in: Circle())

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
            .homeCardSurface(padding: 14)
        }
        .buttonStyle(.plain)
    }

    private func learningCalendarCard(_ snapshot: DashboardSnapshot) -> some View {
        let weekDays = snapshot.calendarWeeks.first?.days ?? []
        let daysWithTasks = weekDays.filter { $0.hasTasks }.count
        let daysCompleted = weekDays.filter { $0.hasTasks && !$0.hasIncompleteTasks }.count

        return VStack(alignment: .leading, spacing: isPad ? 18 : 12) {
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
                        .foregroundStyle(daysCompleted == daysWithTasks ? Color.green : Color.blue)
                        .padding(.horizontal, isPad ? 14 : 10)
                        .padding(.vertical, isPad ? 6 : 4)
                        .background(
                            (daysCompleted == daysWithTasks ? Color.green : Color.blue).opacity(0.11),
                            in: Capsule()
                        )
                } else {
                    Text("本周")
                        .font(isPad ? Font.subheadline.weight(.semibold) : Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: isPad ? 10 : 6) {
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
            HStack(spacing: isPad ? 20 : 12) {
                calendarLegendItem(color: .green, label: "已完成")
                calendarLegendItem(color: .orange, label: "进行中")
                calendarLegendItem(color: .purple, label: "复习")
                calendarLegendItem(color: .cyan, label: "听写")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCardSurface()
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
        VStack(spacing: isPad ? 9 : 5) {
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
        .frame(maxWidth: .infinity, minHeight: isPad ? 112 : 72)
        .padding(.vertical, isPad ? 10 : 5)
        .padding(.horizontal, isPad ? 6 : 2)
        .background(calendarDayBackground(day), in: RoundedRectangle(cornerRadius: isPad ? 16 : 10))
        .overlay {
            if day.isToday {
                RoundedRectangle(cornerRadius: isPad ? 16 : 10)
                    .stroke(.blue.opacity(0.75), lineWidth: 1.5)
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
        return day.hasIncompleteTasks ? .orange.opacity(0.08) : .green.opacity(0.1)
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
            refreshDailyQuote()
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
                    refreshDailyQuote()
                } else {
                    dashboardSnapshotTask?.cancel()
                    dailyQuoteTask?.cancel()
                }
            }
        ))
        .onChange(of: appSettingsStore.aiSummaryEnabled) { _, _ in
            if let dashboardSnapshot {
                refreshDailySummary(for: dashboardSnapshot, force: true)
            }
        }
        .onChange(of: appSettingsStore.aiSummaryModelRawValue) { _, _ in
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
            dailyQuoteTask?.cancel()
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
        .sheet(item: $dailyQuoteDetail) { quote in
            DailyQuoteDetailView(quote: quote)
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
                .onReceive(NotificationCenter.default.publisher(for: .appDataDidChange)) { _ in
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
                PersistentStoreAccessGate.withAccess {
                let calendar = Calendar.current

                // SwiftData models can be invalidated by a concurrent delete or CloudKit merge.
                // Materialize every model into an immutable value while the read transaction is active,
                // then perform the relatively expensive dashboard calculations using values only.
                let source = HomeDashboardDataLoader.load(
                    from: container,
                    referenceDate: referenceDate
                )
                let backgroundContext = ModelContext(container)

                let autoArchivedCompletedAtByTaskID = Dictionary(
                    source.taskExecutions.compactMap { record -> (UUID, Date)? in
                        guard record.status == .completed,
                              let completedAt = record.completedAt,
                              calendar.isDate(completedAt, inSameDayAs: referenceDate) else {
                            return nil
                        }
                        return (record.taskID, completedAt)
                    },
                    uniquingKeysWith: max
                )
                let visibleTaskModels = source.tasks.filter { task in
                    guard task.isArchived else { return true }
                    guard task.task.recurrence.kind == .once,
                          let completedAt = autoArchivedCompletedAtByTaskID[task.task.id] else {
                        return false
                    }
                    return task.updatedAt <= completedAt
                }
                let deduplicatedTaskModels = deduplicatedHomeTasks(source.tasks)
                let deduplicatedVisibleTaskModels = deduplicatedHomeTasks(visibleTaskModels)
                let activeTaskModels = deduplicatedTaskModels.filter {
                    !$0.isArchived && $0.task.timingMode == .scheduled
                }

                let taskProjections = deduplicatedVisibleTaskModels.map(\.task)
                let taskExecutionProjections = source.taskExecutions
                let taskSubitemProjections = source.taskSubtasks
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
                let recentPlans = RecentPlanSupport.visibleProjections(
                    from: deduplicatedTaskModels.map(\.task),
                    executions: taskExecutionProjections,
                    subtasks: taskSubitemProjections,
                    on: referenceDate,
                    includeCompletedToday: true,
                    calendar: calendar
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
                DebugPerf.mark("HomeView background snapshot fetch end reviews=\(source.reviewItems.count) records=\(source.reviewRecords.count) sessions=\(source.dictationSessions.count) entries=\(source.dictationEntries.count) schedules=\(source.schedules.count) tasks=\(deduplicatedVisibleTaskModels.count) todayPending=\(todayPendingSummaries) todayDone=\(todayDoneSummaries)")
                #endif

                let todayPlanKey = ReviewDailyPlan.dayKey(for: referenceDate, calendar: calendar)
                let existingDailyPlan = source.reviewDailyPlans
                    .filter { $0.dayKey == todayPlanKey }
                    .min { lhs, rhs in
                        if lhs.createdAt != rhs.createdAt {
                            return lhs.createdAt < rhs.createdAt
                        }
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                let snapshot = DashboardSnapshot.make(
                    childName: childName,
                    dailyLimit: dailyLimit,
                    dailyPlanItemIDs: existingDailyPlan?.itemIDs,
                    reviewItems: source.reviewItems,
                    reviewRecords: source.reviewRecords,
                    dictationSessions: source.dictationSessions,
                    dictationEntries: source.dictationEntries,
                    schedules: source.schedules,
                    taskItems: taskDisplayItems,
                    calendarTasks: deduplicatedTaskModels.map(HomeCalendarTaskProjection.init),
                    taskExecutions: taskExecutionProjections,
                    taskSubtasks: taskSubitemProjections,
                    recentPlans: recentPlans,
                    activeTaskCount: activeTaskModels.count,
                    pointBalance: source.pointBalance,
                    pointsEarnedToday: source.pointsEarnedToday,
                    currentPointStreak: source.currentPointStreak,
                    referenceDate: referenceDate
                )

                if let existingDailyPlan,
                   existingDailyPlan.itemIDs != snapshot.dailyReviewPlanItemIDs {
                    let planID = existingDailyPlan.id
                    let descriptor = FetchDescriptor<ReviewDailyPlan>(
                        predicate: #Predicate<ReviewDailyPlan> { $0.id == planID }
                    )
                    if let storedPlan = try? backgroundContext.fetch(descriptor).first {
                        storedPlan.itemIDs = snapshot.dailyReviewPlanItemIDs
                        try? backgroundContext.save()
                    }
                } else if existingDailyPlan == nil, !snapshot.dailyReviewPlanItemIDs.isEmpty {
                    backgroundContext.insert(
                        ReviewDailyPlan(
                            dayKey: todayPlanKey,
                            itemIDs: snapshot.dailyReviewPlanItemIDs,
                            createdAt: referenceDate,
                            updatedAt: referenceDate
                        )
                    )
                    try? backgroundContext.save()
                }

                return snapshot
                }
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

                VStack(spacing: 14) {
                    heroCard(snapshot)

                    dailyQuoteCard

                    if !AppStorePreviewMode.isEnabled && syncStatusStore.syncNoticeKind != .ready {
                        syncStatusSummaryCard
                    }

                    todayScheduleCard(snapshot)

                    recentPlansCard(snapshot)

                    todayTasksCard(snapshot)

                    learningCalendarCard(snapshot)

                    pointsSummaryCard(snapshot)

                    // Stat grid
                    statGridSection(snapshot)

                    if isWide {
                        HStack(spacing: 12) {
                            reviewEntryButton(snapshot)
                            dictationEntryButton(snapshot)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 10) {
                            reviewEntryButton(snapshot)
                            dictationEntryButton(snapshot)
                        }
                    }

                    quickEntryCard
                }
                .padding(isWide ? 28 : 16)
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

                VStack(spacing: 14) {
                    loadingHeroCard

                    dailyQuoteCard

                    if isWide {
                        HStack(spacing: 12) {
                            lightweightReviewPlaceholderCard
                            lightweightDictationEntryButton
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 10) {
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
                .padding(isWide ? 28 : 16)
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.8), .cyan.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    @ViewBuilder
    private var dailyQuoteCard: some View {
        switch dailyQuoteState {
        case .available(let quote):
            Button {
                dailyQuoteDetail = quote
            } label: {
                dailyQuoteCardContent(
                    badge: quote.kind.badgeTitle,
                    badgeColor: quote.kind == .verified ? .indigo : .teal,
                    text: quote.text,
                    attribution: quote.nonemptyAttribution,
                    showsDisclosure: true,
                    accessibilityLabel: dailyQuoteAccessibilityLabel(for: quote)
                )
            }
            .buttonStyle(.plain)

        case .loading:
            dailyQuoteCardContent(
                badge: "获取中",
                badgeColor: .secondary,
                text: "正在获取今天的每日一句…",
                attribution: nil,
                showsDisclosure: false,
                accessibilityLabel: "每日一句，正在获取"
            )

        case .exhausted:
            dailyQuoteCardContent(
                badge: "已用完",
                badgeColor: .orange,
                text: "每日一句已用完，等待服务器补充新内容。",
                attribution: nil,
                showsDisclosure: false,
                accessibilityLabel: "每日一句已用完，等待服务器补充新内容"
            )

        case .unavailable:
            dailyQuoteCardContent(
                badge: "暂未获取",
                badgeColor: .secondary,
                text: "联网后会自动获取今天的每日一句。",
                attribution: nil,
                showsDisclosure: false,
                accessibilityLabel: "每日一句暂未获取，联网后会自动获取"
            )
        }
    }

    private func dailyQuoteCardContent(
        badge: String,
        badgeColor: Color,
        text: String,
        attribution: String?,
        showsDisclosure: Bool,
        accessibilityLabel: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "quote.opening")
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.indigo)
                .frame(width: 38, height: 38)
                .background(Color.indigo.opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("每日一句")
                        .font(.headline)

                    Spacer(minLength: 8)

                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(badgeColor.opacity(0.1), in: Capsule())
                }

                Text(text)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let attribution {
                    Text("— \(attribution)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCardSurface(padding: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(showsDisclosure ? "轻点查看解释" : "")
        .animation(.easeInOut(duration: 0.25), value: dailyQuoteState)
    }

    private func dailyQuoteAccessibilityLabel(for quote: DailyQuote) -> String {
        let attributionText = quote.nonemptyAttribution.map { "，出处\($0)" } ?? ""
        return "每日一句，\(quote.kind.badgeTitle)，\(quote.text)\(attributionText)"
    }

    private func refreshDailyQuote(referenceDate: Date = .now) {
        dailyQuoteTask?.cancel()

        let expectedDayKey = DailyQuoteCache.shanghaiDayKey(for: referenceDate)
        if let cached = DailyQuoteCache.standard.load(for: expectedDayKey) {
            dailyQuoteState = .available(cached)
            return
        }
        dailyQuoteState = .loading

        dailyQuoteTask = Task {
            do {
                let response = try await ServerAPIClient.shared.dailyQuote()
                guard !Task.isCancelled,
                      DailyQuoteCache.shanghaiDayKey() == expectedDayKey,
                      response.date == expectedDayKey else {
                    return
                }
                switch response.status {
                case .available:
                    guard let quote = response.dailyQuote else {
                        dailyQuoteState = .unavailable
                        return
                    }
                    DailyQuoteCache.standard.save(quote)
                    dailyQuoteState = .available(quote)
                case .exhausted:
                    DailyQuoteCache.standard.clear()
                    dailyQuoteState = .exhausted
                }
            } catch {
                guard !Task.isCancelled,
                      DailyQuoteCache.shanghaiDayKey() == expectedDayKey else {
                    return
                }
                dailyQuoteState = .unavailable
            }
        }
    }

    private struct DailyQuoteDetailView: View {
        @Environment(\.dismiss) private var dismiss

        let quote: DailyQuote

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "quote.opening")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.indigo)
                                .accessibilityHidden(true)

                            Text(quote.text)
                                .font(.system(.title3, design: .rounded, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            if let attribution = quote.nonemptyAttribution {
                                Text("— \(attribution)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .homeCardSurface(padding: 18)

                        dailyQuoteDetailSection(
                            title: "这句话是什么意思",
                            icon: "text.book.closed",
                            color: .indigo,
                            text: quote.explanation
                        )

                        dailyQuoteDetailSection(
                            title: "今天可以这样做",
                            icon: "figure.walk",
                            color: .teal,
                            text: quote.action
                        )
                    }
                    .padding(16)
                    .frame(maxWidth: 700)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("每日一句")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            dismiss()
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private func dailyQuoteDetailSection(
            title: String,
            icon: String,
            color: Color,
            text: String
        ) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .homeCardSurface(padding: 16)
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.88))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding()
            .background(Color.teal.opacity(0.88))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statGridSection(_ snapshot: DashboardSnapshot) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

        LazyVGrid(columns: columns, spacing: 10) {
            Button {
                activeReviewRoute = HomeReviewRoute(itemIDs: snapshot.dueItemIDs, style: reviewStyle)
            } label: {
                HomeStatGridCard(icon: "book.closed", title: "今日待复习", value: "\(snapshot.dueItems.count)", tint: .orange)
            }
            .buttonStyle(.plain)
            .disabled(snapshot.dueItems.isEmpty)
            
            Button {
                openDictationHome(source: "home stat grid")
            } label: {
                HomeStatGridCard(icon: "text.book.closed", title: "待听写", value: "\(snapshot.pendingDictationCount)", tint: .teal)
            }
            .buttonStyle(.plain)

            dailyReviewRecordButton(
                icon: "checkmark.circle",
                title: "今日已完成",
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
            HomeStatGridCard(icon: "star.fill", title: "全部已掌握", value: "\(snapshot.masteredReviewCount)", tint: .mint)
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
            HomeStatGridCard(icon: icon, title: title, value: value, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private var quickEntryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.tip.crop.circle.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color.blue.opacity(0.09), in: Circle())
                Text("快速录入")
                    .font(isPad ? .title3.weight(.bold) : .headline)
                Spacer()
                Button {
                    showQuickEntryHint = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
            .alert("提示", isPresented: $showQuickEntryHint) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("把当天写错的词句或英语录进来，保存后会从明天开始进入正式复习。")
            }

            HStack(spacing: 10) {
                Button {
                    openAddReview(source: "home quick entry card")
                } label: {
                    quickEntryActionLabel(
                        title: "新增一条错题",
                        subtitle: "随手记一条",
                        icon: "square.and.pencil",
                        tint: .blue
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    BatchAddReviewItemsView()
                } label: {
                    quickEntryActionLabel(
                        title: "批量录入多条",
                        subtitle: "一次添加多条",
                        icon: "text.badge.plus",
                        tint: .indigo
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .homeCardSurface(padding: 12)
    }

    private func quickEntryActionLabel(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(tint.opacity(0.1), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: snapshot.dueItems.isEmpty
                    ? [.gray, .gray.opacity(0.8)]
                    : [.accentColor, .accentColor.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(0.82)
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.92), .teal.opacity(0.82)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .saturation(0.8)
        )
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
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
        if snapshot.hasReachedDailyReviewLimit {
            return "今日题量已经完成，剩余 \(snapshot.allDueCount) 项会在后续继续安排"
        }

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
            VStack(alignment: .leading, spacing: 12) {
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
            .homeCardSurface()
        }
    }

    // MARK: - Today Tasks

    @ViewBuilder
    private func recentPlansCard(_ snapshot: DashboardSnapshot) -> some View {
        if !snapshot.recentPlans.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text("近期计划")
                        .font(.headline)
                    Spacer()
                    Text("\(snapshot.recentPlans.filter { !$0.isCompleted }.count) 项待完成")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(snapshot.recentPlans) { plan in
                    recentPlanHomeRow(plan)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .homeCardSurface()
        }
    }

    private func recentPlanHomeRow(_ plan: RecentPlanProjection) -> some View {
        HStack(spacing: 10) {
            if plan.hasSubtasks {
                Image(systemName: plan.isCompleted ? "checkmark.circle.fill" : "list.bullet.circle")
                    .font(.title3)
                    .foregroundStyle(plan.isCompleted ? .green : .secondary)
            } else {
                Button {
                    if !plan.isCompleted {
                        completeRecentPlan(plan)
                    }
                } label: {
                    Image(systemName: plan.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(plan.isCompleted ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(plan.isCompleted)
            }

            NavigationLink(value: HomeTaskDetailRoute(taskID: plan.task.id, title: plan.task.title)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.task.title)
                        .fontWeight(.medium)
                        .foregroundStyle(plan.isCompleted ? .secondary : .primary)
                        .strikethrough(plan.isCompleted)

                    HStack(spacing: 5) {
                        Text("截止 \(plan.deadline.formatted(.dateTime.month().day()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(plan.isCompleted ? "今日已完成" : plan.deadlineState.statusText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(plan.isCompleted ? .green : recentPlanColor(plan.deadlineState))

                        if plan.hasSubtasks {
                            Text("· \(plan.completedSubtaskCount)/\(plan.totalSubtaskCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(plan.isCompleted ? .green : .blue)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
    }

    private func recentPlanColor(_ state: RecentPlanDeadlineState) -> Color {
        switch state.kind {
        case .overdue:
            return .red
        case .dueToday:
            return .orange
        case .upcoming:
            return state.dayCount <= 7 ? .orange : .blue
        }
    }

    private func completeRecentPlan(_ plan: RecentPlanProjection) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let taskID = plan.task.id
        let executions = (try? modelContext.fetch(
            FetchDescriptor<TaskExecutionRecord>(
                predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID }
            )
        )) ?? []

        guard let task = (try? modelContext.fetch(
            FetchDescriptor<TaskItem>(
                predicate: #Predicate<TaskItem> { $0.id == taskID }
            )
        ))?.first else {
            return
        }

        TaskExecutionSupport.markTaskCompleted(
            task: task,
            occurrenceDate: task.startDate,
            existingExecutions: executions,
            modelContext: modelContext
        )
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelinesInBackground()
        AppDataChangeCenter.post()
        requestDashboardSnapshotRefresh(reason: "recent plan completed", delay: 0)
    }

    @ViewBuilder
    private func todayTasksCard(_ snapshot: DashboardSnapshot) -> some View {
        let pendingItems = snapshot.todayPendingTasks
        let historicalItems = snapshot.historicalPendingTasks
        let doneCount = snapshot.todayCompletedTaskCount
        let todayTaskCount = pendingItems.count + doneCount
        let historyCount = snapshot.historicalPendingTaskCount
        
        if !pendingItems.isEmpty || doneCount > 0 || !historicalItems.isEmpty || snapshot.activeTaskCount > 0 {
            VStack(alignment: .leading, spacing: 12) {
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
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.orange.opacity(0.11), in: Capsule())
                        }

                        if todayTaskCount > 0 {
                            Text("\(doneCount)/\(todayTaskCount) 完成")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(doneCount == todayTaskCount ? Color.green : Color.purple)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    (doneCount == todayTaskCount ? Color.green : Color.purple).opacity(0.11),
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
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.orange.opacity(0.11), in: Capsule())
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
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(.green.opacity(0.11), in: Capsule())
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
            .homeCardSurface()
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
                AppDataChangeCenter.post()
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
                hasReachedDailyReviewLimit: snapshot.hasReachedDailyReviewLimit,
                dailyReviewPlanItemIDs: snapshot.dailyReviewPlanItemIDs,
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
                recentPlans: snapshot.recentPlans,
                calendarWeeks: snapshot.calendarWeeks,
                activeTaskCount: snapshot.activeTaskCount,
                pointBalance: snapshot.pointBalance + PointLedgerService.taskRewardAmount,
                pointsEarnedToday: snapshot.pointsEarnedToday + PointLedgerService.taskRewardAmount,
                currentPointStreak: snapshot.currentPointStreak,
                wrongReviewSamples: snapshot.wrongReviewSamples,
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
                    let now = Date()
                    let calendar = Calendar.current
                    let order = Dictionary(
                        ids.enumerated().map { ($0.element, $0.offset) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let fetched = (try? ctx.fetch(FetchDescriptor<ReviewItem>())) ?? []
                    let filtered = fetched
                        .filter { order[$0.id] != nil }
                        .filter { ReviewScheduler.isDue($0.nextReviewAt, on: now, calendar: calendar) }
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(style.tint.opacity(0.1), lineWidth: 1)
        )
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

private struct HomeStatGridCard: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.1), in: Circle())

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.09), lineWidth: 1)
        )
    }
}

private struct HomeCardSurfaceModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.045), lineWidth: 1)
            )
    }
}

private extension View {
    func homeCardSurface(padding: CGFloat = 16) -> some View {
        modifier(HomeCardSurfaceModifier(padding: padding))
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
        let snapshots = ReviewScheduler.canonicalReviewRecords(reviewRecords).map { record in
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
