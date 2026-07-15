import XCTest
@testable import TypoReview

@MainActor
final class ReviewSchedulerTests: XCTestCase {
    private let scheduler = ReviewScheduler()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testCorrectAnswerAdvancesStageAndSchedulesNextInterval() {
        let now = date(2026, 7, 14, hour: 20)
        let item = makeItem(stage: 2)

        let result = scheduler.handle(item: item, result: .correct, now: now)

        XCTAssertEqual(result.item.stage, 3)
        XCTAssertEqual(result.record.oldStage, 2)
        XCTAssertEqual(result.record.newStage, 3)
        XCTAssertEqual(result.item.nextReviewAt, date(2026, 7, 18))
        XCTAssertEqual(result.item.consecutiveCorrectCount, 1)
        XCTAssertEqual(result.item.consecutiveWrongCount, 0)
    }

    func testSecondWrongAnswerMarksItemAsPriorityAndMovesItBack() {
        let now = date(2026, 7, 14, hour: 20)
        let item = makeItem(stage: 3, consecutiveWrongCount: 1)

        let result = scheduler.handle(item: item, result: .wrong, now: now)

        XCTAssertEqual(result.item.stage, 2)
        XCTAssertEqual(result.item.nextReviewAt, date(2026, 7, 16))
        XCTAssertEqual(result.item.consecutiveWrongCount, 2)
        XCTAssertTrue(result.item.isPriority)
    }

    func testWrongAnswerNeverSchedulesAnotherReviewOnTheSameDay() {
        let now = date(2026, 7, 14, hour: 23, minute: 59)
        let item = makeItem(stage: 0)

        let result = scheduler.handle(item: item, result: .wrong, now: now)

        XCTAssertEqual(result.item.stage, 1)
        XCTAssertEqual(result.item.nextReviewAt, date(2026, 7, 15))
    }

    func testFinalCorrectAnswerMarksItemAsMastered() {
        let item = makeItem(stage: 6)

        let result = scheduler.handle(item: item, result: .correct, now: date(2026, 7, 14))

        XCTAssertEqual(result.item.stage, ReviewScheduler.completionStage)
        XCTAssertEqual(result.item.nextReviewAt, .distantFuture)
        XCTAssertTrue(scheduler.isMastered(result.item))
    }

    func testDueDateUsesNaturalDayInsteadOfExactTime() {
        let reviewDate = date(2026, 7, 14)

        XCTAssertTrue(ReviewScheduler.isDue(reviewDate, on: date(2026, 7, 14, hour: 0, minute: 1), calendar: calendar))
        XCTAssertFalse(ReviewScheduler.isDue(reviewDate, on: date(2026, 7, 13, hour: 23, minute: 59), calendar: calendar))
    }

    func testIntervalCrossesMonthBoundaryCorrectly() {
        let nextDate = scheduler.nextDate(for: 3, from: date(2026, 7, 30, hour: 18))

        XCTAssertEqual(nextDate, date(2026, 8, 3))
    }

