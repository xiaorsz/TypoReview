import SwiftUI
import SwiftData
import WidgetKit

struct TasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var completions: [TaskCompletion]
    @Query(sort: \TaskSubitem.sortOrder) private var allSubtasks: [TaskSubitem]
    @Query(sort: \TaskExecutionRecord.occurrenceDate, order: .reverse) private var executionRecords: [TaskExecutionRecord]
    @Query(sort: \TaskSubitemExecutionRecord.updatedAt, order: .reverse) private var subtaskExecutionRecords: [TaskSubitemExecutionRecord]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]

    private var activeTasks: [TaskItem] {
        allTasks.filter { !$0.isArchived }
    }

    private var activeSchedules: [ScheduleItem] {
        allSchedules.filter { !$0.isArchived }
    }

    private var todayTaskItems: [TodayTaskDisplayItem] {
        TodayTaskListBuilder
            .build(
                from: activeTasks,
                executions: executionRecords,
                subtasks: allSubtasks,
                subtaskExecutions: subtaskExecutionRecords
            )
    }

    private var todayPending: [TodayTaskDisplayItem] {
        todayTaskItems
            .filter { $0.section == .todayPending }
    }

    private var historicalPending: [TodayTaskDisplayItem] {
        todayTaskItems
            .filter { $0.section == .historicalPending }
            .sorted { lhs, rhs in
                if lhs.occurrenceDate == rhs.occurrenceDate {
                    return lhs.task.createdAt < rhs.task.createdAt
                }
                return lhs.occurrenceDate < rhs.occurrenceDate
            }
    }

    private var todayDone: [TodayTaskDisplayItem] {
        todayTaskItems
            .filter { $0.section == .todayDone }
    }

    private var archivedTasks: [TaskItem] {
        allTasks.filter { $0.isArchived }
    }

    private var archivedSchedules: [ScheduleItem] {
        allSchedules.filter { $0.isArchived }
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
                    Section("今日日程") {
                        ForEach(todaySchedules) { schedule in
                            scheduleRow(schedule)
                        }
                    }
                }

                if !todayPending.isEmpty {
                    Section("今日待完成") {
                        ForEach(todayPending) { item in
                            taskRow(item)
                        }
                    }
                }

                if !historicalPending.isEmpty {
                    Section("历史待完成") {
                        ForEach(historicalPending) { item in
                            taskRow(item)
                        }
                    }
                }

                if !todayDone.isEmpty {
                    Section("今日已完成") {
                        ForEach(todayDone) { item in
                            taskRow(item)
                        }
                    }
                }

                // Show tasks that are not appearing today (future or non-scheduled today)
                let otherTasks = activeTasks.filter { task in
                    !todayTaskItems.contains(where: { $0.task.id == task.id })
                }

                if !otherTasks.isEmpty {
                    Section("其它任务") {
                        ForEach(otherTasks) { task in
                            taskRow(task, isDone: false, showActions: false)
                        }
                    }
                }

                if !otherSchedules.isEmpty {
                    Section("其它日程") {
                        ForEach(otherSchedules) { schedule in
                            scheduleRow(schedule)
                        }
                    }
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
    }

    private func taskRow(_ item: TodayTaskDisplayItem, showActions: Bool = true) -> some View {
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

        return HStack(spacing: 14) {
            if showActions {
                if hasSubtasks {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "list.bullet.circle")
                        .font(.title2)
                        .foregroundStyle(isDone ? .green : .secondary)
                } else {
                    Button {
                        toggleCompletion(for: task, occurrenceDate: occurrenceDate ?? .now, isDone: isDone)
                    } label: {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isDone ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                }
            }

            NavigationLink {
                TaskDetailView(task: task)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.title)
                        .font(.headline)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)

                    HStack(spacing: 8) {
                        Label(task.recurrenceLabel, systemImage: task.recurrence.kind == .once ? "1.circle" : "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let effectiveDateRangeLabel = task.effectiveDateRangeLabel {
                            Text(effectiveDateRangeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if task.skipPolicy == .unskippable {
                            Label("不可跳过", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if let occurrenceLabel, !isDone {
                            Text(occurrenceLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }

                        if let totalSubtaskCount, totalSubtaskCount > 0,
                           let completedSubtaskCount {
                            Text("\(completedSubtaskCount)/\(totalSubtaskCount) 子任务")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isDone ? .green : .blue)
                        }
                    }

                    if !task.note.isEmpty {
                        Text(task.note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
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
            HStack(spacing: 14) {
                Image(systemName: "calendar")
                    .font(.title2)
                    .foregroundStyle(.indigo)

                VStack(alignment: .leading, spacing: 6) {
                    Text(schedule.title)
                        .font(.headline)

                    HStack(spacing: 8) {
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
        HStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.title2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(schedule.title)
                    .font(.headline)
                    .strikethrough()
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text(schedule.repeatRule == .once ? schedule.startTime.formatted(.dateTime.year().month().day()) : schedule.repeatRuleLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if let effectiveDateRangeLabel = schedule.effectiveDateRangeLabel {
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
