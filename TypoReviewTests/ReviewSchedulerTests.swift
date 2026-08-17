import XCTest
import SwiftData
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

    func testDayThreeFollowUpSchedulesNextReviewFourDaysLater() {
        let item = makeDictationFollowUpItem(dayThreeDate: date(2026, 6, 4))

        let result = scheduler.handle(
            item: item,
            result: .correct,
            now: date(2026, 6, 4, hour: 20)
        )

        XCTAssertEqual(result.item.dictationFollowUpStep, 2)
        XCTAssertEqual(result.item.nextReviewAt, date(2026, 6, 8))
    }

    func testOverdueDayThreeFollowUpStillKeepsFourDayInterval() {
        let item = makeDictationFollowUpItem(dayThreeDate: date(2026, 6, 4))

        let result = scheduler.handle(
            item: item,
            result: .correct,
            now: date(2026, 6, 10, hour: 20)
        )

        XCTAssertEqual(result.item.dictationFollowUpStep, 2)
        XCTAssertEqual(result.item.nextReviewAt, date(2026, 6, 14))
    }

    func testStageSixUsesThirtyDayConsolidationLabel() {
        let item = makeItem(stage: ReviewScheduler.dictationFollowUpCompleteStage)
        let legacyRecord = ReviewRecord(
            itemID: item.id,
            result: .correct,
            mode: .scheduled,
            oldStage: 2,
            newStage: ReviewScheduler.dictationFollowUpCompleteStage,
            note: ReviewRecord.storedDetailText("已完成听写跟进，已进入阶段 6")
        )

        XCTAssertEqual(item.stageBadgeText, "30天巩固")
        XCTAssertEqual(item.trackingSummaryText, "30天巩固")
        XCTAssertEqual(legacyRecord.stageTransitionText, "第7天复习 -> 30天巩固")
        XCTAssertEqual(legacyRecord.displayDetailText, "已完成听写跟进，已进入30天巩固")
    }

    func testSameScheduledCycleUsesSameRecordIDAcrossDevices() {
        let itemID = UUID()
        let firstCopy = makeItem(id: itemID, stage: 4, nextReviewAt: date(2026, 7, 9))
        let secondCopy = makeItem(id: itemID, stage: 4, nextReviewAt: date(2026, 7, 9))

        let first = scheduler.handle(
            item: firstCopy,
            result: .correct,
            now: date(2026, 7, 11, hour: 20)
        )
        let second = scheduler.handle(
            item: secondCopy,
            result: .correct,
            now: date(2026, 7, 13, hour: 20)
        )

        XCTAssertEqual(first.record.id, second.record.id)
    }

    func testDueItemCanReplaceOrphanedRecordForSameCycle() throws {
        let container = try ModelContainer(
            for: ReviewItem.self,
            ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let now = date(2026, 7, 22, hour: 20)
        let item = makeItem(stage: 3, nextReviewAt: date(2026, 7, 22))
        context.insert(item)

        let orphaned = scheduler.handle(
            item: makeItem(id: item.id, stage: 3, nextReviewAt: date(2026, 7, 22)),
            result: .wrong,
            now: date(2026, 7, 22, hour: 19)
        ).record
        context.insert(orphaned)

        XCTAssertTrue(ReviewScheduler.isDue(item.nextReviewAt, on: now, calendar: calendar))

        let currentAnswer = scheduler.handle(item: item, result: .correct, now: now).record
        let saved = ReviewScheduler.upsertReviewRecord(currentAnswer, in: context)
        try context.save()

        let records = try context.fetch(FetchDescriptor<ReviewRecord>())
        XCTAssertTrue(saved.reusedExistingRecord)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].result, .correct)
        XCTAssertEqual(records[0].reviewedAt, now)
        XCTAssertEqual(item.stage, 4)
        XCTAssertFalse(ReviewScheduler.isDue(item.nextReviewAt, on: now, calendar: calendar))
    }

    func testReconciliationAutomaticallyReplaysOrphanedCurrentCycle() throws {
        let container = try ModelContainer(
            for: ReviewItem.self,
            ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let dueDate = date(2026, 7, 22)
        let reviewedAt = date(2026, 7, 22, hour: 20)
        let item = makeItem(stage: 4, nextReviewAt: dueDate)
        context.insert(item)

        let staleCopy = makeItem(id: item.id, stage: 4, nextReviewAt: dueDate)
        let orphanedRecord = scheduler.handle(
            item: staleCopy,
            result: .correct,
            now: reviewedAt
        ).record
        orphanedRecord.note = ReviewRecord.storedDetailText(
            "已完成本次复习，系统已更新后续安排"
        )
        context.insert(orphanedRecord)

        let repairedCount = try ReviewScheduler.reconcileStandardReviewProgress(in: context)

        XCTAssertEqual(repairedCount, 1)
        XCTAssertEqual(item.stage, 5)
        XCTAssertEqual(item.lastReviewedAt, reviewedAt)
        XCTAssertEqual(item.nextReviewAt, date(2026, 8, 6))
        XCTAssertTrue(orphanedRecord.isExplicitlyConfirmedSubmission)
        XCTAssertFalse(ReviewScheduler.isDue(item.nextReviewAt, on: reviewedAt, calendar: calendar))
    }

    func testReconciliationRepairsCycleWhoseRecordIDCameFromMergedDuplicateItem() throws {
        let container = try ModelContainer(
            for: ReviewItem.self,
            ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let item = makeItem(stage: 4, nextReviewAt: date(2026, 7, 20))
        item.lastReviewedAt = date(2026, 7, 5, hour: 20)
        context.insert(item)

        // The itemID has already been repointed to the surviving item, while this random
        // record ID represents a deterministic ID originally made with a removed item ID.
        let repointedRecord = ReviewRecord(
            id: UUID(),
            itemID: item.id,
            reviewedAt: date(2026, 7, 22, hour: 20),
            result: .correct,
            mode: .scheduled,
            oldStage: 4,
            newStage: 5,
            note: ReviewRecord.storedDetailText("已完成本次复习")
        )
        context.insert(repointedRecord)

        let repairedCount = try ReviewScheduler.reconcileStandardReviewProgress(in: context)

        XCTAssertEqual(repairedCount, 1)
        XCTAssertEqual(item.stage, 5)
        XCTAssertEqual(item.lastReviewedAt, date(2026, 7, 22, hour: 20))
        XCTAssertEqual(item.nextReviewAt, date(2026, 8, 6))
        XCTAssertTrue(repointedRecord.isExplicitlyConfirmedSubmission)
    }

    func testCanonicalHistorySuppressesStaleRepeatedTransition() {
        let itemID = UUID()
        let records = [
            makeRecord(itemID: itemID, reviewedAt: date(2026, 7, 2), oldStage: 3, newStage: 4),
            makeRecord(itemID: itemID, reviewedAt: date(2026, 7, 11), oldStage: 4, newStage: 5),
            makeRecord(itemID: itemID, reviewedAt: date(2026, 7, 13), oldStage: 4, newStage: 5)
        ]

        let canonical = ReviewScheduler.canonicalReviewRecords(records)

        XCTAssertEqual(canonical.count, 2)
        XCTAssertEqual(canonical.first?.reviewedAt, date(2026, 7, 11))
    }

    func testCanonicalHistoryKeepsRepeatedTransitionAfterARealRegression() {
        let itemID = UUID()
        let records = [
            makeRecord(itemID: itemID, reviewedAt: date(2026, 7, 11), oldStage: 4, newStage: 5),
            makeRecord(
                itemID: itemID,
                reviewedAt: date(2026, 7, 26),
                result: .wrong,
                oldStage: 5,
                newStage: 4
            ),
            makeRecord(itemID: itemID, reviewedAt: date(2026, 8, 2), oldStage: 4, newStage: 5)
        ]

        XCTAssertEqual(ReviewScheduler.canonicalReviewRecords(records).count, 3)
    }

    func testCanonicalHistoryKeepsExplicitResubmissionAfterAnOrphanedCycle() {
        let itemID = UUID()
        let earlier = makeRecord(
            itemID: itemID,
            reviewedAt: date(2026, 7, 11),
            oldStage: 4,
            newStage: 5
        )
        let explicitlyResubmitted = makeRecord(
            itemID: itemID,
            reviewedAt: date(2026, 7, 22),
            oldStage: 4,
            newStage: 5
        )
        explicitlyResubmitted.note = ReviewRecord.storedConfirmedDetailText(
            "已完成本次复习，系统已更新后续安排"
        )

        let canonical = ReviewScheduler.canonicalReviewRecords([
            earlier,
            explicitlyResubmitted
        ])

        XCTAssertEqual(canonical.count, 2)
        XCTAssertEqual(canonical.first?.reviewedAt, date(2026, 7, 22))
        XCTAssertEqual(
            explicitlyResubmitted.displayDetailText,
            "已完成本次复习，系统已更新后续安排"
        )
        XCTAssertNil(explicitlyResubmitted.userVisibleNoteText)
    }

    func testDuplicateCycleRewardsCountOnce() {
        let key = "review-same-cycle"
        let first = PointLedgerEntry(
            createdAt: date(2026, 7, 11),
            amount: 1,
            kind: .reward,
            sourceType: .reviewRecord,
            sourceIDRawValue: UUID().uuidString,
            idempotencyKey: key
        )
        let duplicate = PointLedgerEntry(
            createdAt: date(2026, 7, 13),
            amount: 1,
            kind: .reward,
            sourceType: .reviewRecord,
            sourceIDRawValue: UUID().uuidString,
            idempotencyKey: key
        )

        XCTAssertEqual(PointLedgerService.canonicalEntries([duplicate, first]).count, 1)
        XCTAssertEqual(PointLedgerService.canonicalEntries([duplicate, first]).first?.createdAt, first.createdAt)
    }

    func testPointStreakExpiresAfterMissingAFullDay() {
        let entries = [
            makePointActivity(on: date(2026, 7, 13, hour: 20)),
            makePointActivity(on: date(2026, 7, 14, hour: 20))
        ]

        let snapshot = PointLedgerService.streakSnapshot(
            from: entries,
            referenceDate: date(2026, 7, 17, hour: 9),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreak, 0)
        XCTAssertEqual(snapshot.longestStreak, 2)
    }

    func testPointStreakRemainsCurrentWhenLastActivityWasYesterday() {
        let entries = [14, 15, 16].map { day in
            makePointActivity(on: date(2026, 7, day, hour: 20))
        }

        let snapshot = PointLedgerService.streakSnapshot(
            from: entries,
            referenceDate: date(2026, 7, 17, hour: 9),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.longestStreak, 3)
    }

    func testFinishedDictationSessionCountsWithoutReviewOrPointLedgerEntry() {
        let session = DictationSession(
            title: "昨日听写",
            type: .englishWord,
            scheduledDate: date(2026, 7, 16),
            finishedAt: date(2026, 7, 16, hour: 19)
        )

        let snapshot = PointLedgerService.streakSnapshot(
            reviewRecords: [],
            dictationSessions: [session],
            referenceDate: date(2026, 7, 17, hour: 9),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(snapshot.lastActiveDay, date(2026, 7, 16))
    }

    func testPointStreakUsesDatesWhenSyncedOutOfOrder() {
        let entries = [16, 14, 15].map { day in
            makePointActivity(on: date(2026, 7, day, hour: 20))
        }

        let snapshot = PointLedgerService.streakSnapshot(
            from: entries,
            referenceDate: date(2026, 7, 16, hour: 22),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.lastActiveDay, date(2026, 7, 16))
    }

    func testReversedActivityDoesNotCountTowardPointStreak() {
        let first = makePointActivity(on: date(2026, 7, 14, hour: 20))
        let reversed = makePointActivity(on: date(2026, 7, 15, hour: 20))
        let third = makePointActivity(on: date(2026, 7, 16, hour: 20))
        let reversal = PointLedgerEntry(
            createdAt: date(2026, 7, 16, hour: 21),
            amount: -1,
            kind: .reversal,
            sourceType: .reviewRecord,
            sourceIDRawValue: reversed.sourceIDRawValue,
            idempotencyKey: "reverse-\(reversed.id.uuidString)",
            isReversal: true,
            reversesEntryIDRawValue: reversed.id.uuidString
        )

        let snapshot = PointLedgerService.streakSnapshot(
            from: [first, reversed, third, reversal],
            referenceDate: date(2026, 7, 16, hour: 22),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.currentStreak, 1)
        XCTAssertEqual(snapshot.longestStreak, 1)
    }

    func testAwardingThreeActiveDaysStillCreatesTheStreakBonus() throws {
        let container = try ModelContainer(
            for: PointLedgerEntry.self,
            PointRewardState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)

        for day in [14, 15, 16] {
            let record = makeRecord(
                itemID: UUID(),
                reviewedAt: date(2026, 7, day, hour: 20),
                oldStage: 1,
                newStage: 2
            )
            XCTAssertNotNil(PointLedgerService.awardReviewRecord(record, in: context))
        }

        let entries = try context.fetch(FetchDescriptor<PointLedgerEntry>())
        let streakBonuses = entries.filter { $0.sourceType == .dailyStreak }
        let snapshot = PointLedgerService.streakSnapshot(
            from: entries,
            referenceDate: date(2026, 7, 17, hour: 9),
            calendar: calendar
        )

        XCTAssertEqual(streakBonuses.count, 1)
        XCTAssertEqual(streakBonuses.first?.amount, 5)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.amount }, 8)
        XCTAssertEqual(snapshot.currentStreak, 3)
    }

    func testPointReconciliationBackfillsJudgedDictationOnlyOnce() throws {
        let container = try ModelContainer(
            for: PointLedgerEntry.self,
            PointRewardState.self,
            ReviewRecord.self,
            DictationEntry.self,
            DictationSession.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let sessionID = UUID()
        let reviewedAt = date(2026, 7, 16, hour: 20)
        context.insert(DictationSession(
            id: sessionID,
            title: "已判定听写",
            type: .englishWord,
            scheduledDate: reviewedAt,
            finishedAt: reviewedAt,
            reviewedAt: reviewedAt
        ))
        for index in 0..<2 {
            context.insert(DictationEntry(
                sessionID: sessionID,
                sortOrder: index,
                type: .englishWord,
                content: "word-\(index)",
                result: .correct,
                createdAt: reviewedAt,
                updatedAt: reviewedAt
            ))
        }

        let firstResult = try PointLedgerService.reconcileMissingAutomaticRewards(in: context)
        let firstEntries = try context.fetch(FetchDescriptor<PointLedgerEntry>())

        XCTAssertEqual(firstResult.reviewRewardsAdded, 0)
        XCTAssertEqual(firstResult.dictationRewardsAdded, 2)
        XCTAssertEqual(firstResult.dictationAccuracyBonusesAdded, 1)
        XCTAssertEqual(firstEntries.reduce(0) { $0 + $1.amount }, 82)

        let secondResult = try PointLedgerService.reconcileMissingAutomaticRewards(in: context)
        let secondEntries = try context.fetch(FetchDescriptor<PointLedgerEntry>())

        XCTAssertEqual(secondResult.totalAdded, 0)
        XCTAssertEqual(secondEntries.reduce(0) { $0 + $1.amount }, 82)
        XCTAssertEqual(secondEntries.count, firstEntries.count)
    }

    func testReconciliationRepairsScheduleCreatedByStaleDuplicate() throws {
        let container = try ModelContainer(
            for: ReviewItem.self,
            ReviewRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let item = makeItem(id: UUID(), stage: 5, nextReviewAt: date(2026, 7, 28))
        item.lastReviewedAt = date(2026, 7, 13, hour: 20)
        context.insert(item)
        context.insert(makeRecord(
            itemID: item.id,
            reviewedAt: date(2026, 7, 11, hour: 20),
            oldStage: 4,
            newStage: 5
        ))
        context.insert(makeRecord(
            itemID: item.id,
            reviewedAt: date(2026, 7, 13, hour: 20),
            oldStage: 4,
            newStage: 5
        ))

        let repairedCount = try ReviewScheduler.reconcileStandardReviewProgress(in: context)

        XCTAssertEqual(repairedCount, 1)
        XCTAssertEqual(item.lastReviewedAt, date(2026, 7, 11, hour: 20))
        XCTAssertEqual(item.nextReviewAt, date(2026, 7, 26))
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

    private func makeItem(
        id: UUID = UUID(),
        stage: Int,
        nextReviewAt: Date? = nil,
        consecutiveWrongCount: Int = 0
    ) -> ReviewItem {
        ReviewItem(
            id: id,
            type: .phrase,
            content: "清澈",
            prompt: "注意右边偏旁",
            stage: stage,
            nextReviewAt: nextReviewAt ?? date(2026, 7, 14),
            consecutiveWrongCount: consecutiveWrongCount
        )
    }

    private func makeRecord(
        itemID: UUID,
        reviewedAt: Date,
        result: ReviewResult = .correct,
        oldStage: Int,
        newStage: Int
    ) -> ReviewRecord {
        ReviewRecord(
            itemID: itemID,
            reviewedAt: reviewedAt,
            result: result,
            mode: .scheduled,
            oldStage: oldStage,
            newStage: newStage
        )
    }

    private func makePointActivity(on createdAt: Date) -> PointLedgerEntry {
        let sourceID = UUID()
        return PointLedgerEntry(
            createdAt: createdAt,
            amount: PointLedgerService.reviewRewardAmount,
            kind: .reward,
            sourceType: .reviewRecord,
            sourceIDRawValue: sourceID.uuidString,
            idempotencyKey: "review-\(sourceID.uuidString)"
        )
    }

    private func makeDictationFollowUpItem(dayThreeDate: Date) -> ReviewItem {
        ReviewItem(
            type: .englishWord,
            content: "ski",
            prompt: "滑雪",
            stage: 1,
            nextReviewAt: dayThreeDate,
            reviewTrack: .dictationFollowUp,
            dictationFollowUpStep: 1,
            isDictationPass: true
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

    func testReconciledPlanKeepsOnlyCompletedQuotaAheadOfStaleSecondBatch() {
        let reviewedIDs = (0..<50).map { _ in UUID() }
        let staleSecondBatchIDs = (0..<50).map { _ in UUID() }

        let reconciledIDs = ReviewDailyPlan.reconciledItemIDs(
            existingItemIDs: staleSecondBatchIDs,
            reviewedTodayItemIDs: reviewedIDs,
            availableDueItemIDs: staleSecondBatchIDs,
            dailyLimit: 50
        )

        XCTAssertEqual(reconciledIDs, reviewedIDs)
    }

    func testReconciledPlanShowsFortyOneRemainingAfterNineResultsArrive() {
        let plannedIDs = (0..<50).map { _ in UUID() }
        let reviewedIDs = Array(plannedIDs.prefix(9))

        let reconciledIDs = ReviewDailyPlan.reconciledItemIDs(
            existingItemIDs: plannedIDs,
            reviewedTodayItemIDs: reviewedIDs,
            availableDueItemIDs: Array(plannedIDs.dropFirst(9)),
            dailyLimit: 50
        )

        XCTAssertEqual(reconciledIDs.count, 50)
        XCTAssertEqual(Array(reconciledIDs.prefix(9)), reviewedIDs)
        XCTAssertEqual(reconciledIDs.filter { !Set(reviewedIDs).contains($0) }.count, 41)
    }

    func testReconciledPlanReplacesEntriesMadeStaleByIncrementalSync() {
        let stillDueIDs = (0..<19).map { _ in UUID() }
        let staleIDs = (0..<31).map { _ in UUID() }
        let replacementIDs = (0..<31).map { _ in UUID() }
        let existingPlan = stillDueIDs + staleIDs
        let availableDueIDs = stillDueIDs + replacementIDs

        let reconciledIDs = ReviewDailyPlan.reconciledItemIDs(
            existingItemIDs: existingPlan,
            reviewedTodayItemIDs: [],
            availableDueItemIDs: availableDueIDs,
            dailyLimit: 50
        )

        XCTAssertEqual(reconciledIDs.count, 50)
        XCTAssertEqual(Array(reconciledIDs.prefix(19)), stillDueIDs)
        XCTAssertTrue(Set(staleIDs).isDisjoint(with: reconciledIDs))
        XCTAssertEqual(Set(reconciledIDs), Set(availableDueIDs))
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

    func testPausedWeeklyTaskIsExcludedFromCalendarOccurrenceCount() {
        let task = TaskProjection(
            id: UUID(),
            title: "完成学而思数学",
            startDate: date(2026, 3, 20),
            recurrence: .weekly([6]),
            pauseStartedAt: date(2026, 7, 16)
        )

        XCTAssertFalse(task.occurs(on: date(2026, 7, 24), calendar: calendar))
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
