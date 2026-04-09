
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
    let nextReviewAt: Date
    let consecutiveWrongCount: Int

    init(_ item: ReviewItem) {
        id = item.id
        type = item.type
        content = item.content
        prompt = item.prompt
        stage = item.stage
        nextReviewAt = item.nextReviewAt
        consecutiveWrongCount = item.consecutiveWrongCount
    }

    var isMastered: Bool {
        stage >= ReviewScheduler.intervals.count - 1 && consecutiveWrongCount == 0
    }
}

private struct HomeReviewRecordProjection {
    let reviewedAt: Date
    let result: ReviewResult

    init(_ record: ReviewRecord) {
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

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        type = entry.type
        content = entry.content
        prompt = entry.prompt
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
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    init(task: TaskProjection, projection: TodayTaskProjectionResult) {
        self.task = task
        section = projection.section
        occurrenceDate = projection.occurrenceDate
        isCompleted = projection.isCompleted
        pendingOccurrenceCount = projection.pendingOccurrenceCount
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
        overdueOriginText: String?,
        totalSubtaskCount: Int,
        completedSubtaskCount: Int
    ) {
        self.task = task
        self.section = section
        self.occurrenceDate = occurrenceDate
        self.isCompleted = isCompleted
        self.pendingOccurrenceCount = pendingOccurrenceCount
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

private struct HomeReviewRoute: Identifiable, Hashable {
    let itemIDs: [UUID]
    let style: ReviewInteractionStyle

    var id: String {
        "\(style.rawValue)-\(itemIDs.map(\.uuidString).joined(separator: ","))"
    }
}

private struct HomeDictationSessionRoute: Identifiable, Hashable {
    let id: UUID
    let title: String
}

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore: SyncStatusStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    
    @State private var showingReviewPreview = false
    @State private var activeReviewRoute: HomeReviewRoute?
    @State private var previewSession: HomeDictationSessionProjection?
    @State private var activeDictationRoute: HomeDictationSessionRoute?
    @State private var isDictationHomeActive = false
    @State private var isAddReviewActive = false
    @State private var showingDashboardBoard = false
    @State private var showQuickEntryHint = false
    @State private var dashboardSnapshot: DashboardSnapshot?
    @State private var dashboardSnapshotTask: Task<Void, Never>?
    @State private var deferredSaveTask: Task<Void, Never>?
    @State private var isViewVisible = false
    @State private var isDashboardRefreshInFlight = false
    @State private var needsDashboardRefreshAfterCurrent = false

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

    private struct DashboardSnapshot {
        let childName: String
        let dueItems: [HomeReviewItemProjection]
        let allDueCount: Int
        let masteredReviewCount: Int
        let todayCompletedCount: Int
        let todayWrongCount: Int
        let todayCorrectCount: Int
        let todayAccuracyText: String
        let pendingDictationCount: Int
        let latestDictationSession: HomeDictationSessionProjection?
        let latestDictationEntryCount: Int
        let dictationEntriesBySessionID: [UUID: [HomeDictationEntryProjection]]
        let todaySchedules: [HomeScheduleProjection]
        let todayPendingTasks: [HomeTaskDisplayItem]
        let historicalPendingTasks: [HomeTaskDisplayItem]
        let todayCompletedTasks: [HomeTaskDisplayItem]
        let todayCompletedTaskCount: Int
        let totalPendingTaskCount: Int
        let activeTaskCount: Int
        let heroIconName: String
        let heroMessage: String
        let heroSubtitle: String
        let heroGradientColors: [Color]

        var dueItemIDs: [UUID] {
            dueItems.map(\.id)
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
            activeTaskCount: Int,
            referenceDate: Date = .now
        ) -> DashboardSnapshot {
            let name = childName.isEmpty ? "小朋友" : childName
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: referenceDate)

            let allDue = reviewItems
                .filter { $0.nextReviewAt <= referenceDate }
                .sorted { $0.nextReviewAt < $1.nextReviewAt }
            let cappedDueContent = Array(allDue.prefix(dailyLimit))
            let masteredReviewCount = reviewItems.filter(\.isMastered).count

            let todayRecs = reviewRecords.filter { calendar.isDate($0.reviewedAt, inSameDayAs: referenceDate) }
            let tCompleted = todayRecs.count
            let tWrong = todayRecs.filter { $0.result == .wrong }.count
            let tCorrect = todayRecs.filter { $0.result == .correct }.count
            let tAccuracy = tCompleted > 0 ? "\(Int((Double(tCorrect) / Double(tCompleted) * 100).rounded()))%" : "--"

            let pendingSessions = dictationSessions.filter {
                !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
            }
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
            var pendingDictationEntryCount = 0
            var latestDictationEntryCount = 0

            for entry in dictationEntries {
                if pendingSessionIDs.contains(entry.sessionID) {
                    pendingDictationEntryCount += 1
                }
                if entry.sessionID == latestSessionID {
                    latestDictationEntryCount += 1
                }
            }

            let tSchedules = schedules
                .filter { $0.shouldAppear(on: referenceDate) && !$0.hasEnded(on: referenceDate, reference: referenceDate) }
                .sorted { $0.startTimeMinutes < $1.startTimeMinutes }

            let tPendingTasks = taskItems.filter { $0.section == .todayPending }
            let hPendingTasks = taskItems.filter { $0.section == .historicalPending }
                .sorted { lhs, rhs in
                    if lhs.occurrenceDate == rhs.occurrenceDate {
                        return lhs.task.createdAt < rhs.task.createdAt
                    }
                    return lhs.occurrenceDate < rhs.occurrenceDate
                }
            let tCompletedTasks = taskItems.filter { $0.section == .todayDone }
            let tCompletedTaskCount = tCompletedTasks.count
            let totPendingTaskCount = tPendingTasks.count + hPendingTasks.count

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
                if let session = latestDS, !session.isReviewed { parts.append("1 场听写") }
                if parts.isEmpty { return "\(name)，今天没有待办事项" }
                return "\(name) 今天还有 \(parts.joined(separator: "、"))"
            }()

            let hSubtitle: String = {
                if tasksDone && reviewDone && dictationDone { return "表现太棒了！录入新错题或休息一下吧。明天见！" }
                if let session = latestDS, !session.isReviewed {
                    return session.isFinished ? "今天听写已完成，快让家长点击「统一判卷」吧！" : "别忘了还有一场「\(session.title)」听写在进行中。"
                }
                if !hPendingTasks.isEmpty && tPendingTasks.isEmpty { return "还有 \(hPendingTasks.count) 项历史待完成，先清一清积压吧。" }
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
                pendingDictationCount: pendingDictationEntryCount,
                latestDictationSession: latestDS,
                latestDictationEntryCount: latestDictationEntryCount,
                dictationEntriesBySessionID: entriesBySessionID,
                todaySchedules: tSchedules,
                todayPendingTasks: tPendingTasks,
                historicalPendingTasks: hPendingTasks,
                todayCompletedTasks: tCompletedTasks,
                todayCompletedTaskCount: tCompletedTaskCount,
                totalPendingTaskCount: totPendingTaskCount,
                activeTaskCount: activeTaskCount,
                heroIconName: hIcon,
                heroMessage: hMessage,
                heroSubtitle: hSubtitle,
                heroGradientColors: hGradient
            )
        }
    }

