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
    @State private var isViewVisible = false
    @State private var isSnapshotRefreshInFlight = false
    @State private var needsSnapshotRefreshAfterCurrent = false
    @State private var activeAddRoute: AddRoute?

    private struct TaskDetailRoute: Hashable {
        let taskID: UUID
        let title: String
    }

    private enum AddRoute: String, Identifiable {
        case task
        case schedule

        var id: String { rawValue }
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active && isViewVisible
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

    private var upcomingPending: [TodayTaskDisplayItem] {
        todayTasksSnapshot
            .filter { $0.section == .upcomingPending }
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

    private var allTasks: [TaskItem] {
        guard canRenderLiveContent else { return [] }
        return activeTasks
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
            .onAppear {
                isViewVisible = true
                #if DEBUG
                DebugPerf.mark("TasksView onAppear")
                #endif
                requestSnapshotRefresh(reason: "onAppear")
            }
            .onChange(of: scenePhase) { _, newPhase in
                #if DEBUG
                DebugPerf.mark("TasksView scenePhase=\(newPhase)")
                #endif
                if newPhase == .active {
                    requestSnapshotRefresh(reason: "scenePhase active", delay: todayTasksSnapshot.isEmpty ? 0.08 : 0.02)
                } else {
                    snapshotRefreshTask?.cancel()
                }
            }
            .onChange(of: activeTasks) { _, _ in
                requestSnapshotRefresh(reason: "activeTasks")
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
                #if DEBUG
                DebugPerf.mark("TasksView received appDataDidMutate")
                #endif
                requestSnapshotRefresh(reason: "appDataDidMutate")
            }
            .navigationDestination(for: TaskDetailRoute.self) { route in
                DeferredTaskDetailView(route: route)
            }
            .navigationDestination(item: $activeAddRoute) { route in
                switch route {
                case .task:
                    AddTaskView()
                case .schedule:
                    AddScheduleView()
                }
            }
            .onDisappear {
                isViewVisible = false
                #if DEBUG
                DebugPerf.mark("TasksView onDisappear")
                #endif
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

        if !upcomingPending.isEmpty {
            todayTaskSection("未来一周", items: upcomingPending)
        }

        if !todayDone.isEmpty {
            todayTaskSection("今日已完成", items: todayDone)
        }

        if !allTasks.isEmpty {
            otherTaskSection("任务管理", tasks: allTasks)
        }

        if !otherSchedules.isEmpty {
            scheduleSection("日程管理", schedules: otherSchedules)
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
                Button {
                    activeAddRoute = .task
                } label: {
                    Image(systemName: "checklist")
                }
                .buttonStyle(.plain)

                Button {
                    activeAddRoute = .schedule
                } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .buttonStyle(.plain)
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
    
    private func requestSnapshotRefresh(reason: String, delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("TasksView requestSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        guard canRenderLiveContent else { return }
        if isSnapshotRefreshInFlight {
            needsSnapshotRefreshAfterCurrent = true
            #if DEBUG
            DebugPerf.mark("TasksView refresh queued reason=\(reason)")
            #endif
            return
        }
        scheduleSnapshotRefresh(delay: delay)
    }

    private func scheduleSnapshotRefresh(delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("TasksView scheduleSnapshotRefresh delay=\(delay)")
        #endif
        snapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let container = modelContext.container

        snapshotRefreshTask = Task(priority: .utility) {
            let referenceDate = Date()
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            await MainActor.run {
                isSnapshotRefreshInFlight = true
            }
            
            let projectedItems = try? await Task.detached(priority: .utility) {
                #if DEBUG
                DebugPerf.mark("TasksView background snapshot begin")
                #endif
                let backgroundContext = ModelContext(container)
                let calendar = Calendar.current
                
                // 完全在后台线程里进行取数据和投影，绝对不阻塞主线程
                let tasksDesc = FetchDescriptor<TaskItem>()
                let executesDesc = FetchDescriptor<TaskExecutionRecord>()
                let subtasksDesc = FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
                
                let allTasks = (try? backgroundContext.fetch(tasksDesc)) ?? []
                let safeExecutions = (try? backgroundContext.fetch(executesDesc)) ?? []
                let safeSubtasks = (try? backgroundContext.fetch(subtasksDesc)) ?? []

                let completedTodayTaskIDs = Set(
                    safeExecutions
                        .filter { $0.status == .completed && calendar.isDate($0.occurrenceDate, inSameDayAs: referenceDate) }
                        .map(\.taskID)
                )
                let visibleTasks = allTasks.filter {
                    !$0.isArchived || completedTodayTaskIDs.contains($0.id)
                }

                let taskProjections = visibleTasks.map(TaskProjection.init)
                let executionProjections = safeExecutions.map(TaskExecutionRecordProjection.init)
                let subtaskProjections = safeSubtasks.map(TaskSubitemProjection.init)

                let result = TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: executionProjections,
                    subtasks: subtaskProjections,
                    on: referenceDate
                )
                #if DEBUG
                DebugPerf.mark("TasksView background snapshot end tasks=\(visibleTasks.count) records=\(safeExecutions.count) subtasks=\(safeSubtasks.count)")
                #endif
                return result
            }.value

            guard !Task.isCancelled else { return }
            guard let validProjectedItems = projectedItems else { return }
            guard canRenderLiveContent else { return }
            let tasksByID = Dictionary(
                (activeTasks + archivedTasks).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            todayTasksSnapshot = TodayTaskProjectionBuilder.displayItems(
                from: validProjectedItems,
                tasksByID: tasksByID
            )
            #if DEBUG
            DebugPerf.mark("TasksView snapshot applied items=\(todayTasksSnapshot.count)")
            #endif
            isSnapshotRefreshInFlight = false
            if needsSnapshotRefreshAfterCurrent {
                needsSnapshotRefreshAfterCurrent = false
                requestSnapshotRefresh(reason: "coalesced", delay: 0.02)
            }
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
        
        // 1. 立即乐观更新 UI
        optimisticToggleTask(taskID: tid, occurrenceDate: occurrenceDate, isDone: isDone)
        
        // 2. 主线程同步更新数据库，避免后台 Context 跨线程读写导致瞬时回闪（Flash back）
        do {
            let descriptor = FetchDescriptor<TaskExecutionRecord>(
                predicate: #Predicate<TaskExecutionRecord> { $0.taskID == tid }
            )
            let relevantExecutions = (try? modelContext.fetch(descriptor)) ?? []
            
            if isDone {
                TaskExecutionSupport.reopenTaskCompletion(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    existingExecutions: relevantExecutions,
                    modelContext: modelContext
                )
            } else {
                TaskExecutionSupport.markTaskCompleted(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    existingExecutions: relevantExecutions,
                    modelContext: modelContext
                )
            }
            
            try? modelContext.save()
            saveAndReloadWidgetsDeferred()
            NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
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
                    if oldItem.occurrenceDate < today {
                        newSection = .historicalPending
                    } else if Calendar.current.isDate(oldItem.occurrenceDate, inSameDayAs: today) {
                        newSection = .todayPending
                    } else {
                        newSection = .upcomingPending
                    }
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

        let route: TaskDetailRoute

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
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView onAppear title=\(route.title)")
                #endif
                loadTaskAfterNavigationSettles()
            }
            .onChange(of: scenePhase) { _, newPhase in
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView scenePhase=\(newPhase) title=\(route.title)")
                #endif
                if newPhase == .active {
                    loadTaskAfterNavigationSettles()
                } else {
                    loadTask?.cancel()
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView onDisappear title=\(route.title)")
                #endif
                loadTask?.cancel()
            }
        }

        private func loadTaskAfterNavigationSettles() {
            #if DEBUG
            DebugPerf.mark("DeferredTaskDetailView load requested title=\(route.title)")
            #endif
            loadTask?.cancel()
            guard !isReady else { return }
            guard canLoad else { return }

            loadTask = Task { @MainActor in
                #if DEBUG
                DebugPerf.mark("DeferredTaskDetailView load task started title=\(route.title)")
                #endif
                await Task.yield()
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled else { return }
                guard canLoad else { return }
                isReady = true
            }
        }
    }
}
