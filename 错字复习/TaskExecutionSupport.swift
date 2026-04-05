import Foundation
import SwiftData

enum TodayTaskDisplaySection: Sendable {
    case todayPending
    case historicalPending
    case todayDone
}

struct TaskProjection: Sendable {
    let id: UUID
    let createdAt: Date
    let startDate: Date
    let endDate: Date?
    let recurrence: TaskRecurrence
    let skipPolicy: TaskSkipPolicy

    init(_ task: TaskItem) {
        id = task.id
        createdAt = task.createdAt
        startDate = task.startDate
        endDate = task.endDate
        recurrence = task.recurrence
        skipPolicy = task.skipPolicy
    }

    func originText(for pendingDate: Date, relativeTo date: Date) -> String {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)

        if calendar.isDate(pendingDate, equalTo: targetDay, toGranularity: .year) {
            return "原定 \(pendingDate.formatted(.dateTime.month().day()))"
        }
        return "原定 \(pendingDate.formatted(.dateTime.year().month().day()))"
    }

    func scheduledOccurrenceDates(upTo date: Date) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let unclampedTarget = calendar.startOfDay(for: date)
        let target = min(unclampedTarget, effectiveEndDay ?? unclampedTarget)

        guard target >= start else { return [] }

        switch recurrence.kind {
        case .once:
            return [start]

        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            return (0...days).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: start)
            }

        case .weekly:
            var scheduledDates: [Date] = []
            var checkDate = start
            while checkDate <= target {
                let weekday = calendar.component(.weekday, from: checkDate)
                if recurrence.weekdays.contains(weekday) {
                    scheduledDates.append(checkDate)
                }
                guard let nextDate = calendar.date(byAdding: .day, value: 1, to: checkDate) else {
                    break
                }
                checkDate = nextDate
            }
            return scheduledDates
        }
    }

    private var effectiveEndDay: Date? {
        guard let endDate else { return nil }
        return Calendar.current.startOfDay(for: endDate)
    }
}

struct TaskSubitemProjection: Sendable {
    let parentTaskID: UUID
    let taskExecutionID: UUID?
    let status: TaskExecutionStatus
    let sortOrder: Int
    let createdAt: Date

    init(_ subtask: TaskSubitem) {
        parentTaskID = subtask.parentTaskID
        taskExecutionID = subtask.taskExecutionID
        status = subtask.status
        sortOrder = subtask.sortOrder
        createdAt = subtask.createdAt
    }
}

struct TaskExecutionRecordProjection: Sendable {
    let id: UUID
    let taskID: UUID
    let occurrenceDate: Date
    let status: TaskExecutionStatus

    init(_ record: TaskExecutionRecord) {
        id = record.id
        taskID = record.taskID
        occurrenceDate = record.occurrenceDate
        status = record.status
    }
}

struct TodayTaskProjectionResult: Sendable {
    let taskID: UUID
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int
}

struct TodayTaskDisplayItem: Identifiable, Equatable {
    let task: TaskItem
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    static func == (lhs: TodayTaskDisplayItem, rhs: TodayTaskDisplayItem) -> Bool {
        lhs.task.id == rhs.task.id &&
        lhs.section == rhs.section &&
        lhs.occurrenceDate == rhs.occurrenceDate &&
        lhs.isCompleted == rhs.isCompleted &&
        lhs.pendingOccurrenceCount == rhs.pendingOccurrenceCount &&
        lhs.overdueOriginText == rhs.overdueOriginText &&
        lhs.totalSubtaskCount == rhs.totalSubtaskCount &&
        lhs.completedSubtaskCount == rhs.completedSubtaskCount
    }

    var id: String {
        "\(task.id.uuidString)-\(section)-\(occurrenceDate.timeIntervalSince1970)"
    }

    var hasSubtasks: Bool {
        totalSubtaskCount > 0
    }

    var subtaskProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount) 子任务"
    }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

struct TaskOccurrenceSnapshot: Identifiable {
    let task: TaskItem
    let occurrenceDate: Date
    let isCompleted: Bool
    let overdueOriginText: String?
    let executionRecord: TaskExecutionRecord?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int

    var id: String {
        "\(task.id.uuidString)-\(occurrenceDate.timeIntervalSince1970)-\(isCompleted)"
    }

    var hasSubtasks: Bool {
        totalSubtaskCount > 0
    }

    var subtaskProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount) 子任务"
    }

    var simpleProgressText: String? {
        guard hasSubtasks else { return nil }
        return "\(completedSubtaskCount)/\(totalSubtaskCount)"
    }
}

