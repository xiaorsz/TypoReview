import SwiftUI
import SwiftData
import WidgetKit

struct TaskDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let task: TaskItem

    @Query(sort: \TaskSubitem.sortOrder) private var allSubtasks: [TaskSubitem]
    @Query(sort: \TaskExecutionRecord.occurrenceDate, order: .reverse) private var allExecutionRecords: [TaskExecutionRecord]
    @Query(sort: \TaskSubitemExecutionRecord.updatedAt, order: .reverse) private var legacySubtaskExecutionRecords: [TaskSubitemExecutionRecord]

    @State private var selectedOccurrenceDate: Date?
    @State private var preferredExecutionRecordID: UUID?
    @State private var parentDetailDraft = ""
    @State private var isEditingParentDetail = false
    @State private var persistenceErrorMessage: String?
    @State private var subtaskEditorTarget: SubtaskEditorTarget?
    @State private var isCreatingSubtask = false
    @State private var quickSubtaskOccurrenceDate: Date?
    @State private var quickSubtaskTitleDraft = ""
    @State private var subtaskTitleDraft = ""
    @State private var subtaskNoteDraft = ""
    @State private var subtaskDetailDraft = ""
    @State private var subtaskCompletedDraft = false
    @FocusState private var quickSubtaskFieldFocused: Bool

    private struct SubtaskEditorTarget: Identifiable {
        let id = UUID()
        let subtaskID: UUID?
    }

    private var executionRecords: [TaskExecutionRecord] {
        allExecutionRecords.filter { $0.taskID == task.id }
    }

    private var occurrenceSnapshots: [TaskOccurrenceSnapshot] {
        TaskExecutionSupport.occurrenceSnapshots(
            for: task,
            executions: executionRecords,
            subtasks: allSubtasks,
            subtaskExecutions: legacySubtaskExecutionRecords
        )
    }

    private var pendingOccurrences: [TaskOccurrenceSnapshot] {
        occurrenceSnapshots
            .filter { !$0.isCompleted }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
    }

    private var completedOccurrences: [TaskOccurrenceSnapshot] {
        occurrenceSnapshots
            .filter(\.isCompleted)
            .sorted { $0.occurrenceDate > $1.occurrenceDate }
    }

    private var upcomingOccurrences: [TaskOccurrenceSnapshot] {
        let calendar = Calendar.current
        let today = TaskExecutionSupport.day(for: .now)
        guard let endDate = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }

        return task.scheduledOccurrenceDates(upTo: endDate)
            .filter { $0 > today }
            .compactMap { occurrenceDate in
                let record = TaskExecutionSupport.executionRecord(
                    for: task.id,
                    on: occurrenceDate,
                    in: executionRecords
                )
                let occurrenceSubtasks = TaskExecutionSupport.executionSubtasks(
                    for: record,
                    in: allSubtasks
                )
                let completed = TaskExecutionSupport.isOccurrenceCompleted(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    executions: executionRecords,
                    subtasks: allSubtasks
                )
                guard !completed else { return nil }

                return TaskOccurrenceSnapshot(
                    task: task,
                    occurrenceDate: occurrenceDate,
                    isCompleted: false,
                    overdueOriginText: nil,
                    executionRecord: record,
                    totalSubtaskCount: occurrenceSubtasks.count,
                    completedSubtaskCount: occurrenceSubtasks.filter { $0.status == .completed }.count
                )
            }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
    }

    private var selectionSnapshots: [TaskOccurrenceSnapshot] {
        pendingOccurrences + upcomingOccurrences + completedOccurrences
    }

    private var selectedSnapshot: TaskOccurrenceSnapshot? {
        if let selectedOccurrenceDate {
            return selectionSnapshots.first {
                Calendar.current.isDate($0.occurrenceDate, inSameDayAs: selectedOccurrenceDate)
            }
        }
        return pendingOccurrences.first ?? upcomingOccurrences.first ?? completedOccurrences.first
    }

    private var timelineSnapshots: [TaskOccurrenceSnapshot] {
        let all = (pendingOccurrences + upcomingOccurrences).sorted { $0.occurrenceDate < $1.occurrenceDate }
        // Ensure the current selected date is in the timeline if it's completed
        if let selectedDate = selectedOccurrenceDate,
           !all.contains(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: selectedDate) }),
           let selected = completedOccurrences.first(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: selectedDate) }) {
            return (all + [selected]).sorted { $0.occurrenceDate < $1.occurrenceDate }
        }
        return all
    }

    private var currentOccurrenceDate: Date? {
        selectedSnapshot?.occurrenceDate
    }

    private var currentExecutionRecord: TaskExecutionRecord? {
        guard let currentOccurrenceDate else { return nil }
        return bestExecutionRecord(for: currentOccurrenceDate)
    }

    private var currentOccurrenceSubtasks: [TaskSubitem] {
        if let executionID = currentExecutionRecord?.id {
            return occurrenceSubtasks(forExecutionID: executionID)
        }
        return []
    }

    private var subtaskProgressText: String? {
        guard !currentOccurrenceSubtasks.isEmpty else { return nil }
        let completed = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        return "\(completed)/\(currentOccurrenceSubtasks.count) 子任务已完成"
    }

    private var occurrenceSelectionIDs: [String] {
        selectionSnapshots.map(\.id)
    }

    private var isCurrentOccurrenceFuture: Bool {
        guard let currentOccurrenceDate else { return false }
        return currentOccurrenceDate > TaskExecutionSupport.day(for: .now)
    }

    var body: some View {
        List {
            summarySection

            if !timelineSnapshots.isEmpty {
                occurrenceTimelinePicker
            }

            if let selectedSnapshot {
                currentOccurrenceSection(selectedSnapshot)
                subtasksSection
            } else {
                emptyStateSection
            }

            if !pendingOccurrences.isEmpty {
                occurrenceSwitcherSection(title: "待处理记录", snapshots: pendingOccurrences)
            }

            if !completedOccurrences.isEmpty {
                occurrenceSwitcherSection(title: "已完成历史", snapshots: completedOccurrences)
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AddTaskView(task: task)
                } label: {
                    Text("编辑任务")
                }
            }
        }
        .onAppear {
            syncSelectedOccurrence()
            refreshParentDetailDraft()
        }
        .onChange(of: occurrenceSelectionIDs) { _, _ in
            syncSelectedOccurrence()
            refreshParentDetailDraft()
        }
        .onChange(of: selectedOccurrenceDate) { _, _ in
            refreshParentDetailDraft()
        }
        .onDisappear {
            saveParentDetail()
        }
        .alert("保存失败", isPresented: Binding(
            get: { persistenceErrorMessage != nil },
            set: { shouldShow in
                if !shouldShow {
                    persistenceErrorMessage = nil
                }
            }
        )) {
            Button("知道了") {
                persistenceErrorMessage = nil
            }
        } message: {
            Text(persistenceErrorMessage ?? "发生未知错误")
        }
        .sheet(isPresented: $isEditingParentDetail) {
            NavigationStack {
                Form {
                    Section("本次说明") {
                        TextEditor(text: $parentDetailDraft)
                            .frame(minHeight: 180)

                        Text("这里记录这一次执行的情况；长期固定补充仍然放在任务备注里。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("编辑本次说明")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") {
                            isEditingParentDetail = false
                            refreshParentDetailDraft()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            saveParentDetail()
                            isEditingParentDetail = false
                        }
                    }
                }
            }
        }
        .sheet(item: $subtaskEditorTarget) { target in
            NavigationStack {
                Form {
                    Section("子任务名称") {
                        TextField("例如：检查作业、签字、整理书包", text: $subtaskTitleDraft)
                    }

                    Section("子任务备注") {
                        TextField("相对固定的补充说明（可选）", text: $subtaskNoteDraft, axis: .vertical)
                    }

                    Section("这次说明") {
                        TextEditor(text: $subtaskDetailDraft)
                            .frame(minHeight: 150)
                    }

                    if !isCurrentOccurrenceFuture {
                        Section("完成状态") {
                            Toggle("标记为已完成", isOn: $subtaskCompletedDraft)
                        }
                    } else {
                        Section {
                            Text("未来日期可以先写子任务和备注，但不能提前完成。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle(target.subtaskID == nil ? "添加子任务" : "编辑子任务")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") {
                            subtaskEditorTarget = nil
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            saveSubtaskEditor(target)
                        }
                    }
                }
            }
        }
    }

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.headline)

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
                }

                if !task.note.isEmpty {
                    Text(task.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("任务备注适合放长期说明；本次说明请在当前处理里单独记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func currentOccurrenceSection(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        Section("当前处理") {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)

                    Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (snapshot.isCompleted ? Color.green.opacity(0.14) : (isFutureOccurrence(snapshot) ? Color.blue.opacity(0.12) : Color.orange.opacity(0.14))),
                            in: Capsule()
                        )

                    if occurrenceHasDetail(snapshot.occurrenceDate) {
                        noteBadge("有说明")
                    }

                    if currentOccurrenceSubtasks.contains(where: {
                        !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) {
                        noteBadge("子任务有备注")
                    }

                    Spacer(minLength: 8)

                    Button {
                        isEditingParentDetail = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: occurrenceHasDetail(snapshot.occurrenceDate) ? "square.and.pencil" : "plus.bubble")
                            Text(occurrenceHasDetail(snapshot.occurrenceDate) ? "编辑说明" : "添加说明")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if !currentOccurrenceSubtasks.isEmpty {
                    Text("共 \(currentOccurrenceSubtasks.count) 个本次子任务")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }

                if let subtaskProgressText {
                    Text(subtaskProgressText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }

                if isCurrentOccurrenceFuture {
                    Text("可以先为这一天准备子任务和备注，完成要等到当天。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(currentOccurrenceCardBackground(for: snapshot))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(currentOccurrenceCardBorder(for: snapshot), lineWidth: 1)
            )
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    private var subtasksSection: some View {
        Section("本次子任务") {
            if !isCreatingSubtask {
                Button {
                    startQuickSubtaskCreation()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("添加本次子任务")
                                .foregroundStyle(.primary)
                            Text("这条子任务只属于 \((quickSubtaskOccurrenceDate ?? currentOccurrenceDate)?.formatted(.dateTime.month().day()) ?? "当前日期")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isCreatingSubtask {
                quickCreateSubtaskRow
            }

            if currentOccurrenceSubtasks.isEmpty {
                Text("这一天还没有子任务。你可以先添加需要执行的步骤，再逐条完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(currentOccurrenceSubtasks) { subtask in
                    subtaskRow(subtask)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                deleteSubtask(subtask)
                            }
                        }
                }
            }
        }
    }

    private var quickCreateSubtaskRow: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 28, height: 28)

                TextField("输入子任务标题，输完点下方按钮", text: $quickSubtaskTitleDraft)
                    .textInputAutocapitalization(.sentences)
                    .focused($quickSubtaskFieldFocused)
                    .submitLabel(.done)
            }

            HStack(spacing: 16) {
                Spacer()

                Button("取消") {
                    cancelQuickSubtaskCreation()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button {
                    commitIMEAndSave()
                } label: {
                    Text("添加子任务")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(quickSubtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    /// Force-commit any Chinese IME composition text, then save.
    private func commitIMEAndSave() {
        // Force iOS to commit any in-progress IME composition by ending editing
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )

        // Wait for the binding to update after IME commits
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            saveQuickSubtask()
        }
    }

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView(
                "还没有执行记录",
                systemImage: "checklist",
                description: Text("任务开始后，这里会显示每次执行情况和本次子任务。")
            )
        }
    }

    private var occurrenceTimelinePicker: some View {
        Section {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(timelineSnapshots) { snapshot in
                            timelineDateCell(snapshot)
                                .id(snapshot.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let selectedSnapshot {
                        proxy.scrollTo(selectedSnapshot.id, anchor: .center)
                    }
                }
                .onChange(of: selectedSnapshot?.id) { _, newID in
                    if let newID {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private func timelineDateCell(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        let isSelected = isSelected(snapshot)

        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedOccurrenceDate = snapshot.occurrenceDate
            }
        } label: {
            VStack(spacing: 6) {
                Text(snapshot.occurrenceDate.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)

                VStack(spacing: 2) {
                    Text(snapshot.occurrenceDate.formatted(.dateTime.day()))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(snapshot.occurrenceDate.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(isSelected ? .white : .primary)

                // Dot indicator
                Circle()
                    .fill(timelineDotColor(for: snapshot))
                    .frame(width: 5, height: 5)
            }
            .padding(.vertical, 8)
            .frame(width: 54, height: 85)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func timelineDotColor(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if snapshot.isCompleted { return .green }
        if snapshot.occurrenceDate < TaskExecutionSupport.day(for: .now) { return .orange }
        if snapshot.occurrenceDate > TaskExecutionSupport.day(for: .now) { return .blue }
        return .orange // Today pending
    }

    private func occurrenceSwitcherSection(
        title: String,
        snapshots: [TaskOccurrenceSnapshot]
    ) -> some View {
        Section(title) {
            ForEach(snapshots) { snapshot in
                HStack(spacing: 12) {
                    occurrenceLeadingButton(snapshot)

                    Button {
                        selectedOccurrenceDate = snapshot.occurrenceDate
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                occurrenceRow(snapshot)
                            }

                            Spacer()

                            if isSelected(snapshot) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(occurrenceListCardBackground(for: snapshot))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(occurrenceListCardBorder(for: snapshot), lineWidth: isSelected(snapshot) ? 1.5 : 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func occurrenceLeadingButton(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        let canToggle = !snapshot.hasSubtasks && !isFutureOccurrence(snapshot)

        return Button {
            guard canToggle else {
                selectedOccurrenceDate = snapshot.occurrenceDate
                return
            }
            selectedOccurrenceDate = snapshot.occurrenceDate
            toggleOccurrenceCompletion(snapshot)
        } label: {
            Image(systemName: leadingSymbol(for: snapshot))
                .font(.title3)
                .foregroundStyle(leadingColor(for: snapshot))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }

    private func leadingSymbol(for snapshot: TaskOccurrenceSnapshot) -> String {
        if isFutureOccurrence(snapshot) && !snapshot.isCompleted {
            return "clock"
        }
        if snapshot.hasSubtasks {
            return snapshot.isCompleted ? "checkmark.circle.fill" : "list.bullet.circle"
        }
        return snapshot.isCompleted ? "checkmark.circle.fill" : "circle"
    }

    private func leadingColor(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isFutureOccurrence(snapshot) && !snapshot.isCompleted {
            return .blue
        }
        if snapshot.isCompleted {
            return .green
        }
        return .secondary
    }

    private func occurrenceRow(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (snapshot.isCompleted ? Color.green.opacity(0.14) : (isFutureOccurrence(snapshot) ? Color.blue.opacity(0.12) : Color.orange.opacity(0.14))),
                        in: Capsule()
                    )

                if occurrenceHasDetail(snapshot.occurrenceDate) {
                    noteBadge("有说明")
                }
            }

            if let subtaskProgressText = snapshot.subtaskProgressText {
                Text(subtaskProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let detail = snapshot.executionRecord?.detail,
               !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func noteBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: Capsule())
    }

    private func occurrenceHasDetail(_ occurrenceDate: Date) -> Bool {
        let trimmedParentDetail = TaskExecutionSupport
            .executionRecord(for: task.id, on: occurrenceDate, in: executionRecords)?
            .detail
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedParentDetail.isEmpty {
            return true
        }

        let record = TaskExecutionSupport.executionRecord(
            for: task.id,
            on: occurrenceDate,
            in: executionRecords
        )
        return TaskExecutionSupport.executionSubtasks(for: record, in: allSubtasks).contains {
            !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func subtaskRow(_ subtask: TaskSubitem) -> some View {
        let isDone = subtask.status == .completed

        return HStack(alignment: .top, spacing: 12) {
            Button {
                toggleSubtaskCompletion(subtask)
            } label: {
                Image(systemName: leadingSymbol(for: subtask, isDone: isDone))
                    .font(.title3)
                    .foregroundStyle(leadingColor(for: subtask, isDone: isDone))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentOccurrenceFuture)

            Button {
                openEditSubtaskEditor(subtask)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtask.title)
                        .foregroundStyle(.primary)

                    if !subtask.note.isEmpty {
                        Text(subtask.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if !subtask.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtask.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button {
                    moveSubtaskUp(subtask)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(isFirstSubtask(subtask))

                Button {
                    moveSubtaskDown(subtask)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.plain)
                .disabled(isLastSubtask(subtask))

                Image(systemName: "square.and.pencil")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .padding(.vertical, 2)
    }

    private func leadingSymbol(for subtask: TaskSubitem, isDone: Bool) -> String {
        if isCurrentOccurrenceFuture {
            return "clock"
        }
        return isDone ? "checkmark.circle.fill" : "circle"
    }

    private func leadingColor(for subtask: TaskSubitem, isDone: Bool) -> Color {
        if isCurrentOccurrenceFuture {
            return .blue
        }
        return isDone ? .green : .secondary
    }

    private func isSelected(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        guard let selectedOccurrenceDate else { return false }
        return Calendar.current.isDate(snapshot.occurrenceDate, inSameDayAs: selectedOccurrenceDate)
    }

    private func currentOccurrenceCardBackground(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if snapshot.isCompleted {
            return Color.green.opacity(0.10)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.08)
        }
        return Color.orange.opacity(0.10)
    }

    private func currentOccurrenceCardBorder(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if snapshot.isCompleted {
            return Color.green.opacity(0.25)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.25)
        }
        return Color.orange.opacity(0.28)
    }

    private func occurrenceListCardBackground(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isSelected(snapshot) {
            return Color.blue.opacity(0.08)
        }
        if snapshot.isCompleted {
            return Color.green.opacity(0.05)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.04)
        }
        return Color(.secondarySystemGroupedBackground)
    }

    private func occurrenceListCardBorder(for snapshot: TaskOccurrenceSnapshot) -> Color {
        if isSelected(snapshot) {
            return Color.blue.opacity(0.45)
        }
        if snapshot.isCompleted {
            return Color.green.opacity(0.12)
        }
        if isFutureOccurrence(snapshot) {
            return Color.blue.opacity(0.12)
        }
        return Color.black.opacity(0.05)
    }

    private func isFutureOccurrence(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        snapshot.occurrenceDate > TaskExecutionSupport.day(for: .now)
    }

    private func syncSelectedOccurrence() {
        if let selectedOccurrenceDate,
           selectionSnapshots.contains(where: {
               Calendar.current.isDate($0.occurrenceDate, inSameDayAs: selectedOccurrenceDate)
           }) {
            if let resolvedExecutionID = bestExecutionRecord(for: selectedOccurrenceDate)?.id {
                preferredExecutionRecordID = resolvedExecutionID
            }
            return
        }

        selectedOccurrenceDate = pendingOccurrences.first?.occurrenceDate
            ?? upcomingOccurrences.first?.occurrenceDate
            ?? completedOccurrences.first?.occurrenceDate
        if let selectedOccurrenceDate,
           let resolvedExecutionID = bestExecutionRecord(for: selectedOccurrenceDate)?.id {
            preferredExecutionRecordID = resolvedExecutionID
        } else {
            preferredExecutionRecordID = nil
        }
    }

    private func refreshParentDetailDraft() {
        parentDetailDraft = currentExecutionRecord?.detail ?? ""
    }

    private func executionRecord(withID id: UUID) -> TaskExecutionRecord? {
        if let record = executionRecords.first(where: { $0.id == id }) {
            return record
        }

        let descriptor = FetchDescriptor<TaskExecutionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func storedExecutionRecords() -> [TaskExecutionRecord] {
        let taskID = task.id
        let descriptor = FetchDescriptor<TaskExecutionRecord>(
            predicate: #Predicate { record in
                record.taskID == taskID
            },
            sortBy: [
                SortDescriptor(\TaskExecutionRecord.updatedAt, order: .reverse),
                SortDescriptor(\TaskExecutionRecord.createdAt, order: .reverse)
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func bestExecutionRecord(for occurrenceDate: Date) -> TaskExecutionRecord? {
        let sameDay = TaskExecutionSupport.day(for: occurrenceDate)

        // Use @Query results only (avoid redundant SwiftData fetch)
        let candidates = executionRecords.filter {
            Calendar.current.isDate($0.occurrenceDate, inSameDayAs: sameDay)
        }

        // If there's a preferred record for this day, use it directly
        if let preferredID = preferredExecutionRecordID,
           let preferred = candidates.first(where: { $0.id == preferredID }) {
            return preferred
        }

        // Otherwise pick the best one by content richness
        return candidates.max { lhs, rhs in
            ranking(for: lhs) < ranking(for: rhs)
        }
    }

    private func ranking(for record: TaskExecutionRecord) -> (Int, Date, Date) {
        let hasDetail = record.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1
        return (hasDetail, record.updatedAt, record.createdAt)
    }

    private func ensureCurrentExecutionRecord(for occurrenceDate: Date) -> TaskExecutionRecord {
        if let existing = bestExecutionRecord(for: occurrenceDate) {
            preferredExecutionRecordID = existing.id
            return existing
        }

        let record = TaskExecutionSupport.ensureExecutionRecord(
            for: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: storedExecutionRecords(),
            modelContext: modelContext
        )
        preferredExecutionRecordID = record.id
        return record
    }

    private func occurrenceSubtasks(forExecutionID executionID: UUID) -> [TaskSubitem] {
        let descriptor = FetchDescriptor<TaskSubitem>(
            predicate: #Predicate { subtask in
                subtask.taskExecutionIDRawValue == executionID.uuidString && subtask.isArchived == false
            },
            sortBy: [
                SortDescriptor(\TaskSubitem.sortOrder),
                SortDescriptor(\TaskSubitem.createdAt)
            ]
        )

        if let fetched = try? modelContext.fetch(descriptor), !fetched.isEmpty {
            return fetched
        }

        return allSubtasks
            .filter { $0.taskExecutionID == executionID && !$0.isArchived }
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.createdAt < $1.createdAt
                }
                return $0.sortOrder < $1.sortOrder
            }
    }

    private func openEditSubtaskEditor(_ subtask: TaskSubitem) {
        subtaskTitleDraft = subtask.title
        subtaskNoteDraft = subtask.note
        subtaskDetailDraft = subtask.detail
        subtaskCompletedDraft = subtask.status == .completed
        subtaskEditorTarget = SubtaskEditorTarget(subtaskID: subtask.id)
    }

    private func saveParentDetail() {
        guard let currentOccurrenceDate else { return }

        let trimmed = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || currentExecutionRecord != nil else { return }

        let record = ensureCurrentExecutionRecord(for: currentOccurrenceDate)
        record.detail = trimmed
        record.updatedAt = .now
        TaskExecutionSupport.syncExecutionStatus(
            record: record,
            task: task,
            subtasks: allSubtasks
        )
        guard saveModelContext() else { return }
    }

    private func startQuickSubtaskCreation() {
        guard !isCreatingSubtask else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingSubtask = true
        }
        quickSubtaskOccurrenceDate = currentOccurrenceDate
        quickSubtaskTitleDraft = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            quickSubtaskFieldFocused = true
        }
    }

    private func cancelQuickSubtaskCreation() {
        quickSubtaskFieldFocused = false
        quickSubtaskTitleDraft = ""
        quickSubtaskOccurrenceDate = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingSubtask = false
        }
    }

    private func saveQuickSubtask() {
        guard let occurrenceDate = quickSubtaskOccurrenceDate ?? currentOccurrenceDate else { return }
        let trimmedTitle = quickSubtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        let executionRecord = ensureCurrentExecutionRecord(for: occurrenceDate)

        let trimmedDetail = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetail.isEmpty {
            executionRecord.detail = trimmedDetail
            executionRecord.updatedAt = .now
        }

        selectedOccurrenceDate = occurrenceDate

        let newSubtask = TaskSubitem(
            parentTaskID: task.id,
            taskExecutionID: executionRecord.id,
            title: trimmedTitle,
            note: "",
            detail: "",
            status: .pending,
            sortOrder: currentOccurrenceSubtasks.count,
            isArchived: false
        )
        modelContext.insert(newSubtask)

        TaskExecutionSupport.syncExecutionStatus(
            record: executionRecord,
            task: task,
            subtasks: allSubtasks + [newSubtask]
        )

        preferredExecutionRecordID = executionRecord.id
        guard saveModelContext() else { return }

        // Clear title but keep row open to allow adding more subtasks
        quickSubtaskTitleDraft = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            quickSubtaskFieldFocused = true
        }
    }

    private func saveSubtaskEditor(_ target: SubtaskEditorTarget) {
        guard let currentOccurrenceDate else { return }
        let trimmedTitle = subtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        // Ensure execution record first, reuse it for both detail and subtask
        let executionRecord = ensureCurrentExecutionRecord(for: currentOccurrenceDate)

        // Save parent detail onto the same record
        let trimmedDetail = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetail.isEmpty {
            executionRecord.detail = trimmedDetail
            executionRecord.updatedAt = .now
        }

        let status: TaskExecutionStatus = (isCurrentOccurrenceFuture || !subtaskCompletedDraft) ? .pending : .completed
        let completedAt: Date? = status == .completed ? .now : nil

        let affectedSubtask: TaskSubitem
        if let subtaskID = target.subtaskID,
           let existingSubtask = allSubtasks.first(where: { $0.id == subtaskID }) {
            existingSubtask.title = trimmedTitle
            existingSubtask.note = subtaskNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSubtask.detail = subtaskDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSubtask.status = status
            existingSubtask.completedAt = completedAt
            existingSubtask.updatedAt = .now
            affectedSubtask = existingSubtask
        } else {
            let newSubtask = TaskSubitem(
                parentTaskID: task.id,
                taskExecutionID: executionRecord.id,
                title: trimmedTitle,
                note: subtaskNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: subtaskDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status,
                sortOrder: currentOccurrenceSubtasks.count,
                isArchived: false,
                completedAt: completedAt
            )
            modelContext.insert(newSubtask)
            affectedSubtask = newSubtask
        }

        TaskExecutionSupport.syncExecutionStatus(
            record: executionRecord,
            task: task,
            subtasks: allSubtasks.filter { $0.id != affectedSubtask.id } + [affectedSubtask]
        )
        guard saveModelContext() else { return }
        subtaskEditorTarget = nil
    }

    private func toggleSubtaskCompletion(_ subtask: TaskSubitem) {
        guard !isCurrentOccurrenceFuture else { return }
        guard let currentExecutionRecord else { return }

        saveParentDetail()

        let shouldComplete = subtask.status != .completed
        subtask.status = shouldComplete ? .completed : .pending
        subtask.completedAt = shouldComplete ? (subtask.completedAt ?? .now) : nil
        subtask.updatedAt = .now

        TaskExecutionSupport.syncExecutionStatus(
            record: currentExecutionRecord,
            task: task,
            subtasks: allSubtasks
        )
        _ = saveModelContext()
    }

    private func deleteSubtask(_ subtask: TaskSubitem) {
        let executionRecord = currentExecutionRecord
        modelContext.delete(subtask)
        resequenceCurrentOccurrenceSubtasks(excluding: subtask.id)

        if let executionRecord {
            TaskExecutionSupport.syncExecutionStatus(
                record: executionRecord,
                task: task,
                subtasks: allSubtasks.filter { $0.id != subtask.id }
            )
        }

        _ = saveModelContext()
    }

    private func moveSubtaskUp(_ subtask: TaskSubitem) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }), index > 0 else { return }
        let previous = currentOccurrenceSubtasks[index - 1]
        swap(&subtask.sortOrder, &previous.sortOrder)
        subtask.updatedAt = .now
        previous.updatedAt = .now
        _ = saveModelContext(reloadWidgets: false)
    }

    private func moveSubtaskDown(_ subtask: TaskSubitem) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }),
              index < currentOccurrenceSubtasks.count - 1 else { return }
        let next = currentOccurrenceSubtasks[index + 1]
        swap(&subtask.sortOrder, &next.sortOrder)
        subtask.updatedAt = .now
        next.updatedAt = .now
        _ = saveModelContext(reloadWidgets: false)
    }

    private func resequenceCurrentOccurrenceSubtasks(excluding subtaskID: UUID) {
        let remaining = currentOccurrenceSubtasks.filter { $0.id != subtaskID }
        for (index, item) in remaining.enumerated() {
            item.sortOrder = index
            item.updatedAt = .now
        }
    }

    private func isFirstSubtask(_ subtask: TaskSubitem) -> Bool {
        currentOccurrenceSubtasks.first?.id == subtask.id
    }

    private func isLastSubtask(_ subtask: TaskSubitem) -> Bool {
        currentOccurrenceSubtasks.last?.id == subtask.id
    }

    private func toggleOccurrenceCompletion(_ snapshot: TaskOccurrenceSnapshot) {
        if snapshot.isCompleted {
            TaskExecutionSupport.reopenTaskCompletion(
                task: task,
                occurrenceDate: snapshot.occurrenceDate,
                existingExecutions: executionRecords,
                modelContext: modelContext
            )
        } else {
            TaskExecutionSupport.markTaskCompleted(
                task: task,
                occurrenceDate: snapshot.occurrenceDate,
                existingExecutions: executionRecords,
                modelContext: modelContext
            )
        }

        _ = saveModelContext()
        refreshParentDetailDraft()
    }

    @discardableResult
    private func saveModelContext(reloadWidgets: Bool = true) -> Bool {
        do {
            try modelContext.save()
            if reloadWidgets {
                WidgetCenter.shared.reloadAllTimelines()
            }
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return false
        }
    }
}