    private func makeItem(stage: Int, consecutiveWrongCount: Int = 0) -> ReviewItem {
        ReviewItem(
            type: .phrase,
            content: "清澈",
            prompt: "注意右边偏旁",
            stage: stage,
            nextReviewAt: date(2026, 7, 14),
            consecutiveWrongCount: consecutiveWrongCount
        )
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

final class ReviewDailyPlanTests: XCTestCase {
    func testExistingPlanExpandsWhenDailyLimitIncreases() {
        let availableIDs = (0..<60).map { _ in UUID() }
        let existingIDs = Array(availableIDs.prefix(5))

        let expandedIDs = ReviewDailyPlan.expandedItemIDs(
            existingItemIDs: existingIDs,
            availableDueItemIDs: availableIDs,
            dailyLimit: 50
        )

        XCTAssertEqual(expandedIDs.count, 50)
        XCTAssertEqual(Array(expandedIDs.prefix(5)), existingIDs)
    }

    func testExistingPlanDoesNotReplenishCompletedItemsOrShrink() {
        let plannedIDs = (0..<50).map { _ in UUID() }
        let remainingDueIDs = Array(plannedIDs.dropFirst(10))

        XCTAssertEqual(
            ReviewDailyPlan.expandedItemIDs(
                existingItemIDs: plannedIDs,
                availableDueItemIDs: remainingDueIDs,
                dailyLimit: 50
            ),
            plannedIDs
        )
        XCTAssertEqual(
            ReviewDailyPlan.expandedItemIDs(
                existingItemIDs: plannedIDs,
                availableDueItemIDs: remainingDueIDs,
                dailyLimit: 5
            ),
            plannedIDs
        )
    }
}

final class ScheduleDedupSupportTests: XCTestCase {
    func testIdenticalScheduleConfigurationsCollapseToOneDisplayItem() {
        let start = date(hour: 16, minute: 30)
        let end = date(hour: 17, minute: 30)
        let identity = makeIdentity(start: start, end: end)

        let result = ScheduleDedupSupport.deduplicated(["first", "duplicate"]) { _ in identity }

        XCTAssertEqual(result, ["first"])
    }

    func testSchedulesAtDifferentTimesRemainDistinct() {
        let first = makeIdentity(start: date(hour: 16, minute: 30), end: date(hour: 17, minute: 30))
        let second = makeIdentity(start: date(hour: 18), end: date(hour: 19))
        let identities = [first, second]

        let result = ScheduleDedupSupport.deduplicated(Array(identities.indices)) { identities[$0] }

        XCTAssertEqual(result, [0, 1])
    }

    private func makeIdentity(start: Date, end: Date) -> ScheduleDisplayIdentity {
        ScheduleDisplayIdentity(
            title: "钢琴课",
            note: "每周课程",
            startTime: start,
            endTime: end,
            repeatRule: .weekly,
            weekdays: [4, 2],
            effectiveStartDate: date(hour: 0),
            effectiveEndDate: nil,
            calendar: calendar
        )
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 15,
            hour: hour,
            minute: minute
        ))!
    }
}

@MainActor
final class TaskPauseTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testPausedRecurringTaskStopsCreatingOccurrencesFromPauseDate() {
        let task = TaskProjection(
            id: UUID(),
            title: "每日朗读",
            startDate: date(2026, 7, 14),
            recurrence: .daily,
            pauseStartedAt: date(2026, 7, 15)
        )

        XCTAssertEqual(
            task.scheduledOccurrenceDates(upTo: date(2026, 7, 18)),
            [date(2026, 7, 14)]
        )
    }

    func testResumedTaskDoesNotBackfillDatesSkippedWhilePaused() {
        let task = TaskProjection(
            id: UUID(),
            title: "每日朗读",
            startDate: date(2026, 7, 14),
            recurrence: .daily,
            pauseIntervals: [
                TaskPauseInterval(
                    startDate: date(2026, 7, 15),
                    endDate: date(2026, 7, 18)
                )
            ]
        )

        XCTAssertEqual(
            task.scheduledOccurrenceDates(upTo: date(2026, 7, 20)),
            [
                date(2026, 7, 14),
                date(2026, 7, 18),
                date(2026, 7, 19),
                date(2026, 7, 20)
            ]
        )
    }

    func testPauseStateRoundTripsThroughTaskModel() {
        let task = TaskItem(
            title: "每周听写",
            recurrence: .weekly([2, 4]),
            startDate: date(2026, 7, 13)
        )

        task.pause(starting: date(2026, 7, 15))
        XCTAssertTrue(task.isPaused)

        task.resume(on: date(2026, 7, 18))

        XCTAssertFalse(task.isPaused)
        XCTAssertEqual(
            task.pauseIntervals,
            [TaskPauseInterval(startDate: date(2026, 7, 15), endDate: date(2026, 7, 18))]
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        ))!
    }
}
