import SwiftUI
import SwiftData

struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var existingTask: TaskItem?

    @State private var title = ""
    @State private var note = ""
    @State private var recurrenceKind: TaskRecurrence.Kind = .once
    @State private var selectedWeekdays: Set<Int> = []
    @State private var skipPolicy: TaskSkipPolicy = .skippable
    @State private var startDate: Date = .now
    @State private var showSaveToast = false

    init(task: TaskItem? = nil) {
        self.existingTask = task
        if let task {
            _title = State(initialValue: task.title)
            _note = State(initialValue: task.note)
            _recurrenceKind = State(initialValue: task.recurrence.kind)
            _selectedWeekdays = State(initialValue: Set(task.recurrence.weekdays))
            _skipPolicy = State(initialValue: task.skipPolicy)
            _startDate = State(initialValue: task.startDate)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Title & Note
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "pencil.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("任务信息")
                            .font(.headline)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务名称")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("例如：每天朗读课文 20 分钟", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注 (选填)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("补充说明", text: $note)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // Recurrence
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("重复规则")
                            .font(.headline)
                    }

                    Picker("重复", selection: $recurrenceKind) {
                        ForEach(TaskRecurrence.Kind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if recurrenceKind == .weekly {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选择周几")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                ForEach(0..<7, id: \.self) { index in
                                    let displayOrder = (index + 1) % 7 + 1 // Display Mon first
                                    let actualWeekday = displayOrder
                                    let label = weekdayNames[actualWeekday - 1]

                                    Button {
                                        if selectedWeekdays.contains(actualWeekday) {
                                            selectedWeekdays.remove(actualWeekday)
                                        } else {
                                            selectedWeekdays.insert(actualWeekday)
                                        }
                                    } label: {
                                        Text(label)
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                selectedWeekdays.contains(actualWeekday)
                                                    ? Color.accentColor
                                                    : Color(uiColor: .tertiarySystemFill),
                                                in: RoundedRectangle(cornerRadius: 10)
                                            )
                                            .foregroundStyle(selectedWeekdays.contains(actualWeekday) ? .white : .primary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                // Skip Policy & Start Date
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        Text("过期处理")
                            .font(.headline)
                    }

                    Picker("跳过策略", selection: $skipPolicy) {
                        ForEach(TaskSkipPolicy.allCases) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(skipPolicy == .skippable
                         ? "过期未完成就自动作废，不再出现。"
                         : "过期未完成会累积到当天，直到手动完成。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    DatePicker("生效日期", selection: $startDate, displayedComponents: .date)
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            .padding(20)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .toast("已保存 ✓", isPresented: $showSaveToast, duration: 0.8)
        .navigationTitle(existingTask == nil ? "新增任务" : "编辑任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(existingTask == nil ? "保存" : "完成") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
    }

    private func save() {
        let recurrence: TaskRecurrence
        switch recurrenceKind {
        case .once:
            recurrence = .once
        case .daily:
            recurrence = .daily
        case .weekly:
            recurrence = .weekly(Array(selectedWeekdays))
        }

        if let existingTask {
            existingTask.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            existingTask.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            existingTask.recurrence = recurrence
            existingTask.skipPolicy = skipPolicy
            existingTask.startDate = startDate
            existingTask.updatedAt = .now
        } else {
            let task = TaskItem(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                recurrence: recurrence,
                skipPolicy: skipPolicy,
                startDate: startDate
            )
            modelContext.insert(task)
        }

        withAnimation {
            showSaveToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }
}
