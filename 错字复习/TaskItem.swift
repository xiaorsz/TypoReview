import Foundation
import SwiftData

@Model
final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var recurrenceJSON: String?
    var skipPolicyRawValue: String?
    var startDate: Date = Date()
    var endDate: Date?
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        recurrence: TaskRecurrence = .once,
        skipPolicy: TaskSkipPolicy = .skippable,
        startDate: Date = .now,
        endDate: Date? = nil,
        isArchived: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.recurrenceJSON = recurrence.toJSON()
        self.skipPolicyRawValue = skipPolicy.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var recurrence: TaskRecurrence {
        get {
            guard let json = recurrenceJSON else { return .once }
            return TaskRecurrence.fromJSON(json)
        }
        set { recurrenceJSON = newValue.toJSON() }
    }

    var skipPolicy: TaskSkipPolicy {
        get {
            guard let raw = skipPolicyRawValue else { return .skippable }
            return TaskSkipPolicy(rawValue: raw) ?? .skippable
        }
        set { skipPolicyRawValue = newValue.rawValue }
    }

    // MARK: - Today Logic

    /// Whether this task should appear on a given date.
    func shouldAppear(on date: Date, taskCompletions: [TaskCompletion]) -> Bool {
        guard !isArchived else { return false }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)
        let effectiveEndDay = endDate.map { calendar.startOfDay(for: $0) }

        guard targetDay >= start else { return false }
        if let effectiveEndDay, targetDay > effectiveEndDay { return false }
        let completionsToday = completionCount(on: date, taskCompletions: taskCompletions)

        switch recurrence.kind {
        case .once:
            if skipPolicy == .unskippable {
                return pendingOccurrenceCount(on: date, taskCompletions: taskCompletions) > 0
            }

            let anyDone = !taskCompletions.isEmpty
            return !anyDone && calendar.isDate(targetDay, inSameDayAs: start)

        case .daily:
            if skipPolicy == .unskippable {
                return pendingOccurrenceCount(on: date, taskCompletions: taskCompletions) > 0
            }
            return completionsToday == 0

        case .weekly:
            if skipPolicy == .unskippable {
                return pendingOccurrenceCount(on: date, taskCompletions: taskCompletions) > 0
            }

            let weekday = calendar.component(.weekday, from: date)
            return recurrence.weekdays.contains(weekday) && completionsToday == 0
        }
    }

    func isCompletedToday(taskCompletions: [TaskCompletion]) -> Bool {
        isCompleted(on: .now, taskCompletions: taskCompletions)
    }

    func isCompleted(on date: Date, taskCompletions: [TaskCompletion]) -> Bool {
        let completionsToday = completionCount(on: date, taskCompletions: taskCompletions)
        guard completionsToday > 0 else { return false }

        if skipPolicy == .unskippable {
            return pendingOccurrenceCount(on: date, taskCompletions: taskCompletions) == 0
        }

        return true
    }

    func pendingOccurrenceCount(on date: Date, taskCompletions: [TaskCompletion]) -> Int {
        let scheduledCount = scheduledOccurrenceCount(upTo: date)
        let completionCount = completionCount(upTo: date, taskCompletions: taskCompletions)
        return max(0, scheduledCount - completionCount)
    }

    func pendingOccurrenceDates(on date: Date, taskCompletions: [TaskCompletion]) -> [Date] {
        let scheduledDates = scheduledOccurrenceDates(upTo: date)
        let completedCount = min(completionCount(upTo: date, taskCompletions: taskCompletions), scheduledDates.count)
        return Array(scheduledDates.dropFirst(completedCount))
    }

    func earliestPendingOccurrence(on date: Date, taskCompletions: [TaskCompletion]) -> Date? {
        pendingOccurrenceDates(on: date, taskCompletions: taskCompletions).first
    }

    func overdueOriginText(on date: Date, taskCompletions: [TaskCompletion]) -> String? {
        guard skipPolicy == .unskippable else { return nil }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        guard let pendingDate = earliestPendingOccurrence(on: date, taskCompletions: taskCompletions),
              pendingDate < targetDay else {
            return nil
        }

        return originText(for: pendingDate, relativeTo: targetDay)
    }

    func originText(for pendingDate: Date, relativeTo date: Date) -> String {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)

        if calendar.isDate(pendingDate, equalTo: targetDay, toGranularity: .year) {
            return "原定 \(pendingDate.formatted(.dateTime.month().day()))"
        }
        return "原定 \(pendingDate.formatted(.dateTime.year().month().day()))"
    }

    private func scheduledOccurrenceCount(upTo date: Date) -> Int {
        scheduledOccurrenceDates(upTo: date).count
    }

    private func scheduledOccurrenceDates(upTo date: Date) -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let unclampedTarget = calendar.startOfDay(for: date)
        let target = min(unclampedTarget, self.effectiveEndDay ?? unclampedTarget)

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

    private func completionCount(upTo date: Date, taskCompletions: [TaskCompletion]) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let unclampedTarget = calendar.startOfDay(for: date)
        let target = min(unclampedTarget, effectiveEndDay ?? unclampedTarget)

        guard target >= start else { return 0 }

        return taskCompletions.filter { completion in
            let completionDay = calendar.startOfDay(for: completion.completedDate)
            return completionDay >= start && completionDay <= target
        }.count
    }

    private func completionCount(on date: Date, taskCompletions: [TaskCompletion]) -> Int {
        let calendar = Calendar.current
        return taskCompletions.filter {
            calendar.isDate($0.completedDate, inSameDayAs: date)
        }.count
    }

    // MARK: - Display Helpers

    var recurrenceLabel: String {
        switch recurrence.kind {
        case .once:
            return "单次"
        case .daily:
            return "每天"
        case .weekly:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            let days = recurrence.weekdays.sorted().compactMap { wd -> String? in
                guard wd >= 1, wd <= 7 else { return nil }
                return "周\(names[wd - 1])"
            }
            return "每周 \(days.joined(separator: "、"))"
        }
    }

    var effectiveDateRangeLabel: String? {
        guard recurrence.kind != .once, let effectiveEndDay else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        if calendar.isDate(startDay, equalTo: effectiveEndDay, toGranularity: .year) {
            return "\(startDay.formatted(.dateTime.month().day())) - \(effectiveEndDay.formatted(.dateTime.month().day()))"
        }
        return "\(startDay.formatted(.dateTime.year().month().day())) - \(effectiveEndDay.formatted(.dateTime.year().month().day()))"
    }

    private var effectiveEndDay: Date? {
        guard let endDate else { return nil }
        return Calendar.current.startOfDay(for: endDate)
    }
}

