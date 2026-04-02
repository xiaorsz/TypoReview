import Foundation
import SwiftData

enum BoardManualPlaybackOption: String, CaseIterable, Identifiable {
    case unlimited
    case minutes15 = "15m"
    case minutes30 = "30m"
    case minutes45 = "45m"
    case minutes60 = "60m"
    case untilPlaylistEnds = "until_playlist_ends"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlimited:
            return "不限"
        case .minutes15:
            return "15 分钟"
        case .minutes30:
            return "30 分钟"
        case .minutes45:
            return "45 分钟"
        case .minutes60:
            return "1 小时"
        case .untilPlaylistEnds:
            return "直到列表播完"
        }
    }

    var durationMinutes: Int? {
        switch self {
        case .unlimited, .untilPlaylistEnds:
            return nil
        case .minutes15:
            return 15
        case .minutes30:
            return 30
        case .minutes45:
            return 45
        case .minutes60:
            return 60
        }
    }

    var statusText: String {
        switch self {
        case .unlimited:
            return "手动循环播放中"
        case .minutes15, .minutes30, .minutes45, .minutes60, .untilPlaylistEnds:
            return "手动播放中"
        }
    }
}

@Model
final class AppSettings {
    static let defaultChildName = ""
    static let defaultDailyLimit = 15
    static let defaultRemindHour = 19
    static let defaultRemindMinute = 30
    static let defaultReviewInteractionStyle: ReviewInteractionStyle = .oneByOne
    static let defaultBoardAutoplayEnabled = true
    static let defaultBoardAutoplayStartHour = 7
    static let defaultBoardAutoplayStartMinute = 0
    static let defaultBoardAutoplayEndHour = 7
    static let defaultBoardAutoplayEndMinute = 30
    static let defaultBoardAutoplayDurationMinutes = 30
    static let defaultBoardManualPlaybackOption = BoardManualPlaybackOption.untilPlaylistEnds.rawValue
    static let defaultBoardAutoplaySkipWeekends = true
    static let defaultBoardAutoplaySkipChinaHolidays = true
    static let supportedChinaHolidayYearsSummary = ChinaHolidayCalendar.supportedYearsSummary
    static let legacyReviewInteractionStyleKey = "reviewInteractionStyle"

    var id: UUID = UUID()
    var childName: String = AppSettings.defaultChildName
    var dailyLimit: Int = AppSettings.defaultDailyLimit
    var remindHour: Int = AppSettings.defaultRemindHour
    var remindMinute: Int = AppSettings.defaultRemindMinute
    var reviewInteractionStyleRawValue: String = AppSettings.defaultReviewInteractionStyle.rawValue
    var boardAutoplayEnabled: Bool = AppSettings.defaultBoardAutoplayEnabled
    var boardAutoplayStartHour: Int = AppSettings.defaultBoardAutoplayStartHour
    var boardAutoplayStartMinute: Int = AppSettings.defaultBoardAutoplayStartMinute
    var boardAutoplayEndHour: Int = AppSettings.defaultBoardAutoplayEndHour
    var boardAutoplayEndMinute: Int = AppSettings.defaultBoardAutoplayEndMinute
    var boardAutoplayDurationMinutes: Int = AppSettings.defaultBoardAutoplayDurationMinutes
    var boardManualPlaybackOptionRawValue: String = AppSettings.defaultBoardManualPlaybackOption
    var boardAutoplaySkipWeekends: Bool = AppSettings.defaultBoardAutoplaySkipWeekends
    var boardAutoplaySkipChinaHolidays: Bool = AppSettings.defaultBoardAutoplaySkipChinaHolidays

