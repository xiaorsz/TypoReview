import SwiftUI
import SwiftData
import WidgetKit

struct TasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<TaskItem> { !$0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var activeTasks: [TaskItem]
    @Query(filter: #Predicate<TaskItem> { $0.isArchived }, sort: \TaskItem.createdAt, order: .reverse) private var archivedTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var completions: [TaskCompletion]
    @Query(filter: #Predicate<TaskSubitem> { !$0.isArchived }, sort: \TaskSubitem.sortOrder) private var allSubtasks: [TaskSubitem]
    @Query(sort: \TaskExecutionRecord.occurrenceDate, order: .reverse) private var executionRecords: [TaskExecutionRecord]
    @Query(sort: \TaskSubitemExecutionRecord.updatedAt, order: .reverse) private var subtaskExecutionRecords: [TaskSubitemExecutionRecord]
    @Query(filter: #Predicate<ScheduleItem> { !$0.isArchived }, sort: \ScheduleItem.startTime) private var activeSchedules: [ScheduleItem]
    @Query(filter: #Predicate<ScheduleItem> { $0.isArchived }, sort: \ScheduleItem.startTime) private var archivedSchedules: [ScheduleItem]
    
    // Performance Optimization: Cache computed results in a local snapshot
    @State private var todayTasksSnapshot: [TodayTaskDisplayItem] = []
    @State private var snapshotRefreshTask: Task<Void, Never>?

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
        activeTasks.filter { !todayTaskIds.contains($0.id) }
    }

    private var todaySchedules: [ScheduleItem] {
        activeSchedules
            .filter { $0.shouldAppear(on: .now) }
            .sorted { $0.startTimeMinutes < $1.startTimeMinutes }
    }

    private var otherSchedules: [ScheduleItem] {
        activeSchedules
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
        List {
            if activeTasks.isEmpty && archivedTasks.isEmpty && activeSchedules.isEmpty && archivedSchedules.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有任务和日程", systemImage: "checklist")
                    } description: {
                        Text("点右上角添加每日任务、作业提醒和日程安排。")
                    }
                }
            } else {
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

                if !archivedTasks.isEmpty {
                    Section("已归档") {
                        ForEach(archivedTasks) { task in
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
                            .swipeActions {
                                Button("恢复", systemImage: "arrow.uturn.backward") {
                                    task.isArchived = false
                                }
                                .tint(.blue)

                                Button("彻底删除", systemImage: "trash", role: .destructive) {
                                    // Delete all completions for this task too
                                    deleteTask(task)
                                }
                            }
                        }
                    }
                }

                if !archivedSchedules.isEmpty {
                    Section("已归档日程") {
                        ForEach(archivedSchedules) { schedule in
                            archivedScheduleRow(schedule)
                        }
                    }
                }
            }
        }
        .navigationTitle("任务管理")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
            }
        }
        .task {
            scheduleSnapshotRefresh()
        }
        .onChange(of: activeTasks) { _, _ in scheduleSnapshotRefresh() }
        .onChange(of: executionRecords) { _, _ in scheduleSnapshotRefresh() }
        .onChange(of: allSubtasks) { _, _ in scheduleSnapshotRefresh() }
        .onChange(of: subtaskExecutionRecords) { _, _ in scheduleSnapshotRefresh() }
        .onDisappear {
            snapshotRefreshTask?.cancel()
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
        let taskModels = activeTasks
        let taskProjections = taskModels.map(TaskProjection.init)
        let executionProjections = executionRecords.map(TaskExecutionRecordProjection.init)
        let subtaskProjections = allSubtasks.map(TaskSubitemProjection.init)

        snapshotRefreshTask = Task(priority: .utility) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            let projectedItems = await Task.detached(priority: .utility) {
                TodayTaskProjectionBuilder.build(
                    from: taskProjections,
                    executions: executionProjections,
                    subtasks: subtaskProjections
                )
            }.value

            guard !Task.isCancelled else { return }
            let tasksByID = Dictionary(
                taskModels.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            todayTasksSnapshot = TodayTaskProjectionBuilder.displayItems(
                from: projectedItems,
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

            NavigationLink {
                TaskDetailView(task: task)
            } label: {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("归档", systemImage: "archivebox", role: .destructive) {
                withAnimation {
                    task.isArchived = true
                }
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func toggleCompletion(for task: TaskItem, occurrenceDate: Date, isDone: Bool) {
        if isDone {
            TaskExecutionSupport.reopenTaskCompletion(
                task: task,
                occurrenceDate: occurrenceDate,
                existingExecutions: executionRecords,
                modelContext: modelContext
            )
        } else {
            TaskExecutionSupport.markTaskCompleted(
                task: task,
                occurrenceDate: occurrenceDate,
                existingExecutions: executionRecords,
                modelContext: modelContext
            )

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(schedule)
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            }

            Button("归档", systemImage: "archivebox") {
                withAnimation {
                    schedule.isArchived = true
                }
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
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
        .swipeActions {
            Button("恢复", systemImage: "arrow.uturn.backward") {
                schedule.isArchived = false
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .tint(.blue)

            Button("彻底删除", systemImage: "trash", role: .destructive) {
                modelContext.delete(schedule)
                try? modelContext.save()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    private func deleteTask(_ task: TaskItem) {
        let taskID = task.id
        let relatedExecutionRecords = executionRecords.filter { $0.taskID == taskID }
        let relatedExecutionIDs = Set(relatedExecutionRecords.map(\.id))

        for completion in completions where completion.taskID == taskID {
            modelContext.delete(completion)
        }
        for subtaskExecution in subtaskExecutionRecords where relatedExecutionIDs.contains(subtaskExecution.taskExecutionID) {
            modelContext.delete(subtaskExecution)
        }
        for execution in relatedExecutionRecords {
            modelContext.delete(execution)
        }
        for subtask in allSubtasks where subtask.parentTaskID == taskID {
            modelContext.delete(subtask)
        }
        modelContext.delete(task)
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
