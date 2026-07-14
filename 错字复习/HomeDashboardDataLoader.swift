import Foundation
import SwiftData

enum HomeDashboardDataLoader {
    static func load(
        from container: ModelContainer,
        referenceDate: Date
    ) -> HomeDashboardSourceSnapshot {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let todayPlanKey = ReviewDailyPlan.dayKey(for: referenceDate, calendar: calendar)
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate)
        let weekStart = weekInterval?.start ?? calendar.startOfDay(for: referenceDate)
        let weekEnd = weekInterval?.end
            ?? calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? referenceDate

        var source = HomeDashboardSourceSnapshot.empty
        try? context.transaction {
            let reviewItems = ((try? context.fetch(FetchDescriptor<ReviewItem>())) ?? [])
                .map(HomeReviewItemProjection.init)
            let reviewRecords = ((try? context.fetch(
                FetchDescriptor<ReviewRecord>(
                    predicate: #Predicate<ReviewRecord> {
                        $0.reviewedAt >= weekStart && $0.reviewedAt < weekEnd
                    }
                )
            )) ?? []).map(HomeReviewRecordProjection.init)
            let reviewDailyPlans = ((try? context.fetch(
                FetchDescriptor<ReviewDailyPlan>(
                    predicate: #Predicate<ReviewDailyPlan> { $0.dayKey == todayPlanKey }
                )
            )) ?? []).map(HomeReviewDailyPlanProjection.init)
            let dictationSessions = ((try? context.fetch(FetchDescriptor<DictationSession>())) ?? [])
                .map(HomeDictationSessionProjection.init)
            let dictationEntries = ((try? context.fetch(FetchDescriptor<DictationEntry>())) ?? [])
                .map(HomeDictationEntryProjection.init)
            let schedules = ((try? context.fetch(
                FetchDescriptor<ScheduleItem>(predicate: #Predicate<ScheduleItem> { !$0.isArchived })
            )) ?? []).map(HomeScheduleProjection.init)
            let tasks = ((try? context.fetch(FetchDescriptor<TaskItem>())) ?? [])
                .map(HomeTaskModelProjection.init)
            let taskExecutions = ((try? context.fetch(FetchDescriptor<TaskExecutionRecord>())) ?? [])
                .map(TaskExecutionRecordProjection.init)
            let taskSubtasks = ((try? context.fetch(
                FetchDescriptor<TaskSubitem>(predicate: #Predicate<TaskSubitem> { !$0.isArchived })
            )) ?? []).map(TaskSubitemProjection.init)
            let pointEntries = (try? context.fetch(FetchDescriptor<PointLedgerEntry>())) ?? []
            let pointAmountsAndDates = pointEntries.map { (amount: $0.amount, createdAt: $0.createdAt) }
            let pointState = (try? context.fetch(FetchDescriptor<PointRewardState>()))?.first

            source = HomeDashboardSourceSnapshot(
                reviewItems: reviewItems,
                reviewRecords: reviewRecords,
                reviewDailyPlans: reviewDailyPlans,
                dictationSessions: dictationSessions,
                dictationEntries: dictationEntries,
                schedules: schedules,
                tasks: tasks,
                taskExecutions: taskExecutions,
                taskSubtasks: taskSubtasks,
                pointBalance: pointAmountsAndDates.reduce(0) { $0 + $1.amount },
                pointsEarnedToday: pointAmountsAndDates
                    .filter { $0.amount > 0 && calendar.isDate($0.createdAt, inSameDayAs: referenceDate) }
                    .reduce(0) { $0 + $1.amount },
                currentPointStreak: pointState?.currentStreak ?? 0
            )
        }
        return source
    }
}