    init(
        id: UUID = UUID(),
        childName: String = AppSettings.defaultChildName,
        dailyLimit: Int = AppSettings.defaultDailyLimit,
        remindHour: Int = AppSettings.defaultRemindHour,
        remindMinute: Int = AppSettings.defaultRemindMinute,
        reviewInteractionStyle: ReviewInteractionStyle = AppSettings.defaultReviewInteractionStyle,
        boardAutoplayEnabled: Bool = AppSettings.defaultBoardAutoplayEnabled,
        boardAutoplayStartHour: Int = AppSettings.defaultBoardAutoplayStartHour,
        boardAutoplayStartMinute: Int = AppSettings.defaultBoardAutoplayStartMinute,
        boardAutoplayEndHour: Int = AppSettings.defaultBoardAutoplayEndHour,
        boardAutoplayEndMinute: Int = AppSettings.defaultBoardAutoplayEndMinute,
        boardAutoplayDurationMinutes: Int = AppSettings.defaultBoardAutoplayDurationMinutes,
        boardManualPlaybackOption: BoardManualPlaybackOption = .untilPlaylistEnds,
        boardAutoplaySkipWeekends: Bool = AppSettings.defaultBoardAutoplaySkipWeekends,
        boardAutoplaySkipChinaHolidays: Bool = AppSettings.defaultBoardAutoplaySkipChinaHolidays
    ) {
        self.id = id
        self.childName = childName
        self.dailyLimit = dailyLimit
        self.remindHour = remindHour
        self.remindMinute = remindMinute
        self.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
        self.boardAutoplayEnabled = boardAutoplayEnabled
        self.boardAutoplayStartHour = boardAutoplayStartHour
        self.boardAutoplayStartMinute = boardAutoplayStartMinute
        self.boardAutoplayEndHour = boardAutoplayEndHour
        self.boardAutoplayEndMinute = boardAutoplayEndMinute
        self.boardAutoplayDurationMinutes = boardAutoplayDurationMinutes
        self.boardManualPlaybackOptionRawValue = boardManualPlaybackOption.rawValue
        self.boardAutoplaySkipWeekends = boardAutoplaySkipWeekends
        self.boardAutoplaySkipChinaHolidays = boardAutoplaySkipChinaHolidays
    }

    static func ensureSingleton(in modelContext: ModelContext) throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>()
        let allSettings = try modelContext.fetch(descriptor)

        guard let canonical = chooseCanonical(from: allSettings) else {
            let settings = AppSettings()
            modelContext.insert(settings)
            try modelContext.save()
            return settings
        }

        for duplicate in allSettings where duplicate.id != canonical.id {
            modelContext.delete(duplicate)
        }

        canonical.migrateLegacyReviewInteractionStyleIfNeeded()
        canonical.migrateLegacyBoardAutoplayDurationIfNeeded()

        if modelContext.hasChanges {
            try modelContext.save()
        }

