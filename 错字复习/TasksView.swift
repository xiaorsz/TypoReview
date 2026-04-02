import SwiftUI
import SwiftData
import WidgetKit

struct TasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var completions: [TaskCompletion]
    @Query(sort: \ScheduleItem.startTime) private var allSchedules: [ScheduleItem]

    private var activeTasks: [TaskItem] {
        allTasks.filter { !$0.isArchived }
    }

    private var activeSchedules: [ScheduleItem] {
        allSchedules.filter { !$0.isArchived }
    }

    private var todayTaskItems: [TodayTaskDisplayItem] {
        TodayTaskListBuilder
            .build(from: activeTasks, completions: completions)
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
                                    let taskID = task.id
                                    for c in completions where c.taskID == taskID {
                                        modelContext.delete(c)
                                    }
                                    modelContext.delete(task)
                                    try? modelContext.save()
                                    WidgetCenter.shared.reloadAllTimelines()
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
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("任务管理")
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
            occurrenceLabel: item.overdueOriginText
        )
    }

    private func taskRow(_ task: TaskItem, isDone: Bool, showActions: Bool = true, occurrenceLabel: String? = nil) -> some View {
        HStack(spacing: 14) {
            if showActions {
                Button {
                    toggleCompletion(for: task, isDone: isDone)
                } label: {
                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isDone ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
            }

            NavigationLink {
                AddTaskView(task: task)
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

    private func toggleCompletion(for task: TaskItem, isDone: Bool) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        if isDone {
            // Un-complete: remove today's completion
            if let completion = completions.first(where: {
                $0.taskID == task.id && calendar.isDate($0.completedDate, inSameDayAs: today)
            }) {
                modelContext.delete(completion)
            }
        } else {
            // Complete: add a completion record
            let completion = TaskCompletion(
                taskID: task.id,
                completedDate: today
            )
            modelContext.insert(completion)

            // For once tasks, also archive
            if task.recurrence.kind == .once {
                task.isArchived = true
            }

            // Haptic
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
}
