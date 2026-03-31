
import SwiftUI
import SwiftData
import Observation
import AVFoundation
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

    private var heroIconName: String {
        let tasksDone = todayPendingTasks.isEmpty && todayCompletedTaskCount > 0
        let reviewDone = dueItems.isEmpty
        let dictationDone = latestDictationSession?.isReviewed ?? true
        let scheduleDone = todaySchedules.isEmpty
        
        if tasksDone && reviewDone && dictationDone && scheduleDone { return "checkmark.seal.fill" }
        if reviewDone && dictationDone { return "sparkles" }
        if todayPendingTasks.isEmpty { return "book.fill" }
        return "figure.run"
    }

    private var heroMessage: String {
        let pendingTaskCount = todayPendingTasks.count
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
        let pendingTaskCount = todayPendingTasks.count
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
        let tasksDone = todayPendingTasks.isEmpty && todayCompletedTaskCount > 0
        let reviewDone = dueItems.isEmpty
        let dictationDone = latestDictationSession?.isReviewed ?? true
        
        if tasksDone && reviewDone && dictationDone {
            return [.green.opacity(0.85), .mint.opacity(0.65)]
        }
        if !todayPendingTasks.isEmpty || !dueItems.isEmpty || !(latestDictationSession?.isReviewed ?? true) {
            if !todayPendingTasks.isEmpty && !dueItems.isEmpty {
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

                    if !syncStatusStore.cloudKitInitializationError.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("CloudKit 初始化失败详单")
                                    .font(.headline)
                            }
                            .foregroundStyle(.red)

                            Text(syncStatusStore.cloudKitInitializationError)
                                .font(.caption.monospaced())
                                .foregroundStyle(.red.opacity(0.8))
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
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
            Image(systemName: syncStatusStore.isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
                .symbolEffect(.rotate, isActive: syncStatusStore.isRefreshing)
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

    private var todayTasks: [TaskItem] {
        todayTaskItems.map(\.task)
    }

    private var todayPendingTasks: [TaskItem] {
        todayTaskItems.filter { !$0.isCompleted }.map(\.task)
    }

    private var todayCompletedTaskCount: Int {
        todayTaskItems.filter(\.isCompleted).count
    }

    @ViewBuilder
    private var todayTasksCard: some View {
        let taskItems = todayTaskItems
        let doneCount = todayCompletedTaskCount
        
        if !taskItems.isEmpty || !allTasks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    Text("今日任务")
                        .font(.headline)
                    Spacer()
                    if !taskItems.isEmpty {
                        Text("\(doneCount)/\(taskItems.count) 已完成")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(doneCount == taskItems.count ? .green : .orange)
                    }
                }

                if taskItems.isEmpty && !allTasks.isEmpty {
                    Text("今天没有待完成的任务。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(taskItems) { item in
                        let task = item.task
                        let isDone = item.isCompleted
                        let overdueOriginText = item.overdueOriginText
                        
                        HStack(spacing: 12) {
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

                                    if let overdueOriginText, !isDone {
                                        Text(overdueOriginText)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
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

struct DashboardBoardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Query(sort: \ReviewItem.nextReviewAt) private var reviewItems: [ReviewItem]
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var dictationSessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var dictationEntries: [DictationEntry]
    @Query(sort: \TaskItem.createdAt) private var allTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var taskCompletions: [TaskCompletion]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]
    @Query private var settings: [AppSettings]

    @State private var previousIdleTimerDisabled = false
    @State private var boardNow = Date.now

    private let scheduler = ReviewScheduler()

    private var childName: String {
        guard let settings = settings.first else { return "小朋友" }
        return settings.childName.isEmpty ? "小朋友" : settings.childName
    }

    private var dueItems: [ReviewItem] {
        reviewItems
            .filter { $0.nextReviewAt <= boardNow }
            .sorted { $0.nextReviewAt < $1.nextReviewAt }
    }

    private var pendingDictationSessions: [DictationSession] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: boardNow)
        return dictationSessions
            .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var pendingDictationCount: Int {
        pendingDictationSessions.reduce(into: 0) { result, session in
            result += dictationEntries.filter { $0.sessionID == session.id }.count
        }
    }

    private var pendingDictationBoardItems: [BoardTextItem] {
        pendingDictationSessions.flatMap { session in
            dictationEntries
                .filter { $0.sessionID == session.id }
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { entry in
                    return BoardTextItem(id: entry.id, text: entry.content, detail: "")
                }
        }
    }

    private var todayTaskItems: [TodayTaskDisplayItem] {
        TodayTaskListBuilder
            .build(from: allTasks.filter { !$0.isArchived }, completions: taskCompletions, on: boardNow)
    }

    private var todayPendingTasks: [TodayTaskDisplayItem] {
        todayTaskItems.filter { !$0.isCompleted }
    }

    private var todayCompletedTaskCount: Int {
        todayTaskItems.filter(\.isCompleted).count
    }

    private var todaySchedules: [ScheduleItem] {
        allSchedules
            .filter { $0.shouldAppear(on: boardNow) && !$0.hasEnded(on: boardNow, reference: boardNow) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private var todayCompletedCount: Int {
        let calendar = Calendar.current
        return reviewRecords.filter { calendar.isDate($0.reviewedAt, inSameDayAs: boardNow) }
            .count
    }

    private var todayHeadline: String {
        var parts: [String] = []
        if !todayPendingTasks.isEmpty {
            parts.append("\(todayPendingTasks.count) 项待办")
        }
        if !dueItems.isEmpty {
            parts.append("\(dueItems.count) 项复习")
        }
        if pendingDictationCount > 0 {
            parts.append("\(pendingDictationCount) 条听写")
        }
        return parts.isEmpty ? "\(childName) 今天都完成了" : "\(childName) 今天还有 \(parts.joined(separator: "、"))"
    }

    var body: some View {
        GeometryReader { proxy in
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

                VStack(spacing: 28) {
                    boardHeader
                    boardStats
                    boardContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, boardTopInset(for: proxy))
                .padding(.horizontal, 36)
                .padding(.bottom, 28)

                exitBoardButton
                    .padding(.top, topOverlayPadding(for: proxy))
                    .padding(.trailing, 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .onAppear(perform: activateIdleTimerOverride)
        .onDisappear(perform: restoreIdleTimer)
        .onReceive(boardRefreshTimer) { boardNow = $0 }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                boardNow = .now
                activateIdleTimerOverride()
            } else {
                restoreIdleTimer()
            }
        }
    }

    private var boardHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text("听写复习看板")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(todayHeadline)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                HStack(spacing: 10) {
                    Label(syncStatusStore.statusText, systemImage: syncStatusStore.isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
                        .symbolEffect(.rotate, isActive: syncStatusStore.isRefreshing)
                        .font(.headline)
                    Text("已掌握 \(reviewItems.filter(scheduler.isMastered).count) 项")
                        .font(.headline)
                }
                .foregroundStyle(.white.opacity(0.8))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(context.date.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    private var boardStats: some View {
        HStack(spacing: 18) {
            BoardStatCard(title: "今日待办", value: "\(todayPendingTasks.count)", tint: .orange)
            BoardStatCard(title: "待复习", value: "\(dueItems.count)", tint: .blue)
            BoardStatCard(title: "待听写", value: "\(pendingDictationCount)", tint: .teal)
            BoardScheduleStatCard(schedule: todaySchedules.first, tint: .green)
        }
    }

    private var boardContent: some View {
        HStack(alignment: .top, spacing: 18) {
            boardColumn(
                title: "今日任务",
                icon: "checklist",
                items: todayTaskItems,
                emptyTitle: "今天没有任务",
                itemText: { item in
                    item.isCompleted ? "\(item.task.title) · 已完成" : item.task.title
                }
            )

            boardColumn(
                title: "待复习",
                icon: "book.closed.fill",
                items: dueItems,
                emptyTitle: "今天没有待复习",
                itemText: { item in
                    let prompt = item.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    return prompt.isEmpty ? item.content : "\(item.content) · \(prompt)"
                }
            )

            boardColumn(
                title: "待听写",
                icon: "text.book.closed.fill",
                items: pendingDictationBoardItems,
                emptyTitle: "今天没有待听写",
                itemText: { item in
                    item.text
                }
            )
        }
    }

    private func boardColumn<Item: Identifiable>(
        title: String,
        icon: String,
        items: [Item],
        emptyTitle: String,
        itemText: @escaping (Item) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(.white)

            if items.isEmpty {
                VStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.25))
                    Text(emptyTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(24)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 28))
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.prefix(10))) { item in
                        Text(itemText(item))
                            .font(.system(size: 24, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 20))
                    }

                    if items.count > 10 {
                        Text("还有 \(items.count - 10) 项未展示")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func boardTopInset(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 8) : max(proxy.safeAreaInsets.top, 12)
        return safeTop + 18
    }

    private func isLandscapeBoardLayout(fallbackSize: CGSize) -> Bool {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }

        if let activeScene {
            return activeScene.interfaceOrientation.isLandscape
        }
        return fallbackSize.width > fallbackSize.height
    }

    private func topOverlayPadding(for proxy: GeometryProxy) -> CGFloat {
        let isLandscape = isLandscapeBoardLayout(fallbackSize: proxy.size)
        let safeTop = isLandscape ? min(proxy.safeAreaInsets.top, 8) : max(proxy.safeAreaInsets.top, 12)
        return safeTop + 10
    }

    private var exitBoardButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.22), in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var boardRefreshTimer: Timer.TimerPublisher {
        Timer.publish(every: 300, on: .main, in: .common)
    }

    private func activateIdleTimerOverride() {
        let application = UIApplication.shared
        previousIdleTimerDisabled = application.isIdleTimerDisabled
        application.isIdleTimerDisabled = true
    }

    private func restoreIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
    }
}

private struct BoardTextItem: Identifiable {
    let id: UUID
    let text: String
    let detail: String
}

private struct BoardStatCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct BoardScheduleStatCard: View {
    let schedule: ScheduleItem?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日日程")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if let schedule {
                Text(schedule.title)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(schedule.timeRangeText(on: .now))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            } else {
                Text("0")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(tint.opacity(0.32), in: RoundedRectangle(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }
}