        return canonical
    }

    private static func chooseCanonical(from settings: [AppSettings]) -> AppSettings? {
        settings.max { lhs, rhs in
            let lhsScore = lhs.priorityScore
            let rhsScore = rhs.priorityScore

            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }

            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private var priorityScore: Int {
        var score = 0

        if childName != AppSettings.defaultChildName {
            score += 8
        }

        if dailyLimit != AppSettings.defaultDailyLimit {
            score += 4
        }

        if remindHour != AppSettings.defaultRemindHour || remindMinute != AppSettings.defaultRemindMinute {
            score += 2
        }

        if reviewInteractionStyle != AppSettings.defaultReviewInteractionStyle {
            score += 1
        }

        if boardAutoplayEnabled != AppSettings.defaultBoardAutoplayEnabled {
            score += 1
        }

        if boardAutoplayStartHour != AppSettings.defaultBoardAutoplayStartHour
            || boardAutoplayStartMinute != AppSettings.defaultBoardAutoplayStartMinute
            || boardAutoplayDurationMinutes != AppSettings.defaultBoardAutoplayDurationMinutes {
            score += 2
        }

        if boardManualPlaybackOptionRawValue != AppSettings.defaultBoardManualPlaybackOption {
            score += 1
        }

        if boardAutoplaySkipWeekends != AppSettings.defaultBoardAutoplaySkipWeekends
            || boardAutoplaySkipChinaHolidays != AppSettings.defaultBoardAutoplaySkipChinaHolidays {
            score += 1
        }

        return score
    }

    var reviewInteractionStyle: ReviewInteractionStyle {
        get { ReviewInteractionStyle(rawValue: reviewInteractionStyleRawValue) ?? AppSettings.defaultReviewInteractionStyle }
        set { reviewInteractionStyleRawValue = newValue.rawValue }
    }

    var boardManualPlaybackOption: BoardManualPlaybackOption {
        get { BoardManualPlaybackOption(rawValue: boardManualPlaybackOptionRawValue) ?? .untilPlaylistEnds }
        set { boardManualPlaybackOptionRawValue = newValue.rawValue }
    }

    private func migrateLegacyReviewInteractionStyleIfNeeded() {
        guard reviewInteractionStyle == AppSettings.defaultReviewInteractionStyle else { return }
        guard let legacyValue = UserDefaults.standard.string(forKey: AppSettings.legacyReviewInteractionStyleKey) else { return }
        guard let legacyStyle = ReviewInteractionStyle(rawValue: legacyValue) else { return }

        reviewInteractionStyle = legacyStyle
    }

    private func migrateLegacyBoardAutoplayDurationIfNeeded() {
        let legacyDuration = legacyBoardAutoplayDurationMinutes()
        if boardAutoplayDurationMinutes <= 0
            || (boardAutoplayDurationMinutes == AppSettings.defaultBoardAutoplayDurationMinutes
                && legacyDuration != AppSettings.defaultBoardAutoplayDurationMinutes) {
            boardAutoplayDurationMinutes = legacyDuration
        }

        synchronizeLegacyBoardAutoplayEndTime()
    }

    var boardAutoplayTimeSummary: String {
        guard let window = boardAutoplayWindow(on: .now) else {
            return "\(formattedTime(hour: boardAutoplayStartHour, minute: boardAutoplayStartMinute)) · \(boardAutoplayDurationSummary)"
        }

        return "\(formattedTime(from: window.start)) - \(formattedTime(from: window.end))"
    }

    var boardAutoplayDurationSummary: String {
        formattedDuration(minutes: normalizedBoardAutoplayDurationMinutes)
    }

    var boardManualPlaybackOptionSummary: String {
        boardManualPlaybackOption.title
    }

    var boardAutoplayRuleSummary: String {
        var rules: [String] = []
        if boardAutoplaySkipWeekends {
            rules.append("周末不播放")
        }
        if boardAutoplaySkipChinaHolidays {
            rules.append("法定节假日不播放")
        }
        return rules.isEmpty ? "每天都可自动播放" : rules.joined(separator: " · ")
    }

    var hasValidBoardAutoplayWindow: Bool {
        guard let window = boardAutoplayWindow(on: .now) else { return false }
        return window.end > window.start
    }

    func boardAutoplayWindow(on date: Date) -> (start: Date, end: Date)? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        guard let start = calendar.date(
            bySettingHour: boardAutoplayStartHour,
            minute: boardAutoplayStartMinute,
            second: 0,
            of: day
        ) else {
            return nil
        }

        guard let end = calendar.date(byAdding: .minute, value: normalizedBoardAutoplayDurationMinutes, to: start),
              end > start else {
            return nil
        }

        return (start, end)
    }

    func isBoardAutoplayActive(on date: Date) -> Bool {
        guard boardAutoplayEnabled, isBoardAutoplayAllowed(on: date), let window = boardAutoplayWindow(on: date) else {
            return false
        }

        return date >= window.start && date < window.end
    }

    func isBoardAutoplayAllowed(on date: Date) -> Bool {
        boardAutoplayBlockedReason(on: date) == nil
    }

    func boardAutoplayBlockedReason(on date: Date) -> String? {
        let calendar = Calendar(identifier: .gregorian)

        if boardAutoplaySkipWeekends && calendar.isDateInWeekend(date) {
            return "周末不播放"
        }

        if boardAutoplaySkipChinaHolidays && ChinaHolidayCalendar.isHoliday(date) {
            return "节假日不播放"
        }

        return nil
    }

    func setBoardAutoplayStart(hour: Int, minute: Int) {
        boardAutoplayStartHour = hour
        boardAutoplayStartMinute = minute
        synchronizeLegacyBoardAutoplayEndTime()
    }

    func setBoardAutoplayDuration(minutes: Int) {
        boardAutoplayDurationMinutes = minutes
        synchronizeLegacyBoardAutoplayEndTime()
    }

    func synchronizeLegacyBoardAutoplayEndTime() {
        guard let window = boardAutoplayWindow(on: .now) else { return }
        let components = Calendar.current.dateComponents([.hour, .minute], from: window.end)
        boardAutoplayEndHour = components.hour ?? AppSettings.defaultBoardAutoplayEndHour
        boardAutoplayEndMinute = components.minute ?? AppSettings.defaultBoardAutoplayEndMinute
    }

    private var normalizedBoardAutoplayDurationMinutes: Int {
        max(5, boardAutoplayDurationMinutes)
    }

    private func legacyBoardAutoplayDurationMinutes() -> Int {
        var components = DateComponents()
        components.hour = boardAutoplayStartHour
        components.minute = boardAutoplayStartMinute
        guard let start = Calendar.current.date(from: components) else {
            return AppSettings.defaultBoardAutoplayDurationMinutes
        }

        components.hour = boardAutoplayEndHour
        components.minute = boardAutoplayEndMinute
        guard let end = Calendar.current.date(from: components) else {
            return AppSettings.defaultBoardAutoplayDurationMinutes
        }

        let duration = Int(end.timeIntervalSince(start) / 60)
        return duration > 0 ? duration : AppSettings.defaultBoardAutoplayDurationMinutes
    }

    private func formattedTime(hour: Int, minute: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "HH:mm"

        var components = DateComponents()
        components.hour = hour
        components.minute = minute

        return formatter.string(from: Calendar.current.date(from: components) ?? .now)
    }

    private func formattedTime(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formattedDuration(minutes: Int) -> String {
        if minutes % 60 == 0 {
            return "\(minutes / 60) 小时"
        }
        return "\(minutes) 分钟"
    }

    private enum ChinaHolidayCalendar {
        static let supportedYearsSummary = "2025、2026"

        private static let calendar = Calendar(identifier: .gregorian)
        private static let timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        // Official holiday dates from State Council General Office notices:
        // 2025: https://www.gov.cn/zhengce/content/202411/content_6986382.htm
        // 2026: https://www.gov.cn/zhengce/content/202510/content_7034453.htm
        private static let holidayDatesByYear: [Int: Set<String>] = [
            2025: [
                "2025-01-01",
                "2025-01-28", "2025-01-29", "2025-01-30", "2025-01-31",
                "2025-02-01", "2025-02-02", "2025-02-03", "2025-02-04",
                "2025-04-04", "2025-04-05", "2025-04-06",
                "2025-05-01", "2025-05-02", "2025-05-03", "2025-05-04", "2025-05-05",
                "2025-05-31", "2025-06-01", "2025-06-02",
                "2025-10-01", "2025-10-02", "2025-10-03", "2025-10-04",
                "2025-10-05", "2025-10-06", "2025-10-07", "2025-10-08"
            ],
            2026: [
                "2026-01-01", "2026-01-02", "2026-01-03",
                "2026-02-15", "2026-02-16", "2026-02-17", "2026-02-18",
                "2026-02-19", "2026-02-20", "2026-02-21", "2026-02-22", "2026-02-23",
                "2026-04-04", "2026-04-05", "2026-04-06",
                "2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04", "2026-05-05",
                "2026-06-19", "2026-06-20", "2026-06-21",
                "2026-09-25", "2026-09-26", "2026-09-27",
                "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04",
                "2026-10-05", "2026-10-06", "2026-10-07"
            ]
        ]

        static func isHoliday(_ date: Date) -> Bool {
            guard let key = holidayKey(for: date),
                  let year = Int(key.prefix(4)) else {
                return false
            }

            return holidayDatesByYear[year]?.contains(key) ?? false
        }

        private static func holidayKey(for date: Date) -> String? {
            var components = calendar.dateComponents(in: timeZone, from: date)
            guard let year = components.year,
                  let month = components.month,
                  let day = components.day else {
                return nil
            }

            components.timeZone = timeZone
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
    }
}
