import Foundation
import SwiftData

@Model
final class AppSettings {
    static let defaultChildName = ""
    static let defaultDailyLimit = 15
    static let defaultRemindHour = 19
    static let defaultRemindMinute = 30
    static let defaultReviewInteractionStyle: ReviewInteractionStyle = .oneByOne
    static let legacyReviewInteractionStyleKey = "reviewInteractionStyle"

    var id: UUID = UUID()
    var childName: String = AppSettings.defaultChildName
    var dailyLimit: Int = AppSettings.defaultDailyLimit
    var remindHour: Int = AppSettings.defaultRemindHour
    var remindMinute: Int = AppSettings.defaultRemindMinute
    var reviewInteractionStyleRawValue: String = AppSettings.defaultReviewInteractionStyle.rawValue

    init(
        id: UUID = UUID(),
        childName: String = AppSettings.defaultChildName,
        dailyLimit: Int = AppSettings.defaultDailyLimit,
        remindHour: Int = AppSettings.defaultRemindHour,
        remindMinute: Int = AppSettings.defaultRemindMinute,
        reviewInteractionStyle: ReviewInteractionStyle = AppSettings.defaultReviewInteractionStyle
    ) {
        self.id = id
        self.childName = childName
        self.dailyLimit = dailyLimit
        self.remindHour = remindHour
        self.remindMinute = remindMinute
        self.reviewInteractionStyleRawValue = reviewInteractionStyle.rawValue
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

        return score
    }

    var reviewInteractionStyle: ReviewInteractionStyle {
        get { ReviewInteractionStyle(rawValue: reviewInteractionStyleRawValue) ?? AppSettings.defaultReviewInteractionStyle }
        set { reviewInteractionStyleRawValue = newValue.rawValue }
    }

    private func migrateLegacyReviewInteractionStyleIfNeeded() {
        guard reviewInteractionStyle == AppSettings.defaultReviewInteractionStyle else { return }
        guard let legacyValue = UserDefaults.standard.string(forKey: AppSettings.legacyReviewInteractionStyleKey) else { return }
        guard let legacyStyle = ReviewInteractionStyle(rawValue: legacyValue) else { return }

        reviewInteractionStyle = legacyStyle
    }
}
