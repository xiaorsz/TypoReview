import SwiftUI
import SwiftData
import WidgetKit
import UIKit

struct TaskDetailView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let task: TaskItem

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
    @State private var isDetailDataActive = false
    @State private var allSubtasks: [TaskSubitemProjection] = []
    @State private var allExecutionRecords: [TaskExecutionRecordProjection] = []
    @State private var currentOccurrenceSubtasks: [TaskSubitemProjection] = []
    @State private var currentExecutionRecord: TaskExecutionRecordProjection? = nil

    private struct SubtaskEditorTarget: Identifiable {
        let id = UUID()
        let subtaskID: UUID?
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
        if let selectedOccurrenceDate {
            return selectionSnapshots.first {
                Calendar.current.isDate($0.occurrenceDate, inSameDayAs: selectedOccurrenceDate)
            }
        }
        return pendingOccurrences.first ?? upcomingOccurrences.first ?? completedOccurrences.first
    }

    private var currentOccurrenceDate: Date? { selectedSnapshot?.occurrenceDate }

    private var subtaskProgressText: String? {
        guard !currentOccurrenceSubtasks.isEmpty else { return nil }
        let completed = currentOccurrenceSubtasks.filter { $0.status == .completed }.count
        return "\(completed)/\(currentOccurrenceSubtasks.count) 子任务已完成"
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

    // MARK: - Body
    
    var body: some View {
        List {
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
                
                if !completedOccurrences.isEmpty {
                    occurrenceSwitcherSection(title: "已完成历史", snapshots: completedOccurrences)
                }
            } else {
                detailLoadingSection
            }
        }
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AddTaskView(task: task) } label: { Text("编辑任务") }
            }
        }
        .onAppear { activateDetailDataAfterNavigationSettles() }
        .onDisappear {
            detailDataActivationTask?.cancel()
            occurrenceSnapshotRefreshTask?.cancel()
            deferredPersistenceTask?.cancel()
            saveParentDetail()
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
            refreshDetailModelsAndSnapshot()
        }
        .onChange(of: allSubtasks.count) { _, _ in refreshDetailModelsAndSnapshot() }
        .onChange(of: allExecutionRecords.count) { _, _ in refreshDetailModelsAndSnapshot() }
        .onChange(of: selectedOccurrenceDate) { _, _ in
            let t0 = CACurrentMediaTime()
            syncCalendarToSelectedDate()
            refreshParentDetailDraft()
            print("🕰️ [DEBUG - DateSwitch] MAIN THREAD UNBLOCKED IN: \(String(format: "%.4fs", CACurrentMediaTime() - t0))")
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
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.title3.weight(.bold))
                HStack(spacing: 3) {
                    Text(task.recurrenceShortLabel).font(.caption).foregroundStyle(.secondary)
                    if let label = task.effectiveDateRangeLabel {
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 4)
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
        let isSelected = selectedOccurrenceDate != nil && Calendar.current.isDate(date, inSameDayAs: selectedOccurrenceDate!)
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
                HStack {
                    VStack(alignment: .leading) {
                        Text(snapshot.occurrenceDate.formatted(.dateTime.month().day())).font(.headline)
                        Text(snapshot.isCompleted ? "已完成" : (isFutureOccurrence(snapshot) ? "未来" : "待处理"))
                            .font(.caption.bold())
                            .foregroundStyle(snapshot.isCompleted ? .green : (isFutureOccurrence(snapshot) ? .blue : .orange))
                    }
                    Spacer()
                    Button { isEditingParentDetail = true } label: {
                        Label(snapshot.hasDetail ? "编辑说明" : "添加说明", systemImage: "plus.bubble")
                            .font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                    }.buttonStyle(.plain)
                }
                if !task.note.isEmpty {
                    Text(task.note).font(.caption).foregroundStyle(.secondary).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                }
            }.padding(12)
        }
    }

    private var subtasksSection: some View {
        Section("本次子任务") {
            if !isCreatingSubtask {
                Button { startQuickSubtaskCreation() } label: {
                    Label("添加子任务", systemImage: "plus.circle.fill").font(.subheadline).foregroundStyle(.blue)
                }.buttonStyle(.plain).padding(.vertical, 4)
            } else {
                quickCreateSubtaskRow
            }

            ForEach(currentOccurrenceSubtasks) { subtask in
                subtaskRow(subtask)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { deleteSubtask(subtask) } label: { Label("删除", systemImage: "trash") }
                    }
            }
        }
    }

    private func subtaskRow(_ subtask: TaskSubitemProjection) -> some View {
        let isDone = subtask.status == .completed
        return HStack(spacing: 0) {
            // 左侧：独立勾选区
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.bold))
                .foregroundStyle(isDone ? .green : .secondary)
                .frame(width: 44, height: 44) // 增大物理触感区域
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isCurrentOccurrenceFuture {
                        toggleSubtaskCompletion(subtask)
                    }
                }
                .opacity(isCurrentOccurrenceFuture ? 0.5 : 1.0)
            
            // 中间：编辑区
            VStack(alignment: .leading, spacing: 2) {
                Text(subtask.title)
                    .strikethrough(isDone)
                    .foregroundStyle(isDone ? .secondary : .primary)
                if !subtask.note.isEmpty {
                    Text(subtask.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                // 打开编辑器时由于需要模型，这里通过 ID 查找
                openEditSubtaskEditor(subtaskID: subtask.id)
            }
            
            // 右侧：详情图标
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.quaternary)
                .padding(.trailing, 4)
        }
        .padding(.vertical, 2)
    }

    private var quickCreateSubtaskRow: some View {
        VStack(spacing: 8) {
            TextField("输入子任务...", text: $quickSubtaskTitleDraft).focused($quickSubtaskFieldFocused)
            HStack {
                Spacer()
                Button("取消") { cancelQuickSubtaskCreation() }.font(.subheadline)
                Button("添加") { saveQuickSubtask() }.font(.subheadline.bold()).disabled(quickSubtaskTitleDraft.isEmpty)
            }
        }.padding(.vertical, 4)
    }

    private func occurrenceSwitcherSection(title: String, snapshots: [TaskOccurrenceSnapshot]) -> some View {
        Section(title) {
            ForEach(snapshots) { snapshot in
                HStack(spacing: 0) {
                    // 左侧：状态勾选点
                    Image(systemName: snapshot.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(snapshot.isCompleted ? .green : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !isFutureOccurrence(snapshot) && !snapshot.hasSubtasks {
                                toggleOccurrenceCompletion(snapshot)
                            }
                        }
                        .opacity((isFutureOccurrence(snapshot) || snapshot.hasSubtasks) ? 0.5 : 1.0)
                    
                    // 右侧：切换点
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.occurrenceDate.formatted(.dateTime.year().month().day()))
                            .font(.subheadline.weight(.semibold))
                        if !snapshot.executionDetail.isEmpty {
                            Text(snapshot.executionDetail)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            selectedOccurrenceDate = snapshot.occurrenceDate
                        }
                    }
                    
                    if let sel = selectedOccurrenceDate, Calendar.current.isDate(snapshot.occurrenceDate, inSameDayAs: sel) {
                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.blue)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var emptyStateSection: some View {
        Section { Text("暂无记录").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding() }
    }

    // MARK: - Sheets

    private var parentDetailEditorSheet: some View {
        NavigationStack {
            Form { Section("本次说明") { TextEditor(text: $parentDetailDraft).frame(minHeight: 150) } }
            .navigationTitle("编辑本次说明").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { isEditingParentDetail = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveParentDetail(); isEditingParentDetail = false } }
            }
        }
    }

    private func subtaskEditorSheet(_ target: SubtaskEditorTarget) -> some View {
        NavigationStack {
            Form {
                Section("内容") { TextField("标题", text: $subtaskTitleDraft); TextField("备注", text: $subtaskNoteDraft) }
                Section("说明") { TextEditor(text: $subtaskDetailDraft).frame(minHeight: 100) }
                if !isCurrentOccurrenceFuture { Toggle("已完成", isOn: $subtaskCompletedDraft) }
            }
            .navigationTitle(target.subtaskID == nil ? "添加子任务" : "编辑子任务").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { subtaskEditorTarget = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { saveSubtaskEditor(target) } }
            }
        }
    }

    // MARK: - Logic & Actions

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active { if !isDetailDataActive { activateDetailDataAfterNavigationSettles() } }
        else if phase == .background { isDetailDataActive = false }
    }

    private func activateDetailDataAfterNavigationSettles() {
        detailDataActivationTask?.cancel()
        isDetailDataActive = false
        detailDataActivationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            isDetailDataActive = true
            refreshDetailModelsAndSnapshot()
        }
    }

    private func refreshDetailModelsAndSnapshot() {
        occurrenceSnapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }
        
        let tid = task.id
        let container = modelContext.container
        let selectedDate = selectedOccurrenceDate ?? .now
        
        occurrenceSnapshotRefreshTask = Task(priority: .userInitiated) {
            // 显式声明返回类型以解决 nil 推断问题
            typealias RefreshResult = ([TaskOccurrenceSnapshot], [TaskSubitemProjection], [TaskExecutionRecordProjection], [TaskSubitemProjection], TaskExecutionRecordProjection?)
            
            let results: RefreshResult? = try? await Task.detached(priority: .userInitiated) {
                let ctx = ModelContext(container)
                let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                guard let t else { return nil }
                
                let records = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
                let subtasks = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                
                let snapshots = TaskExecutionSupport.occurrenceSnapshots(for: t, executions: records, subtasks: subtasks, subtaskExecutions: [])
                let subProjections = subtasks.filter { !$0.isArchived }.map(TaskSubitemProjection.init)
                let recProjections = records.map(TaskExecutionRecordProjection.init)
                
                let targetDay = TaskExecutionSupport.day(for: selectedDate)
                let curRec = recProjections.first { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay) }
                
                let curSubProjections: [TaskSubitemProjection]
                if let rid = curRec?.id {
                     curSubProjections = subProjections.filter { $0.taskExecutionID == rid }
                                                     .sorted { $0.sortOrder < $1.sortOrder }
                } else {
                     curSubProjections = []
                }
                
                return (snapshots, subProjections, recProjections, curSubProjections, curRec)
            }.value
            
            guard !Task.isCancelled, let res = results else { return }
            
            await MainActor.run {
                withAnimation(.smooth(duration: 0.2)) {
                    occurrenceSnapshotState = OccurrenceSnapshotState(
                        pending: res.0.filter { !$0.isCompleted && $0.occurrenceDate < TaskExecutionSupport.day(for: .now) },
                        completed: res.0.filter { $0.isCompleted }.sorted { $0.occurrenceDate > $1.occurrenceDate },
                        upcoming: res.0.filter { !$0.isCompleted && $0.occurrenceDate >= TaskExecutionSupport.day(for: .now) }
                    )
                    allSubtasks = res.1
                    allExecutionRecords = res.2
                    currentOccurrenceSubtasks = res.3
                    currentExecutionRecord = res.4
                    isDetailDataActive = true
                }
            }
        }
    }

    private func syncCalendarToSelectedDate() {
        guard let date = selectedOccurrenceDate else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let diff = calendar.dateComponents([.weekOfYear], from: today, to: date).weekOfYear ?? 0
        if diff < weekOffset || diff >= weekOffset + 2 { withAnimation { weekOffset = diff } }
    }

    private func refreshParentDetailDraft() { parentDetailDraft = selectedSnapshot?.executionDetail ?? "" }

    private func saveParentDetail() {
        guard let date = currentOccurrenceDate else { return }
        let tid = task.id
        let container = modelContext.container
        let noteDraft = parentDetailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        
        Task.detached(priority: .utility) {
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
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
            }
        }
    }



    private func toggleSubtaskCompletion(_ subtask: TaskSubitemProjection) {
        guard !isCurrentOccurrenceFuture, let date = currentOccurrenceDate else { return }
        
        let targetSID = subtask.id
        let targetStatus: TaskExecutionStatus = (subtask.status == .completed) ? .pending : .completed
        let targetCompletedAt: Date? = (targetStatus == .completed) ? .now : nil
        
        // 1. UI 立即响应投影数据变化（Optimistic UI）
        withAnimation(.easeInOut(duration: 0.12)) {
            if let idx = currentOccurrenceSubtasks.firstIndex(where: { $0.id == targetSID }) {
               var updated = currentOccurrenceSubtasks[idx]
               updated.status = targetStatus
               currentOccurrenceSubtasks[idx] = updated
            }
        }
        
        let tid = task.id
        let container = modelContext.container
        
        // 2. 后台强同步真正的模型
        Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            do {
                guard let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first else { return }
                let allRecs = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
                let record = TaskExecutionSupport.ensureExecutionRecord(for: t, occurrenceDate: date, existingExecutions: allRecs, modelContext: ctx)
                
                let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                
                if let targetS = allS.first(where: { $0.id == targetSID }) {
                    targetS.status = targetStatus
                    targetS.completedAt = targetCompletedAt
                    targetS.updatedAt = .now
                    
                    // 关键：如果子任务以前没关联这个 record（比如刚从旧模板迁移），在这里关联上
                    if targetS.taskExecutionID == nil {
                        targetS.taskExecutionID = record.id
                    }
                }
                
                // 同步 execution 状态
                TaskExecutionSupport.syncExecutionStatus(record: record, task: t, subtasks: allS)
                
                try? ctx.save()
                
                await MainActor.run {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
                }
            } catch {
                print("Toggle subtask background sync failed: \(error)")
            }
        }
    }

    private func startQuickSubtaskCreation() {
        isCreatingSubtask = true
        quickSubtaskFieldFocused = true
    }

    private func cancelQuickSubtaskCreation() {
        isCreatingSubtask = false
        quickSubtaskTitleDraft = ""
    }

    private func saveQuickSubtask() {
        guard let date = currentOccurrenceDate, !quickSubtaskTitleDraft.isEmpty else { return }
        let tid = task.id
        let container = modelContext.container
        let titleDraft = quickSubtaskTitleDraft
        
        Task.detached(priority: .userInitiated) {
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
                title: titleDraft,
                note: "",
                detail: "",
                status: .pending,
                sortOrder: occurrenceS.count
            )
            ctx.insert(newSub)
            
            // 同步状态并存储
            let updatedAllS = allS + [newSub]
            TaskExecutionSupport.syncExecutionStatus(record: record, task: task, subtasks: updatedAllS)
            
            try? ctx.save()
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
            }
        }
        
        quickSubtaskTitleDraft = ""
        isCreatingSubtask = false
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
        let tid = task.id
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
                    NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
                }
            }
        }
        subtaskEditorTarget = nil
    }

    private func deleteSubtask(_ sub: TaskSubitemProjection) {
        let sid = sub.id
        let tid = task.id
        let container = modelContext.container
        
        Task.detached(priority: .utility) {
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.id == sid })
            if let target = (try? ctx.fetch(descriptor))?.first {
                // 如果有关联的执行记录，同步一下状态
                let rid = target.taskExecutionID
                ctx.delete(target)
                
                if let rid {
                    let er = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.id == rid })))?.first
                    let t = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
                    let allS = (try? ctx.fetch(FetchDescriptor<TaskSubitem>(predicate: #Predicate { $0.parentTaskID == tid }))) ?? []
                    if let er, let t {
                        TaskExecutionSupport.syncExecutionStatus(record: er, task: t, subtasks: allS)
                    }
                }
                
                try? ctx.save()
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
                }
            }
        }
    }

    private func toggleOccurrenceCompletion(_ snapshot: TaskOccurrenceSnapshot) {
        guard !isFutureOccurrence(snapshot) else { return }
        
        // 1. 主线程 UI 抢跑：直接修改本地内存快照状态以实现瞬时反馈
        let isReopening = snapshot.isCompleted
        let occurrenceDate = snapshot.occurrenceDate
        
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            // 在内存中移动快照，让用户立刻看到圆圈变色
            var nextPending = occurrenceSnapshotState.pending
            var nextCompleted = occurrenceSnapshotState.completed
            
            if isReopening {
                // 已完成 -> 待处理
                if let idx = nextCompleted.firstIndex(where: { Calendar.current.isDate($0.occurrenceDate, inSameDayAs: occurrenceDate) }) {
                    var item = nextCompleted.remove(at: idx)
                    item.isCompleted = false
                    nextPending.append(item)
                    nextPending.sort { $0.occurrenceDate < $1.occurrenceDate }
                }
            } else {
                // 待处理 -> 已完成
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
        }
        
        let tid = task.id
        let container = modelContext.container
        
        // 2. 将沉重的业务逻辑推到后台执行真正的存盘
        Task.detached(priority: .userInitiated) {
            let ctx = ModelContext(container)
            // ... (后台逻辑保持不变)
            let bgTask = (try? ctx.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == tid })))?.first
            let bgExecutions = (try? ctx.fetch(FetchDescriptor<TaskExecutionRecord>(predicate: #Predicate { $0.taskID == tid }))) ?? []
            
            guard let validTask = bgTask else { return }
            
            if isReopening {
                TaskExecutionSupport.reopenTaskCompletion(task: validTask, occurrenceDate: occurrenceDate, existingExecutions: bgExecutions, modelContext: ctx)
            } else {
                TaskExecutionSupport.markTaskCompleted(task: validTask, occurrenceDate: occurrenceDate, existingExecutions: bgExecutions, modelContext: ctx)
            }
            
            try? ctx.save()
            
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("appDataDidMutate"), object: nil)
            }
        }
    }
}
