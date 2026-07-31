import WidgetKit
import SwiftUI
import SwiftData

struct Provider: TimelineProvider {
    
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            todayTasks: [],
            configuredTaskCount: 0,
            completedTaskCount: 0,
            historicalPendingCount: 0,
            recentPlans: [],
            pendingReviewCount: 3,
            pendingDictationCount: 2
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = fetchEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = fetchEntry()
        // Refresh every hour or so
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    private func fetchEntry() -> SimpleEntry {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            ReviewDailyPlan.self,
            TaskItem.self,
            TaskCompletion.self,
            TaskSubitem.self,
            TaskExecutionRecord.self,
            TaskSubitemExecutionRecord.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self,
            PointLedgerEntry.self,
            PointRewardState.self
        ])

        guard let container = widgetModelContainer(for: schema) else {
            return SimpleEntry(
                date: Date(),
                todayTasks: [],
                configuredTaskCount: 0,
                completedTaskCount: 0,
                historicalPendingCount: 0,
                recentPlans: [],
                pendingReviewCount: 0,
                pendingDictationCount: 0
            )
        }
        
        let context = ModelContext(container)
        
        let calendar = Calendar.current
        var todayTasks: [WidgetTaskItem] = []
        var configuredTaskCount = 0
        var completedTaskCount = 0
        var historicalPendingCount = 0
        var recentPlans: [RecentPlanProjection] = []
        if let allTasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            let today = Date()
            let taskExecutions = (try? context.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? []
            let subtasks = (try? context.fetch(
                FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
            )) ?? []
            let autoArchivedCompletedAtByTaskID = Dictionary(
                taskExecutions.compactMap { record -> (UUID, Date)? in
                    guard record.status == .completed,
                          let completedAt = record.completedAt,
                          calendar.isDate(completedAt, inSameDayAs: today) else {
                        return nil
                    }
                    return (record.taskID, completedAt)
                },
                uniquingKeysWith: max
            )
            let visibleTasks = allTasks.filter { task in
                guard task.isArchived else { return true }
                guard task.recurrence.kind == .once,
                      let completedAt = autoArchivedCompletedAtByTaskID[task.id] else {
                    return false
                }
                return task.updatedAt <= completedAt
            }
            let deduplicatedTasks = TaskDedupSupport.deduplicatedTasks(allTasks)
            let deduplicatedVisibleTasks = TaskDedupSupport.deduplicatedTasks(visibleTasks)
            let taskProjections = deduplicatedVisibleTasks.map(TaskProjection.init)
            let taskProjectionResults = TodayTaskProjectionBuilder.build(
                from: taskProjections,
                executions: taskExecutions.map(TaskExecutionRecordProjection.init),
                subtasks: subtasks.map(TaskSubitemProjection.init),
                on: today
            )
            let tasksByID = Dictionary(
                deduplicatedVisibleTasks.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let taskItems = TaskDedupSupport.deduplicatedDisplayItems(
                taskProjectionResults.compactMap { projection in
                    tasksByID[projection.taskID].map { task in
                        TodayTaskDisplayItem(
                            task: task,
                            section: projection.section,
                            occurrenceDate: projection.occurrenceDate,
                            isCompleted: projection.isCompleted,
                            pendingOccurrenceCount: projection.pendingOccurrenceCount,
                            historicalPendingCount: projection.historicalPendingCount,
                            totalPendingOccurrenceCount: projection.totalPendingOccurrenceCount,
                            overdueOriginText: projection.overdueOriginText,
                            totalSubtaskCount: projection.totalSubtaskCount,
                            completedSubtaskCount: projection.completedSubtaskCount
                        )
                    }
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
            configuredTaskCount = deduplicatedTasks.filter {
                !$0.isArchived && $0.timingMode == .scheduled
            }.count
            let taskSections = TodayTaskSectionSnapshotBuilder.build(
                from: taskItems,
                taskID: { $0.task.id },
                section: { $0.section }
            )
            let visibleTodayTasks = taskSections.todayPendingItems + taskSections.todayDoneItems
            completedTaskCount = taskSections.todayDoneItems.count
            historicalPendingCount = taskSections.historicalPendingTotalCount
            todayTasks = visibleTodayTasks.map {
                WidgetTaskItem(
                    id: $0.task.id,
                    title: $0.task.title,
                    isCompleted: $0.isCompleted,
                    overdueOriginText: $0.overdueOriginText,
                    historicalPendingCount: $0.historicalPendingCount,
                    totalPendingOccurrenceCount: $0.totalPendingOccurrenceCount
                )
            }
            recentPlans = RecentPlanSupport.visibleProjections(
                from: deduplicatedTasks.map(TaskProjection.init),
                executions: taskExecutions.map(TaskExecutionRecordProjection.init),
                subtasks: subtasks.map(TaskSubitemProjection.init),
                on: today,
                includeCompletedToday: false,
                calendar: calendar
            )
        }
        
        var reviewsCount = 0
        if let reviewItems = try? context.fetch(FetchDescriptor<ReviewItem>()),
           let reviewRecords = try? context.fetch(FetchDescriptor<ReviewRecord>()),
           let dailyPlans = try? context.fetch(FetchDescriptor<ReviewDailyPlan>()) {
            let now = Date.now
            let dayKey = ReviewDailyPlan.dayKey(for: now, calendar: calendar)
            let plan = ReviewDailyPlan.preferred(from: dailyPlans.filter { $0.dayKey == dayKey })
            let reviewedTodayItemIDs = Set(
                reviewRecords.compactMap { record -> UUID? in
                    guard record.mode != .dictation,
                          calendar.isDate(record.reviewedAt, inSameDayAs: now) else {
                        return nil
                    }
                    return record.itemID
                }
            )
            let todayStart = calendar.startOfDay(for: now)
            let dueItems: [ReviewItem] = ReviewContentIdentity.canonicalReviewItems(from: reviewItems)
                .filter { item in
                    item.nextReviewAt != .distantFuture
                        && calendar.startOfDay(for: item.nextReviewAt) <= todayStart
                }
            let dueItemIDs = Set(dueItems.map { $0.id })

            if let plan {
                reviewsCount = plan.itemIDs.filter {
                    dueItemIDs.contains($0) && !reviewedTodayItemIDs.contains($0)
                }.count
            } else {
                let settings = (try? context.fetch(FetchDescriptor<AppSettings>()))
                    .flatMap { AppSettings.chooseCanonical(from: $0) }
                let dailyLimit = settings?.dailyLimit ?? AppSettings.defaultDailyLimit
                reviewsCount = min(
                    dueItems.filter { !reviewedTodayItemIDs.contains($0.id) }.count,
                    dailyLimit
                )
            }
        }
        
        var dictationsCount = 0
        if let sessions = try? context.fetch(FetchDescriptor<DictationSession>()),
           let allEntries = try? context.fetch(FetchDescriptor<DictationEntry>()) {
            let todayStart = calendar.startOfDay(for: .now)
            let todayEnd = calendar.date(byAdding: .init(day: 1, second: -1), to: todayStart)!
            let pendingSessions = sessions.filter { session in
                !session.isReviewed && session.scheduledDate <= todayEnd
            }
            
            for session in pendingSessions {
                dictationsCount += allEntries.filter { $0.sessionID == session.id }.count
            }
        }
        
        return SimpleEntry(
            date: Date(),
            todayTasks: todayTasks,
            configuredTaskCount: configuredTaskCount,
            completedTaskCount: completedTaskCount,
            historicalPendingCount: historicalPendingCount,
            recentPlans: recentPlans,
            pendingReviewCount: reviewsCount,
            pendingDictationCount: dictationsCount
        )
    }

    private func widgetModelContainer(for schema: Schema) -> ModelContainer? {
        let groupIdentifier = "group.cc.xiaorsz.typo-review"
        let preferredConfig = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(groupIdentifier),
            cloudKitDatabase: .none
        )

        if let container = try? ModelContainer(for: schema, configurations: preferredConfig) {
            return container
        }

        guard let legacyURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)?
            .appendingPathComponent("typo-review.store") else {
            return nil
        }

        let legacyConfig = ModelConfiguration(
            schema: schema,
            url: legacyURL,
            cloudKitDatabase: .none
        )
        return try? ModelContainer(for: schema, configurations: legacyConfig)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let todayTasks: [WidgetTaskItem]
    let configuredTaskCount: Int
    let completedTaskCount: Int
    let historicalPendingCount: Int
    let recentPlans: [RecentPlanProjection]
    let pendingReviewCount: Int
    let pendingDictationCount: Int
}

