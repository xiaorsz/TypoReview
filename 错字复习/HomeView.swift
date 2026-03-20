import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Query(sort: \ReviewItem.nextReviewAt) private var reviewItems: [ReviewItem]
    @Query(sort: \ReviewRecord.reviewedAt, order: .reverse) private var reviewRecords: [ReviewRecord]
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var dictationSessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var dictationEntries: [DictationEntry]
    @Query private var settings: [AppSettings]
    @Query(filter: #Predicate<TaskItem> { !$0.isArchived }, sort: \TaskItem.createdAt) private var activeTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var taskCompletions: [TaskCompletion]
    @AppStorage("reviewInteractionStyle") private var reviewStyle: ReviewInteractionStyle = .oneByOne

    private let scheduler = ReviewScheduler()

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

    private var heroEmoji: String {
        if dueItems.isEmpty { return "🎉" }
        if dueItems.count <= 5 { return "✨" }
        return "💪"
    }

    private var heroMessage: String {
        if dueItems.isEmpty {
            return "今天的复习全部完成了！"
        }
        return "\(childName) 今天待复习 \(dueItems.count) 项"
    }

    private var heroSubtitle: String {
        if dueItems.isEmpty {
            return "可以去录入新的错题，或者休息一下。明天见！"
        }
        if allDueItems.count > dailyLimit {
            return "今天共有 \(allDueItems.count) 项到期，推荐先练 \(dailyLimit) 项。"
        }
        return "孩子在纸上写，家长判定对错，同一题当天只练一次。"
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                let isWide = proxy.size.width >= 700

                VStack(spacing: 20) {
                    heroCard

                    // Stat grid
                    let columns = isWide
                        ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
                        : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

                    LazyVGrid(columns: columns, spacing: 12) {
                        StatGridCard(icon: "book.closed", title: "待复习", value: "\(dueItems.count)", tint: .orange)
                        StatGridCard(icon: "checkmark.circle", title: "今日完成", value: "\(todayCompletedCount)", tint: .green)
                        StatGridCard(icon: "xmark.circle", title: "今日答错", value: "\(todayWrongCount)", tint: .red)
                        StatGridCard(icon: "percent", title: "正确率", value: todayAccuracyText, tint: .blue)
                        StatGridCard(icon: "exclamationmark.triangle", title: "重点复习", value: "\(reviewItems.filter(\.isPriority).count)", tint: .orange)
                        StatGridCard(icon: "star.fill", title: "已掌握", value: "\(reviewItems.filter(scheduler.isMastered).count)", tint: .mint)
                    }

                    todayTasksCard

                    quickEntryCard

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
                }
                .padding(isWide ? 32 : 20)
                .frame(maxWidth: 960, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("今日复习")
        .task {
            if settings.isEmpty {
                modelContext.insert(AppSettings())
            }
        }
        .toolbar {
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

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heroEmoji)
                .font(.system(size: 48))

            Text(heroMessage)
                .font(.system(.title, design: .rounded, weight: .bold))

            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))

            syncStatusBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(
                    LinearGradient(
                        colors: dueItems.isEmpty
                            ? [.green.opacity(0.85), .mint.opacity(0.65)]
                            : [.orange.opacity(0.9), .yellow.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var syncStatusBadge: some View {
        HStack(spacing: 10) {
            Image(systemName: syncStatusStore.isRefreshing ? "arrow.triangle.2.circlepath" : "icloud")
                .symbolEffect(.rotate, isActive: syncStatusStore.isRefreshing)
            Text(syncStatusStore.statusText)
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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

            Text("把当天写错的汉字、词语或单词录进来，保存后直接进入今天待复习。")
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
        Group {
            if reviewStyle == .batch {
                NavigationLink {
                    BatchReviewSessionView(items: dueItems)
                } label: {
                    reviewEntryLabel
                }
                .disabled(dueItems.isEmpty)
            } else {
                NavigationLink {
                    ReviewSessionView(items: dueItems)
                } label: {
                    reviewEntryLabel
                }
                .disabled(dueItems.isEmpty)
            }
        }
    }

    private var reviewEntryLabel: some View {
        HStack {
            Image(systemName: "play.fill")
            Text("开始今天复习")
            if !dueItems.isEmpty {
                Text("(\(dueItems.count))")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .font(.title3.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding()
        .background(dueItems.isEmpty ? Color.gray : Color.accentColor)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var dictationEntryButton: some View {
        NavigationLink {
            DictationHomeView()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label("进入今日听写", systemImage: "text.book.closed.fill")
                    .font(.title3.weight(.semibold))
                Text(dictationStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.teal)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
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

    // MARK: - Today Tasks

    private var todayPendingTasks: [TaskItem] {
        activeTasks.filter { $0.shouldAppear(on: .now, completions: taskCompletions) }
    }

    private var todayCompletedTaskCount: Int {
        let calendar = Calendar.current
        return taskCompletions.filter { calendar.isDateInToday($0.completedDate) }.count
    }

    @ViewBuilder
    private var todayTasksCard: some View {
        let pending = todayPendingTasks
        let doneCount = todayCompletedTaskCount
        let totalCount = pending.count + doneCount

        if totalCount > 0 || !activeTasks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "checklist")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    Text("今日任务")
                        .font(.headline)
                    Spacer()
                    if totalCount > 0 {
                        Text("\(doneCount)/\(totalCount) 已完成")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(doneCount == totalCount ? .green : .orange)
                    }
                }

                if pending.isEmpty && doneCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("今日任务全部完成！")
                            .fontWeight(.semibold)
                    }
                } else if pending.isEmpty {
                    Text("今天没有待完成的任务。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(pending) { task in
                        HStack(spacing: 12) {
                            Button {
                                completeTask(task)
                            } label: {
                                Image(systemName: "circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.title)
                                    .fontWeight(.medium)
                                HStack(spacing: 6) {
                                    Text(task.recurrenceLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if task.skipPolicy == .unskippable {
                                        Text("不可跳过")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }

                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }

                NavigationLink {
                    TasksView()
                } label: {
                    Text("管理全部任务")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
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

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}