    private func heroCard(_ snapshot: DashboardSnapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
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

                Text(snapshot.heroSubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                
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
        .onDisappear {
            isViewVisible = false
            #if DEBUG
            DebugPerf.mark("HomeView onDisappear")
            #endif
            dashboardSnapshotTask?.cancel()
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
        .fullScreenCover(isPresented: $showingDashboardBoard) {
            DashboardBoardView()
        }
        .toolbar {
            if isPad {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("看板", systemImage: "rectangle.inset.filled.and.person.filled") {
                        showingDashboardBoard = true
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
            let snapshot = await Task.detached(priority: .utility) {
                let backgroundContext = ModelContext(container)

                let reviewModels = (try? backgroundContext.fetch(FetchDescriptor<ReviewItem>())) ?? []
                let reviewRecordModels = (try? backgroundContext.fetch(FetchDescriptor<ReviewRecord>())) ?? []
                let sessionModels = (try? backgroundContext.fetch(FetchDescriptor<DictationSession>())) ?? []
                let entryModels = (try? backgroundContext.fetch(FetchDescriptor<DictationEntry>())) ?? []
                let scheduleModels = (try? backgroundContext.fetch(
                    FetchDescriptor<ScheduleItem>(predicate: #Predicate<ScheduleItem> { !$0.isArchived })
                )) ?? []
                let taskModels = (try? backgroundContext.fetch(
                    FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { !$0.isArchived })
                )) ?? []
                let executionModels = (try? backgroundContext.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? []
                let subtaskModels = (try? backgroundContext.fetch(
                    FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
                )) ?? []

                let taskProjections = taskModels.map(TaskProjection.init)
                let taskProjectionResults = TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: executionModels.map(TaskExecutionRecordProjection.init),
                    subtasks: subtaskModels.map(TaskSubitemProjection.init)
                )
                let tasksByID = Dictionary(
                    taskProjections.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let taskDisplayItems = taskProjectionResults.compactMap { result -> HomeTaskDisplayItem? in
                    guard let task = tasksByID[result.taskID] else { return nil }
                    return HomeTaskDisplayItem(task: task, projection: result)
                }

                #if DEBUG
                DebugPerf.mark("HomeView background snapshot fetch end reviews=\(reviewModels.count) records=\(reviewRecordModels.count) sessions=\(sessionModels.count) entries=\(entryModels.count) schedules=\(scheduleModels.count) tasks=\(taskModels.count)")
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
                    activeTaskCount: taskModels.count
                )
            }.value

            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            dashboardSnapshot = snapshot
            isDashboardRefreshInFlight = false
            #if DEBUG
            DebugPerf.mark("HomeView dashboardSnapshot applied")
            #endif
            if needsDashboardRefreshAfterCurrent {
                needsDashboardRefreshAfterCurrent = false
                requestDashboardSnapshotRefresh(reason: "coalesced", delay: refreshDashboardSnapshotDelay)
            }
        }
    }

    private func mainContentView(_ snapshot: DashboardSnapshot) -> some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= 700

                VStack(spacing: 20) {
                    heroCard(snapshot)

                    if syncStatusStore.syncNoticeKind != .ready {
                        syncStatusSummaryCard
                    }

                    todayScheduleCard(snapshot)

                    todayTasksCard(snapshot)

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

            
            StatGridCard(icon: "checkmark.circle", title: "今日完成", value: "\(snapshot.todayCompletedCount)", tint: .green)
            StatGridCard(icon: "xmark.circle", title: "今日答错", value: "\(snapshot.todayWrongCount)", tint: .red)
            StatGridCard(icon: "percent", title: "正确率", value: snapshot.todayAccuracyText, tint: .blue)
            StatGridCard(icon: "star.fill", title: "已掌握", value: "\(snapshot.masteredReviewCount)", tint: .mint)
        }
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
                Text("把当天写错的词句或英语录进来，保存后直接进入今天待复习。")
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
            .buttonStyle(.bordered)
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
        .background(snapshot.dueItems.isEmpty ? Color.gray : Color.accentColor)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
        .background(Color.teal)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func openDictationHome(source: String) {
        #if DEBUG
        DebugPerf.mark("Home openDictationHome source=\(source)")
        #endif
        dashboardSnapshotTask?.cancel()
        isDictationHomeActive = true
    }

    private func openAddReview(source: String) {
        #if DEBUG
        DebugPerf.mark("Home openAddReview source=\(source)")
        #endif
        dashboardSnapshotTask?.cancel()
        isAddReviewActive = true
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

        if snapshot.pendingDictationCount > count, !latestDictationSession.isReviewed {
            return "待听写共 \(snapshot.pendingDictationCount) 条 · 当前「\(latestDictationSession.title)」\(count) 条 · \(status)"
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
        let pendingItems = collapsedHomeTaskItems(snapshot.todayPendingTasks)
        let pendingTaskIDs = Set(pendingItems.map(\.task.id))
        let historicalItems = collapsedHomeTaskItems(
            snapshot.historicalPendingTasks.filter { !pendingTaskIDs.contains($0.task.id) }
        )
        let doneCount = snapshot.todayCompletedTaskCount
        let todayTaskCount = pendingItems.count + doneCount
        let historyCount = snapshot.historicalPendingTasks.count
        
        if !pendingItems.isEmpty || doneCount > 0 || !historicalItems.isEmpty || snapshot.activeTaskCount > 0 {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    Text("今日任务")
                        .font(.headline)
                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        if historyCount > 0 {
                            Text("另有 \(historyCount) 项历史待完成")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }

                        if todayTaskCount > 0 {
                            Text("\(doneCount)/\(todayTaskCount) 已完成")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(doneCount == todayTaskCount ? .green : .orange)
                        }
                    }
                }

                if pendingItems.isEmpty && historicalItems.isEmpty && snapshot.activeTaskCount > 0 {
                    Text("今天没有待完成的任务。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(pendingItems) { item in
                        todayTaskRow(item)
                    }
                    
                    if !historicalItems.isEmpty {
                        Divider()
                            .padding(.vertical, 8)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("历史待完成")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.orange)
                            
                            ForEach(historicalItems) { item in
                                todayTaskRow(item)
                            }
                        }
                    }
                    
                    if !snapshot.todayCompletedTasks.isEmpty {
                        Divider()
                            .padding(.vertical, 8)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("今日已完成")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.green)
                            
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

                            if !isDone, item.pendingOccurrenceCount > 1 {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text("\(item.pendingOccurrenceCount)次待办")
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

    private func collapsedHomeTaskItems(_ items: [HomeTaskDisplayItem]) -> [HomeTaskDisplayItem] {
        var seenTaskIDs = Set<UUID>()
        return items.filter { item in
            seenTaskIDs.insert(item.task.id).inserted
        }
    }

    private func completeTask(_ task: TaskProjection, occurrenceDate: Date) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        
        let tid = task.id
        let container = modelContext.container
        
        // 1. 立即乐观更新 UI
        optimisticCompleteHomeTask(taskID: tid, occurrenceDate: occurrenceDate)
        
        // 2. 后台处理同步
        Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            
            do {
                let descriptor = FetchDescriptor<TaskExecutionRecord>(
                    predicate: #Predicate<TaskExecutionRecord> { $0.taskID == tid }
                )
                let relevantExecutions = (try? ctx.fetch(descriptor)) ?? []
                
                // 后台重新获取对象
                let bgTask = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                
                if let validTask = bgTask {
                    TaskExecutionSupport.markTaskCompleted(
                        task: validTask,
                        occurrenceDate: occurrenceDate,
                        existingExecutions: relevantExecutions,
                        modelContext: ctx
                    )
                    
                    try? ctx.save()
                    
                    await MainActor.run {
                        // 告知全应用数据已变动，刷新必要 UI
                        NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
                    }
                }
            } catch {
                print("Home task complete background sync failed: \(error)")
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
                overdueOriginText: oldItem.overdueOriginText,
                totalSubtaskCount: oldItem.totalSubtaskCount,
                completedSubtaskCount: oldItem.totalSubtaskCount
            )

            dashboardSnapshot = DashboardSnapshot(
                childName: snapshot.childName,
                dueItems: snapshot.dueItems,
                allDueCount: snapshot.allDueCount,
                masteredReviewCount: snapshot.masteredReviewCount,
                todayCompletedCount: snapshot.todayCompletedCount,
                todayWrongCount: snapshot.todayWrongCount,
                todayCorrectCount: snapshot.todayCorrectCount,
                todayAccuracyText: snapshot.todayAccuracyText,
                pendingDictationCount: snapshot.pendingDictationCount,
                latestDictationSession: snapshot.latestDictationSession,
                latestDictationEntryCount: snapshot.latestDictationEntryCount,
                dictationEntriesBySessionID: snapshot.dictationEntriesBySessionID,
                todaySchedules: snapshot.todaySchedules,
                todayPendingTasks: snapshot.todayPendingTasks.filter { !($0.task.id == taskID && $0.occurrenceDate == occurrenceDate) },
                historicalPendingTasks: snapshot.historicalPendingTasks.filter { !($0.task.id == taskID && $0.occurrenceDate == occurrenceDate) },
                todayCompletedTasks: snapshot.todayCompletedTasks + [newItem],
                todayCompletedTaskCount: snapshot.todayCompletedTaskCount + 1,
                totalPendingTaskCount: max(snapshot.totalPendingTaskCount - 1, 0),
                activeTaskCount: snapshot.activeTaskCount,
                heroIconName: snapshot.heroIconName,
                heroMessage: snapshot.heroMessage,
                heroSubtitle: snapshot.heroSubtitle,
                heroGradientColors: snapshot.heroGradientColors
            )
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
            .navigationTitle(route.style == .batch ? "统一判卷" : "复习")
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

                let ids = route.itemIDs
                let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
                let fetched = (try? modelContext.fetch(FetchDescriptor<ReviewItem>())) ?? []
                let filtered = fetched
                    .filter { order[$0.id] != nil }
                    .sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }

                items = filtered
                loadFailed = filtered.isEmpty
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
        .background(style.background, in: RoundedRectangle(cornerRadius: 16))
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
                                    }
                                }

                                Spacer()

                                Button {
                                    speaker.speak(content: entry.content, type: entry.type)
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
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    speaker.speak(content: item.content, type: item.type)
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
}

private struct SyncStatusIconView: View {
    let isRefreshing: Bool

    var body: some View {
        Image(systemName: isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
            .symbolVariant(isRefreshing ? .circle : .none)
    }
}
