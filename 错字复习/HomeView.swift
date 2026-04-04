
import SwiftUI
import SwiftData
import Observation
import AVFoundation
import AVKit
import WidgetKit
import UIKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore: SyncStatusStore
    @Query(sort: \ReviewItem.nextReviewAt) private var reviewItems: [ReviewItem]
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var dictationSessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var dictationEntries: [DictationEntry]
    @Query private var settings: [AppSettings]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \TaskSubitem.sortOrder) private var taskSubitems: [TaskSubitem]
    @Query(sort: \TaskExecutionRecord.occurrenceDate, order: .reverse) private var taskExecutionRecords: [TaskExecutionRecord]
    @Query(sort: \TaskSubitemExecutionRecord.updatedAt, order: .reverse) private var taskSubitemExecutionRecords: [TaskSubitemExecutionRecord]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]
    
    @State private var showingReviewPreview = false
    @State private var isReviewActive = false
    @State private var previewSession: DictationSession?
    @State private var activeDictationSession: DictationSession?
    @State private var selectedTaskForDetail: TaskItem?
    @State private var showingDashboardBoard = false
    @State private var showQuickEntryHint = false

    private let scheduler = ReviewScheduler()
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var activeTasks: [TaskItem] {
        allTasks.filter { !$0.isArchived }
    }

    private var dailyLimit: Int {
        settings.first?.dailyLimit ?? 15
    }

    private var reviewStyle: ReviewInteractionStyle {
        settings.first?.reviewInteractionStyle ?? AppSettings.defaultReviewInteractionStyle
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
        let name = settings.first?.childName.isEmpty ?? true ? "小朋友" : (settings.first?.childName ?? "小朋友")
        
        let allDue = reviewItems
            .filter { $0.nextReviewAt <= .now }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
        
        let limit = settings.first?.dailyLimit ?? 15
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
        
        // Optimize Dictation count: build entry map once
        let entryMap = Dictionary(grouping: dictationEntries, by: { $0.sessionID })
        let pendingSessions = dictationSessions.filter {
            !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
        }
        let pDictationCount = pendingSessions.reduce(0) { $0 + (entryMap[$1.id]?.count ?? 0) }
        
        let latestDS: DictationSession? = {
            if let firstPending = pendingSessions.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
                return firstPending
            }
            return dictationSessions.filter {
                calendar.startOfDay(for: $0.scheduledDate) <= todayStart
            }.min(by: { $0.scheduledDate > $1.scheduledDate })
        }()
        
        let tSchedules = allSchedules
            .filter { $0.shouldAppear(on: .now) && !$0.hasEnded(on: .now, reference: .now) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
        
        let taskItems = TodayTaskListBuilder.build(
            from: activeTasks,
            executions: taskExecutionRecords,
            subtasks: taskSubitems,
            subtaskExecutions: taskSubitemExecutionRecords
        )
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
        let tasksDone = totPendingTaskCount == 0 && (tCompletedTaskCount > 0 || allTasks.isEmpty)
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
            pendingDictationCount: pDictationCount,
            latestDictationSession: latestDS,
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
        let snapshot = makeSnapshot()
        
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
                    entries: dictationEntries.filter { $0.sessionID == session.id }.sorted { $0.sortOrder < $1.sortOrder },
                    onStartSession: {
                        activeDictationSession = session
                    }
                )
            }
            .navigationDestination(item: $activeDictationSession) { session in
                DictationSessionView(
                    session: session,
                    entries: dictationEntries.filter { $0.sessionID == session.id }.sorted { $0.sortOrder < $1.sortOrder }
                )
            }
            .navigationDestination(item: $selectedTaskForDetail) { task in
                TaskDetailView(task: task)
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

        let count = dictationEntries.filter { $0.sessionID == latestDictationSession.id }.count
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

            Button {
                selectedTaskForDetail = task
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .fontWeight(.medium)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .strikethrough(isDone)

                    HStack(spacing: 4) {
                        Text(task.recurrenceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let effectiveDateRangeLabel = task.effectiveDateRangeLabel {
                            Text(effectiveDateRangeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if task.skipPolicy == .unskippable {
                            Text("不可跳过")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }

                        if let occurrenceLabel, !isDone {
                            Text(occurrenceLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }

                        if let progressText = item.subtaskProgressText {
                            Text(progressText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isDone ? .green : .blue)
                        }

                        if !isDone, item.pendingOccurrenceCount > 1 {
                            Text("共 \(item.pendingOccurrenceCount) 次待处理")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    .opacity(isDone ? 0.6 : 1.0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
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
        TaskExecutionSupport.markTaskCompleted(
            task: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: taskExecutionRecords,
            modelContext: modelContext
        )
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
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
            .rotationEffect(isRefreshing ? .degrees(360) : .zero)
            .animation(
                isRefreshing
                ? .linear(duration: 1).repeatForever(autoreverses: false)
                : .default,
                value: isRefreshing
            )
    }
}
