
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
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var taskCompletions: [TaskCompletion]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]
    
    @State private var showingReviewPreview = false
    @State private var isReviewActive = false
    @State private var previewSession: DictationSession?
    @State private var activeDictationSession: DictationSession?
    @State private var showingDashboardBoard = false

    private let scheduler = ReviewScheduler()
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var allDueItems: [ReviewItem] {
        reviewItems
            .filter { $0.nextReviewAt <= .now }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }

    private var dailyLimit: Int {
        settings.first?.dailyLimit ?? 15
    }

    /// Items capped to dailyLimit for today's session
    private var dueItems: [ReviewItem] {
        Array(allDueItems.prefix(dailyLimit))
    }

    private var childName: String {
        guard let settings = settings.first else { return "小朋友" }
        return settings.childName.isEmpty ? "小朋友" : settings.childName
    }

    private var reviewStyle: ReviewInteractionStyle {
        settings.first?.reviewInteractionStyle ?? AppSettings.defaultReviewInteractionStyle
    }

    private var todayRecords: [ReviewRecord] {
        let calendar = Calendar.current
        return reviewRecords.filter { calendar.isDateInToday($0.reviewedAt) }
    }

    private var todayCompletedCount: Int { todayRecords.count }
    private var todayWrongCount: Int { todayRecords.filter { $0.result == .wrong }.count }
    private var todayCorrectCount: Int { todayRecords.filter { $0.result == .correct }.count }

    private var todayAccuracyText: String {
        guard todayCompletedCount > 0 else { return "--" }
        let accuracy = Int((Double(todayCorrectCount) / Double(todayCompletedCount) * 100).rounded())
        return "\(accuracy)%"
    }

    private var pendingDictationCount: Int {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        let pendingSessions = dictationSessions.filter {
            !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart
        }
        
        var totalCount = 0
        for session in pendingSessions {
            totalCount += dictationEntries.filter { $0.sessionID == session.id }.count
        }
        return totalCount
    }

    private var latestDictationSession: DictationSession? {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        
        // First look for any pending/unfinished sessions scheduled for today or earlier
        let pending = dictationSessions.filter { 
            !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart 
        }
        
        if let firstPending = pending.sorted(by: { $0.scheduledDate < $1.scheduledDate }).first {
            return firstPending
        }
        
        // If no pending ones, show the most recent session that wasn't scheduled in the future
        return dictationSessions.filter {
            calendar.startOfDay(for: $0.scheduledDate) <= todayStart
        }.min(by: { $0.scheduledDate > $1.scheduledDate })
    }

    private var todaySchedules: [ScheduleItem] {
        allSchedules
            .filter { $0.shouldAppear(on: .now) && !$0.hasEnded(on: .now, reference: .now) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private var totalPendingTaskCount: Int {
        todayPendingTasks.count + historicalPendingTaskItems.count
    }

    private var heroIconName: String {
        let tasksDone = totalPendingTaskCount == 0 && (todayCompletedTaskCount > 0 || allTasks.isEmpty)
        let reviewDone = dueItems.isEmpty
        let dictationDone = latestDictationSession?.isReviewed ?? true
        let scheduleDone = todaySchedules.isEmpty
        
        if tasksDone && reviewDone && dictationDone && scheduleDone { return "checkmark.seal.fill" }
        if reviewDone && dictationDone { return "sparkles" }
        if totalPendingTaskCount == 0 { return "book.fill" }
        return "figure.run"
    }

    private var heroMessage: String {
        let pendingTaskCount = totalPendingTaskCount
        let pendingReviewCount = dueItems.count
        
        // Dictation is "pending" if it's not reviewed yet
        let dictationPending = latestDictationSession != nil && !latestDictationSession!.isReviewed
        
        let tasksDone = pendingTaskCount == 0 && todayCompletedTaskCount > 0
        let reviewDone = pendingReviewCount == 0
        let dictationDone = !dictationPending

        if tasksDone && reviewDone && dictationDone {
            return "今天的任务、复习和听写全部完成了！"
        }

        var parts: [String] = []
        if pendingTaskCount > 0 {
            parts.append("\(pendingTaskCount) 项任务")
        }
        if !todaySchedules.isEmpty {
            parts.append("\(todaySchedules.count) 项日程")
        }
        if pendingReviewCount > 0 {
            parts.append("\(pendingReviewCount) 项复习")
        }
        if dictationPending {
            parts.append("1 场听写")
        }

        if parts.isEmpty {
            return "\(childName)，今天没有待办事项"
        }
        return "\(childName) 今天还有 \(parts.joined(separator: "、"))"
    }

    private var heroSubtitle: String {
        let pendingTaskCount = totalPendingTaskCount
        let pendingReviewCount = dueItems.count
        let dictationSession = latestDictationSession
        
        let tasksDone = pendingTaskCount == 0 && todayCompletedTaskCount > 0
        let reviewDone = pendingReviewCount == 0
        let dictationDone = dictationSession?.isReviewed ?? true

        if tasksDone && reviewDone && dictationDone {
            return "表现太棒了！录入新错题或休息一下吧。明天见！"
        }
        
        if let session = dictationSession, !session.isReviewed {
            if session.isFinished {
                return "今天听写已完成，快让家长点击「统一判卷」吧！"
            } else {
                return "别忘了还有一场「\(session.title)」听写在进行中。"
            }
        }
        
        if !historicalPendingTaskItems.isEmpty && todayPendingTasks.isEmpty {
            return "还有 \(historicalPendingTaskItems.count) 项历史待完成，先清一清积压吧。"
        }
        if pendingTaskCount > 0 && pendingReviewCount > 0 {
            return "先完成今天的任务，再做错题复习。加油！"
        }
        if pendingTaskCount > 0 {
            return "先把今天的任务完成吧！"
        }
        if allDueItems.count > dailyLimit {
            return "今天共有 \(allDueItems.count) 项到期，推荐先练 \(dailyLimit) 项。"
        }
        return "孩子在纸上写，家长判定对错，同一题当天只练一次。"
    }

    /// Hero card gradient adapts to overall completion status
    private var heroGradientColors: [Color] {
        let tasksDone = totalPendingTaskCount == 0 && (todayCompletedTaskCount > 0 || allTasks.isEmpty)
        let reviewDone = dueItems.isEmpty
        let dictationDone = latestDictationSession?.isReviewed ?? true
        
        if tasksDone && reviewDone && dictationDone {
            return [.green.opacity(0.85), .mint.opacity(0.65)]
        }
        if totalPendingTaskCount > 0 || !dueItems.isEmpty || !(latestDictationSession?.isReviewed ?? true) {
            if totalPendingTaskCount > 0 && !dueItems.isEmpty {
                return [.orange.opacity(0.9), .yellow.opacity(0.65)]
            }
            return [.blue.opacity(0.8), .cyan.opacity(0.6)]
        }
        return [.blue.opacity(0.8), .cyan.opacity(0.6)]
    }

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: heroIconName)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(heroMessage)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(heroSubtitle)
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
                        colors: heroGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= 700

                VStack(spacing: 20) {
                    heroCard

                    if syncStatusStore.syncNoticeKind != .ready {
                        syncStatusSummaryCard
                    }

                    todayScheduleCard

                    todayTasksCard

                    // Stat grid
                    statGridSection

                    if isWide {
                        HStack(spacing: 16) {
                            reviewEntryButton
                            dictationEntryButton
                        }
                    } else {
                        VStack(spacing: 12) {
                            reviewEntryButton
                            dictationEntryButton
                        }
                    }

                    quickEntryCard
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: 960, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("首页")
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
            .navigationDestination(isPresented: $isReviewActive) {
                if reviewStyle == .batch {
                    BatchReviewSessionView(items: dueItems)
                } else {
                    ReviewSessionView(items: dueItems)
                }
            }
            .sheet(isPresented: $showingReviewPreview) {
                ReviewPreviewView(
                    items: dueItems,
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
    private var statGridSection: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

        LazyVGrid(columns: columns, spacing: 12) {
            Group {
                if reviewStyle == .batch {
                    NavigationLink {
                        BatchReviewSessionView(items: dueItems)
                    } label: {
                        StatGridCard(icon: "book.closed", title: "待复习", value: "\(dueItems.count)", tint: .orange)
                    }
                } else {
                    NavigationLink {
                        ReviewSessionView(items: dueItems)
                    } label: {
                        StatGridCard(icon: "book.closed", title: "待复习", value: "\(dueItems.count)", tint: .orange)
                    }
                }
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!dueItems.isEmpty)
            
            NavigationLink {
                DictationHomeView()
            } label: {
                StatGridCard(icon: "text.book.closed", title: "待听写", value: "\(pendingDictationCount)", tint: .teal)
            }
            .buttonStyle(.plain)

            
            StatGridCard(icon: "checkmark.circle", title: "今日完成", value: "\(todayCompletedCount)", tint: .green)
            StatGridCard(icon: "xmark.circle", title: "今日答错", value: "\(todayWrongCount)", tint: .red)
            StatGridCard(icon: "percent", title: "正确率", value: todayAccuracyText, tint: .blue)
            StatGridCard(icon: "star.fill", title: "已掌握", value: "\(reviewItems.filter(scheduler.isMastered).count)", tint: .mint)
        }
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

    private var quickEntryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "pencil.tip.crop.circle.badge.plus")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("快速录入")
                    .font(.headline)
            }

            Text("把当天写错的词句或英语录进来，保存后直接进入今天待复习。")
                .foregroundStyle(.secondary)
                .font(.subheadline)

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
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var reviewEntryButton: some View {
        Button {
            isReviewActive = true
        } label: {
            reviewEntryLabel
        }
        .buttonStyle(.plain)
        .disabled(dueItems.isEmpty)
    }

    private var reviewEntryLabel: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("开始今天复习")
                }
                .font(.title3.weight(.semibold))

                Text(reviewStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
            
            Spacer()
            
            if !dueItems.isEmpty {
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
        .background(dueItems.isEmpty ? Color.gray : Color.accentColor)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var reviewStatusText: String {
        if dueItems.isEmpty {
            return "今天复习已经全部完成了"
        }
        return "还有 \(dueItems.count) 项待复习"
    }

    private var dictationEntryButton: some View {
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

                    Text(dictationStatusText)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                
                Spacer()
                
                if let session = latestDictationSession, !session.isFinished && !session.isReviewed {
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

    private var dictationStatusText: String {
        guard let latestDictationSession else {
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
    private var todayScheduleCard: some View {
        let schedules = todaySchedules

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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    // MARK: - Today Tasks

    private var todayTaskItems: [TodayTaskDisplayItem] {
        TodayTaskListBuilder.build(from: allTasks, completions: taskCompletions)
    }

    private var todayPendingTasks: [TodayTaskDisplayItem] {
        todayTaskItems.filter { $0.section == .todayPending }
    }

    private var historicalPendingTaskItems: [TodayTaskDisplayItem] {
        todayTaskItems
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }

    private var todayCompletedTaskItems: [TodayTaskDisplayItem] {
        todayTaskItems.filter { $0.section == .todayDone }
    }

    private var todayCompletedTaskCount: Int {
        todayCompletedTaskItems.count
    }

    @ViewBuilder
    private var todayTasksCard: some View {
        let pendingItems = todayPendingTasks
        let doneItems = todayCompletedTaskItems
        let historicalItems = historicalPendingTaskItems
        let doneCount = todayCompletedTaskCount
        let todayTaskCount = pendingItems.count + doneCount
        let historyCount = historicalItems.count
        
        if !pendingItems.isEmpty || !doneItems.isEmpty || !historicalItems.isEmpty || !allTasks.isEmpty {
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

                if pendingItems.isEmpty && historicalItems.isEmpty && !allTasks.isEmpty {
                    Text("今天没有待完成的任务。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(pendingItems) { item in
                        todayTaskRow(item)
                    }

                    if !historicalItems.isEmpty {
                        if !pendingItems.isEmpty {
                            Divider()
                                .overlay(.white.opacity(0.1))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("历史待完成")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)

                            ForEach(historicalItems) { item in
                                todayTaskRow(item)
                            }
                        }
                    }

                    if !doneItems.isEmpty {
                        if !pendingItems.isEmpty || !historicalItems.isEmpty {
                            Divider()
                                .overlay(.white.opacity(0.1))
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("今日已完成")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)

                            ForEach(doneItems) { item in
                                todayTaskRow(item)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func todayTaskRow(_ item: TodayTaskDisplayItem) -> some View {
        let task = item.task
        let isDone = item.isCompleted
        let occurrenceLabel = item.overdueOriginText

        return HStack(spacing: 12) {
            Button {
                if !isDone {
                    completeTask(task)
                }
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isDone)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .fontWeight(.medium)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .strikethrough(isDone)

                HStack(spacing: 6) {
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
                }
                .opacity(isDone ? 0.6 : 1.0)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func completeTask(_ task: TaskItem) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        let completion = TaskCompletion(taskID: task.id, completedDate: today)
        modelContext.insert(completion)

        if task.recurrence.kind == .once {
            task.isArchived = true
        }

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
