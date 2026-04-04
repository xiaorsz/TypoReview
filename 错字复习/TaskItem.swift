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

    var effectiveEndDay: Date? {
        guard let endDate else { return nil }
        return Calendar.current.startOfDay(for: endDate)
    }
}
