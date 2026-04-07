import SwiftUI
import SwiftData
import WidgetKit
import UIKit

struct TasksView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TaskItem> { !$0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var activeTasks: [TaskItem]
    @Query(filter: #Predicate<TaskItem> { $0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var archivedTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var completions: [TaskCompletion]
    @Query(filter: #Predicate<ScheduleItem> { !$0.isArchived }, sort: \ScheduleItem.startTime) private var activeSchedules: [ScheduleItem]
    @Query(filter: #Predicate<ScheduleItem> { $0.isArchived }, sort: \ScheduleItem.startTime) private var archivedSchedules: [ScheduleItem]
    
    // Performance Optimization: Cache computed results in a local snapshot
    @State private var todayTasksSnapshot: [TodayTaskDisplayItem] = []
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var deferredSaveTask: Task<Void, Never>?

    private struct TaskDetailRoute: Hashable {
        let taskID: UUID
        let title: String
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active
    }

    private var todayPending: [TodayTaskDisplayItem] {
        todayTasksSnapshot
            .filter { $0.section == .todayPending }
    }
    
    private var historicalPending: [TodayTaskDisplayItem] {
        todayTasksSnapshot
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }
    
    private var todayDone: [TodayTaskDisplayItem] {
        todayTasksSnapshot
            .filter { $0.section == .todayDone }
    }

    private var todayTaskIds: Set<UUID> {
        Set(todayTasksSnapshot.map(\.task.id))
    }



    private var otherTasks: [TaskItem] {
        guard canRenderLiveContent else { return [] }
        return activeTasks.filter { !todayTaskIds.contains($0.id) }
    }

    private var todaySchedules: [ScheduleItem] {
        guard canRenderLiveContent else { return [] }
        return activeSchedules
            .filter { $0.shouldAppear(on: .now) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private var otherSchedules: [ScheduleItem] {
        guard canRenderLiveContent else { return [] }
        return activeSchedules
            .filter { schedule in
                !todaySchedules.contains(where: { $0.id == schedule.id })
            }
            .sorted { lhs, rhs in
                if lhs.repeatRule == .once, rhs.repeatRule == .once {
                    return lhs.startTime < rhs.startTime
                }
                if lhs.repeatRule == .once { return true }
                if rhs.repeatRule == .once { return false }
                return lhs.title.localizedCompare(rhs.title) == .orderedAscending
            }
    }

    var body: some View {
        taskList
            .navigationTitle("任务管理")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    addMenu
                }
            }
            .task {
                scheduleSnapshotRefresh()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    scheduleSnapshotRefresh()
                } else {
                    snapshotRefreshTask?.cancel()
                }
            }
            .onChange(of: activeTasks) { _, _ in scheduleSnapshotRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
                scheduleSnapshotRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                scheduleSnapshotRefresh()
            }
            .navigationDestination(for: TaskDetailRoute.self) { route in
                DeferredTaskDetailView(route: route)
            }
            .onDisappear {
                snapshotRefreshTask?.cancel()
            }
    }

    private var taskList: some View {
        List {
            taskListContent
        }
    }

    @ViewBuilder
    private var taskListContent: some View {
        if !canRenderLiveContent {
            EmptyView()
        } else if activeTasks.isEmpty && archivedTasks.isEmpty && activeSchedules.isEmpty && archivedSchedules.isEmpty {
            emptyStateSection
        } else {
            activeSections
            archivedSections
        }
    }

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView {
                Label("还没有任务和日程", systemImage: "checklist")
            } description: {
                Text("点右上角添加每日任务、作业提醒和日程安排。")
            }
        }
    }

    @ViewBuilder
    private var activeSections: some View {
        if !todaySchedules.isEmpty {
            scheduleSection("今日日程", schedules: todaySchedules)
        }

        if !todayPending.isEmpty {
            todayTaskSection("今日待完成", items: todayPending)
        }

        if !historicalPending.isEmpty {
            todayTaskSection("历史待完成", items: historicalPending)
        }

        if !todayDone.isEmpty {
            todayTaskSection("今日已完成", items: todayDone)
        }

        if !otherTasks.isEmpty {
            otherTaskSection("其它任务", tasks: otherTasks)
        }

        if !otherSchedules.isEmpty {
            scheduleSection("其它日程", schedules: otherSchedules)
        }
    }

    @ViewBuilder
    private var archivedSections: some View {
        if !archivedTasks.isEmpty {
            archivedTaskSection
        }

        if !archivedSchedules.isEmpty {
            archivedScheduleSection
        }
    }

    private var archivedTaskSection: some View {
        Section("已归档") {
            ForEach(archivedTasks) { task in
                archivedTaskRow(task)
            }
        }
    }

    private var archivedScheduleSection: some View {
        Section("已归档日程") {
            ForEach(archivedSchedules) { schedule in
                archivedScheduleRow(schedule)
            }
        }
    }

