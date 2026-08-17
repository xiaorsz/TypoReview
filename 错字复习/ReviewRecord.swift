import Foundation
import SwiftData

@Model
final class ReviewRecord {
    static let detailNotePrefix = "__detail__:"
    static let confirmedDetailNotePrefix = "__confirmed_detail__:"

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

    var isExplicitlyConfirmedSubmission: Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(Self.confirmedDetailNotePrefix)
    }

    func markAsExplicitlyConfirmedSubmission() {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNote.hasPrefix(Self.confirmedDetailNotePrefix) else { return }

        let detail: String
        if trimmedNote.hasPrefix(Self.detailNotePrefix) {
            detail = String(trimmedNote.dropFirst(Self.detailNotePrefix.count))
        } else {
            detail = trimmedNote
        }
        note = Self.confirmedDetailNotePrefix + detail
    }

    static func canonicalRecords(_ records: [ReviewRecord]) -> [ReviewRecord] {
        Dictionary(grouping: records, by: \.itemID).values
            .flatMap { itemRecords -> [ReviewRecord] in
                let ordered = itemRecords.sorted {
                    if $0.reviewedAt != $1.reviewedAt {
                        return $0.reviewedAt < $1.reviewedAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                }
                var seenCycleIDs = Set<UUID>()
                var resolvedStage: Int?
                var result: [ReviewRecord] = []

                for record in ordered {
                    guard seenCycleIDs.insert(record.id).inserted else { continue }

                    if let resolvedStage,
                       record.result == .correct,
                       record.oldStage < resolvedStage,
                       record.newStage <= resolvedStage,
                       !record.isExplicitlyConfirmedSubmission {
                        continue
                    }

                    result.append(record)
                    resolvedStage = record.newStage
                }

                return result
            }
            .sorted {
                if $0.reviewedAt != $1.reviewedAt {
                    return $0.reviewedAt > $1.reviewedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
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

    /// Makes independently-created plans converge after CloudKit delivers today's
    /// review records. Completed items take precedence over a stale local plan, so
    /// another device cannot schedule a second batch after the daily quota is done.
    static func reconciledItemIDs(
        existingItemIDs: [UUID],
        reviewedTodayItemIDs: [UUID],
        availableDueItemIDs: [UUID],
        dailyLimit: Int
    ) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        let reviewedTodaySet = Set(reviewedTodayItemIDs)
        let availableDueSet = Set(availableDueItemIDs)
        let uniqueReviewedCount = reviewedTodaySet.count
        let targetCount = max(max(dailyLimit, 0), uniqueReviewedCount)

        func appendUntilFull(_ itemIDs: [UUID]) {
            guard result.count < targetCount else { return }
            for itemID in itemIDs where seen.insert(itemID).inserted {
                result.append(itemID)
                if result.count >= targetCount { return }
            }
        }

        appendUntilFull(reviewedTodayItemIDs)
        // A plan may be created before an incremental pull updates ReviewItem
        // state. Keep completed-today entries for quota accounting and still-due
        // entries for continuity, but discard stale IDs so newly due work can fill
        // the vacated slots.
        appendUntilFull(existingItemIDs.filter {
            reviewedTodaySet.contains($0) || availableDueSet.contains($0)
        })
        appendUntilFull(availableDueItemIDs)
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
