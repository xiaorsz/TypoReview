import Foundation
import SwiftData
import SwiftUI

enum PointLedgerKind: String, Codable, CaseIterable, Identifiable {
    case reward = "奖励"
    case streakBonus = "连续奖励"
    case redemption = "兑换"
    case reversal = "冲正"

    var id: String { rawValue }
}

enum PointLedgerSourceType: String, Codable, CaseIterable, Identifiable {
    case reviewRecord = "复习"
    case dictationEntry = "听写"
    case reviewAccuracyBonus = "复习正确率"
    case dictationAccuracyBonus = "听写正确率"
    case taskExecution = "待办"
    case dailyStreak = "连续学习"
    case manualRedemption = "手动兑换"
    case manualAdjustment = "手动调整"

    var id: String { rawValue }
}

@Model
final class PointLedgerEntry {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var amount: Int = 0
    var kindRawValue: String = PointLedgerKind.reward.rawValue
    var sourceTypeRawValue: String = PointLedgerSourceType.reviewRecord.rawValue
    var sourceIDRawValue: String = ""
    var idempotencyKey: String = ""
    var note: String = ""
    var isReversal: Bool = false
    var reversesEntryIDRawValue: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        amount: Int,
        kind: PointLedgerKind,
        sourceType: PointLedgerSourceType,
        sourceIDRawValue: String,
        idempotencyKey: String,
        note: String = "",
        isReversal: Bool = false,
        reversesEntryIDRawValue: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.amount = amount
        self.kindRawValue = kind.rawValue
        self.sourceTypeRawValue = sourceType.rawValue
        self.sourceIDRawValue = sourceIDRawValue
        self.idempotencyKey = idempotencyKey
        self.note = note
        self.isReversal = isReversal
        self.reversesEntryIDRawValue = reversesEntryIDRawValue
    }

    var kind: PointLedgerKind {
        get { PointLedgerKind(rawValue: kindRawValue) ?? .reward }
        set { kindRawValue = newValue.rawValue }
    }

    var sourceType: PointLedgerSourceType {
        get { PointLedgerSourceType(rawValue: sourceTypeRawValue) ?? .reviewRecord }
        set { sourceTypeRawValue = newValue.rawValue }
    }

    var signedAmountText: String {
        amount > 0 ? "+\(amount)" : "\(amount)"
    }
}

@Model
final class PointRewardState {
    var id: UUID = UUID()
    var currentStreak: Int = 0
    var lastActiveDay: Date?
    var longestStreak: Int = 0
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        currentStreak: Int = 0,
        lastActiveDay: Date? = nil,
        longestStreak: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.currentStreak = currentStreak
        self.lastActiveDay = lastActiveDay
        self.longestStreak = longestStreak
        self.updatedAt = updatedAt
    }
}

struct PointBalanceSnapshot {
    let balance: Int
    let currentStreak: Int
    let longestStreak: Int
}

struct PointStreakSnapshot {
    let currentStreak: Int
    let longestStreak: Int
    let lastActiveDay: Date?
}

struct AccuracyBonusReward {
    let amount: Int
}

struct PointRewardReconciliationResult {
    let reviewRewardsAdded: Int
    let dictationRewardsAdded: Int
    let dictationAccuracyBonusesAdded: Int

    var totalAdded: Int {
        reviewRewardsAdded + dictationRewardsAdded + dictationAccuracyBonusesAdded
    }
}

enum PointLedgerService {
    static let reviewRewardAmount = 1
    static let dictationRewardAmount = 1
    static let taskRewardAmount = 5