struct WidgetTaskItem: Identifiable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    let overdueOriginText: String?
    let historicalPendingCount: Int
    let totalPendingOccurrenceCount: Int
}

struct TypoWidgetEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .systemLarge {
                largeView
            } else if family == .systemExtraLarge {
                extraLargeView
            } else {
                mediumView
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [.blue.opacity(0.85), .cyan.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var historicalSummaryText: String {
        if entry.todayTasks.isEmpty {
            return "\(entry.historicalPendingCount) 次历史待办"
        }
        return "另有 \(entry.historicalPendingCount) 次历史待办"
    }

    @ViewBuilder
    private func historicalSummaryLabel(_ font: Font) -> some View {
        if entry.historicalPendingCount > 0 {
            Text(historicalSummaryText)
                .font(font)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    private func backlogBadge(_ count: Int, font: Font) -> some View {
        Text("历史 \(count) 次")
            .font(font.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.18), in: Capsule())
    }

    private func taskRow(
        _ task: WidgetTaskItem,
        iconFont: Font,
        titleFont: Font,
        badgeFont: Font
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(iconFont)
                .foregroundStyle(task.isCompleted ? .green : .white.opacity(0.6))

            Text(task.title)
                .font(titleFont)
                .lineLimit(1)
                .foregroundStyle(task.isCompleted ? .white.opacity(0.75) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)

            if task.historicalPendingCount > 0 {
                backlogBadge(task.historicalPendingCount, font: badgeFont)
            }
        }
    }

    private func recentPlanColor(_ plan: RecentPlanProjection) -> Color {
        switch plan.deadlineState.kind {
        case .overdue:
            return .red
        case .dueToday:
            return .orange
        case .upcoming:
            return plan.deadlineState.dayCount <= 7 ? .orange : .blue
        }
    }

    private func recentPlanRow(_ plan: RecentPlanProjection, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 9) {
            Image(systemName: "flag.fill")
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(recentPlanColor(plan))

            Text(plan.task.title)
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(plan.deadlineState.statusText)
                .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                .foregroundStyle(recentPlanColor(plan))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func recentPlansSection(maxPlans: Int, compact: Bool) -> some View {
        if !entry.recentPlans.isEmpty {
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                HStack {
                    Label("近期计划", systemImage: "calendar.badge.exclamationmark")
                        .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer()
                    if entry.recentPlans.count > maxPlans {
                        Text("另有 \(entry.recentPlans.count - maxPlans) 项")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }

                ForEach(Array(entry.recentPlans.prefix(maxPlans))) { plan in
                    recentPlanRow(plan, compact: compact)
                }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: compact ? 10 : 12))
        }
    }
    
    private var largeView: some View {
        let maxTasks = entry.recentPlans.isEmpty ? 5 : 3
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                Text("听写复习")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.white)
            
            HStack(spacing: 12) {
                MediumStatBox(title: "待复习", count: entry.pendingReviewCount, color: .orange)
                MediumStatBox(title: "待听写", count: entry.pendingDictationCount, color: .teal)
            }

            recentPlansSection(maxPlans: 2, compact: false)
            
            Divider()
                .overlay(.white.opacity(0.6))
                .padding(.vertical, 0)
            
            VStack(alignment: .leading, spacing: 18) { // Changed from 14 to 18
                HStack(alignment: .top) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.clipboard")
                        Text("今日任务")
                    }
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        if !entry.todayTasks.isEmpty {
                            Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                        }

                        historicalSummaryLabel(.caption)

                        if entry.todayTasks.count > maxTasks {
                            Text("还有 \(entry.todayTasks.count - maxTasks) 项任务未展示")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                
                if entry.todayTasks.isEmpty {
                    VStack(alignment: .center) {
                        Spacer()
                        Text(entry.configuredTaskCount == 0 ? "还没有任务" : "今天没有待完成的任务")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(entry.todayTasks.prefix(maxTasks))) { task in
                                taskRow(
                                    task,
                                    iconFont: .headline.weight(.semibold),
                                    titleFont: .headline.weight(.semibold),
                                    badgeFont: .caption2
                                )
                            }
                        }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }
    
    private var mediumView: some View {
        let maxTasks = entry.recentPlans.isEmpty ? 2 : 1
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                Text("听写复习")
                    .font(.headline)
                
                Spacer()
                
                HStack(spacing: 6) {
                    SmallStat(title: "复习", count: entry.pendingReviewCount, color: .orange)
                    SmallStat(title: "听写", count: entry.pendingDictationCount, color: .teal)
                }
            }
            .foregroundStyle(.white)

            recentPlansSection(maxPlans: 1, compact: true)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.clipboard")
                        Text("今日任务")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        if !entry.todayTasks.isEmpty {
                            Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                        }

                        historicalSummaryLabel(.caption2)

                        if entry.todayTasks.count > maxTasks {
                            Text("还有 \(entry.todayTasks.count - maxTasks) 项")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                
                if entry.todayTasks.isEmpty {
                    VStack(alignment: .center) {
                        Spacer()
                        Text(entry.configuredTaskCount == 0 ? "还没有任务" : "今天没有待完成的任务")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entry.todayTasks.prefix(maxTasks))) { task in
                            taskRow(
                                task,
                                iconFont: .subheadline,
                                titleFont: .subheadline.weight(.medium),
                                badgeFont: .caption2
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var extraLargeView: some View {
        let maxTasks = entry.recentPlans.isEmpty ? 5 : 3
        return HStack(spacing: 24) {
            // Left Column: Stats & Meta
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.title.weight(.bold))
                        Text("听写复习本")
                            .font(.title2.weight(.bold))
                    }
                }
                .foregroundStyle(.white)
                
                Spacer()
                
                VStack(spacing: 12) {
                    LargeStatCard(title: "待复习题目", count: entry.pendingReviewCount, icon: "book.closed.fill", color: .orange)
                    LargeStatCard(title: "今日待听写", count: entry.pendingDictationCount, icon: "text.book.closed.fill", color: .teal)
                }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Right Column: Tasks
            VStack(alignment: .leading, spacing: 14) {
                recentPlansSection(maxPlans: 2, compact: false)

                HStack(alignment: .top) {
                    Label("今日任务", systemImage: "list.bullet.clipboard.fill")
                        .font(.headline)
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 4) {
                        if !entry.todayTasks.isEmpty {
                            Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                        }

                        historicalSummaryLabel(.subheadline)

                        if entry.todayTasks.count > maxTasks {
                            Text("还有 \(entry.todayTasks.count - maxTasks) 项")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                
                if entry.todayTasks.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.3))
                        Text(entry.configuredTaskCount == 0 ? "还没有任务" : "今天没有待完成的任务")
                            .font(.title3.weight(.semibold))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(.white)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(entry.todayTasks.prefix(maxTasks))) { task in
                            taskRow(
                                task,
                                iconFont: .title3.weight(.bold),
                                titleFont: .title3.weight(.semibold),
                                badgeFont: .caption
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 24))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        }
        .padding(24)
    }
}

struct LargeStatCard: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            
            Text("\(count)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct MediumStatBox: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            Text("\(count)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SmallStat: View {
    let title: String
    let count: Int
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
            Text("\(count)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.85), in: Capsule())
    }
}

struct TypoWidget: Widget {
    let kind: String = "TypoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            TypoWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("复习进度")
        .description("显示今日的待办任务详情和复习听写进度。")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}
