import Foundation
import SwiftData

@Model
final class DictationSession {
    var id: UUID
    var title: String
    var typeRawValue: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var scheduledDate: Date = Date()
    var finishedAt: Date?
    var reviewedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        type: ReviewItemType,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        scheduledDate: Date = .now,
        finishedAt: Date? = nil,
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.typeRawValue = type.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.scheduledDate = scheduledDate
        self.finishedAt = finishedAt
        self.reviewedAt = reviewedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var isFinished: Bool {
        finishedAt != nil
    }

    var isReviewed: Bool {
        reviewedAt != nil
    }
}
