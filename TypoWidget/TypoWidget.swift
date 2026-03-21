import WidgetKit
import SwiftUI
import SwiftData

struct Provider: TimelineProvider {
    
    @MainActor
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), pendingTasks: [], pendingReviewCount: 3, pendingDictationCount: 2)
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
        // Must use the App Group container URL to share data between target and main app!
        guard let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.cc.xiaorsz.typo-review")?.appendingPathComponent("typo-review.store") else {
            return SimpleEntry(date: Date(), pendingTasks: [], pendingReviewCount: 0, pendingDictationCount: 0)
        }
        
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self
        ])
        
        let config = ModelConfiguration(url: sharedContainerURL, cloudKitDatabase: .none)
        
        guard let container = try? ModelContainer(for: schema, configurations: config) else {
            return SimpleEntry(date: Date(), pendingTasks: [], pendingReviewCount: 0, pendingDictationCount: 0)
        }
        
        let context = ModelContext(container)
        
        let calendar = Calendar.current
        var tasks: [TaskItem] = []
        if let allTasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            let today = Date()
            let taskCompletions = (try? context.fetch(FetchDescriptor<TaskCompletion>())) ?? []
            for task in allTasks {
                // TaskItem's `shouldAppear` internal logic already validates recurrence
                // and correctly checks if it's already completed for the given date.
                if task.shouldAppear(on: today, completions: taskCompletions) {
                    tasks.append(task)
                }
            }
        }
        
        var reviewsCount = 0
        if let reviewItems = try? context.fetch(FetchDescriptor<ReviewItem>()) {
            reviewsCount = reviewItems.filter { $0.nextReviewAt <= .now }.count
        }
        
        var dictationsCount = 0
        if let sessions = try? context.fetch(FetchDescriptor<DictationSession>()) {
            let todayStart = calendar.startOfDay(for: .now)
            let todayEnd = calendar.date(byAdding: .init(day: 1, second: -1), to: todayStart)!
            let pendingDictations = sessions.filter { session in
                !session.isFinished && session.scheduledDate >= todayStart && session.scheduledDate <= todayEnd
            }
            dictationsCount = pendingDictations.count
        }
        
        return SimpleEntry(date: Date(), pendingTasks: tasks, pendingReviewCount: reviewsCount, pendingDictationCount: dictationsCount)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let pendingTasks: [TaskItem]
    let pendingReviewCount: Int
    let pendingDictationCount: Int
}

struct TypoWidgetEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if family == .systemLarge {
                largeView
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
        let maxTasks = 4
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
                        Text("今日待办")
                    }
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    
                    if entry.pendingTasks.count > maxTasks {
                        Spacer()
                        Text("还有 \(entry.pendingTasks.count - maxTasks) 项任务未展示")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                
                if entry.pendingTasks.isEmpty {
                    VStack(alignment: .center) {
                        Spacer()
                        Text("全部完成 🎉")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(entry.pendingTasks.prefix(maxTasks)), id: \.id) { task in
                            HStack(spacing: 12) {
                                Image(systemName: "circle")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(task.title)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
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
                        Text("今日待办")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    
                    if entry.pendingTasks.count > maxTasks {
                        Spacer()
                        Text("还有 \(entry.pendingTasks.count - maxTasks) 项")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                
                if entry.pendingTasks.isEmpty {
                    VStack(alignment: .center) {
                        Spacer()
                        Text("全部完成 🎉")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(entry.pendingTasks.prefix(maxTasks)), id: \.id) { task in
                            HStack(spacing: 10) {
                                Image(systemName: "circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(task.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .foregroundStyle(.white)
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
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
