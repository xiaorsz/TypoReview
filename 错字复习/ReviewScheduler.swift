import Foundation
import SwiftData

struct ReviewScheduler {
    static let intervals: [Int] = [
        0,
        1,
        2,
        4,
        7,
        15,
        30
    ]
    static let dictationFollowUpCompleteStage = 6
    static let completionStage = 7

    func nextDate(for stage: Int, from date: Date = .now) -> Date {
        let safeStage = max(0, min(stage, Self.intervals.count - 1))
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: Self.intervals[safeStage], to: date) ?? date
        return Self.normalizedReviewDate(target, calendar: calendar)
    }

    func nextDayStart(from date: Date = .now) -> Date {
        dayStart(after: 1, from: date)
    }

    func dayStart(after days: Int, from date: Date = .now) -> Date {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return calendar.startOfDay(for: target)
    }

    static func normalizedReviewDate(_ date: Date, calendar: Calendar = .current) -> Date {
        guard date != .distantFuture else { return date }
        return calendar.startOfDay(for: date)
    }

    static func isDue(_ nextReviewAt: Date, on referenceDate: Date = .now, calendar: Calendar = .current) -> Bool {
        guard nextReviewAt != .distantFuture else { return false }
        return normalizedReviewDate(nextReviewAt, calendar: calendar) <= calendar.startOfDay(for: referenceDate)
    }

    static func isMastered(stage: Int, consecutiveWrongCount: Int) -> Bool {
        stage >= completionStage && consecutiveWrongCount == 0
    }

    @discardableResult
    static func normalizeStoredReviewDates(in modelContext: ModelContext, calendar: Calendar = .current) throws -> Int {
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        var normalizedCount = 0

        for item in items {
            let normalizedDate = normalizedReviewDate(item.nextReviewAt, calendar: calendar)
            guard item.nextReviewAt != normalizedDate else { continue }
            item.nextReviewAt = normalizedDate
            normalizedCount += 1
        }

        return normalizedCount
    }

    @discardableResult
    static func migrateLegacyStageSevenCaps(in modelContext: ModelContext) throws -> Int {
        let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        let itemsByID = Dictionary(grouping: items, by: \.id)
            .compactMapValues { ReviewContentIdentity.preferredReviewItem(from: $0) }
        let latestRecordDateByItemID = Dictionary(
            records.map { ($0.itemID, $0.reviewedAt) },
            uniquingKeysWith: max
        )
        var latestMigratedRecordDateByItemID: [UUID: Date] = [:]
        var migratedCount = 0

        for record in records {
            guard record.result == .correct,
                  record.newStage >= completionStage || (
                    record.newStage == dictationFollowUpCompleteStage &&
                    record.note.contains("已完成所有复习")
                  ),
                  !record.note.contains("听写跟进") else {
                continue
            }

            record.newStage = completionStage
            if record.note.hasPrefix("__detail__:") {
                record.note = "__detail__:已完成所有复习，当前标记为已掌握"
            }
            latestMigratedRecordDateByItemID[record.itemID] = max(
                latestMigratedRecordDateByItemID[record.itemID] ?? .distantPast,
                record.reviewedAt
            )
            migratedCount += 1
        }

        for item in items where item.reviewTrack == .standard && item.consecutiveWrongCount == 0 {
            if item.stage >= completionStage {
                if item.nextReviewAt != .distantFuture {
                    item.nextReviewAt = .distantFuture
                    item.updatedAt = .now
                    migratedCount += 1
                }
            } else if item.stage == dictationFollowUpCompleteStage,
                      item.nextReviewAt == .distantFuture {
                item.stage = completionStage
                item.updatedAt = .now
                migratedCount += 1
            }
        }

        for (itemID, migratedRecordDate) in latestMigratedRecordDateByItemID {
            guard latestRecordDateByItemID[itemID] == migratedRecordDate,
                  let item = itemsByID[itemID],
                  item.stage == completionStage,
                  item.consecutiveWrongCount == 0 else {
                continue
            }

            item.stage = completionStage
            item.nextReviewAt = .distantFuture
            item.reviewTrack = .standard
            item.dictationFollowUpStep = 0
            item.isDictationPass = false
            item.updatedAt = .now
            migratedCount += 1
        }

        return migratedCount
    }

    @discardableResult
    static func deduplicateReviewItems(in modelContext: ModelContext) throws -> Int {
        let items = try modelContext.fetch(FetchDescriptor<ReviewItem>())
        let records = try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        let recordsByItemID = Dictionary(grouping: records, by: \.itemID)
        let groupedItems = Dictionary(grouping: items) { item in
            ReviewContentIdentity.key(for: item)
        }
        var changedCount = 0

        for (key, duplicateItems) in groupedItems {
            let normalizedContent = key.components(separatedBy: "|").last ?? ""
            guard !normalizedContent.isEmpty, duplicateItems.count > 1,
                  let canonical = ReviewContentIdentity.preferredReviewItem(from: duplicateItems) else {
                continue
            }

            for duplicate in duplicateItems where duplicate.persistentModelID != canonical.persistentModelID {
                mergeReviewItem(duplicate, into: canonical)

                for record in recordsByItemID[duplicate.id, default: []] {
                    record.itemID = canonical.id
                    changedCount += 1
                }

                modelContext.delete(duplicate)
                changedCount += 1
            }
        }

        return changedCount
    }

    private static func mergeReviewItem(_ duplicate: ReviewItem, into canonical: ReviewItem) {
        if canonical.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.prompt = duplicate.prompt
        }
        if canonical.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.note = duplicate.note
        }
        if canonical.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            canonical.source = duplicate.source
        }

        canonical.createdAt = min(canonical.createdAt, duplicate.createdAt)
        canonical.updatedAt = max(canonical.updatedAt, duplicate.updatedAt)
        switch (canonical.lastReviewedAt, duplicate.lastReviewedAt) {
        case let (current?, incoming?):
            canonical.lastReviewedAt = max(current, incoming)
        case (nil, let incoming?):
            canonical.lastReviewedAt = incoming
        default:
            break
        }
    }

    func dictationFollowUpDate(for step: Int, from date: Date = .now) -> Date {
        switch step {
        case 1:
            return dayStart(after: 3, from: date)
        default:
            return dayStart(after: 7, from: date)
        }
    }

    func handle(
        item: ReviewItem,
        result: ReviewResult,
        mode: ReviewMode = .scheduled,
        now: Date = .now
    ) -> (item: ReviewItem, record: ReviewRecord) {
        let oldStage = item.stage
        item.lastReviewedAt = now
        item.updatedAt = now

        if item.reviewTrack == .dictationFollowUp || item.isDictationPass {
            let currentStep = item.resolvedDictationFollowUpStep
            if result == .correct {
                item.consecutiveCorrectCount += 1
                item.consecutiveWrongCount = 0
                item.isPriority = false

                if currentStep <= 1 {
                    item.reviewTrack = .dictationFollowUp
                    item.dictationFollowUpStep = 2
                    item.isDictationPass = true
                    item.stage = max(item.stage, 2)
                    item.nextReviewAt = dictationFollowUpDate(for: 2, from: now)
                } else {
                    item.stage = max(item.stage, Self.dictationFollowUpCompleteStage)
                    item.reviewTrack = .standard
                    item.dictationFollowUpStep = 0
                    item.isDictationPass = false
                    item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                }
            } else {
                item.reviewTrack = .standard
                item.dictationFollowUpStep = 0
                item.isDictationPass = false
                item.consecutiveCorrectCount = 0
                item.consecutiveWrongCount += 1
                item.stage = 1
                item.nextReviewAt = nextDayStart(from: now)
                item.isPriority = true
            }
        } else {
            switch result {
            case .correct:
                item.consecutiveCorrectCount += 1
                item.consecutiveWrongCount = 0
                item.stage = nextStageAfterCorrect(from: item.stage)
                item.nextReviewAt = item.stage >= Self.completionStage
                    ? .distantFuture
                    : nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                item.isPriority = false
            case .wrong:
                item.consecutiveCorrectCount = 0
                item.consecutiveWrongCount += 1
                item.stage = max(item.stage - 1, 1)
                item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
                item.isPriority = item.consecutiveWrongCount >= 2
            }
        }

        return (
            item,
            ReviewRecord(
                itemID: item.id,
                reviewedAt: now,
                result: result,
                mode: mode,
                oldStage: oldStage,
                newStage: item.stage
            )
        )
    }

    func isMastered(_ item: ReviewItem) -> Bool {
        Self.isMastered(stage: item.stage, consecutiveWrongCount: item.consecutiveWrongCount)
            && item.nextReviewAt == .distantFuture
    }

    private func nextStageAfterCorrect(from currentStage: Int) -> Int {
        // The first successful formal review should not create another due item
        // on the very next day. Jumping from stage 0 to 2 skips that back-to-back run.
        if currentStage <= 0 {
            return min(2, Self.completionStage)
        }
        return min(currentStage + 1, Self.completionStage)
    }

    private func nextReviewDateAvoidingSameDay(for stage: Int, from date: Date) -> Date {
        let candidate = nextDate(for: stage, from: date)
        let calendar = Calendar.current

        guard calendar.isDate(candidate, inSameDayAs: date) else {
            return candidate
        }

        return nextDayStart(from: date)
    }
}
