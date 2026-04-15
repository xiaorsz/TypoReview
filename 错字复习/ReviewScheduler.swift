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
        30,
        30
    ]

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
                    item.stage = Self.intervals.count - 1
                    item.reviewTrack = .standard
                    item.dictationFollowUpStep = 0
                    item.isDictationPass = false
                    item.nextReviewAt = .distantFuture
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
                item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
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
                mode: .scheduled,
                oldStage: oldStage,
                newStage: item.stage
            )
        )
    }

    func isMastered(_ item: ReviewItem) -> Bool {
        item.stage >= Self.intervals.count - 1 && item.consecutiveWrongCount == 0
    }

    private func nextStageAfterCorrect(from currentStage: Int) -> Int {
        // The first successful formal review should not create another due item
        // on the very next day. Jumping from stage 0 to 2 skips that back-to-back run.
        if currentStage <= 0 {
            return min(2, Self.intervals.count - 1)
        }
        return min(currentStage + 1, Self.intervals.count - 1)
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