enum TaskExecutionSupport {
    static func day(for date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func legacyTemplateSubtasks(
        for taskID: UUID,
        in subtasks: [TaskSubitem]
    ) -> [TaskSubitem] {
        subtasks
            .filter {
                $0.parentTaskID == taskID &&
                $0.taskExecutionID == nil &&
                !$0.isArchived
            }
            .sorted(by: sortSubtasks)
    }

    static func executionSubtasks(
        for executionRecord: TaskExecutionRecord?,
        in subtasks: [TaskSubitem]
    ) -> [TaskSubitem] {
        guard let executionRecord else { return [] }
        return subtasks
            .filter {
                $0.taskExecutionID == executionRecord.id &&
                !$0.isArchived
            }
            .sorted(by: sortSubtasks)
    }

    static func executionRecord(
        for taskID: UUID,
        on occurrenceDate: Date,
        in executions: [TaskExecutionRecord]
    ) -> TaskExecutionRecord? {
        let targetDay = day(for: occurrenceDate)
        return executions.first(where: {
            $0.taskID == taskID && Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay)
        })
    }

    static func subtaskProgress(
        for executionRecord: TaskExecutionRecord?,
        in subtasks: [TaskSubitem]
    ) -> (completed: Int, total: Int) {
        let executionSubtasks = executionSubtasks(for: executionRecord, in: subtasks)
        let completed = executionSubtasks.filter { $0.status == .completed }.count
        return (completed, executionSubtasks.count)
    }

