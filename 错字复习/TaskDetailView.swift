import SwiftUI
import SwiftData
import WidgetKit
import UIKit

struct TaskDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let taskID: UUID
    let initialTitle: String

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
    @State private var weekOffset: Int = 0
    @State private var occurrenceSnapshotState = OccurrenceSnapshotState.empty
    @State private var occurrenceSnapshotRefreshTask: Task<Void, Never>?
    @State private var detailDataActivationTask: Task<Void, Never>?
    @State private var deferredPersistenceTask: Task<Void, Never>?
    @State private var completionPersistenceTask: Task<Void, Never>?
    @State private var isCompletionPersistenceInFlight = false
    @State private var isDetailDataActive = false
    @State private var isRefreshInFlight = false
    @State private var needsRefreshAfterCurrent = false
    @State private var isSyncingSelectedOccurrenceDate = false
    @State private var isTaskUnavailable = false
    @State private var pendingSubtaskCompletionMutations: [UUID: PendingSubtaskCompletionMutation] = [:]
    @State private var pendingOccurrenceCompletionMutations: [Date: PendingOccurrenceCompletionMutation] = [:]
    @State private var allSubtasks: [TaskSubitemProjection] = []
    @State private var allExecutionRecords: [TaskExecutionRecordProjection] = []
    @State private var currentOccurrenceSubtasks: [TaskSubitemProjection] = []
    @State private var currentExecutionRecord: TaskExecutionRecordProjection? = nil
    @State private var taskProjection: TaskProjection

    init(taskID: UUID, initialTitle: String) {
        self.taskID = taskID
        self.initialTitle = initialTitle
        _taskProjection = State(initialValue: TaskProjection(id: taskID, title: initialTitle))
    }

    init(task: TaskItem) {
        self.init(taskID: task.id, initialTitle: task.title)
        _taskProjection = State(initialValue: TaskProjection(task))
    }

    private struct SubtaskEditorTarget: Identifiable {
        let id = UUID()
        let subtaskID: UUID?
    }

    private struct PendingSubtaskCompletionMutation: Sendable {
        let occurrenceDate: Date
        let status: TaskExecutionStatus
        let completedAt: Date?
        let actionID: String
        let startedAt: CFTimeInterval
    }

    private struct PendingOccurrenceCompletionMutation: Sendable {
        let occurrenceDate: Date
        let isReopening: Bool
        let actionID: String
        let startedAt: CFTimeInterval
    }

    private struct OccurrenceSnapshotState: Sendable {
        let pending: [TaskOccurrenceSnapshot]
        let completed: [TaskOccurrenceSnapshot]
        let upcoming: [TaskOccurrenceSnapshot]

        static let empty = OccurrenceSnapshotState(
            pending: [],
            completed: [],
            upcoming: []
        )

        var selection: [TaskOccurrenceSnapshot] {
            pending + upcoming + completed
        }

        var timeline: [TaskOccurrenceSnapshot] {
            pending + upcoming + completed
        }
    }

    // MARK: - Computed Properties
    
    private var canRenderLiveContent: Bool {
        scenePhase == .active
    }

    private var canReadDetailQueries: Bool {
        canRenderLiveContent && isDetailDataActive
    }

    private var pendingOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.pending }
    private var completedOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.completed }
    private var upcomingOccurrences: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.upcoming }
    private var selectionSnapshots: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.selection }
    private var timelineSnapshots: [TaskOccurrenceSnapshot] { occurrenceSnapshotState.timeline }

    private var selectedSnapshot: TaskOccurrenceSnapshot? {
        guard let resolvedDate = Self.resolvedSelectedOccurrenceDate(in: selectionSnapshots, requestedDate: selectedOccurrenceDate) else {
            return nil
        }
        return selectionSnapshots.first {
            Calendar.current.isDate($0.occurrenceDate, inSameDayAs: resolvedDate)
        }
    }

    private var currentOccurrenceDate: Date? {
        Self.resolvedSelectedOccurrenceDate(in: selectionSnapshots, requestedDate: selectedOccurrenceDate)
    }

    private var subtaskProgressText: String? {
        guard !currentOccurrenceSubtasks.isEmpty else { return nil }
        let completed = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        return "\(completed)/\(currentOccurrenceSubtasks.count) 子任务已完成"
    }

    private var currentOccurrenceHasSubtaskNotes: Bool {
        currentOccurrenceSubtasks.contains {
            !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var isCurrentOccurrenceFuture: Bool {
        guard let date = currentOccurrenceDate else { return false }
        return isFutureOccurrence(date: date)
    }

    private func isFutureOccurrence(date: Date) -> Bool {
        date > TaskExecutionSupport.day(for: .now)
    }

    private func isFutureOccurrence(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        isFutureOccurrence(date: snapshot.occurrenceDate)
    }

    nonisolated private static func resolvedSelectedOccurrenceDate(
        in snapshots: [TaskOccurrenceSnapshot],
        requestedDate: Date?
    ) -> Date? {
        if let requestedDate,
           snapshots.contains(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: requestedDate) }) {
            return TaskExecutionSupport.day(for: requestedDate)
        }
        return defaultOccurrenceDate(in: snapshots)
    }

    nonisolated private static func defaultOccurrenceDate(in snapshots: [TaskOccurrenceSnapshot]) -> Date? {
        let today = TaskExecutionSupport.day(for: .now)
        let pending = snapshots
            .filter { !$0.isCompleted && $0.occurrenceDate < today }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
        if let date = pending.first?.occurrenceDate {
            return date
        }

        let upcoming = snapshots
            .filter { !$0.isCompleted && $0.occurrenceDate >= today }
            .sorted { $0.occurrenceDate < $1.occurrenceDate }
        if let date = upcoming.first?.occurrenceDate {
            return date
        }

        return snapshots
            .filter(\.isCompleted)
            .sorted { $0.occurrenceDate > $1.occurrenceDate }
            .first?
            .occurrenceDate
    }

    nonisolated private static func perfMark(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
#if DEBUG
        DebugPerf.mark("TaskDetailView \(message)", file: file, line: line)
#endif
    }

    nonisolated private static func perfWatchMainThread(_ label: String, threshold: TimeInterval = 0.6) {
#if DEBUG
        DebugPerf.watchMainThread("TaskDetailView \(label)", threshold: threshold)
#endif
    }

    nonisolated private static func perfMillis(since startedAt: CFTimeInterval) -> String {
        String(format: "%.1fms", (CACurrentMediaTime() - startedAt) * 1000)
    }

    nonisolated private static func perfDateLabel(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return date.formatted(.dateTime.year().month().day())
    }

    // MARK: - Body
    
    var body: some View {
        List {
            if isTaskUnavailable {
                unavailableStateSection
            } else {
                summarySection

                if isDetailDataActive {
                    occurrenceCalendarGrid

                    if let snapshot = selectedSnapshot {
                        currentOccurrenceSection(snapshot)
                        subtasksSection
                    } else {
                        emptyStateSection
                    }

                    if !pendingOccurrences.isEmpty {
                        occurrenceSwitcherSection(title: "待处理记录", snapshots: pendingOccurrences)
                    }

                    if !upcomingOccurrences.isEmpty {
                        occurrenceSwitcherSection(title: "未来待办", snapshots: upcomingOccurrences)
                    }

                    if !completedOccurrences.isEmpty {
                        occurrenceSwitcherSection(title: "已完成历史", snapshots: completedOccurrences)
                    }
                } else {
                    detailLoadingSection
                }
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TaskEditorLoaderView(taskID: taskID, fallbackTitle: taskProjection.title)
                } label: {
                    Text("编辑任务")
                }
            }
        }
        .onAppear {
            Self.perfMark("onAppear task=\(taskProjection.title)")
            activateDetailDataAfterNavigationSettles()
        }
        .onDisappear {
            Self.perfMark("onDisappear task=\(taskProjection.title)")
            detailDataActivationTask?.cancel()
            occurrenceSnapshotRefreshTask?.cancel()
            deferredPersistenceTask?.cancel()
            flushPendingCompletionMutationsOnExit()
            saveParentDetail()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
            Self.perfMark("received appDataDidMutate")
            requestDetailRefresh(reason: "appDataDidMutate")
        }
        .onChange(of: selectedOccurrenceDate) { _, _ in
            if isSyncingSelectedOccurrenceDate {
                isSyncingSelectedOccurrenceDate = false
                return
            }
            let t0 = CACurrentMediaTime()
            Self.perfMark("selectedOccurrenceDate changed to=\(Self.perfDateLabel(selectedOccurrenceDate))")
            syncCalendarToSelectedDate()
            refreshParentDetailDraft()
            requestDetailRefresh(reason: "selectedOccurrenceDate")
            Self.perfMark("selectedOccurrenceDate main path end elapsed=\(Self.perfMillis(since: t0))")
        }
        .onChange(of: weekOffset) { _, _ in
            guard isDetailDataActive else { return }
            requestDetailRefresh(reason: "weekOffset")
        }
        .sheet(isPresented: $isEditingParentDetail) { parentDetailEditorSheet }
        .sheet(item: $subtaskEditorTarget) { target in subtaskEditorSheet(target) }
        .alert("保存失败", isPresented: Binding(get: { persistenceErrorMessage != nil }, set: { if !$0 { persistenceErrorMessage = nil } })) {
            Button("知道了") { persistenceErrorMessage = nil }
        } message: { Text(persistenceErrorMessage ?? "发生未知错误") }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(taskProjection.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label(taskProjection.recurrenceLabel, systemImage: taskProjection.recurrence.kind == .once ? "1.circle" : "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let effectiveDateRangeLabel = taskProjection.effectiveDateRangeLabel {
                        Text(effectiveDateRangeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if taskProjection.skipPolicy == .unskippable {
                        Label("不可跳过", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !taskProjection.note.isEmpty {
                    Text(taskProjection.note)
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

    private var detailLoadingSection: some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("正在加载...").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    private var occurrenceCalendarGrid: some View {
        Section {
            VStack(spacing: 12) {
                headerView
                weekdayLabels
                dateGrid
            }.padding(.vertical, 8)
        }
    }

    private var headerView: some View {
        HStack {
            Button { withAnimation { weekOffset -= 1 } } label: { Image(systemName: "chevron.left").padding(8).background(Circle().fill(.quaternary)) }
            Spacer()
            Text(calendarMonthYearLabel).font(.headline)
            Spacer()
            Button { withAnimation { weekOffset += 1 } } label: { Image(systemName: "chevron.right").padding(8).background(Circle().fill(.quaternary)) }
        }.buttonStyle(.plain).padding(.horizontal)
    }

    private var weekdayLabels: some View {
        HStack {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { day in
                Text(day).font(.caption2.bold()).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private var dateGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(gridDates, id: \.self) { date in
                calendarCell(for: date)
            }
        }
    }

    private var gridStartDate: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        let startOfWeek = calendar.date(from: components)!
        return calendar.date(byAdding: .day, value: weekOffset * 7, to: startOfWeek)!
    }

    private var gridDates: [Date] {
        (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: gridStartDate) }
    }

    private var calendarMonthYearLabel: String {
        let middleDate = Calendar.current.date(byAdding: .day, value: 7, to: gridStartDate)!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年 M月"
        return formatter.string(from: middleDate)
    }

    private func calendarCell(for date: Date) -> some View {
        let snapshot = timelineSnapshots.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: date) }
        let isSelected = currentOccurrenceDate.map { Calendar.current.isDate(date, inSameDayAs: $0) } ?? false
        let isToday = Calendar.current.isDateInToday(date)
        
        return Button {
            withAnimation(.spring(response: 0.3)) { selectedOccurrenceDate = date }
        } label: {
            VStack {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(size: 16, weight: isToday ? .black : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? .white : (isToday ? .red : cellContentColor(snapshot)))
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor : cellBackgroundColor(snapshot)))
        }.buttonStyle(.plain)
    }

    private func cellBackgroundColor(_ snapshot: TaskOccurrenceSnapshot?) -> Color {
        guard let s = snapshot else { return Color(uiColor: .systemGray6).opacity(0.4) }
        if s.isCompleted { return .green.opacity(0.15) }
        return s.occurrenceDate < TaskExecutionSupport.day(for: .now) ? .orange.opacity(0.15) : .blue.opacity(0.15)
    }

    private func cellContentColor(_ snapshot: TaskOccurrenceSnapshot?) -> Color {
        guard let s = snapshot else { return .secondary.opacity(0.4) }
        if s.isCompleted { return .green }
        return s.occurrenceDate < TaskExecutionSupport.day(for: .now) ? .orange : .blue
    }

    private func currentOccurrenceSection(_ snapshot: TaskOccurrenceSnapshot) -> some View {
        Section("当前处理") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                            .font(.headline)

                        HStack(spacing: 6) {
                            Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    (snapshot.isCompleted ? Color.green.opacity(0.14) : (isFutureOccurrence(snapshot) ? Color.blue.opacity(0.12) : Color.orange.opacity(0.14))),
                                    in: Capsule()
                                )

                            if snapshot.hasDetail {
                                noteBadge("有说明")
                            }

                            if currentOccurrenceHasSubtaskNotes {
                                noteBadge("子任务有备注")
                            }
                        }
                    }

                    Spacer()

                    Button {
                        isEditingParentDetail = true
                    } label: {
                        Label(
                            snapshot.hasDetail ? "编辑说明" : "添加说明",
                            systemImage: snapshot.hasDetail ? "square.and.pencil" : "plus.bubble"
                        )
                        .font(.caption.weight(.semibold))
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
                Button { startQuickSubtaskCreation() } label: {
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
                .padding(.vertical, 4)
            } else {
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
                            Button(role: .destructive) { deleteSubtask(subtask) } label: { Label("删除", systemImage: "trash") }
                        }
                }
            }
        }
    }

    private func subtaskRow(_ subtask: TaskSubitemProjection) -> some View {
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
            .transaction { transaction in
                transaction.animation = nil
            }

            Button {
                openEditSubtaskEditor(subtaskID: subtask.id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtask.title)
                        .strikethrough(isDone)
                        .foregroundStyle(isDone ? .secondary : .primary)

                    if !subtask.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                        .background(
                            quickSubtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.blue,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func occurrenceSwitcherSection(title: String, snapshots: [TaskOccurrenceSnapshot]) -> some View {
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

    private var emptyStateSection: some View {
        Section {
            ContentUnavailableView(
                "还没有执行记录",
                systemImage: "checklist",
                description: Text("任务开始后，这里会显示每次执行情况和本次子任务。")
            )
        }
    }

    private var unavailableStateSection: some View {
        Section {
            ContentUnavailableView(
                "任务不存在",
                systemImage: "exclamationmark.triangle",
                description: Text("这个任务可能已经被删除，或当前数据还没有同步完成。")
            )
        }
    }

    // MARK: - Sheets

    private var parentDetailEditorSheet: some View {
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

    private func subtaskEditorSheet(_ target: SubtaskEditorTarget) -> some View {
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

                if snapshot.hasDetail {
                    noteBadge("有说明")
                }
            }

            if let subtaskProgressText = snapshot.subtaskProgressText {
                Text(subtaskProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !snapshot.executionDetail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(snapshot.executionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func isSelected(_ snapshot: TaskOccurrenceSnapshot) -> Bool {
        guard let currentOccurrenceDate else { return false }
        return Calendar.current.isDate(snapshot.occurrenceDate, inSameDayAs: currentOccurrenceDate)
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

    // MARK: - Logic & Actions

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            if !isDetailDataActive {
                activateDetailDataAfterNavigationSettles()
            } else {
                requestDetailRefresh(reason: "scenePhase active")
            }
        } else if phase == .background {
            isDetailDataActive = false
            occurrenceSnapshotRefreshTask?.cancel()
            isRefreshInFlight = false
            needsRefreshAfterCurrent = false
        }
    }

    private func activateDetailDataAfterNavigationSettles() {
        detailDataActivationTask?.cancel()
        isDetailDataActive = false
        Self.perfMark("activateDetailDataAfterNavigationSettles requested")
        Self.perfWatchMainThread("activateDetailDataAfterNavigationSettles", threshold: 0.5)
        detailDataActivationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            isDetailDataActive = true
            Self.perfMark("activateDetailDataAfterNavigationSettles firing refresh")
            requestDetailRefresh(reason: "activateDetailDataAfterNavigationSettles")
        }
    }

    private func requestDetailRefresh(reason: String) {
        guard canRenderLiveContent else { return }

        if isRefreshInFlight {
            needsRefreshAfterCurrent = true
            Self.perfMark("refresh queued reason=\(reason)")
            return
        }

        refreshDetailModelsAndSnapshot(reason: reason)
    }

    private func scheduleDeferredDetailRefresh(after delay: TimeInterval = 0.9, reason: String) {
        deferredPersistenceTask?.cancel()
        deferredPersistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if isCompletionPersistenceInFlight ||
                !pendingSubtaskCompletionMutations.isEmpty ||
                !pendingOccurrenceCompletionMutations.isEmpty {
                Self.perfMark(
                    "refresh reconcile deferred reason=\(reason) pendingSubtasks=\(pendingSubtaskCompletionMutations.count) pendingOccurrences=\(pendingOccurrenceCompletionMutations.count) inFlight=\(isCompletionPersistenceInFlight)"
                )
                scheduleDeferredDetailRefresh(after: 0.25, reason: reason)
                return
            }
            requestDetailRefresh(reason: reason)
        }
    }

    private func scheduleCompletionPersistenceFlush(after delay: TimeInterval = 0.25) {
        completionPersistenceTask?.cancel()
        completionPersistenceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await persistPendingCompletionMutations()
        }
    }

    @MainActor
    private func flushPendingCompletionMutationsOnExit() {
        completionPersistenceTask?.cancel()
        guard !pendingSubtaskCompletionMutations.isEmpty || !pendingOccurrenceCompletionMutations.isEmpty else { return }
        Task { @MainActor in
            await persistPendingCompletionMutations(scheduleReconcile: false)
        }
    }

    @MainActor
    private func queueSubtaskCompletionPersistence(
        subtaskID: UUID,
        occurrenceDate: Date,
        status: TaskExecutionStatus,
        completedAt: Date?,
        actionID: String,
        startedAt: CFTimeInterval
    ) {
        pendingSubtaskCompletionMutations[subtaskID] = PendingSubtaskCompletionMutation(
            occurrenceDate: TaskExecutionSupport.day(for: occurrenceDate),
            status: status,
            completedAt: completedAt,
            actionID: actionID,
            startedAt: startedAt
        )
        scheduleCompletionPersistenceFlush()
    }

    @MainActor
    private func queueOccurrenceCompletionPersistence(
        occurrenceDate: Date,
        isReopening: Bool,
        actionID: String,
        startedAt: CFTimeInterval
    ) {
        let day = TaskExecutionSupport.day(for: occurrenceDate)
        pendingOccurrenceCompletionMutations[day] = PendingOccurrenceCompletionMutation(
            occurrenceDate: day,
            isReopening: isReopening,
            actionID: actionID,
            startedAt: startedAt
        )
        scheduleCompletionPersistenceFlush()
    }

    @MainActor
    private func persistPendingCompletionMutations(scheduleReconcile: Bool = true) async {
        let subtaskMutations = pendingSubtaskCompletionMutations
        let occurrenceMutations = pendingOccurrenceCompletionMutations
        guard !subtaskMutations.isEmpty || !occurrenceMutations.isEmpty else { return }

        pendingSubtaskCompletionMutations = [:]
        pendingOccurrenceCompletionMutations = [:]
        isCompletionPersistenceInFlight = true

        let tid = taskID
        let container = modelContext.container
        let batchID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark(
            "completion batch requested id=\(batchID) subtasks=\(subtaskMutations.count) occurrences=\(occurrenceMutations.count)"
        )

        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            guard let task = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first else {
                return
            }

            var executionRecords = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
            let subtasks = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []

            for (subtaskID, mutation) in subtaskMutations {
                let record = TaskExecutionSupport.ensureExecutionRecord(
                    for: task,
                    occurrenceDate: mutation.occurrenceDate,
                    existingExecutions: executionRecords,
                    modelContext: ctx
                )
                if !executionRecords.contains(where: { $0.id == record.id }) {
                    executionRecords.append(record)
                }

                if let targetSubtask = subtasks.first(where: { $0.id == subtaskID }) {
                    targetSubtask.status = mutation.status
                    targetSubtask.completedAt = mutation.completedAt
                    targetSubtask.updatedAt = .now
                    if targetSubtask.taskExecutionID == nil {
                        targetSubtask.taskExecutionID = record.id
                    }
                }

                TaskExecutionSupport.syncExecutionStatus(record: record, task: task, subtasks: subtasks)
            }

            if !occurrenceMutations.isEmpty {
                let sortedMutations = occurrenceMutations.values.sorted { $0.occurrenceDate < $1.occurrenceDate }
                for mutation in sortedMutations {
                    executionRecords = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? executionRecords
                    if mutation.isReopening {
                        TaskExecutionSupport.reopenTaskCompletion(
                            task: task,
                            occurrenceDate: mutation.occurrenceDate,
                            existingExecutions: executionRecords,
                            modelContext: ctx
                        )
                    } else {
                        TaskExecutionSupport.markTaskCompleted(
                            task: task,
                            occurrenceDate: mutation.occurrenceDate,
                            existingExecutions: executionRecords,
                            modelContext: ctx
                        )
                    }
                }
            }

            try? ctx.save()
            Self.perfMark("completion batch bg saved id=\(batchID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")

            await MainActor.run {
                Self.perfMark("completion batch main reconcile id=\(batchID) total=\(Self.perfMillis(since: startedAt))")
                isCompletionPersistenceInFlight = false
                let hasQueuedMutations = !pendingSubtaskCompletionMutations.isEmpty || !pendingOccurrenceCompletionMutations.isEmpty
                if hasQueuedMutations {
                    scheduleCompletionPersistenceFlush(after: 0.2)
                }
                if scheduleReconcile && !hasQueuedMutations {
                    scheduleDeferredDetailRefresh(after: 0.35, reason: "completion batch reconcile")
                }
            }
        }
    }

    private func refreshDetailModelsAndSnapshot(reason: String) {
        occurrenceSnapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        isRefreshInFlight = true
        
        let tid = taskID
        let container = modelContext.container
        let requestedSelectedDate = selectedOccurrenceDate
        let visibleGridEndDate = gridDates.last ?? TaskExecutionSupport.day(for: .now)
        let refreshID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()

        Self.perfMark("refresh requested id=\(refreshID) reason=\(reason) selected=\(Self.perfDateLabel(requestedSelectedDate))")
        Self.perfWatchMainThread("refresh \(refreshID)", threshold: 0.45)
        
        occurrenceSnapshotRefreshTask = Task(priority: .userInitiated) {
            typealias RefreshResult = (
                TaskProjection?,
                [TaskOccurrenceSnapshot],
                [TaskSubitemProjection],
                [TaskExecutionRecordProjection],
                [TaskSubitemProjection],
                TaskExecutionRecordProjection?,
                Date?
            )
            
            let results: RefreshResult? = await Task.detached(priority: .userInitiated) {
                let backgroundStartedAt = CACurrentMediaTime()
                Self.perfMark("refresh bg begin id=\(refreshID)")
                let ctx = ModelContext(container)
                let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                guard let t else {
                    Self.perfMark("refresh bg missing task id=\(refreshID)")
                    return (nil, [], [], [], [], nil, nil)
                }
                let taskProjection = TaskProjection(t)
                let refreshUpperBound = max(
                    TaskExecutionSupport.day(for: .now),
                    TaskExecutionSupport.day(for: visibleGridEndDate),
                    requestedSelectedDate.map(TaskExecutionSupport.day(for:)) ?? TaskExecutionSupport.day(for: .now)
                )
                
                let records = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
                let subtasks = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                
                let snapshots = TaskExecutionSupport.occurrenceSnapshots(
                    for: t,
                    executions: records,
                    subtasks: subtasks,
                    subtaskExecutions: [],
                    on: refreshUpperBound
                )
                let subProjections = subtasks.filter { !$0.isArchived }.map(TaskSubitemProjection.init)
                let recProjections = records.map(TaskExecutionRecordProjection.init)
                
                let resolvedSelectedDate = Self.resolvedSelectedOccurrenceDate(in: snapshots, requestedDate: requestedSelectedDate)
                let resolvedSnapshot = resolvedSelectedDate.flatMap { targetDate in
                    snapshots.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDate) }
                }
                let curRec: TaskExecutionRecordProjection?
                if let executionRecordID = resolvedSnapshot?.executionRecordID {
                    curRec = recProjections.first { $0.id == executionRecordID }
                } else if let resolvedSelectedDate {
                    let targetDay = TaskExecutionSupport.day(for: resolvedSelectedDate)
                    curRec = recProjections.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay) }
                } else {
                    curRec = nil
                }
                
                let curSubProjections: [TaskSubitemProjection]
                if let rid = curRec?.id {
                     curSubProjections = subProjections.filter { $0.taskExecutionID == rid }
                                                     .sorted { $0.sortOrder < $1.sortOrder }
                } else {
                     curSubProjections = []
                }
                
                Self.perfMark(
                    "refresh bg end id=\(refreshID) elapsed=\(Self.perfMillis(since: backgroundStartedAt)) snapshots=\(snapshots.count) records=\(records.count) subtasks=\(subtasks.count) currentSubtasks=\(curSubProjections.count)"
                )
                return (taskProjection, snapshots, subProjections, recProjections, curSubProjections, curRec, resolvedSelectedDate)
            }.value
            
            guard !Task.isCancelled, let res = results else {
                await MainActor.run {
                    isRefreshInFlight = false
                }
                return
            }
            
            await MainActor.run {
                let applyStartedAt = CACurrentMediaTime()
                Self.perfMark("refresh main apply begin id=\(refreshID)")
                if let projection = res.0 {
                    taskUnavailableApplyReset(using: projection, result: res)
                } else {
                    isTaskUnavailable = true
                    occurrenceSnapshotState = .empty
                    allSubtasks = []
                    allExecutionRecords = []
                    currentOccurrenceSubtasks = []
                    currentExecutionRecord = nil
                    isDetailDataActive = true
                }
                Self.perfMark(
                    "refresh main apply end id=\(refreshID) apply=\(Self.perfMillis(since: applyStartedAt)) total=\(Self.perfMillis(since: startedAt)) pending=\(occurrenceSnapshotState.pending.count) completed=\(occurrenceSnapshotState.completed.count) upcoming=\(occurrenceSnapshotState.upcoming.count)"
                )
                isRefreshInFlight = false
                if needsRefreshAfterCurrent {
                    needsRefreshAfterCurrent = false
                    refreshDetailModelsAndSnapshot(reason: "coalesced")
                }
            }
        }
    }

    private func taskUnavailableApplyReset(
        using projection: TaskProjection,
        result: (
            TaskProjection?,
            [TaskOccurrenceSnapshot],
            [TaskSubitemProjection],
            [TaskExecutionRecordProjection],
            [TaskSubitemProjection],
            TaskExecutionRecordProjection?,
            Date?
        )
    ) {
        taskUnavailableApplyProjection(projection)
        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: result.1.filter { !$0.isCompleted && $0.occurrenceDate < TaskExecutionSupport.day(for: .now) },
            completed: result.1.filter { $0.isCompleted }.sorted { $0.occurrenceDate > $1.occurrenceDate },
            upcoming: result.1.filter { !$0.isCompleted && $0.occurrenceDate >= TaskExecutionSupport.day(for: .now) }
        )
        allSubtasks = result.2
        allExecutionRecords = result.3
        currentOccurrenceSubtasks = result.4
        currentExecutionRecord = result.5
        isDetailDataActive = true
        if let resolvedSelectedDate = result.6,
           selectedOccurrenceDate.map({ !Calendar.current.isDate($0, inSameDayAs: resolvedSelectedDate) }) ?? true {
            isSyncingSelectedOccurrenceDate = true
            selectedOccurrenceDate = resolvedSelectedDate
        }
    }

    private func taskUnavailableApplyProjection(_ projection: TaskProjection) {
        isTaskUnavailable = false
        taskProjection = projection
    }

    private func syncCalendarToSelectedDate() {
        guard let date = selectedOccurrenceDate else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let diff = calendar.dateComponents([.weekOfYear], from: today, to: date).weekOfYear ?? 0
        if diff < weekOffset || diff >= weekOffset + 2 { withAnimation { weekOffset = diff } }
    }

    private func refreshParentDetailDraft() { parentDetailDraft = selectedSnapshot?.executionDetail ?? "" }

    private func applyOptimisticSubtaskProjectionUpdate(
        subtaskID: UUID,
        status: TaskExecutionStatus
    ) {
        if let index = allSubtasks.firstIndex(where: { $0.id == subtaskID }) {
            var updated = allSubtasks[index]
            updated.status = status
            allSubtasks[index] = updated
        }
    }

    private func applyOptimisticOccurrenceSnapshotUpdate(for occurrenceDate: Date) {
        guard let existingSnapshot = timelineSnapshots.first(where: {
            Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }) else {
            return
        }

        let totalSubtaskCount = currentOccurrenceSubtasks.count
        let completedSubtaskCount = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        let updatedIsCompleted = totalSubtaskCount > 0
            ? completedSubtaskCount == totalSubtaskCount
            : existingSnapshot.isCompleted

        let updatedSnapshot = TaskOccurrenceSnapshot(
            taskID: existingSnapshot.taskID,
            occurrenceDate: existingSnapshot.occurrenceDate,
            isCompleted: updatedIsCompleted,
            overdueOriginText: updatedIsCompleted ? nil : existingSnapshot.overdueOriginText,
            executionRecordID: existingSnapshot.executionRecordID,
            executionDetail: existingSnapshot.executionDetail,
            hasDetail: existingSnapshot.hasDetail,
            totalSubtaskCount: totalSubtaskCount,
            completedSubtaskCount: completedSubtaskCount
        )

        var remainingPending = occurrenceSnapshotState.pending.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }
        var remainingUpcoming = occurrenceSnapshotState.upcoming.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }
        var remainingCompleted = occurrenceSnapshotState.completed.filter {
            !Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate)
        }

        let today = TaskExecutionSupport.day(for: .now)
        if updatedSnapshot.isCompleted {
            remainingCompleted.append(updatedSnapshot)
            remainingCompleted.sort { $0.occurrenceDate > $1.occurrenceDate }
        } else if updatedSnapshot.occurrenceDate < today {
            remainingPending.append(updatedSnapshot)
            remainingPending.sort { $0.occurrenceDate < $1.occurrenceDate }
        } else {
            remainingUpcoming.append(updatedSnapshot)
            remainingUpcoming.sort { $0.occurrenceDate < $1.occurrenceDate }
        }

        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: remainingPending,
            completed: remainingCompleted,
            upcoming: remainingUpcoming
        )
    }

    private func saveParentDetail() {
        guard let date = currentOccurrenceDate else { return }
        let tid = taskID
        let container = modelContext.container
        let noteDraft = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("saveParentDetail requested id=\(actionID) date=\(Self.perfDateLabel(date)) noteLength=\(noteDraft.count)")
        
        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            // 后台获取或创建 record
            let ed = FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid })
            let recs = (try? ctx.fetch(ed)) ?? []
            let record = TaskExecutionSupport.ensureExecutionRecord(for: (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))!.first!, occurrenceDate: date, existingExecutions: recs, modelContext: ctx)
            
            record.detail = noteDraft
            record.updatedAt = .now
            
            let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
            TaskExecutionSupport.syncExecutionStatus(record: record, task: (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))!.first!, subtasks: allS)
            
            try? ctx.save()
                Self.perfMark("saveParentDetail bg end id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                await MainActor.run {
                    Self.perfMark("saveParentDetail main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    requestDetailRefresh(reason: "saveParentDetail")
                }
            }
        }



    private func toggleSubtaskCompletion(_ subtask: TaskSubitemProjection) {
        guard !isCurrentOccurrenceFuture, let date = currentOccurrenceDate else { return }
        
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        let targetSID = subtask.id
        let targetStatus: TaskExecutionStatus = (subtask.status == .completed) ? .pending : .completed
        let targetCompletedAt: Date? = (targetStatus == .completed) ? .now : nil
        Self.perfMark("subtask toggle tap id=\(actionID) subtask=\(subtask.title) to=\(targetStatus.rawValue) date=\(Self.perfDateLabel(date))")
        Self.perfWatchMainThread("subtask toggle \(actionID)", threshold: 0.35)
        
        // 1. UI 立即响应投影数据变化（Optimistic UI）
        if let idx = currentOccurrenceSubtasks.firstIndex(where: { $0.id == targetSID }) {
           var updated = currentOccurrenceSubtasks[idx]
           updated.status = targetStatus
           currentOccurrenceSubtasks[idx] = updated
        }
        applyOptimisticSubtaskProjectionUpdate(subtaskID: targetSID, status: targetStatus)
        applyOptimisticOccurrenceSnapshotUpdate(for: date)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        queueSubtaskCompletionPersistence(
            subtaskID: targetSID,
            occurrenceDate: date,
            status: targetStatus,
            completedAt: targetCompletedAt,
            actionID: actionID,
            startedAt: startedAt
        )
        Self.perfMark("subtask toggle optimistic id=\(actionID) elapsed=\(Self.perfMillis(since: startedAt))")
    }

    private func startQuickSubtaskCreation() {
        guard !isCreatingSubtask else { return }
        quickSubtaskOccurrenceDate = currentOccurrenceDate
        quickSubtaskTitleDraft = ""
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingSubtask = true
        }
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

    private func commitIMEAndSave() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            saveQuickSubtask()
        }
    }

    private func saveQuickSubtask() {
        guard let date = quickSubtaskOccurrenceDate ?? currentOccurrenceDate else { return }
        let trimmedTitle = quickSubtaskTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("quickSubtask save requested id=\(actionID) date=\(Self.perfDateLabel(date)) titleLength=\(trimmedTitle.count)")
        
        Task.detached(priority: .userInitiated) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            // 找当前 task 和 record
            guard let task = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first else { return }
            let ed = FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid })
            let recs = (try? ctx.fetch(ed)) ?? []
            let record = TaskExecutionSupport.ensureExecutionRecord(for: task, occurrenceDate: date, existingExecutions: recs, modelContext: ctx)
            
            // 下发子任务
            let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
            let occurrenceS = allS.filter { $0.taskExecutionID == record.id && !$0.isArchived }
            
            let newSub = TaskSubitem(
                parentTaskID: tid,
                taskExecutionID: record.id,
                title: trimmedTitle,
                note: "",
                detail: "",
                status: .pending,
                sortOrder: occurrenceS.count
            )
            ctx.insert(newSub)
            
            // 同步状态并存储
            let updatedAllS = allS + [newSub]
            TaskExecutionSupport.syncExecutionStatus(record: record, task: task, subtasks: updatedAllS)
            
            do {
                try ctx.save()
                Self.perfMark("quickSubtask bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                await MainActor.run {
                    selectedOccurrenceDate = date
                    cancelQuickSubtaskCreation()
                    Self.perfMark("quickSubtask main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    requestDetailRefresh(reason: "saveQuickSubtask")
                }
            } catch {
                await MainActor.run {
                    persistenceErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openEditSubtaskEditor(subtaskID: UUID) {
        // 先找到对应的投影来初始化编辑器状态（草图相关可以暂时放在主线程）
        if let proj = allSubtasks.first(where: { $0.id == subtaskID }) {
            subtaskTitleDraft = proj.title
            subtaskNoteDraft = proj.note
            subtaskDetailDraft = proj.detail
            subtaskCompletedDraft = proj.status == .completed
            subtaskEditorTarget = SubtaskEditorTarget(subtaskID: subtaskID)
        }
    }

    private func saveSubtaskEditor(_ target: SubtaskEditorTarget) {
        guard let sid = target.subtaskID else { return }
        let tid = taskID
        let container = modelContext.container
        let (title, note, detail, isCompleted) = (subtaskTitleDraft, subtaskNoteDraft, subtaskDetailDraft, subtaskCompletedDraft)
        
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.id == sid })
            if let sub = (try? ctx.fetch(descriptor))?.first {
                sub.title = title
                sub.note = note
                sub.detail = detail
                sub.status = isCompleted ? .completed : .pending
                sub.completedAt = isCompleted ? .now : nil
                sub.updatedAt = .now
                
                // 给 execution 同步
                if let rid = sub.taskExecutionID {
                    let er = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.id == rid })))?.first
                    let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                    let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                    if let er, let t {
                        TaskExecutionSupport.syncExecutionStatus(record: er, task: t, subtasks: allS)
                    }
                }
                
                try? ctx.save()
                await MainActor.run {
                    requestDetailRefresh(reason: "saveSubtaskEditor")
                }
            }
        }
        subtaskEditorTarget = nil
    }

    private func deleteSubtask(_ sub: TaskSubitemProjection) {
        let sid = sub.id
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("deleteSubtask requested id=\(actionID) subtask=\(sub.title)")
        
        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.id == sid })
            if let target = (try? ctx.fetch(descriptor))?.first {
                // 如果有关联的执行记录，同步一下状态
                let rid = target.taskExecutionID
                ctx.delete(target)

                if let rid {
                    let remaining = ((try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? [])
                        .filter { $0.taskExecutionID == rid && !$0.isArchived }
                        .sorted {
                            if $0.sortOrder == $1.sortOrder {
                                return $0.createdAt < $1.createdAt
                            }
                            return $0.sortOrder < $1.sortOrder
                        }
                    for (index, item) in remaining.enumerated() {
                        item.sortOrder = index
                        item.updatedAt = .now
                    }
                }
                
                if let rid {
                    let er = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.id == rid })))?.first
                    let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                    let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                    if let er, let t {
                        TaskExecutionSupport.syncExecutionStatus(record: er, task: t, subtasks: allS)
                    }
                }
                
                try? ctx.save()
                Self.perfMark("deleteSubtask bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                await MainActor.run {
                    Self.perfMark("deleteSubtask main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    requestDetailRefresh(reason: "deleteSubtask")
                }
            }
        }
    }

    private func moveSubtaskUp(_ subtask: TaskSubitemProjection) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }), index > 0 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            let moving = currentOccurrenceSubtasks.remove(at: index)
            currentOccurrenceSubtasks.insert(moving, at: index - 1)
        }

        persistSubtaskMove(subtaskID: subtask.id, neighborID: currentOccurrenceSubtasks[index].id)
    }

    private func moveSubtaskDown(_ subtask: TaskSubitemProjection) {
        guard let index = currentOccurrenceSubtasks.firstIndex(where: { $0.id == subtask.id }),
              index < currentOccurrenceSubtasks.count - 1 else { return }

        withAnimation(.easeInOut(duration: 0.18)) {
            let moving = currentOccurrenceSubtasks.remove(at: index)
            currentOccurrenceSubtasks.insert(moving, at: index + 1)
        }

        persistSubtaskMove(subtaskID: subtask.id, neighborID: currentOccurrenceSubtasks[index].id)
    }

    private func persistSubtaskMove(subtaskID: UUID, neighborID: UUID) {
        let tid = taskID
        let container = modelContext.container
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        Self.perfMark("subtask move requested id=\(actionID) subtaskID=\(subtaskID.uuidString.prefix(6)) neighborID=\(neighborID.uuidString.prefix(6))")

        Task.detached(priority: .utility) {
            let backgroundStartedAt = CACurrentMediaTime()
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid })
            let allS = (try? ctx.fetch(descriptor)) ?? []

            guard let moving = allS.first(where: { $0.id == subtaskID }),
                  let neighbor = allS.first(where: { $0.id == neighborID }) else { return }

            let originalSortOrder = moving.sortOrder
            moving.sortOrder = neighbor.sortOrder
            neighbor.sortOrder = originalSortOrder
            moving.updatedAt = .now
            neighbor.updatedAt = .now

            do {
                try ctx.save()
                Self.perfMark("subtask move bg saved id=\(actionID) elapsed=\(Self.perfMillis(since: backgroundStartedAt))")
                await MainActor.run {
                    Self.perfMark("subtask move main refresh id=\(actionID) total=\(Self.perfMillis(since: startedAt))")
                    requestDetailRefresh(reason: "moveSubtask")
                }
            } catch {
                await MainActor.run {
                    persistenceErrorMessage = error.localizedDescription
                    requestDetailRefresh(reason: "moveSubtask error")
                }
            }
        }
    }

    private func isFirstSubtask(_ subtask: TaskSubitemProjection) -> Bool {
        currentOccurrenceSubtasks.first?.id == subtask.id
    }

    private func isLastSubtask(_ subtask: TaskSubitemProjection) -> Bool {
        currentOccurrenceSubtasks.last?.id == subtask.id
    }

    private func leadingSymbol(for subtask: TaskSubitemProjection, isDone: Bool) -> String {
        if isCurrentOccurrenceFuture {
            return "clock"
        }
        return isDone ? "checkmark.circle.fill" : "circle"
    }

    private func leadingColor(for subtask: TaskSubitemProjection, isDone: Bool) -> Color {
        if isCurrentOccurrenceFuture {
            return .blue
        }
        return isDone ? .green : .secondary
    }

    private func noteBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: Capsule())
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

    private func toggleOccurrenceCompletion(_ snapshot: TaskOccurrenceSnapshot) {
        guard !isFutureOccurrence(snapshot) else { return }
        
        let actionID = String(UUID().uuidString.prefix(6))
        let startedAt = CACurrentMediaTime()
        // 1. 主线程 UI 抢跑：直接修改本地内存快照状态以实现瞬时反馈
        let isReopening = snapshot.isCompleted
        let occurrenceDate = snapshot.occurrenceDate
        Self.perfMark("occurrence toggle tap id=\(actionID) date=\(Self.perfDateLabel(occurrenceDate)) reopening=\(isReopening)")
        Self.perfWatchMainThread("occurrence toggle \(actionID)", threshold: 0.35)
        
        var nextPending = occurrenceSnapshotState.pending
        var nextCompleted = occurrenceSnapshotState.completed
        
        if isReopening {
            if let idx = nextCompleted.firstIndex(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate) }) {
                var item = nextCompleted.remove(at: idx)
                item.isCompleted = false
                nextPending.append(item)
                nextPending.sort { $0.occurrenceDate < $1.occurrenceDate }
            }
        } else {
            if let idx = nextPending.firstIndex(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate) }) {
                var item = nextPending.remove(at: idx)
                item.isCompleted = true
                nextCompleted.append(item)
                nextCompleted.sort { $0.occurrenceDate > $1.occurrenceDate }
            }
        }
        
        occurrenceSnapshotState = OccurrenceSnapshotState(
            pending: nextPending,
            completed: nextCompleted,
            upcoming: occurrenceSnapshotState.upcoming
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        queueOccurrenceCompletionPersistence(
            occurrenceDate: occurrenceDate,
            isReopening: isReopening,
            actionID: actionID,
            startedAt: startedAt
        )
        Self.perfMark("occurrence toggle optimistic id=\(actionID) elapsed=\(Self.perfMillis(since: startedAt))")
    }

}

private struct TaskEditorLoaderView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let taskID: UUID
    let fallbackTitle: String

    @State private var task: TaskItem?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let task {
                AddTaskView(task: task)
            } else if loadFailed {
                ContentUnavailableView("任务不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(fallbackTitle)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle("编辑任务")
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
