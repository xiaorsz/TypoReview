
import SwiftUI
import SwiftData
import Observation
import AVFoundation
import AVKit
import WidgetKit
import UIKit

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore: SyncStatusStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @Query(sort: \ReviewItem.nextReviewAt) private var reviewItems: [ReviewItem]
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var dictationSessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var dictationEntries: [DictationEntry]
    @Query(filter: #Predicate<TaskItem> { !$0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var activeTasks: [TaskItem]
    @Query(filter: #Predicate<ScheduleItem> { !$0.isArchived }, sort: \ScheduleItem.startTime) private var activeSchedules: [ScheduleItem]
    
    @State private var showingReviewPreview = false
    @State private var isReviewActive = false
    @State private var previewSession: DictationSession?
    @State private var activeDictationSession: DictationSession?
    @State private var showingDashboardBoard = false
    @State private var showQuickEntryHint = false
    @State private var dashboardSnapshot: DashboardSnapshot?
    @State private var homeTaskSnapshot: [TodayTaskDisplayItem] = []
    @State private var dashboardSnapshotTask: Task<Void, Never>?
    @State private var homeTaskSnapshotTask: Task<Void, Never>?
    @State private var deferredSaveTask: Task<Void, Never>?

    private let scheduler = ReviewScheduler()
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var dailyLimit: Int {
        appSettingsStore.dailyLimit
    }

    private var reviewStyle: ReviewInteractionStyle {
        appSettingsStore.reviewInteractionStyle
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active
    }

    private struct HomeTaskDetailRoute: Hashable {
        let taskID: UUID
        let title: String
    }

    private struct DashboardSnapshot {
        let childName: String
        let dueItems: [ReviewItem]
        let allDueCount: Int
        let todayCompletedCount: Int
        let todayWrongCount: Int
        let todayCorrectCount: Int
        let todayAccuracyText: String
        let pendingDictationCount: Int
        let latestDictationSession: DictationSession?
        let latestDictationEntryCount: Int
        let todaySchedules: [ScheduleItem]
        let todayPendingTasks: [TodayTaskDisplayItem]
        let historicalPendingTasks: [TodayTaskDisplayItem]
        let todayCompletedTasks: [TodayTaskDisplayItem]
        let todayCompletedTaskCount: Int
        let totalPendingTaskCount: Int
        let heroIconName: String
        let heroMessage: String
        let heroSubtitle: String
        let heroGradientColors: [Color]
    }

    private func makeSnapshot() -> DashboardSnapshot {
        let name = appSettingsStore.childName.isEmpty ? "小朋友" : appSettingsStore.childName
        
        let allDue = reviewItems
            .filter { $0.nextReviewAt <= .now }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
        
        let limit = appSettingsStore.dailyLimit
        let cappedDueContent = Array(allDue.prefix(limit))
        
        let calendar = Calendar.current
        let todayRecs = reviewRecords.filter { calendar.isDateInToday($0.reviewedAt) }
        let tCompleted = todayRecs.count
        let tWrong = todayRecs.filter { $0.result == .wrong }.count
        let tCorrect = todayRecs.filter { $0.result == .correct }.count
        
        var tAccuracy = "--"
        if tCompleted > 0 {
            let accuracy = Int((Double(tCorrect) / Double(tCompleted) * 100).rounded())
            tAccuracy = "\(accuracy)%"
        }
        
        let todayStart = calendar.startOfDay(for: .now)
        
        let pendingSessions = dictationSessions.filter {
            !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
        }
        let latestDS: DictationSession? = {
            if let firstPending = pendingSessions.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
                return firstPending
            }
            return dictationSessions.filter {
                calendar.startOfDay(for: $0.scheduledDate) <= todayStart
            }.min(by: { $0.scheduledDate > $1.scheduledDate })
        }()
        let pendingSessionIDs = Set(pendingSessions.map(\.id))
        let latestSessionID = latestDS?.id
        var pendingDictationEntryCount = 0
        var latestDictationEntryCount = 0

        for entry in dictationEntries {
            let sessionID = entry.sessionID
            if pendingSessionIDs.contains(sessionID) {
                pendingDictationEntryCount += 1
            }
            if sessionID == latestSessionID {
                latestDictationEntryCount += 1
            }
        }
        
        let tSchedules = activeSchedules
            .filter { $0.shouldAppear(on: .now) && !$0.hasEnded(on: .now, reference: .now) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
        
        let taskItems = homeTaskSnapshot
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
        
        // Hero logic (single pass)
        let tasksDone = totPendingTaskCount == 0 && (tCompletedTaskCount > 0 || activeTasks.isEmpty)
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
            if allDue.count > limit { return "今天共有 \(allDue.count) 项到期，推荐先练 \(limit) 项。" }
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
            todayCompletedCount: tCompleted,
            todayWrongCount: tWrong,
            todayCorrectCount: tCorrect,
            todayAccuracyText: tAccuracy,
            pendingDictationCount: pendingDictationEntryCount,
            latestDictationSession: latestDS,
            latestDictationEntryCount: latestDictationEntryCount,
            todaySchedules: tSchedules,
            todayPendingTasks: tPendingTasks,
            historicalPendingTasks: hPendingTasks,
            todayCompletedTasks: tCompletedTasks,
            todayCompletedTaskCount: tCompletedTaskCount,
            totalPendingTaskCount: totPendingTaskCount,
            heroIconName: hIcon,
            heroMessage: hMessage,
            heroSubtitle: hSubtitle,
            heroGradientColors: hGradient
        )
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
                ProgressView("正在准备数据...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .task {
            scheduleHomeTaskSnapshotRefresh()
        }
        .modifier(HomeViewDataReconstructor(
            scenePhase: scenePhase,
            activeTasks: activeTasks,
            reviewItemsCount: reviewItems.count,
            reviewRecordsCount: reviewRecords.count,
            dictationSessionsCount: dictationSessions.count,
            dictationEntriesCount: dictationEntries.count,
            activeSchedulesCount: activeSchedules.count,
            appRevision: appSettingsStore.revision,
            onRefresh: {
                scheduleHomeTaskSnapshotRefresh()
                scheduleDashboardSnapshotUpdate()
            },
            onTaskRefresh: {
                scheduleHomeTaskSnapshotRefresh()
            },
            onDashboardRefresh: {
                scheduleDashboardSnapshotUpdate()
            },
            onSceneChange: { newPhase in
                if newPhase == .active {
                    scheduleHomeTaskSnapshotRefresh()
                } else {
                    dashboardSnapshotTask?.cancel()
                    homeTaskSnapshotTask?.cancel()
                }
            }
        ))
        .onDisappear {
            dashboardSnapshotTask?.cancel()
            homeTaskSnapshotTask?.cancel()
        }
    }

    private struct HomeViewDataReconstructor: ViewModifier {
        let scenePhase: ScenePhase
        let activeTasks: [TaskItem]
        let reviewItemsCount: Int
        let reviewRecordsCount: Int
        let dictationSessionsCount: Int
        let dictationEntriesCount: Int
        let activeSchedulesCount: Int
        let appRevision: Int
        
        let onRefresh: () -> Void
        let onTaskRefresh: () -> Void
        let onDashboardRefresh: () -> Void
        let onSceneChange: (ScenePhase) -> Void

        func body(content: Content) -> some View {
            content
                .onChange(of: scenePhase) { _, newPhase in onSceneChange(newPhase) }
                .onChange(of: appRevision) { _, _ in onDashboardRefresh() }
                .onChange(of: activeTasks) { _, _ in onRefresh() }
                .onChange(of: reviewItemsCount) { _, _ in onDashboardRefresh() }
                .onChange(of: reviewRecordsCount) { _, _ in onDashboardRefresh() }
                .onChange(of: dictationSessionsCount) { _, _ in onDashboardRefresh() }
                .onChange(of: dictationEntriesCount) { _, _ in onDashboardRefresh() }
                .onChange(of: activeSchedulesCount) { _, _ in onDashboardRefresh() }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
                    onRefresh()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    onRefresh()
                }
        }
    }

    private func scheduleDashboardSnapshotUpdate() {
        dashboardSnapshotTask?.cancel()
        guard canRenderLiveContent else { return }
        dashboardSnapshotTask = Task(priority: .utility) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            dashboardSnapshot = makeSnapshot()
        }
    }

    private func scheduleHomeTaskSnapshotRefresh() {
        homeTaskSnapshotTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let container = modelContext.container
        let taskModels = activeTasks

        homeTaskSnapshotTask = Task(priority: .utility) {
            await Task.yield()
            guard !Task.isCancelled else { return }

            let projectedItems = try? await Task.detached(priority: .utility) {
                let backgroundContext = ModelContext(container)
                
                let tasksDesc = FetchDescriptor<TaskItem>(predicate: #Predicate<TaskItem> { !$0.isArchived })
                let executesDesc = FetchDescriptor<TaskExecutionRecord>()
                let subtasksDesc = FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
                
                let safeTasks = (try? backgroundContext.fetch(tasksDesc)) ?? []
                let safeExecutions = (try? backgroundContext.fetch(executesDesc)) ?? []
                let safeSubtasks = (try? backgroundContext.fetch(subtasksDesc)) ?? []

                let taskProjections = safeTasks.map(TaskProjection.init)
                let executionProjections = safeExecutions.map(TaskExecutionRecordProjection.init)
                let subtaskProjections = safeSubtasks.map(TaskSubitemProjection.init)

                return TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: executionProjections,
                    subtasks: subtaskProjections
                )
            }.value

            guard !Task.isCancelled else { return }
            guard let validProjectedItems = projectedItems else { return }
            guard canRenderLiveContent else { return }
            let tasksByID = Dictionary(
                taskModels.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            homeTaskSnapshot = TodayTaskProjectionBuilder.displayItems(
                from: validProjectedItems,
                tasksByID: tasksByID
            )
            scheduleDashboardSnapshotUpdate()
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
            .sheet(item: $previewSession) { session in
                DictationPreviewView(
                    session: session,
                    entries: entries(for: session.id),
                    onStartSession: {
                        activeDictationSession = session
                    }
                )
            }
            .navigationDestination(item: $activeDictationSession) { session in
                DictationSessionView(
                    session: session,
                    entries: entries(for: session.id)
                )
            }
            .navigationDestination(for: HomeTaskDetailRoute.self) { route in
                HomeDeferredTaskDetailView(route: route)
            }
            .navigationDestination(isPresented: $isReviewActive) {
                if reviewStyle == .batch {
                    BatchReviewSessionView(items: snapshot.dueItems)
                } else {
                    ReviewSessionView(items: snapshot.dueItems)
                }
            }
            .sheet(isPresented: $showingReviewPreview) {
                ReviewPreviewView(
                    items: snapshot.dueItems,
                    onStartReview: {
                        isReviewActive = true
                    }
                )
            }
            .fullScreenCover(isPresented: $showingDashboardBoard) {
                DashboardBoardView()
            }
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
                    NavigationLink {
                        AddReviewItemView()
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

    @ViewBuilder
    private func statGridSection(_ snapshot: DashboardSnapshot) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

        LazyVGrid(columns: columns, spacing: 12) {
            Group {
                if reviewStyle == .batch {
                    NavigationLink {
                        BatchReviewSessionView(items: snapshot.dueItems)
                    } label: {
                        StatGridCard(icon: "book.closed", title: "待复习", value: "\(snapshot.dueItems.count)", tint: .orange)
                    }
                } else {
                    NavigationLink {
                        ReviewSessionView(items: snapshot.dueItems)
                    } label: {
                        StatGridCard(icon: "book.closed", title: "待复习", value: "\(snapshot.dueItems.count)", tint: .orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!snapshot.dueItems.isEmpty)
            
            NavigationLink {
                DictationHomeView()
            } label: {
                StatGridCard(icon: "text.book.closed", title: "待听写", value: "\(snapshot.pendingDictationCount)", tint: .teal)
            }
            .buttonStyle(.plain)

            
            StatGridCard(icon: "checkmark.circle", title: "今日完成", value: "\(snapshot.todayCompletedCount)", tint: .green)
            StatGridCard(icon: "xmark.circle", title: "今日答错", value: "\(snapshot.todayWrongCount)", tint: .red)
            StatGridCard(icon: "percent", title: "正确率", value: snapshot.todayAccuracyText, tint: .blue)
            StatGridCard(icon: "star.fill", title: "已掌握", value: "\(reviewItems.filter(scheduler.isMastered).count)", tint: .mint)
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

            NavigationLink {
                AddReviewItemView()
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
            isReviewActive = true
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

                Text(snapshot.dueItems.isEmpty ? "今天复习已经全部完成了" : "还有 \(snapshot.dueItems.count) 项待复习")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
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
        NavigationLink {
            DictationHomeView()
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
                        .lineLimit(1)
                }
                
                Spacer()
                
                if let session = snapshot.latestDictationSession, !session.isFinished && !session.isReviewed {
                    Button {
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
        .buttonStyle(.plain)
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

        return "\(latestDictationSession.title) · \(count) 条 · \(status)"
    }

    private func entries(for sessionID: UUID) -> [DictationEntry] {
        dictationEntries.filter { $0.sessionID == sessionID }
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
        
        if !pendingItems.isEmpty || doneCount > 0 || !historicalItems.isEmpty || !activeTasks.isEmpty {
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

                if pendingItems.isEmpty && historicalItems.isEmpty && !activeTasks.isEmpty {
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

    private func todayTaskRow(_ item: TodayTaskDisplayItem) -> some View {
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

    private func collapsedHomeTaskItems(_ items: [TodayTaskDisplayItem]) -> [TodayTaskDisplayItem] {
        var seenTaskIDs = Set<UUID>()
        return items.filter { item in
            seenTaskIDs.insert(item.task.id).inserted
        }
    }

    private func completeTask(_ task: TaskItem, occurrenceDate: Date) {
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
            if let index = homeTaskSnapshot.firstIndex(where: { $0.task.id == taskID && $0.occurrenceDate == occurrenceDate }) {
                let oldItem = homeTaskSnapshot[index]
                let newItem = TodayTaskDisplayItem(
                    task: oldItem.task,
                    section: .todayDone,
                    occurrenceDate: oldItem.occurrenceDate,
                    isCompleted: true, // 首页任务栏点击肯定是完成
                    pendingOccurrenceCount: oldItem.pendingOccurrenceCount,
                    overdueOriginText: oldItem.overdueOriginText,
                    totalSubtaskCount: oldItem.totalSubtaskCount,
                    completedSubtaskCount: oldItem.totalSubtaskCount
                )
                homeTaskSnapshot[index] = newItem
            }
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
        @Environment(\.modelContext) private var modelContext

        let route: HomeTaskDetailRoute

        @State private var task: TaskItem?
        @State private var loadTask: Task<Void, Never>?
        @State private var loadFailed = false

        private var canLoad: Bool {
            scenePhase == .active && UIApplication.shared.applicationState == .active
        }

        var body: some View {
            Group {
                if let task {
                    TaskDetailView(task: task)
                } else if loadFailed {
                    ContentUnavailableView("任务不存在", systemImage: "exclamationmark.triangle")
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
            guard task == nil else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                await Task.yield()
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }

                do {
                    let taskID = route.taskID
                    var descriptor = FetchDescriptor<TaskItem>(
                        predicate: #Predicate<TaskItem> { $0.id == taskID }
                    )
                    descriptor.fetchLimit = 1
                    task = try modelContext.fetch(descriptor).first
                    loadFailed = task == nil
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

// MARK: - Review Preview View

struct ReviewPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()
    
    let items: [ReviewItem]
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