enum TodayTaskDisplaySection {
    case todayPending
    case historicalPending
    case todayDone
}

struct TodayTaskDisplayItem: Identifiable {
    let task: TaskItem
    let section: TodayTaskDisplaySection
    let occurrenceDate: Date
    let isCompleted: Bool
    let pendingOccurrenceCount: Int
    let overdueOriginText: String?

    var id: String {
        "\(task.id.uuidString)-\(section)-\(occurrenceDate.timeIntervalSince1970)"
    }
}

enum TodayTaskListBuilder {
    static func build(
        from tasks: [TaskItem],
        completions: [TaskCompletion],
        on date: Date = .now
    ) -> [TodayTaskDisplayItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        
        // Optimize: Group completions by taskID once
        let completionMap = Dictionary(grouping: completions, by: { $0.taskID })

        return tasks.flatMap { task -> [TodayTaskDisplayItem] in
            let taskCompletions = completionMap[task.id] ?? []
            
            if task.skipPolicy == .unskippable {
                var items = task.pendingOccurrenceDates(on: date, taskCompletions: taskCompletions).map { pendingDate in
                    let isToday = calendar.isDate(pendingDate, inSameDayAs: today)
                    return TodayTaskDisplayItem(
                        task: task,
                        section: isToday ? .todayPending : .historicalPending,
                        occurrenceDate: pendingDate,
                        isCompleted: false,
                        pendingOccurrenceCount: task.pendingOccurrenceCount(on: date, taskCompletions: taskCompletions),
                        overdueOriginText: isToday ? nil : task.originText(for: pendingDate, relativeTo: today)
                    )
                }

                if task.isCompleted(on: date, taskCompletions: taskCompletions) {
                    items.append(
                        TodayTaskDisplayItem(
                            task: task,
                            section: .todayDone,
                            occurrenceDate: today,
                            isCompleted: true,
                            pendingOccurrenceCount: 0,
                            overdueOriginText: nil
                        )
                    )
                }

                return items
            }

            let isCompleted = task.isCompleted(on: date, taskCompletions: taskCompletions)
            let shouldAppear = task.shouldAppear(on: date, taskCompletions: taskCompletions)
            guard shouldAppear || isCompleted else { return [] }

            return [
                TodayTaskDisplayItem(
                    task: task,
                    section: isCompleted ? .todayDone : .todayPending,
                    occurrenceDate: today,
                    isCompleted: isCompleted,
                    pendingOccurrenceCount: task.pendingOccurrenceCount(on: date, taskCompletions: taskCompletions),
                    overdueOriginText: task.overdueOriginText(on: date, taskCompletions: taskCompletions)
                )
            ]
        }
    }
}
