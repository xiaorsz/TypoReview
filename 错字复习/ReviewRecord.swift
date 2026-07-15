import Foundation
import SwiftData

@Model
final class ReviewRecord {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var reviewedAt: Date = Date()
    var resultRawValue: String = ReviewResult.correct.rawValue
    var modeRawValue: String = ReviewMode.scheduled.rawValue
    var oldStage: Int = 0
    var newStage: Int = 0
    var note: String = ""

    init(
        id: UUID = UUID(),
        itemID: UUID,
        reviewedAt: Date = .now,
        result: ReviewResult,
        mode: ReviewMode,
        oldStage: Int,
        newStage: Int,
        note: String = ""
    ) {
        self.id = id
        self.itemID = itemID
        self.reviewedAt = reviewedAt
        self.resultRawValue = result.rawValue
        self.modeRawValue = mode.rawValue
        self.oldStage = oldStage
        self.newStage = newStage
        self.note = note
    }

    var result: ReviewResult {
        get { ReviewResult(rawValue: resultRawValue) ?? .correct }
        set { resultRawValue = newValue.rawValue }
    }

    var mode: ReviewMode {
        get { ReviewMode(rawValue: modeRawValue) ?? .scheduled }
        set { modeRawValue = newValue.rawValue }
    }
}

@Model
final class ReviewDailyPlan {
    var id: UUID = UUID()
    var dayKey: String = ""
    var itemIDsRawValue: String = "[]"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        dayKey: String,
        itemIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.dayKey = dayKey
        self.itemIDsRawValue = Self.encodeItemIDs(itemIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var itemIDs: [UUID] {
        get { Self.decodeItemIDs(itemIDsRawValue) }
        set {
            itemIDsRawValue = Self.encodeItemIDs(newValue)
            updatedAt = .now
        }
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func preferred(from plans: [ReviewDailyPlan]) -> ReviewDailyPlan? {
        plans.min { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    static func expandedItemIDs(
        existingItemIDs: [UUID],
        availableDueItemIDs: [UUID],
        dailyLimit: Int
    ) -> [UUID] {
        var seen = Set<UUID>()
        var result = existingItemIDs.filter { seen.insert($0).inserted }
        let targetCount = max(dailyLimit, 0)

        guard result.count < targetCount else { return result }

        for itemID in availableDueItemIDs where seen.insert(itemID).inserted {
            result.append(itemID)
            if result.count >= targetCount {
                break
            }
        }

        return result
    }

    private static func encodeItemIDs(_ ids: [UUID]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    private static func decodeItemIDs(_ value: String) -> [UUID] {
        guard let data = value.data(using: .utf8),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return ids
    }
}
