import Foundation
import SwiftData

@Model
final class TaskItem {
    var id: UUID = UUID()
    var title: String = ""
    var note: String = ""
    var recurrenceJSON: String = "{}"
    var skipPolicyRawValue: String = "可跳过"
    var startDate: Date = Date()
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
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var recurrence: TaskRecurrence {
        get { TaskRecurrence.fromJSON(recurrenceJSON) }
        set { recurrenceJSON = newValue.toJSON() }
    }

    var skipPolicy: TaskSkipPolicy {
        get { TaskSkipPolicy(rawValue: skipPolicyRawValue) ?? .skippable }
        set { skipPolicyRawValue = newValue.rawValue }
    }

    // MARK: - Today Logic

    /// Whether this task should appear on a given date.
    func shouldAppear(on date: Date, completions: [TaskCompletion]) -> Bool {
        guard !isArchived else { return false }

        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        let start = calendar.startOfDay(for: startDate)

        guard targetDay >= start else { return false }

        // Already completed for this date?
        let alreadyDone = completions.contains {
            $0.taskID == id && calendar.isDate($0.completedDate, inSameDayAs: date)
        }
        if alreadyDone { return false }

        switch recurrence.kind {
        case .once:
            // Single task: show on startDate. If unskippable and not done, keep showing.
            let anyDone = completions.contains { $0.taskID == id }
            if anyDone { return false }
            if calendar.isDate(targetDay, inSameDayAs: start) {
                return true
            }
            // Past start date
            return skipPolicy == .unskippable

        case .daily:
            // Daily: always appears
            return true

        case .weekly:
            let weekday = calendar.component(.weekday, from: date)
            if recurrence.weekdays.contains(weekday) {
                return true
            }
            // Check if there are overdue undone days for unskippable
            if skipPolicy == .unskippable {
                return hasOverdueOccurrence(before: date, completions: completions)
            }
            return false
        }
    }

    /// For weekly unskippable: check if any past scheduled weekday was missed.
    private func hasOverdueOccurrence(before date: Date, completions: [TaskCompletion]) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let target = calendar.startOfDay(for: date)

        // Look back up to 30 days
        var checkDate = calendar.date(byAdding: .day, value: -1, to: target)!
        let limit = calendar.date(byAdding: .day, value: -30, to: target)!

        while checkDate >= start && checkDate >= limit {
            let wd = calendar.component(.weekday, from: checkDate)
            if recurrence.weekdays.contains(wd) {
                let wasDone = completions.contains {
                    $0.taskID == id && calendar.isDate($0.completedDate, inSameDayAs: checkDate)
                }
                if !wasDone {
                    return true
                }
            }
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }
        return false
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
}