    @ViewBuilder
    private var addMenu: some View {
        if #available(iOS 18.0, *) {
            Menu {
                NavigationLink {
                    AddTaskView()
                } label: {
                    Label("新增任务", systemImage: "checklist")
                }

                NavigationLink {
                    AddScheduleView()
                } label: {
                    Label("新增日程", systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus")
            }
        } else {
            HStack(spacing: 14) {
                NavigationLink {
                    AddTaskView()
                } label: {
                    Image(systemName: "checklist")
                }

                NavigationLink {
                    AddScheduleView()
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
            }
        }
    }

    private func archivedTaskRow(_ task: TaskItem) -> some View {
        HStack {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                Text(task.recurrenceLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .iOS17SafeSwipeActions {
            Button("恢复", systemImage: "arrow.uturn.backward") {
                task.isArchived = false
            }
            .tint(.blue)

            Button("彻底删除", systemImage: "trash", role: .destructive) {
                deleteTask(task)
            }
        }
    }

    private func scheduleSection(_ title: LocalizedStringKey, schedules: [ScheduleItem]) -> some View {
        Section(title) {
            ForEach(schedules) { schedule in
                scheduleRow(schedule)
            }
        }
    }

    private func todayTaskSection(_ title: LocalizedStringKey, items: [TodayTaskDisplayItem]) -> some View {
        Section(title) {
            ForEach(items) { item in
                todayTaskRow(item)
            }
        }
    }

    private func otherTaskSection(_ title: LocalizedStringKey, tasks: [TaskItem]) -> some View {
        Section(title) {
            ForEach(tasks) { task in
                taskRow(task, isDone: false, showActions: false)
            }
        }
    }
    
    private func scheduleSnapshotRefresh() {
        snapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let container = modelContext.container
        let taskModels = activeTasks

        snapshotRefreshTask = Task(priority: .utility) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            
            let projectedItems = try? await Task.detached(priority: .utility) {
                let backgroundContext = ModelContext(container)
                
                // 完全在后台线程里进行取数据和投影，绝对不阻塞主线程
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
            todayTasksSnapshot = TodayTaskProjectionBuilder.displayItems(
                from: validProjectedItems,
                tasksByID: tasksByID
            )
        }
    }

    private func todayTaskRow(_ item: TodayTaskDisplayItem, showActions: Bool = true) -> some View {
        taskRow(
            item.task,
            isDone: item.isCompleted,
            showActions: showActions,
            occurrenceDate: item.occurrenceDate,
            occurrenceLabel: item.overdueOriginText,
            totalSubtaskCount: item.totalSubtaskCount,
            completedSubtaskCount: item.completedSubtaskCount
        )
    }

    private func taskRow(
        _ task: TaskItem,
        isDone: Bool,
        showActions: Bool = true,
        occurrenceDate: Date? = nil,
        occurrenceLabel: String? = nil,
        totalSubtaskCount: Int? = nil,
        completedSubtaskCount: Int? = nil
    ) -> some View {
        let hasSubtasks = (totalSubtaskCount ?? 0) > 0

        return HStack(spacing: 10) {
            if showActions {
                if hasSubtasks {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "list.bullet.circle")
                        .font(.title3)
                        .foregroundStyle(isDone ? .green : .secondary)
                } else {
                    Button {
                        toggleCompletion(for: task, occurrenceDate: occurrenceDate ?? .now, isDone: isDone)
                    } label: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isDone ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
            }

            NavigationLink(value: TaskDetailRoute(taskID: task.id, title: task.title)) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .fontWeight(.medium)
                            .strikethrough(isDone)
                            .foregroundStyle(isDone ? .secondary : .primary)

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
                                    
                                Text(task.originShortText(for: occurrenceDate ?? .now))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }

                            if let totalSubtaskCount, totalSubtaskCount > 0,
                               let completedSubtaskCount {
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    
                                Text("\(completedSubtaskCount)/\(totalSubtaskCount)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(isDone ? .green : .blue)
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                        if !task.note.isEmpty {
                            Text(task.note)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .iOS17SafeSwipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("归档", systemImage: "archivebox", role: .destructive) {
                withAnimation {
                    task.isArchived = true
                }
                saveAndReloadWidgetsDeferred()
            }
        }
    }

    private func toggleCompletion(for task: TaskItem, occurrenceDate: Date, isDone: Bool) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        
        let tid = task.id
        let container = modelContext.container
        
        // 1. 立即乐观更新 UI
        optimisticToggleTask(taskID: tid, occurrenceDate: occurrenceDate, isDone: isDone)
        
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
                    if isDone {
                        TaskExecutionSupport.reopenTaskCompletion(
                            task: validTask,
                            occurrenceDate: occurrenceDate,
                            existingExecutions: relevantExecutions,
                            modelContext: ctx
                        )
                    } else {
                        TaskExecutionSupport.markTaskCompleted(
                            task: validTask,
                            occurrenceDate: occurrenceDate,
                            existingExecutions: relevantExecutions,
                            modelContext: ctx
                        )
                    }
                    
                    try? ctx.save()
                    
                    await MainActor.run {
                        NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
                    }
                }
            } catch {
                print("Task manager toggle background sync failed: \(error)")
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

    private func optimisticToggleTask(taskID: UUID, occurrenceDate: Date, isDone: Bool) {
        withAnimation {
            if let index = todayTasksSnapshot.firstIndex(where: { $0.task.id == taskID && $0.occurrenceDate == occurrenceDate }) {
                let oldItem = todayTasksSnapshot[index]
                let nowCompleted = !isDone
                let today = TaskExecutionSupport.day(for: .now)
                
                let newSection: TodayTaskDisplaySection
                if nowCompleted {
                    newSection = .todayDone
                } else {
                    newSection = (oldItem.occurrenceDate < today) ? .historicalPending : .todayPending
                }
                
                let newItem = TodayTaskDisplayItem(
                    task: oldItem.task,
                    section: newSection,
                    occurrenceDate: oldItem.occurrenceDate,
                    isCompleted: nowCompleted,
                    pendingOccurrenceCount: oldItem.pendingOccurrenceCount,
                    overdueOriginText: oldItem.overdueOriginText,
                    totalSubtaskCount: oldItem.totalSubtaskCount,
                    completedSubtaskCount: nowCompleted ? oldItem.totalSubtaskCount : 0
                )
                todayTasksSnapshot[index] = newItem
            }
        }
    }

    private func scheduleRow(_ schedule: ScheduleItem) -> some View {
        NavigationLink {
            AddScheduleView(schedule: schedule)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.indigo)
                    .frame(width: 4, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(schedule.title)
                        .fontWeight(.medium)

                    HStack(spacing: 4) {
                        Text(schedule.timeRangeText(on: .now))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.indigo)

                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(schedule.repeatRuleLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                
                            Text(effectiveDateRangeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !schedule.note.isEmpty {
                        Text(schedule.note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .iOS17SafeSwipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(schedule)
                saveAndReloadWidgetsDeferred()
            }

            Button("归档", systemImage: "archivebox") {
                withAnimation {
                    schedule.isArchived = true
                }
                saveAndReloadWidgetsDeferred()
            }
            .tint(.orange)
        }
    }

    private func archivedScheduleRow(_ schedule: ScheduleItem) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.secondary.opacity(0.3))
                .frame(width: 4, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.title)
                    .fontWeight(.medium)
                    .strikethrough()
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(schedule.repeatRule == .once ? schedule.startTime.formatted(.dateTime.year().month().day()) : schedule.repeatRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            
                        Text(effectiveDateRangeLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .iOS17SafeSwipeActions {
            Button("恢复", systemImage: "arrow.uturn.backward") {
                schedule.isArchived = false
                saveAndReloadWidgetsDeferred()
            }
            .tint(.blue)

            Button("彻底删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(schedule)
                saveAndReloadWidgetsDeferred()
            }
        }
    }

    private func deleteTask(_ task: TaskItem) {
        let taskID = task.id
        
        do {
            // 局部精准抓取
            let recordsDesc = FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate<TaskExecutionRecord> { $0.taskID == taskID })
            let relatedExecutionRecords = try modelContext.fetch(recordsDesc)
            let relatedExecutionIDs = Set(relatedExecutionRecords.map(\.id))

            let completionsDesc = FetchDescriptor<TaskCompletion>(predicate: #Predicate<TaskCompletion> { $0.taskID == taskID })
            let relatedCompletions = try modelContext.fetch(completionsDesc)

            let subtaskExDesc = FetchDescriptor<TaskSubitemExecutionRecord>()
            let allSubtaskEx = try modelContext.fetch(subtaskExDesc)
            
            let subtasksDesc = FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { $0.parentTaskID == taskID })
            let relatedSubtasks = try modelContext.fetch(subtasksDesc)

            for completion in relatedCompletions {
                modelContext.delete(completion)
            }
            for subtaskExecution in allSubtaskEx where relatedExecutionIDs.contains(subtaskExecution.taskExecutionID) {
                modelContext.delete(subtaskExecution)
            }
            for execution in relatedExecutionRecords {
                modelContext.delete(execution)
            }
            for subtask in relatedSubtasks {
                modelContext.delete(subtask)
            }
            
            modelContext.delete(task)
            saveAndReloadWidgetsDeferred()
        } catch {
            print("Failed to delete task: \(error)")
        }
    }

    private struct DeferredTaskDetailView: View {
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.modelContext) private var modelContext

        let route: TaskDetailRoute

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
}