    static func isOccurrenceCompleted(
        task: TaskItem,
        occurrenceDate: Date,
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord] = []
    ) -> Bool {
        let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)

        if occurrenceSubtasks.isEmpty {
            return record?.status == .completed
        }

        return occurrenceSubtasks.allSatisfy { $0.status == .completed }
    }

    static func occurrenceSnapshots(
        for task: TaskItem,
        executions: [TaskExecutionRecord],
        subtasks allSubtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TaskOccurrenceSnapshot] {
        let calendar = Calendar.current
        let today = day(for: date)

        return task.scheduledOccurrenceDates(upTo: date).compactMap { occurrenceDate in
            let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
            let completed = isOccurrenceCompleted(
                task: task,
                occurrenceDate: occurrenceDate,
                executions: executions,
                subtasks: allSubtasks,
                subtaskExecutions: subtaskExecutions
            )

            if !completed &&
                task.skipPolicy == .skippable &&
                !calendar.isDate(occurrenceDate, inSameDayAs: today) &&
                record == nil {
                return nil
            }

            let progress = subtaskProgress(
                for: record,
                in: allSubtasks
            )
            let overdueOriginText: String? = {
                guard task.skipPolicy == .unskippable, occurrenceDate < today else { return nil }
                return task.originText(for: occurrenceDate, relativeTo: today)
            }()

            return TaskOccurrenceSnapshot(
                task: task,
                occurrenceDate: occurrenceDate,
                isCompleted: completed,
                overdueOriginText: completed ? nil : overdueOriginText,
                executionRecord: record,
                totalSubtaskCount: progress.total,
                completedSubtaskCount: progress.completed
            )
        }
    }

    static func buildTodayItems(
        from tasks: [TaskItem],
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        let calendar = Calendar.current
        let today = day(for: date)

        return tasks.flatMap { task -> [TodayTaskDisplayItem] in
            let snapshots = occurrenceSnapshots(
                for: task,
                executions: executions,
                subtasks: subtasks,
                subtaskExecutions: subtaskExecutions,
                on: date
            )
            let pendingCount = snapshots.filter { !$0.isCompleted }.count

            return snapshots.compactMap { snapshot -> TodayTaskDisplayItem? in
                let section: TodayTaskDisplaySection
                if snapshot.isCompleted {
                    guard calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) else { return nil }
                    section = .todayDone
                } else if calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) {
                    section = .todayPending
                } else {
                    section = .historicalPending
                }

                return TodayTaskDisplayItem(
                    task: task,
                    section: section,
                    occurrenceDate: snapshot.occurrenceDate,
                    isCompleted: snapshot.isCompleted,
                    pendingOccurrenceCount: pendingCount,
                    overdueOriginText: snapshot.overdueOriginText,
                    totalSubtaskCount: snapshot.totalSubtaskCount,
                    completedSubtaskCount: snapshot.completedSubtaskCount
                )
            }
        }
    }

    static func ensureExecutionRecord(
        for task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) -> TaskExecutionRecord {
        if let record = executionRecord(for: task.id, on: occurrenceDate, in: existingExecutions) {
            return record
        }

        let record = TaskExecutionRecord(
            taskID: task.id,
            occurrenceDate: day(for: occurrenceDate)
        )
        modelContext.insert(record)
        return record
    }

    static func syncExecutionStatus(
        record: TaskExecutionRecord,
        task: TaskItem,
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord] = []
    ) {
        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)
        if occurrenceSubtasks.isEmpty {
            if record.status == .completed {
                record.completedAt = record.completedAt ?? .now
            }
        } else if occurrenceSubtasks.allSatisfy({ $0.status == .completed }) {
            record.status = .completed
            record.completedAt = record.completedAt ?? .now
            if task.recurrence.kind == .once {
                task.isArchived = true
            }
        } else {
            record.status = .pending
            record.completedAt = nil
            if task.recurrence.kind == .once {
                task.isArchived = false
            }
        }
        record.updatedAt = .now
    }

    static func markTaskCompleted(
        task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) {
        let record = ensureExecutionRecord(
            for: task,
            occurrenceDate: occurrenceDate,
            existingExecutions: existingExecutions,
            modelContext: modelContext
        )
        record.status = .completed
        record.completedAt = .now
        record.updatedAt = .now

        if task.recurrence.kind == .once {
            task.isArchived = true
        }
    }

    static func reopenTaskCompletion(
        task: TaskItem,
        occurrenceDate: Date,
        existingExecutions: [TaskExecutionRecord],
        modelContext: ModelContext
    ) {
        guard let record = executionRecord(for: task.id, on: occurrenceDate, in: existingExecutions) else {
            return
        }

        let isToday = Calendar.current.isDate(occurrenceDate, inSameDayAs: .now)
        if record.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isToday {
            modelContext.delete(record)
        } else {
            record.status = .pending
            record.completedAt = nil
            record.updatedAt = .now
        }

        if task.recurrence.kind == .once {
            task.isArchived = false
        }
    }

    static func targetMigrationOccurrenceDate(
        for task: TaskItem,
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        referenceDate: Date = .now
    ) -> Date {
        let today = day(for: referenceDate)
        let scheduledUpToToday = task.scheduledOccurrenceDates(upTo: referenceDate)
        if let firstPending = scheduledUpToToday.first(where: {
            !isOccurrenceCompleted(
                task: task,
                occurrenceDate: $0,
                executions: executions,
                subtasks: subtasks
            )
        }) {
            return firstPending
        }

        let calendar = Calendar.current
        if let lookahead = calendar.date(byAdding: .day, value: 7, to: today) {
            if let nextFuture = task.scheduledOccurrenceDates(upTo: lookahead).first(where: { $0 > today }) {
                return nextFuture
            }
        }

        return scheduledUpToToday.last ?? day(for: task.startDate)
    }

    static func migrateLegacySubtasksIfNeeded(in modelContext: ModelContext) {
        let allSubtasks = (try? modelContext.fetch(FetchDescriptor<TaskSubitem>())) ?? []
        let legacySubtasks = allSubtasks.filter { $0.taskExecutionID == nil }
        guard !legacySubtasks.isEmpty else { return }

        let tasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
        let allExecutions = (try? modelContext.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? []
        let legacyExecutionRecords = (try? modelContext.fetch(FetchDescriptor<TaskSubitemExecutionRecord>())) ?? []

        let tasksByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let legacySubtasksByID = Dictionary(legacySubtasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let executionsByTask = Dictionary(grouping: allExecutions, by: \.taskID)

        var allKnownSubtasks = allSubtasks

        for legacyExecution in legacyExecutionRecords {
            guard
                let template = legacySubtasksByID[legacyExecution.subtaskID],
                let task = tasksByID[template.parentTaskID],
                let executionRecord = allExecutions.first(where: { $0.id == legacyExecution.taskExecutionID })
            else {
                continue
            }

            let exists = allKnownSubtasks.contains {
                $0.taskExecutionID == executionRecord.id &&
                $0.title == template.title &&
                $0.sortOrder == template.sortOrder
            }
            guard !exists else { continue }

            let migrated = TaskSubitem(
                parentTaskID: task.id,
                taskExecutionID: executionRecord.id,
                title: template.title,
                note: template.note,
                detail: legacyExecution.detail,
                status: legacyExecution.status,
                sortOrder: template.sortOrder,
                isArchived: false,
                completedAt: legacyExecution.completedAt,
                createdAt: legacyExecution.createdAt,
                updatedAt: legacyExecution.updatedAt
            )
            modelContext.insert(migrated)
            allKnownSubtasks.append(migrated)
        }

        let legacyTemplatesByTask = Dictionary(grouping: legacySubtasks, by: \.parentTaskID)
        var executionPool = allExecutions

        for (taskID, templates) in legacyTemplatesByTask {
            guard let task = tasksByID[taskID] else { continue }

            let targetDate = targetMigrationOccurrenceDate(
                for: task,
                executions: executionsByTask[taskID] ?? executionPool.filter { $0.taskID == taskID },
                subtasks: allKnownSubtasks
            )
            let executionRecord = ensureExecutionRecord(
                for: task,
                occurrenceDate: targetDate,
                existingExecutions: executionPool,
                modelContext: modelContext
            )
            if !executionPool.contains(where: { $0.id == executionRecord.id }) {
                executionPool.append(executionRecord)
            }

            for template in templates {
                let exists = allKnownSubtasks.contains {
                    $0.taskExecutionID == executionRecord.id &&
                    $0.title == template.title &&
                    $0.sortOrder == template.sortOrder
                }
                guard !exists else { continue }

                let migrated = TaskSubitem(
                    parentTaskID: task.id,
                    taskExecutionID: executionRecord.id,
                    title: template.title,
                    note: template.note,
                    detail: template.detail,
                    status: template.status,
                    sortOrder: template.sortOrder,
                    isArchived: false,
                    completedAt: template.completedAt,
                    createdAt: template.createdAt,
                    updatedAt: template.updatedAt
                )
                modelContext.insert(migrated)
                allKnownSubtasks.append(migrated)
            }
        }

        legacyExecutionRecords.forEach(modelContext.delete)
        legacySubtasks.forEach(modelContext.delete)

        if modelContext.hasChanges {
            try? modelContext.save()
        }
    }

    private static func sortSubtasks(_ lhs: TaskSubitem, _ rhs: TaskSubitem) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}

enum TodayTaskListBuilder {
    static func build(
        from tasks: [TaskItem],
        completions: [TaskCompletion],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        let migratedExecutions = completions.map { completion in
            TaskExecutionRecord(
                id: completion.id,
                taskID: completion.taskID,
                occurrenceDate: completion.completedDate,
                detail: "",
                status: .completed,
                completedAt: completion.completedAt,
                createdAt: completion.completedAt,
                updatedAt: completion.completedAt
            )
        }
        return build(
            from: tasks,
            executions: migratedExecutions,
            subtasks: [],
            subtaskExecutions: [],
            on: date
        )
    }

    static func build(
        from tasks: [TaskItem],
        executions: [TaskExecutionRecord],
        subtasks: [TaskSubitem],
        subtaskExecutions: [TaskSubitemExecutionRecord],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        TaskExecutionSupport.buildTodayItems(
            from: tasks,
            executions: executions,
            subtasks: subtasks,
            subtaskExecutions: subtaskExecutions,
            on: date
        )
    }
}

enum TodayTaskProjectionBuilder {
    static func build(
        from tasks: [TaskProjection],
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        on date: Date = .now
    ) -> [TodayTaskProjectionResult] {
        let calendar = Calendar.current
        let today = Calendar.current.startOfDay(for: date)

        return tasks.flatMap { task -> [TodayTaskProjectionResult] in
            let snapshots = occurrenceSnapshots(
                for: task,
                executions: executions,
                subtasks: subtasks,
                on: date
            )
            let pendingCount = snapshots.filter { !$0.isCompleted }.count

            return snapshots.compactMap { snapshot in
                let section: TodayTaskDisplaySection
                if snapshot.isCompleted {
                    guard calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) else { return nil }
                    section = .todayDone
                } else if calendar.isDate(snapshot.occurrenceDate, inSameDayAs: today) {
                    section = .todayPending
                } else {
                    section = .historicalPending
                }

                return TodayTaskProjectionResult(
                    taskID: task.id,
                    section: section,
                    occurrenceDate: snapshot.occurrenceDate,
                    isCompleted: snapshot.isCompleted,
                    pendingOccurrenceCount: pendingCount,
                    overdueOriginText: snapshot.overdueOriginText,
                    totalSubtaskCount: snapshot.totalSubtaskCount,
                    completedSubtaskCount: snapshot.completedSubtaskCount
                )
            }
        }
    }

    static func displayItems(
        from projections: [TodayTaskProjectionResult],
        tasksByID: [UUID: TaskItem]
    ) -> [TodayTaskDisplayItem] {
        projections.compactMap { projection in
            guard let task = tasksByID[projection.taskID] else { return nil }
            return TodayTaskDisplayItem(
                task: task,
                section: projection.section,
                occurrenceDate: projection.occurrenceDate,
                isCompleted: projection.isCompleted,
                pendingOccurrenceCount: projection.pendingOccurrenceCount,
                overdueOriginText: projection.overdueOriginText,
                totalSubtaskCount: projection.totalSubtaskCount,
                completedSubtaskCount: projection.completedSubtaskCount
            )
        }
    }

    private static func occurrenceSnapshots(
        for task: TaskProjection,
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection],
        on date: Date = .now
    ) -> [ProjectedTaskOccurrenceSnapshot] {
        let calendar = Calendar.current
        let today = Calendar.current.startOfDay(for: date)

        return task.scheduledOccurrenceDates(upTo: date).compactMap { occurrenceDate in
            let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
            let completed = isOccurrenceCompleted(
                task: task,
                occurrenceDate: occurrenceDate,
                executions: executions,
                subtasks: subtasks
            )

            if !completed &&
                task.skipPolicy == .skippable &&
                !calendar.isDate(occurrenceDate, inSameDayAs: today) &&
                record == nil {
                return nil
            }

            let progress = subtaskProgress(
                for: record,
                in: subtasks
            )
            let overdueOriginText: String? = {
                guard task.skipPolicy == .unskippable, occurrenceDate < today else { return nil }
                return task.originText(for: occurrenceDate, relativeTo: today)
            }()

            return ProjectedTaskOccurrenceSnapshot(
                taskID: task.id,
                createdAt: task.createdAt,
                occurrenceDate: occurrenceDate,
                isCompleted: completed,
                overdueOriginText: completed ? nil : overdueOriginText,
                totalSubtaskCount: progress.total,
                completedSubtaskCount: progress.completed
            )
        }
    }

    private static func executionRecord(
        for taskID: UUID,
        on occurrenceDate: Date,
        in executions: [TaskExecutionRecordProjection]
    ) -> TaskExecutionRecordProjection? {
        let targetDay = Calendar.current.startOfDay(for: occurrenceDate)
        return executions.first(where: {
            $0.taskID == taskID && Calendar.current.isDate($0.occurrenceDate, inSameDayAs: targetDay)
        })
    }

    private static func isOccurrenceCompleted(
        task: TaskProjection,
        occurrenceDate: Date,
        executions: [TaskExecutionRecordProjection],
        subtasks: [TaskSubitemProjection]
    ) -> Bool {
        let record = executionRecord(for: task.id, on: occurrenceDate, in: executions)
        let occurrenceSubtasks = executionSubtasks(for: record, in: subtasks)

        if occurrenceSubtasks.isEmpty {
            return record?.status == .completed
        }

        return occurrenceSubtasks.allSatisfy { $0.status == .completed }
    }

    private static func executionSubtasks(
        for executionRecord: TaskExecutionRecordProjection?,
        in subtasks: [TaskSubitemProjection]
    ) -> [TaskSubitemProjection] {
        guard let executionRecord else { return [] }
        return subtasks
            .filter { $0.taskExecutionID == executionRecord.id }
            .sorted(by: sortSubtasks)
    }

    private static func subtaskProgress(
        for executionRecord: TaskExecutionRecordProjection?,
        in subtasks: [TaskSubitemProjection]
    ) -> (completed: Int, total: Int) {
        let executionSubtasks = executionSubtasks(for: executionRecord, in: subtasks)
        let completed = executionSubtasks.filter { $0.status == .completed }.count
        return (completed, executionSubtasks.count)
    }

    private static func sortSubtasks(_ lhs: TaskSubitemProjection, _ rhs: TaskSubitemProjection) -> Bool {
        if lhs.sortOrder == rhs.sortOrder {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.sortOrder < rhs.sortOrder
    }
}

private struct ProjectedTaskOccurrenceSnapshot {
    let taskID: UUID
    let createdAt: Date
    let occurrenceDate: Date
    let isCompleted: Bool
    let overdueOriginText: String?
    let totalSubtaskCount: Int
    let completedSubtaskCount: Int
}