    static func canonicalEntries(_ entries: [PointLedgerEntry]) -> [PointLedgerEntry] {
        Dictionary(grouping: entries) { entry in
            entry.idempotencyKey.isEmpty ? "legacy-\(entry.id.uuidString)" : entry.idempotencyKey
        }.values.compactMap { duplicates in
            duplicates.min {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
    }

    static func streakSnapshot(
        from entries: [PointLedgerEntry],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> PointStreakSnapshot {
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let nextReferenceDay = calendar.date(byAdding: .day, value: 1, to: referenceDay)
            ?? referenceDate.addingTimeInterval(24 * 60 * 60)
        let eligibleEntries = canonicalEntries(entries).filter { $0.createdAt < nextReferenceDay }
        let reversedEntryIDs = Set(eligibleEntries.compactMap { entry in
            entry.isReversal ? entry.reversesEntryIDRawValue : nil
        })
        let activityDates = eligibleEntries.compactMap { entry -> Date? in
            guard entry.amount > 0,
                  !entry.isReversal,
                  !reversedEntryIDs.contains(entry.id.uuidString),
                  entry.sourceType == .reviewRecord || entry.sourceType == .dictationEntry else {
                return nil
            }
            return entry.createdAt
        }
        return streakSnapshot(
            activityDates: activityDates,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    static func streakSnapshot(
        reviewRecords: [ReviewRecord],
        dictationSessions: [DictationSession],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> PointStreakSnapshot {
        let reviewDates = ReviewRecord.canonicalRecords(reviewRecords).map(\.reviewedAt)
        let dictationDates = Dictionary(grouping: dictationSessions, by: \.id).values.flatMap { sessions in
            [
                sessions.compactMap(\.finishedAt).max(),
                sessions.compactMap(\.reviewedAt).max()
            ].compactMap { $0 }
        }
        return streakSnapshot(
            activityDates: reviewDates + dictationDates,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    static func streakSnapshot(
        activityDates: [Date],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> PointStreakSnapshot {
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let nextReferenceDay = calendar.date(byAdding: .day, value: 1, to: referenceDay)
            ?? referenceDate.addingTimeInterval(24 * 60 * 60)
        let activeDays = Set(activityDates.lazy
            .filter { $0 < nextReferenceDay }
            .map { calendar.startOfDay(for: $0) })
        let orderedDays = activeDays.sorted()

        var longestStreak = 0
        var runningStreak = 0
        var previousDay: Date?
        for day in orderedDays {
            if let previousDay,
               let expectedDay = calendar.date(byAdding: .day, value: 1, to: previousDay),
               calendar.isDate(day, inSameDayAs: expectedDay) {
                runningStreak += 1
            } else {
                runningStreak = 1
            }
            longestStreak = max(longestStreak, runningStreak)
            previousDay = day
        }

        guard let lastActiveDay = orderedDays.last else {
            return PointStreakSnapshot(currentStreak: 0, longestStreak: 0, lastActiveDay: nil)
        }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: referenceDay)
        let isCurrent = calendar.isDate(lastActiveDay, inSameDayAs: referenceDay)
            || yesterday.map { calendar.isDate(lastActiveDay, inSameDayAs: $0) } == true

        return PointStreakSnapshot(
            currentStreak: isCurrent ? streakLength(endingOn: lastActiveDay, activeDays: activeDays, calendar: calendar) : 0,
            longestStreak: longestStreak,
            lastActiveDay: lastActiveDay
        )
    }

    static func accuracyBonusReward(correctCount: Int, totalCount: Int) -> AccuracyBonusReward? {
        guard totalCount > 0, correctCount >= 0, correctCount <= totalCount else { return nil }

        if correctCount == totalCount {
            return AccuracyBonusReward(amount: 80)
        }

        let accuracy = roundedAccuracyPercent(correctCount: correctCount, totalCount: totalCount)
        if accuracy >= 90 {
            return AccuracyBonusReward(amount: 50)
        } else if accuracy >= 80 {
            return AccuracyBonusReward(amount: 30)
        } else if accuracy >= 70 {
            return AccuracyBonusReward(amount: 20)
        } else if accuracy >= 60 {
            return AccuracyBonusReward(amount: 5)
        }

        return nil
    }

    static func accuracyBonusAmount(correctCount: Int, totalCount: Int) -> Int {
        accuracyBonusReward(correctCount: correctCount, totalCount: totalCount)?.amount ?? 0
    }

    @discardableResult
    static func awardReviewAccuracyBonus(
        sessionID: UUID,
        correctCount: Int,
        totalCount: Int,
        createdAt: Date = .now,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        awardAccuracyBonus(
            sourceType: .reviewAccuracyBonus,
            sourceIDRawValue: sessionID.uuidString,
            idempotencyKey: "review-accuracy-bonus-\(sessionID.uuidString)",
            title: "复习",
            correctCount: correctCount,
            totalCount: totalCount,
            createdAt: createdAt,
            in: modelContext
        )
    }

    @discardableResult
    static func awardDictationAccuracyBonus(
        sessionID: UUID,
        correctCount: Int,
        totalCount: Int,
        createdAt: Date = .now,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        awardAccuracyBonus(
            sourceType: .dictationAccuracyBonus,
            sourceIDRawValue: sessionID.uuidString,
            idempotencyKey: "dictation-accuracy-bonus-\(sessionID.uuidString)",
            title: "听写",
            correctCount: correctCount,
            totalCount: totalCount,
            createdAt: createdAt,
            in: modelContext
        )
    }

    static func currentSnapshot(in modelContext: ModelContext) -> PointBalanceSnapshot {
        let entries = canonicalEntries(
            (try? modelContext.fetch(FetchDescriptor<PointLedgerEntry>())) ?? []
        )
        let reviewRecords = (try? modelContext.fetch(FetchDescriptor<ReviewRecord>())) ?? []
        let dictationSessions = (try? modelContext.fetch(FetchDescriptor<DictationSession>())) ?? []
        let streak = streakSnapshot(
            reviewRecords: reviewRecords,
            dictationSessions: dictationSessions
        )
        return PointBalanceSnapshot(
            balance: entries.reduce(0) { $0 + $1.amount },
            currentStreak: streak.currentStreak,
            longestStreak: streak.longestStreak
        )
    }

    @discardableResult
    private static func awardAccuracyBonus(
        sourceType: PointLedgerSourceType,
        sourceIDRawValue: String,
        idempotencyKey: String,
        title: String,
        correctCount: Int,
        totalCount: Int,
        createdAt: Date,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        guard let reward = accuracyBonusReward(correctCount: correctCount, totalCount: totalCount) else {
            return nil
        }

        let accuracyText = formattedAccuracyText(correctCount: correctCount, totalCount: totalCount)
        return awardIfNeeded(
            amount: reward.amount,
            kind: .reward,
            sourceType: sourceType,
            sourceIDRawValue: sourceIDRawValue,
            idempotencyKey: idempotencyKey,
            note: "\(title)正确率 \(accuracyText)，额外奖励 \(reward.amount) 分",
            createdAt: createdAt,
            countsAsActiveDay: false,
            in: modelContext
        )
    }

    private static func formattedAccuracyText(correctCount: Int, totalCount: Int) -> String {
        guard totalCount > 0 else { return "--" }
        let accuracy = roundedAccuracyPercent(correctCount: correctCount, totalCount: totalCount)
        return "\(accuracy)%"
    }

    private static func roundedAccuracyPercent(correctCount: Int, totalCount: Int) -> Int {
        Int((Double(correctCount) / Double(totalCount) * 100).rounded())
    }

    static func currentBalance(in modelContext: ModelContext) -> Int {
        currentSnapshot(in: modelContext).balance
    }

    /// Repairs rewards that can be absent when completed activity arrives through
    /// CloudKit or a backup restore instead of the local grading flow.
    @discardableResult
    static func reconcileMissingAutomaticRewards(
        in modelContext: ModelContext
    ) throws -> PointRewardReconciliationResult {
        let existingKeys = Set(
            try modelContext.fetch(FetchDescriptor<PointLedgerEntry>()).map(\.idempotencyKey)
        )
        var knownKeys = existingKeys
        var reviewRewardsAdded = 0
        var dictationRewardsAdded = 0
        var dictationAccuracyBonusesAdded = 0

        let reviewRecords = ReviewRecord.canonicalRecords(
            try modelContext.fetch(FetchDescriptor<ReviewRecord>())
        ).sorted { $0.reviewedAt < $1.reviewedAt }
        for record in reviewRecords {
            let key = "review-\(record.id.uuidString)"
            guard !knownKeys.contains(key) else { continue }
            if awardReviewRecord(record, in: modelContext) != nil {
                knownKeys.insert(key)
                reviewRewardsAdded += 1
            }
        }

        let fetchedEntries = try modelContext.fetch(FetchDescriptor<DictationEntry>())
        let dictationEntries = Dictionary(grouping: fetchedEntries, by: \.id).values.compactMap { duplicates in
            duplicates.max {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.createdAt < $1.createdAt
            }
        }
        let judgedEntries = dictationEntries
            .filter { $0.result != .pending }
            .sorted { $0.updatedAt < $1.updatedAt }
        for entry in judgedEntries {
            let key = "dictation-entry-\(entry.id.uuidString)"
            guard !knownKeys.contains(key) else { continue }
            if awardDictationEntry(entry, in: modelContext) != nil {
                knownKeys.insert(key)
                dictationRewardsAdded += 1
            }
        }

        let entriesBySessionID = Dictionary(grouping: dictationEntries, by: \.sessionID)
        let sessionsByID = Dictionary(
            grouping: try modelContext.fetch(FetchDescriptor<DictationSession>()),
            by: \.id
        )
        let reviewedSessions = sessionsByID.compactMap { sessionID, duplicates -> (UUID, Date)? in
            guard let reviewedAt = duplicates.compactMap(\.reviewedAt).max() else { return nil }
            return (sessionID, reviewedAt)
        }.sorted { $0.1 < $1.1 }

        for (sessionID, reviewedAt) in reviewedSessions {
            let key = "dictation-accuracy-bonus-\(sessionID.uuidString)"
            guard !knownKeys.contains(key) else { continue }
            let entries = entriesBySessionID[sessionID] ?? []
            guard !entries.isEmpty, entries.allSatisfy({ $0.result != .pending }) else { continue }
            let correctCount = entries.filter { $0.result == .correct }.count
            if awardDictationAccuracyBonus(
                sessionID: sessionID,
                correctCount: correctCount,
                totalCount: entries.count,
                createdAt: reviewedAt,
                in: modelContext
            ) != nil {
                knownKeys.insert(key)
                dictationAccuracyBonusesAdded += 1
            }
        }

        return PointRewardReconciliationResult(
            reviewRewardsAdded: reviewRewardsAdded,
            dictationRewardsAdded: dictationRewardsAdded,
            dictationAccuracyBonusesAdded: dictationAccuracyBonusesAdded
        )
    }

    @discardableResult
    static func awardReviewRecord(
        _ record: ReviewRecord,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        awardIfNeeded(
            amount: reviewRewardAmount,
            kind: .reward,
            sourceType: .reviewRecord,
            sourceIDRawValue: record.id.uuidString,
            idempotencyKey: "review-\(record.id.uuidString)",
            note: "完成复习：\(record.result.rawValue)",
            createdAt: record.reviewedAt,
            countsAsActiveDay: true,
            in: modelContext
        )
    }

    @discardableResult
    static func awardDictationEntry(
        _ entry: DictationEntry,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        guard entry.result != .pending else { return nil }
        return awardIfNeeded(
            amount: dictationRewardAmount,
            kind: .reward,
            sourceType: .dictationEntry,
            sourceIDRawValue: entry.id.uuidString,
            idempotencyKey: "dictation-entry-\(entry.id.uuidString)",
            note: "完成听写判定：\(entry.content)",
            createdAt: entry.updatedAt,
            countsAsActiveDay: true,
            in: modelContext
        )
    }

    @discardableResult
    static func awardTaskExecution(
        _ record: TaskExecutionRecord,
        taskTitle: String,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        guard record.status == .completed else { return nil }
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return awardIfNeeded(
            amount: taskRewardAmount,
            kind: .reward,
            sourceType: .taskExecution,
            sourceIDRawValue: record.id.uuidString,
            idempotencyKey: "task-execution-\(record.id.uuidString)",
            note: trimmedTitle.isEmpty ? "完成待办" : "完成待办：\(trimmedTitle)",
            createdAt: record.completedAt ?? .now,
            countsAsActiveDay: false,
            in: modelContext
        )
    }

    @discardableResult
    static func redeemManual(
        title: String,
        amount: Int,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount > 0, !trimmedTitle.isEmpty else { return nil }
        guard currentBalance(in: modelContext) >= amount else { return nil }

        let id = UUID()
        let entry = PointLedgerEntry(
            id: id,
            createdAt: .now,
            amount: -amount,
            kind: .redemption,
            sourceType: .manualRedemption,
            sourceIDRawValue: id.uuidString,
            idempotencyKey: "manual-redemption-\(id.uuidString)",
            note: trimmedTitle
        )
        modelContext.insert(entry)
        return entry
    }

    @discardableResult
    static func addManualPoints(
        title: String,
        amount: Int,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amount > 0, !trimmedTitle.isEmpty else { return nil }

        let id = UUID()
        let entry = PointLedgerEntry(
            id: id,
            createdAt: .now,
            amount: amount,
            kind: .reward,
            sourceType: .manualAdjustment,
            sourceIDRawValue: id.uuidString,
            idempotencyKey: "manual-add-points-\(id.uuidString)",
            note: trimmedTitle
        )
        modelContext.insert(entry)
        return entry
    }

    static func reverseEntries(
        sourceType: PointLedgerSourceType,
        sourceID: UUID,
        in modelContext: ModelContext
    ) {
        reverseEntries(
            sourceType: sourceType,
            sourceIDRawValue: sourceID.uuidString,
            in: modelContext
        )
    }

    static func reverseEntries(
        sourceType: PointLedgerSourceType,
        sourceIDRawValue: String,
        in modelContext: ModelContext
    ) {
        let typeRawValue = sourceType.rawValue
        let entries = (try? modelContext.fetch(
            FetchDescriptor<PointLedgerEntry>(
                predicate: #Predicate<PointLedgerEntry> { entry in
                    entry.sourceTypeRawValue == typeRawValue &&
                    entry.sourceIDRawValue == sourceIDRawValue &&
                    !entry.isReversal
                }
            )
        )) ?? []

        for entry in entries where !hasReversal(for: entry, in: modelContext) {
            let reversalID = UUID()
            let reversal = PointLedgerEntry(
                id: reversalID,
                createdAt: .now,
                amount: -entry.amount,
                kind: .reversal,
                sourceType: entry.sourceType,
                sourceIDRawValue: entry.sourceIDRawValue,
                idempotencyKey: "reverse-\(entry.id.uuidString)",
                note: "冲正：\(entry.note)",
                isReversal: true,
                reversesEntryIDRawValue: entry.id.uuidString
            )
            modelContext.insert(reversal)
        }
    }

    @discardableResult
    private static func awardIfNeeded(
        amount: Int,
        kind: PointLedgerKind,
        sourceType: PointLedgerSourceType,
        sourceIDRawValue: String,
        idempotencyKey: String,
        note: String,
        createdAt: Date,
        countsAsActiveDay: Bool,
        in modelContext: ModelContext
    ) -> PointLedgerEntry? {
        guard amount > 0 else { return nil }
        guard !hasEntry(idempotencyKey: idempotencyKey, in: modelContext) else { return nil }

        let entry = PointLedgerEntry(
            createdAt: createdAt,
            amount: amount,
            kind: kind,
            sourceType: sourceType,
            sourceIDRawValue: sourceIDRawValue,
            idempotencyKey: idempotencyKey,
            note: note
        )
        modelContext.insert(entry)

        if countsAsActiveDay {
            applyDailyStreakIfNeeded(on: createdAt, in: modelContext)
        }

        return entry
    }

    private static func applyDailyStreakIfNeeded(on date: Date, in modelContext: ModelContext) {
        let calendar = Calendar.current
        let activeDay = calendar.startOfDay(for: date)
        let entries = (try? modelContext.fetch(FetchDescriptor<PointLedgerEntry>())) ?? []
        let currentSnapshot = streakSnapshot(from: entries, referenceDate: .now, calendar: calendar)
        let activeDaySnapshot = streakSnapshot(from: entries, referenceDate: activeDay, calendar: calendar)
        let state = ensureRewardState(in: modelContext)

        state.currentStreak = currentSnapshot.currentStreak
        state.lastActiveDay = currentSnapshot.lastActiveDay
        state.longestStreak = currentSnapshot.longestStreak
        state.updatedAt = .now

        let streakEndingOnActiveDay = activeDaySnapshot.currentStreak
        let bonusAmount: Int
        if streakEndingOnActiveDay == 3 {
            bonusAmount = 5
        } else if streakEndingOnActiveDay == 7 || (streakEndingOnActiveDay > 7 && streakEndingOnActiveDay % 7 == 0) {
            bonusAmount = 15
        } else {
            bonusAmount = 0
        }

        guard bonusAmount > 0 else { return }

        let dayKey = dayKey(for: activeDay)
        _ = awardIfNeeded(
            amount: bonusAmount,
            kind: .streakBonus,
            sourceType: .dailyStreak,
            sourceIDRawValue: dayKey,
            idempotencyKey: "daily-streak-\(dayKey)",
            note: "连续学习 \(streakEndingOnActiveDay) 天",
            createdAt: date,
            countsAsActiveDay: false,
            in: modelContext
        )
    }

    private static func ensureRewardState(in modelContext: ModelContext) -> PointRewardState {
        let states = ((try? modelContext.fetch(FetchDescriptor<PointRewardState>())) ?? []).sorted {
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        if let canonical = states.first {
            for duplicate in states.dropFirst() {
                modelContext.delete(duplicate)
            }
            return canonical
        }

        let state = PointRewardState()
        modelContext.insert(state)
        return state
    }

    private static func streakLength(
        endingOn endDay: Date,
        activeDays: Set<Date>,
        calendar: Calendar
    ) -> Int {
        var length = 0
        var cursor = calendar.startOfDay(for: endDay)
        while activeDays.contains(cursor) {
            length += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previousDay
        }
        return length
    }

    private static func hasEntry(idempotencyKey: String, in modelContext: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<PointLedgerEntry>(
            predicate: #Predicate<PointLedgerEntry> { entry in
                entry.idempotencyKey == idempotencyKey
            }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func hasReversal(for entry: PointLedgerEntry, in modelContext: ModelContext) -> Bool {
        let reversedID = entry.id.uuidString
        let descriptor = FetchDescriptor<PointLedgerEntry>(
            predicate: #Predicate<PointLedgerEntry> { candidate in
                candidate.reversesEntryIDRawValue == reversedID
            }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }
}

struct AccuracyBonusCard: View {
    let title: String
    let amount: Int
    let accuracyText: String
    var tint: Color = .orange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: amount > 0 ? "trophy.fill" : "trophy")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(iconColor)
                    .frame(width: 52, height: 52)
                    .background(iconColor.opacity(amount > 0 ? 0.18 : 0.10), in: Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    HStack(spacing: 8) {
                        if amount > 0 {
                            Text("已到账")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green, in: Capsule())
                        }

                        Spacer(minLength: 0)
                    }

                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(messageColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("+\(amount)")
                        .font(.system(size: amount > 0 ? 36 : 28, weight: .black, design: .rounded))
                        .foregroundStyle(amount > 0 ? Color.green : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("积分")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 92, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Label(accuracyText, systemImage: "percent")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.12), in: Capsule())

                Text(nextTierText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(22)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(borderColor, lineWidth: amount > 0 ? 1.5 : 1)
        )
    }

    private var message: String {
        if amount > 0 {
            return "正确率 \(accuracyText)，本次额外奖励 \(amount) 分"
        }

        return "本次未获得额外奖励，正确率达到 60% 后可获得 +5 分"
    }

    private var iconColor: Color {
        amount > 0 ? .yellow : tint
    }

    private var messageColor: Color {
        amount > 0 ? Color.primary.opacity(0.78) : Color.secondary
    }

    private var cardBackground: some ShapeStyle {
        amount > 0
            ? AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.yellow.opacity(0.26),
                        tint.opacity(0.16),
                        Color(uiColor: .secondarySystemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            : AnyShapeStyle(.thinMaterial)
    }

    private var borderColor: Color {
        amount > 0 ? .yellow.opacity(0.55) : .secondary.opacity(0.12)
    }

    private var nextTierText: String {
        guard let accuracyValue = Int(accuracyText.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else {
            return "奖励档位：60% +5，70% +20，80% +30，90% +50，100% +80"
        }

        if accuracyValue >= 100 {
            return "已获得最高正确率奖励"
        } else if accuracyValue >= 90 {
            return "全对可升级到 +80"
        } else if accuracyValue >= 80 {
            return "达到 90% 可升级到 +50"
        } else if accuracyValue >= 70 {
            return "达到 80% 可升级到 +30"
        } else if accuracyValue >= 60 {
            return "达到 70% 可升级到 +20"
        }

        return "达到 60% 可获得 +5"
    }
}

struct PointsDashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PointLedgerEntry.createdAt, order: .reverse) private var entries: [PointLedgerEntry]
    @Query private var reviewRecords: [ReviewRecord]
    @Query private var dictationSessions: [DictationSession]
    @Query private var taskExecutions: [TaskExecutionRecord]
    @Query private var taskItems: [TaskItem]

    @State private var redemptionTitle = ""
    @State private var redemptionAmountText = "5"
    @State private var additionTitle = ""
    @State private var additionAmountText = "5"
    @State private var errorMessage: String?

    private var balance: Int {
        canonicalEntries.reduce(0) { $0 + $1.amount }
    }

    private var currentStreak: Int {
        streakSnapshot.currentStreak
    }

    private var longestStreak: Int {
        streakSnapshot.longestStreak
    }

    private var streakSnapshot: PointStreakSnapshot {
        PointLedgerService.streakSnapshot(
            reviewRecords: reviewRecords,
            dictationSessions: dictationSessions
        )
    }

    private var canRedeem: Bool {
        guard let redemptionAmount else { return false }
        return !redemptionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            balance >= redemptionAmount
    }

    private var canAddPoints: Bool {
        additionAmount != nil &&
            !additionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var redemptionAmount: Int? {
        positiveInt(from: redemptionAmountText)
    }

    private var additionAmount: Int? {
        positiveInt(from: additionAmountText)
    }

    private var displayItems: [PointLedgerDisplayItem] {
        PointLedgerDisplayItem.items(
            from: canonicalEntries,
            taskTitleByExecutionID: taskTitleByExecutionID
        )
    }

    private var canonicalEntries: [PointLedgerEntry] {
        PointLedgerService.canonicalEntries(entries)
    }

    private var recentDisplayItems: [PointLedgerDisplayItem] {
        Array(displayItems.prefix(10))
    }

    private var taskTitleByExecutionID: [String: String] {
        PointTaskTitleResolver.titleByExecutionID(
            taskExecutions: taskExecutions,
            taskItems: taskItems
        )
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    PointsSettingsIcon(name: "star.circle.fill", color: .yellow)
                    Text("当前积分")
                    Spacer()
                    Text("\(balance)")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.orange)
                }

                HStack {
                    PointsSettingsIcon(name: "flame.fill", color: .red)
                    Text("连续学习")
                    Spacer()
                    Text("\(currentStreak) 天")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    PointsSettingsIcon(name: "trophy.fill", color: .purple)
                    Text("最长连续")
                    Spacer()
                    Text("\(longestStreak) 天")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("积分概览")
            } footer: {
                Text("连续学习统计完成听写、听写判定和错题复习，待办任务完成不计入连续天数。")
            }

            Section {
                TextField("兑换内容", text: $redemptionTitle)
                LabeledContent("消耗积分") {
                    TextField("1", text: $redemptionAmountText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    redeem()
                } label: {
                    Label("确认兑换", systemImage: "gift.fill")
                }
                .disabled(!canRedeem)
            } header: {
                Text("手动兑换")
            } footer: {
                Text("兑换会生成一条负数流水，不会删除历史记录。")
            }

            Section {
                TextField("增加说明", text: $additionTitle)
                LabeledContent("增加积分") {
                    TextField("1", text: $additionAmountText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }

                Button {
                    addPoints()
                } label: {
                    Label("确认增加", systemImage: "plus.circle.fill")
                }
                .disabled(!canAddPoints)
            } header: {
                Text("手动增加")
            } footer: {
                Text("增加会生成一条正数流水，适合记录家长额外奖励。")
            }

            Section {
                if entries.isEmpty {
                    Text("还没有积分记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentDisplayItems) { item in
                        PointLedgerEntryRow(item: item)
                    }

                    if displayItems.count > recentDisplayItems.count {
                        NavigationLink {
                            PointLedgerHistoryView()
                        } label: {
                            HStack {
                                Label("查看全部明细", systemImage: "list.bullet.rectangle")
                                Spacer()
                                Text("\(displayItems.count) 组")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("最近明细")
            } footer: {
                if displayItems.count > recentDisplayItems.count {
                    Text("复习和听写的单项积分会按天汇总显示，完整流水仍保留在数据中。")
                }
            }
        }
        .navigationTitle("积分与兑换")
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func redeem() {
        guard let amount = redemptionAmount else {
            errorMessage = "请输入有效的消耗积分。"
            return
        }

        guard PointLedgerService.redeemManual(
            title: redemptionTitle,
            amount: amount,
            in: modelContext
        ) != nil else {
            errorMessage = "积分不足，或兑换内容还没有填写。"
            return
        }

        do {
            try modelContext.save()
            redemptionTitle = ""
            redemptionAmountText = "5"
            AppDataChangeCenter.post()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addPoints() {
        guard let amount = additionAmount else {
            errorMessage = "请输入有效的增加积分。"
            return
        }

        guard PointLedgerService.addManualPoints(
            title: additionTitle,
            amount: amount,
            in: modelContext
        ) != nil else {
            errorMessage = "增加说明还没有填写，或积分数字无效。"
            return
        }

        do {
            try modelContext.save()
            additionTitle = ""
            additionAmountText = "5"
            AppDataChangeCenter.post()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func positiveInt(from text: String) -> Int? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmedText), value > 0 else { return nil }
        return value
    }
}

private struct PointLedgerHistoryView: View {
    @Query(sort: \PointLedgerEntry.createdAt, order: .reverse) private var entries: [PointLedgerEntry]
    @Query private var taskExecutions: [TaskExecutionRecord]
    @Query private var taskItems: [TaskItem]

    private var taskTitleByExecutionID: [String: String] {
        PointTaskTitleResolver.titleByExecutionID(
            taskExecutions: taskExecutions,
            taskItems: taskItems
        )
    }

    private var displayItems: [PointLedgerDisplayItem] {
        PointLedgerDisplayItem.items(
            from: PointLedgerService.canonicalEntries(entries),
            taskTitleByExecutionID: taskTitleByExecutionID
        )
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("还没有积分记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayItems) { item in
                    PointLedgerEntryRow(item: item)
                }
            }
        }
        .navigationTitle("积分明细")
    }
}

private struct PointLedgerEntryRow: View {
    let item: PointLedgerDisplayItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.iconName)
                .font(.headline)
                .foregroundStyle(item.iconColor)
                .frame(width: 30, height: 30)
                .background(item.iconColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.signedAmountText)
                .font(.headline.weight(.bold))
                .foregroundStyle(item.amount >= 0 ? .green : .red)
        }
        .padding(.vertical, 4)
    }
}

private struct PointLedgerDisplayItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let amount: Int
    let kind: PointLedgerKind
    let createdAt: Date

    var signedAmountText: String {
        amount > 0 ? "+\(amount)" : "\(amount)"
    }

    var iconName: String {
        switch kind {
        case .reward:
            return "plus.circle.fill"
        case .streakBonus:
            return "flame.fill"
        case .redemption:
            return "gift.fill"
        case .reversal:
            return "arrow.uturn.backward.circle.fill"
        }
    }

    var iconColor: Color {
        switch kind {
        case .reward:
            return .green
        case .streakBonus:
            return .orange
        case .redemption:
            return .purple
        case .reversal:
            return .red
        }
    }

    static func items(
        from entries: [PointLedgerEntry],
        taskTitleByExecutionID: [String: String]
    ) -> [PointLedgerDisplayItem] {
        let calendar = Calendar.current
        var compactEntriesByKey: [PointLedgerCompactKey: [PointLedgerEntry]] = [:]
        var items: [PointLedgerDisplayItem] = []

        for entry in entries {
            if let key = PointLedgerCompactKey(entry: entry, calendar: calendar) {
                compactEntriesByKey[key, default: []].append(entry)
            } else {
                items.append(
                    PointLedgerDisplayItem.single(
                        entry: entry,
                        taskTitle: taskTitleByExecutionID[entry.sourceIDRawValue]
                    )
                )
            }
        }

        for (key, groupedEntries) in compactEntriesByKey {
            items.append(PointLedgerDisplayItem.compact(key: key, entries: groupedEntries))
        }

        return items.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id < rhs.id
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func single(
        entry: PointLedgerEntry,
        taskTitle: String?
    ) -> PointLedgerDisplayItem {
        PointLedgerDisplayItem(
            id: "entry-\(entry.id.uuidString)",
            title: title(for: entry, taskTitle: taskTitle),
            subtitle: entry.createdAt.formatted(date: .abbreviated, time: .shortened),
            amount: entry.amount,
            kind: entry.kind,
            createdAt: entry.createdAt
        )
    }

    private static func compact(
        key: PointLedgerCompactKey,
        entries: [PointLedgerEntry]
    ) -> PointLedgerDisplayItem {
        let sortedEntries = entries.sorted { $0.createdAt > $1.createdAt }
        let amount = sortedEntries.reduce(0) { $0 + $1.amount }
        let createdAt = sortedEntries.first?.createdAt ?? key.day
        let titlePrefix = key.sourceType == .reviewRecord ? "完成复习" : "完成听写判定"
        let subtitle = "\(key.day.formatted(date: .abbreviated, time: .omitted)) · \(entries.count) 条记录"

        return PointLedgerDisplayItem(
            id: "compact-\(key.sourceType.rawValue)-\(Int(key.day.timeIntervalSinceReferenceDate))",
            title: "\(titlePrefix) \(entries.count) 项",
            subtitle: subtitle,
            amount: amount,
            kind: .reward,
            createdAt: createdAt
        )
    }

    private static func title(for entry: PointLedgerEntry, taskTitle: String?) -> String {
        if entry.sourceType == .taskExecution,
           let taskTitle,
           !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.isReversal ? "冲正：完成待办：\(taskTitle)" : "完成待办：\(taskTitle)"
        }

        if !entry.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return entry.note
        }
        return entry.kind.rawValue
    }
}

private struct PointLedgerCompactKey: Hashable {
    let sourceType: PointLedgerSourceType
    let day: Date

    init?(entry: PointLedgerEntry, calendar: Calendar) {
        guard entry.kind == .reward,
              !entry.isReversal,
              entry.amount > 0,
              entry.sourceType == .reviewRecord || entry.sourceType == .dictationEntry else {
            return nil
        }

        self.sourceType = entry.sourceType
        self.day = calendar.startOfDay(for: entry.createdAt)
    }
}

private enum PointTaskTitleResolver {
    static func titleByExecutionID(
        taskExecutions: [TaskExecutionRecord],
        taskItems: [TaskItem]
    ) -> [String: String] {
        let titlesByTaskID = Dictionary(
            taskItems.map { ($0.id, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )

        return Dictionary(
            taskExecutions.compactMap { execution -> (String, String)? in
                guard let title = titlesByTaskID[execution.taskID] else { return nil }
                return (execution.id.uuidString, title)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

private struct PointsSettingsIcon: View {
    let name: String
    let color: Color

    var body: some View {
        Image(systemName: name)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
