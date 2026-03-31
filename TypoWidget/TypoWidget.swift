import WidgetKit
import SwiftUI
import SwiftData

@MainActor
struct Provider: TimelineProvider {
    
    @MainActor
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(
            date: Date(),
            todayTasks: [],
            configuredTaskCount: 0,
            completedTaskCount: 0,
            pendingReviewCount: 3,
            pendingDictationCount: 2
        )
    }

    @MainActor
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = fetchEntry()
        completion(entry)
    }

    @MainActor
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = fetchEntry()
        // Refresh every hour or so
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
    
    @MainActor
    private func fetchEntry() -> SimpleEntry {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self
        ])

        guard let container = widgetModelContainer(for: schema) else {
            return SimpleEntry(
                date: Date(),
                todayTasks: [],
                configuredTaskCount: 0,
                completedTaskCount: 0,
                pendingReviewCount: 0,
                pendingDictationCount: 0
            )
        }
        
        let context = ModelContext(container)
        
        let calendar = Calendar.current
        var todayTasks: [WidgetTaskItem] = []
        var configuredTaskCount = 0
        var completedTaskCount = 0
        if let allTasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            let today = Date()
            let taskCompletions = (try? context.fetch(FetchDescriptor<TaskCompletion>())) ?? []
            configuredTaskCount = allTasks.filter { !$0.isArchived }.count
            let taskItems = TodayTaskListBuilder.build(from: allTasks, completions: taskCompletions, on: today)
            completedTaskCount = taskItems.filter(\.isCompleted).count
            todayTasks = taskItems.map {
                WidgetTaskItem(
                    id: $0.task.id,
                    title: $0.task.title,
                    isCompleted: $0.isCompleted,
                    overdueOriginText: $0.overdueOriginText
                )
            }
        }
        
        var reviewsCount = 0
        if let reviewItems = try? context.fetch(FetchDescriptor<ReviewItem>()) {
            reviewsCount = reviewItems.filter { $0.nextReviewAt <= .now }.count
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
    let pendingReviewCount: Int
    let pendingDictationCount: Int
}

struct WidgetTaskItem: Identifiable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    let overdueOriginText: String?
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
    
    private var largeView: some View {
        let maxTasks = 5
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
            
            Divider()
                .overlay(.white.opacity(0.6))
                .padding(.vertical, 0)
            
            VStack(alignment: .leading, spacing: 18) { // Changed from 14 to 18
                HStack(alignment: .bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.clipboard")
                        Text("今日任务")
                    }
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()

                    if !entry.todayTasks.isEmpty {
                        Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                    }

                    if entry.todayTasks.count > maxTasks {
                        Spacer()
                        Text("还有 \(entry.todayTasks.count - maxTasks) 项任务未展示")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
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
                                HStack(spacing: 14) {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(task.isCompleted ? .green : .white.opacity(0.6))
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(task.title)
                                            .font(.headline.weight(.semibold))
                                            .lineLimit(1)
                                            .foregroundStyle(task.isCompleted ? .white.opacity(0.75) : .white)
                                        if let overdueOriginText = task.overdueOriginText, !task.isCompleted {
                                            Text(overdueOriginText)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.white.opacity(0.78))
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
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
        let maxTasks = 2
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
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom) {
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet.clipboard")
                        Text("今日任务")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    
                    Spacer()

                    if !entry.todayTasks.isEmpty {
                        Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                    }

                    if entry.todayTasks.count > maxTasks {
                        Spacer()
                        Text("还有 \(entry.todayTasks.count - maxTasks) 项")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
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
                            HStack(spacing: 10) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline)
                                    .foregroundStyle(task.isCompleted ? .green : .white.opacity(0.6))
                                HStack(alignment: .firstTextBaseline, spacing: 5) {
                                    Text(task.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .foregroundStyle(task.isCompleted ? .white.opacity(0.75) : .white)
                                    if let overdueOriginText = task.overdueOriginText, !task.isCompleted {
                                        Text(overdueOriginText)
                                            .font(.caption2)
                                            .foregroundStyle(.white.opacity(0.74))
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
        let maxTasks = 5
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
                HStack {
                    Label("今日任务", systemImage: "list.bullet.clipboard.fill")
                        .font(.headline)
                    
                    Spacer()
                    
                    if !entry.todayTasks.isEmpty {
                        Text("\(entry.completedTaskCount)/\(entry.todayTasks.count) 已完成")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(entry.completedTaskCount == entry.todayTasks.count ? .green : .white.opacity(0.8))
                    }

                    if entry.todayTasks.count > maxTasks {
                        Text("还有 \(entry.todayTasks.count - maxTasks) 项")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
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
                            HStack(spacing: 14) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(task.isCompleted ? .green : .white.opacity(0.5))
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(task.title)
                                        .font(.title3.weight(.semibold))
                                        .lineLimit(1)
                                        .foregroundStyle(task.isCompleted ? .white.opacity(0.75) : .white)
                                    if let overdueOriginText = task.overdueOriginText, !task.isCompleted {
                                        Text(overdueOriginText)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.white.opacity(0.78))
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
