import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class AppSettingsStore {
    private enum StorageKeys {
        static let snapshot = "app_settings_snapshot_v1"
        static let legacyReviewInteractionStyle = "reviewInteractionStyle"
    }

    private let userDefaults: UserDefaults
    private(set) var revision: Int = 0
    private(set) var lastSwiftDataError = ""

    var id: UUID
    var childName: String
    var dailyLimit: Int
    var remindHour: Int
    var remindMinute: Int
    var reviewInteractionStyle: ReviewInteractionStyle
    var boardAutoplayEnabled: Bool
    var boardAutoplayStartHour: Int
    var boardAutoplayStartMinute: Int
    var boardAutoplayEndHour: Int
    var boardAutoplayEndMinute: Int
    var boardAutoplayDurationMinutes: Int
    var boardAutoplaySlotsRawValue: String
    var boardManualPlaybackOptionRawValue: String
    var boardAutoplaySkipWeekends: Bool
    var boardAutoplaySkipChinaHolidays: Bool

    private var hasBootstrapped = false

    init(appGroupIdentifier: String? = nil) {
        if let appGroupIdentifier,
           let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier) {
            userDefaults = sharedDefaults
        } else {
            userDefaults = .standard
        }

        // ⚠️ 注意：不能在这里实例化 AppSettings()。
        // AppSettings 是 @Model 类，实例化时 SwiftData 会调用 ModelContainer.currentContainer()，
        // 但 AppSettingsStore 在 TypoReviewApp.init() 的最开头就被创建，ModelContainer 还不存在。
        // iOS 17 上这会触发 _assertionFailure 崩溃。改为直接使用静态默认常量。
        id = UUID()
        childName = AppSettings.defaultChildName
        dailyLimit = AppSettings.defaultDailyLimit
        remindHour = AppSettings.defaultRemindHour
        remindMinute = AppSettings.defaultRemindMinute
        reviewInteractionStyle = AppSettings.defaultReviewInteractionStyle
        boardAutoplayEnabled = AppSettings.defaultBoardAutoplayEnabled
        boardAutoplayStartHour = AppSettings.defaultBoardAutoplayStartHour
        boardAutoplayStartMinute = AppSettings.defaultBoardAutoplayStartMinute
        boardAutoplayEndHour = AppSettings.defaultBoardAutoplayEndHour
        boardAutoplayEndMinute = AppSettings.defaultBoardAutoplayEndMinute
        boardAutoplayDurationMinutes = AppSettings.defaultBoardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = AppSettings.defaultBoardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = AppSettings.defaultBoardManualPlaybackOption
        boardAutoplaySkipWeekends = AppSettings.defaultBoardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = AppSettings.defaultBoardAutoplaySkipChinaHolidays

        if let snapshot = loadSnapshotFromDefaults() {
            apply(snapshot: snapshot, incrementRevision: false)
        }
    }

    var boardManualPlaybackOption: BoardManualPlaybackOption {
        // ⚠️ 不能调 modelRepresentation.boardManualPlaybackOption —— 那会造成循环：
        // modelRepresentation → self.boardManualPlaybackOption → modelRepresentation → ∞ 栈溢出
        get { BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds }
        set { boardManualPlaybackOptionRawValue = newValue.rawValue }
    }

    var boardAutoplaySlots: [BoardAutoplaySlot] {
        get { modelRepresentation.boardAutoplaySlots }
        set {
            let settings = modelRepresentation
            settings.boardAutoplaySlots = newValue
            apply(from: settings, incrementRevision: false)
        }
    }

    var boardAutoplayTimeSummary: String {
        modelRepresentation.boardAutoplayTimeSummary
    }

    var boardAutoplayDurationSummary: String {
        modelRepresentation.boardAutoplayDurationSummary
    }

    var boardManualPlaybackOptionSummary: String {
        modelRepresentation.boardManualPlaybackOptionSummary
    }

    var boardAutoplayRuleSummary: String {
        modelRepresentation.boardAutoplayRuleSummary
    }

    var hasValidBoardAutoplayWindow: Bool {
        modelRepresentation.hasValidBoardAutoplayWindow
    }

    var snapshot: AppSettingsSnapshot {
        AppSettingsSnapshot(modelRepresentation)
    }

    // ⚠️ 只能在 ModelContainer 创建完成（bootstrap 被调用）之后调用此属性。
    // AppSettings 是 @Model 类，实例化需要 ModelContainer.currentContainer 已存在。
    // 在 TypoReviewApp.init() → AppSettingsStore.init() 阶段禁止调用。
    var modelRepresentation: AppSettings {
        let settings = AppSettings(
            id: id,
            childName: childName,
            dailyLimit: dailyLimit,
            remindHour: remindHour,
            remindMinute: remindMinute,
            reviewInteractionStyle: reviewInteractionStyle,
            boardAutoplayEnabled: boardAutoplayEnabled,
            boardAutoplayStartHour: boardAutoplayStartHour,
            boardAutoplayStartMinute: boardAutoplayStartMinute,
            boardAutoplayEndHour: boardAutoplayEndHour,
            boardAutoplayEndMinute: boardAutoplayEndMinute,
            boardAutoplayDurationMinutes: boardAutoplayDurationMinutes,
            boardAutoplaySlots: [],
            boardManualPlaybackOption: .untilPlaylistEnds, // 固定传常量，rawValue 在下方立即被覆盖；不能传 self.boardManualPlaybackOption（循环）
            boardAutoplaySkipWeekends: boardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: boardAutoplaySkipChinaHolidays
        )
        settings.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
        settings.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
        settings.boardManualPlaybackOptionRawValue = boardManualPlaybackOptionRawValue
        return settings
    }

    func bootstrap(using modelContext: ModelContext) {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        if loadSnapshotFromDefaults() != nil {
            return
        }

        let previousSnapshot = snapshot

        if let migratedSnapshot = loadSnapshotFromSwiftData(using: modelContext) {
            apply(snapshot: migratedSnapshot, incrementRevision: false)
        }

        persistToDefaults()
        if snapshot != previousSnapshot {
            markChanged()
        }
    }

    func refreshFromSwiftDataIfPossible(using modelContext: ModelContext) {
        guard let remoteSnapshot = loadSnapshotFromSwiftData(using: modelContext) else {
            return
        }

        guard remoteSnapshot != snapshot else { return }
        apply(snapshot: remoteSnapshot, incrementRevision: false)
        persistToDefaults()
        markChanged()
    }

    func persist(using modelContext: ModelContext) {
        persistToDefaults()
        markChanged()
        syncToSwiftDataIfPossible(using: modelContext)
    }

    func restore(from snapshot: AppSettingsSnapshot?, using modelContext: ModelContext) {
        if let snapshot {
            apply(snapshot: snapshot, incrementRevision: false)
        } else {
            // 不实例化 AppSettings()（@Model 类需要 ModelContainer），改为直接应用默认 snapshot
            apply(snapshot: makeDefaultSnapshot(), incrementRevision: false)
        }
        persist(using: modelContext)
    }

    private func makeDefaultSnapshot() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            id: UUID(),
            childName: AppSettings.defaultChildName,
            dailyLimit: AppSettings.defaultDailyLimit,
            remindHour: AppSettings.defaultRemindHour,
            remindMinute: AppSettings.defaultRemindMinute,
            reviewInteractionStyleRawValue: AppSettings.defaultReviewInteractionStyle.rawValue,
            boardAutoplayEnabled: AppSettings.defaultBoardAutoplayEnabled,
            boardAutoplayStartHour: AppSettings.defaultBoardAutoplayStartHour,
            boardAutoplayStartMinute: AppSettings.defaultBoardAutoplayStartMinute,
            boardAutoplayEndHour: AppSettings.defaultBoardAutoplayEndHour,
            boardAutoplayEndMinute: AppSettings.defaultBoardAutoplayEndMinute,
            boardAutoplayDurationMinutes: AppSettings.defaultBoardAutoplayDurationMinutes,
            boardAutoplaySlotsRawValue: AppSettings.defaultBoardAutoplaySlotsRawValue,
            boardManualPlaybackOptionRawValue: AppSettings.defaultBoardManualPlaybackOption,
            boardAutoplaySkipWeekends: AppSettings.defaultBoardAutoplaySkipWeekends,
            boardAutoplaySkipChinaHolidays: AppSettings.defaultBoardAutoplaySkipChinaHolidays
        )
    }

    func boardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.boardAutoplayWindow(on: date)
    }

    func currentBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.currentBoardAutoplayWindow(on: date)
    }

    func nextBoardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        modelRepresentation.nextBoardAutoplayWindow(on: date)
    }

    func isBoardAutoplayActive(on date: Date) -> Bool {
        modelRepresentation.isBoardAutoplayActive(on: date)
    }

    func boardAutoplayBlockedReason(on date: Date) -> String? {
        modelRepresentation.boardAutoplayBlockedReason(on: date)
    }

    func addBoardAutoplaySlot() {
        let settings = modelRepresentation
        settings.addBoardAutoplaySlot()
        apply(from: settings, incrementRevision: false)
    }

    func updateBoardAutoplaySlot(id: UUID, _ update: (inout BoardAutoplaySlot) -> Void) {
        let settings = modelRepresentation
        settings.updateBoardAutoplaySlot(id: id, update)
        apply(from: settings, incrementRevision: false)
    }

    func removeBoardAutoplaySlot(id: UUID) {
        let settings = modelRepresentation
        settings.removeBoardAutoplaySlot(id: id)
        apply(from: settings, incrementRevision: false)
    }

    private func apply(snapshot: AppSettingsSnapshot, incrementRevision: Bool) {
        id = snapshot.id
        childName = snapshot.childName
        dailyLimit = snapshot.dailyLimit
        remindHour = snapshot.remindHour
        remindMinute = snapshot.remindMinute
        reviewInteractionStyle = ReviewInteractionStyle(rawValue: snapshot.reviewInteractionStyleRawValue)
            ?? AppSettings.defaultReviewInteractionStyle
        boardAutoplayEnabled = snapshot.boardAutoplayEnabled
        boardAutoplayStartHour = snapshot.boardAutoplayStartHour
        boardAutoplayStartMinute = snapshot.boardAutoplayStartMinute
        boardAutoplayEndHour = snapshot.boardAutoplayEndHour
        boardAutoplayEndMinute = snapshot.boardAutoplayEndMinute
        boardAutoplayDurationMinutes = snapshot.boardAutoplayDurationMinutes
        boardAutoplaySlotsRawValue = snapshot.boardAutoplaySlotsRawValue
        boardManualPlaybackOptionRawValue = snapshot.boardManualPlaybackOptionRawValue
        boardAutoplaySkipWeekends = snapshot.boardAutoplaySkipWeekends
        boardAutoplaySkipChinaHolidays = snapshot.boardAutoplaySkipChinaHolidays

        if incrementRevision {
            markChanged()
        }
    }

    private func apply(from settings: AppSettings, incrementRevision: Bool) {
        apply(snapshot: AppSettingsSnapshot(settings), incrementRevision: incrementRevision)
    }

    private func persistToDefaults() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            userDefaults.set(data, forKey: StorageKeys.snapshot)
        }
        UserDefaults.standard.set(reviewInteractionStyle.rawValue, forKey: StorageKeys.legacyReviewInteractionStyle)
    }

    private func loadSnapshotFromDefaults() -> AppSettingsSnapshot? {
        guard let data = userDefaults.data(forKey: StorageKeys.snapshot) else {
            return nil
        }
        return try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
    }

    private func loadSnapshotFromSwiftData(using modelContext: ModelContext) -> AppSettingsSnapshot? {
        do {
            return try safelyAccessSwiftData {
                try modelContext.fetch(FetchDescriptor<AppSettings>()).first.map(AppSettingsSnapshot.init)
            }
        } catch {
            lastSwiftDataError = error.localizedDescription
            print("AppSettings migration from SwiftData skipped: \(error)")
            return nil
        }
    }

    private func syncToSwiftDataIfPossible(using modelContext: ModelContext) {
        do {
            try safelyAccessSwiftData {
                let existing = try modelContext.fetch(FetchDescriptor<AppSettings>())
                let target: AppSettings
                if let first = existing.first {
                    target = first
                } else {
                    target = AppSettings()
                    modelContext.insert(target)
                }

                target.id = id
                target.childName = childName
                target.dailyLimit = dailyLimit
                target.remindHour = remindHour
                target.remindMinute = remindMinute
                target.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
                target.boardAutoplayEnabled = boardAutoplayEnabled
                target.boardAutoplayStartHour = boardAutoplayStartHour
                target.boardAutoplayStartMinute = boardAutoplayStartMinute
                target.boardAutoplayEndHour = boardAutoplayEndHour
                target.boardAutoplayEndMinute = boardAutoplayEndMinute
                target.boardAutoplayDurationMinutes = boardAutoplayDurationMinutes
                target.boardAutoplaySlotsRawValue = boardAutoplaySlotsRawValue
                target.boardManualPlaybackOptionRawValue = boardManualPlaybackOptionRawValue
                target.boardAutoplaySkipWeekends = boardAutoplaySkipWeekends
                target.boardAutoplaySkipChinaHolidays = boardAutoplaySkipChinaHolidays

                for duplicate in existing.dropFirst() {
                    modelContext.delete(duplicate)
                }

                if modelContext.hasChanges {
                    try modelContext.save()
                }
            }
            lastSwiftDataError = ""
        } catch {
            lastSwiftDataError = error.localizedDescription
            print("AppSettings sync to SwiftData skipped: \(error)")
        }
    }

    private func markChanged() {
        revision &+= 1
    }

    private func safelyAccessSwiftData<T>(_ work: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        do {
            try ObjectiveCExceptionCatcher.perform {
                result = Result(catching: work)
            }
        } catch {
            throw error
        }

        guard let result else {
            throw NSError(
                domain: "cc.xiaorsz.typo-review.app-settings",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "设置读取没有返回结果。"]
            )
        }

        return try result.get()
    }
}
