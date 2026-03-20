import SwiftUI
import SwiftData

struct TasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var allTasks: [TaskItem]
    @Query(sort: \TaskCompletion.completedAt, order: .reverse) private var completions: [TaskCompletion]

    private var activeTasks: [TaskItem] {
        allTasks.filter { !$0.isArchived }
    }

    private var todayPending: [TaskItem] {
        activeTasks.filter { $0.shouldAppear(on: .now, completions: completions) }
    }

    private var todayDone: [TaskItem] {
        let calendar = Calendar.current
        let todayCompletionIDs = Set(
            completions
                .filter { calendar.isDateInToday($0.completedDate) }
                .map(\.taskID)
        )
        return activeTasks.filter { todayCompletionIDs.contains($0.id) }
    }

    private var archivedTasks: [TaskItem] {
        allTasks.filter { $0.isArchived }
    }

    var body: some View {
        List {
            if activeTasks.isEmpty && archivedTasks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有任务", systemImage: "checklist")
                    } description: {
                        Text("点右上角添加每日任务、作业提醒等待办事项。")
                    }
                }
            } else {
                if !todayPending.isEmpty {
                    Section("今日待完成") {
                        ForEach(todayPending) { task in
                            taskRow(task, isDone: false)
                        }
                    }
                }

                if !todayDone.isEmpty {
                    Section("今日已完成") {
                        ForEach(todayDone) { task in
                            taskRow(task, isDone: true)
                        }
                    }
                }

                // Show tasks that are not appearing today (future or non-scheduled today)
                let otherTasks = activeTasks.filter { task in
                    !todayPending.contains(where: { $0.id == task.id }) &&
                    !todayDone.contains(where: { $0.id == task.id })
                }

                if !otherTasks.isEmpty {
                    Section("其它任务") {
                        ForEach(otherTasks) { task in
                            taskRow(task, isDone: false, showActions: false)
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
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("任务管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddTaskView()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    private func taskRow(_ task: TaskItem, isDone: Bool, showActions: Bool = true) -> some View {
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

                        if task.skipPolicy == .unskippable {
                            Label("不可跳过", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
        .swipeActions(edge: .trailing) {
            Button("归档", systemImage: "archivebox", role: .destructive) {
                withAnimation {
                    task.isArchived = true
                }
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
    }
}
