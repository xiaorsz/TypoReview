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

struct AccuracyBonusReward {
    let amount: Int
}

enum PointLedgerService {
    static let reviewRewardAmount = 1
    static let dictationRewardAmount = 1
    static let taskRewardAmount = 5

    static func accuracyBonusReward(correctCount: Int, totalCount: Int) -> AccuracyBonusReward? {
        guard totalCount > 0, correctCount >= 0, correctCount <= totalCount else { return nil }

        if correctCount == totalCount {
            return AccuracyBonusReward(amount: 80)
        }

        let accuracy = Double(correctCount) / Double(totalCount)
        if accuracy >= 0.9 {
            return AccuracyBonusReward(amount: 50)
        } else if accuracy >= 0.8 {
            return AccuracyBonusReward(amount: 30)
        } else if accuracy >= 0.7 {
            return AccuracyBonusReward(amount: 20)
        } else if accuracy >= 0.6 {
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
        let entries = (try? modelContext.fetch(FetchDescriptor<PointLedgerEntry>())) ?? []
        let state = (try? modelContext.fetch(FetchDescriptor<PointRewardState>()))?.first
        return PointBalanceSnapshot(
            balance: entries.reduce(0) { $0 + $1.amount },
            currentStreak: state?.currentStreak ?? 0,
            longestStreak: state?.longestStreak ?? 0
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
        let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
        return "\(accuracy)%"
    }

    static func currentBalance(in modelContext: ModelContext) -> Int {
        currentSnapshot(in: modelContext).balance
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
        let state = ensureRewardState(in: modelContext)

        if let lastActiveDay = state.lastActiveDay,
           calendar.isDate(lastActiveDay, inSameDayAs: activeDay) {
            return
        }

        if let lastActiveDay = state.lastActiveDay,
           let yesterday = calendar.date(byAdding: .day, value: -1, to: activeDay),
           calendar.isDate(lastActiveDay, inSameDayAs: yesterday) {
            state.currentStreak += 1
        } else {
            state.currentStreak = 1
        }

        state.lastActiveDay = activeDay
        state.longestStreak = max(state.longestStreak, state.currentStreak)
        state.updatedAt = .now

        let bonusAmount: Int
        if state.currentStreak == 3 {
            bonusAmount = 5
        } else if state.currentStreak == 7 || (state.currentStreak > 7 && state.currentStreak % 7 == 0) {
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
            note: "连续学习 \(state.currentStreak) 天",
            createdAt: date,
            countsAsActiveDay: false,
            in: modelContext
        )
    }

    private static func ensureRewardState(in modelContext: ModelContext) -> PointRewardState {
        let states = (try? modelContext.fetch(FetchDescriptor<PointRewardState>())) ?? []
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
        HStack(spacing: 14) {
            Image(systemName: amount > 0 ? "star.circle.fill" : "star.circle")
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("+\(amount)")
                .font(.title3.weight(.bold))
                .foregroundStyle(amount > 0 ? .green : .secondary)
        }
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var message: String {
        if amount > 0 {
            return "正确率 \(accuracyText)，已额外奖励 \(amount) 分"
        }

        return "正确率达到 60% 后可获得额外积分"
    }
}

struct PointsDashboardView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \PointLedgerEntry.createdAt, order: .reverse) private var entries: [PointLedgerEntry]
    @Query private var rewardStates: [PointRewardState]
    @Query private var taskExecutions: [TaskExecutionRecord]
    @Query private var taskItems: [TaskItem]

    @State private var redemptionTitle = ""
    @State private var redemptionAmount = 5
    @State private var errorMessage: String?

    private var balance: Int {
        entries.reduce(0) { $0 + $1.amount }
    }

    private var currentStreak: Int {
        rewardStates.first?.currentStreak ?? 0
    }

    private var longestStreak: Int {
        rewardStates.first?.longestStreak ?? 0
    }

    private var canRedeem: Bool {
        redemptionAmount > 0 &&
        !redemptionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        balance >= redemptionAmount
    }

    private var recentEntries: [PointLedgerEntry] {
        Array(entries.prefix(10))
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
                Text("连续学习只统计听写判定和错题复习，待办任务完成不计入连续天数。")
            }

            Section {
                TextField("兑换内容", text: $redemptionTitle)
                Stepper(value: $redemptionAmount, in: 1...max(balance, redemptionAmount, 1)) {
                    HStack {
                        Text("消耗积分")
                        Spacer()
                        Text("\(redemptionAmount)")
                            .foregroundStyle(.secondary)
                    }
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
                if entries.isEmpty {
                    Text("还没有积分记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentEntries) { entry in
                        PointLedgerEntryRow(
                            entry: entry,
                            taskTitle: taskTitleByExecutionID[entry.sourceIDRawValue]
                        )
                    }

                    if entries.count > recentEntries.count {
                        NavigationLink {
                            PointLedgerHistoryView()
                        } label: {
                            HStack {
                                Label("查看全部明细", systemImage: "list.bullet.rectangle")
                                Spacer()
                                Text("\(entries.count) 条")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("最近明细")
            } footer: {
                if entries.count > recentEntries.count {
                    Text("这里只显示最近 10 条，完整流水可进入全部明细查看。")
                }
            }
        }
        .navigationTitle("积分与兑换")
        .alert("兑换失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func redeem() {
        guard PointLedgerService.redeemManual(
            title: redemptionTitle,
            amount: redemptionAmount,
            in: modelContext
        ) != nil else {
            errorMessage = "积分不足，或兑换内容还没有填写。"
            return
        }

        do {
            try modelContext.save()
            redemptionTitle = ""
            redemptionAmount = min(5, max(balance, 1))
            NotificationCenter.default.post(name: Notification.Name("appDataDidMutate"), object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
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

    var body: some View {
        List {
            if entries.isEmpty {
                Text("还没有积分记录")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    PointLedgerEntryRow(
                        entry: entry,
                        taskTitle: taskTitleByExecutionID[entry.sourceIDRawValue]
                    )
                }
            }
        }
        .navigationTitle("积分明细")
    }
}

private struct PointLedgerEntryRow: View {
    let entry: PointLedgerEntry
    let taskTitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(iconColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.signedAmountText)
                .font(.headline.weight(.bold))
                .foregroundStyle(entry.amount >= 0 ? .green : .red)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
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

    private var iconName: String {
        switch entry.kind {
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

    private var iconColor: Color {
        switch entry.kind {
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
