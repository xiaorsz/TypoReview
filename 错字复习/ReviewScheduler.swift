import Foundation

struct ReviewScheduler {
    static let intervals: [TimeInterval] = [
        0,
        20 * 60,
        24 * 60 * 60,
        2 * 24 * 60 * 60,
        4 * 24 * 60 * 60,
        7 * 24 * 60 * 60,
        15 * 24 * 60 * 60,
        30 * 24 * 60 * 60
    ]

    func nextDate(for stage: Int, from date: Date = .now) -> Date {
        let safeStage = max(0, min(stage, Self.intervals.count - 1))
        return date.addingTimeInterval(Self.intervals[safeStage])
    }

    func handle(
        item: ReviewItem,
        result: ReviewResult,
        now: Date = .now
    ) -> (item: ReviewItem, record: ReviewRecord) {
        let oldStage = item.stage
        item.lastReviewedAt = now
        item.updatedAt = now

        switch result {
        case .correct:
            item.consecutiveCorrectCount += 1
            item.consecutiveWrongCount = 0
            item.stage = min(item.stage + 1, Self.intervals.count - 1)
            item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
            item.isPriority = false
        case .wrong:
            item.consecutiveCorrectCount = 0
            item.consecutiveWrongCount += 1
            item.stage = max(item.stage - 1, 1)
            item.nextReviewAt = nextReviewDateAvoidingSameDay(for: item.stage, from: now)
            item.isPriority = item.consecutiveWrongCount >= 2
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

    private func nextReviewDateAvoidingSameDay(for stage: Int, from date: Date) -> Date {
        let candidate = nextDate(for: stage, from: date)
        let calendar = Calendar.current

        guard calendar.isDate(candidate, inSameDayAs: date) else {
            return candidate
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return calendar.startOfDay(for: tomorrow)
    }
}
