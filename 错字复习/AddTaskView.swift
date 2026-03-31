import SwiftUI
import SwiftData
import WidgetKit

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
    @State private var endDate: Date = .now
    @State private var hasEndDate = false
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
            _endDate = State(initialValue: task.endDate ?? task.startDate)
            _hasEndDate = State(initialValue: task.endDate != nil)
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let weekdayNames = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                introCard
                infoCard
                recurrenceCard
                policyCard
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

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(existingTask == nil ? "新增任务" : "编辑任务")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            Text("任务可以设置为单次或按周期重复。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.85), .indigo.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("任务名称", systemImage: "star.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                
                TextField("例如：每天朗读课文 20 分钟", text: $title)
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Label("备注 (可选)", systemImage: "tag.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.purple)
                
                TextField("补充说明", text: $note)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var recurrenceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("重复规则")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("重复", selection: $recurrenceKind) {
                    ForEach(TaskRecurrence.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            if recurrenceKind == .weekly {
                Divider()
                
                VStack(alignment: .leading, spacing: 12) {
                    Label("选择周几执行", systemImage: "calendar.badge.clock")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)

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
                                            : Color(uiColor: .secondarySystemBackground),
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
    }

    private var policyCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("过期处理")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("跳过策略", selection: $skipPolicy) {
                    ForEach(TaskSkipPolicy.allCases) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            
            Text(skipPolicy == .skippable
                 ? "提示：过期未完成就自动作废，不再出现。"
                 : "提示：过期未完成会累积到当天，直到手动完成。")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if recurrenceKind == .once {
                    DatePicker("生效日期", selection: $startDate, displayedComponents: .date)
                        .font(.subheadline.weight(.medium))
                } else {
                    Label("生效范围", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.blue)

                    DatePicker("开始日期", selection: $startDate, displayedComponents: .date)
                        .font(.subheadline.weight(.medium))

                    Toggle("设置结束日期", isOn: $hasEndDate.animation())
                        .font(.subheadline.weight(.medium))

                    if hasEndDate {
                        DatePicker("结束日期", selection: $endDate, in: startDate..., displayedComponents: .date)
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .onChange(of: startDate) { _, newStartDate in
            if endDate < newStartDate {
                endDate = newStartDate
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
            existingTask.endDate = recurrenceKind == .once ? nil : (hasEndDate ? endDate : nil)
            existingTask.updatedAt = .now
        } else {
            let task = TaskItem(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                recurrence: recurrence,
                skipPolicy: skipPolicy,
                startDate: startDate,
                endDate: recurrenceKind == .once ? nil : (hasEndDate ? endDate : nil)
            )
            modelContext.insert(task)
        }

        withAnimation {
            showSaveToast = true
        }
        try? modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }
}
