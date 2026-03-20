import Foundation
import SwiftData

@Model
final class ReviewItem {
    var id: UUID
    var typeRawValue: String
    var content: String
    var prompt: String
    var note: String
    var source: String
    var stage: Int
    var nextReviewAt: Date
    var lastReviewedAt: Date?
    var consecutiveCorrectCount: Int
    var consecutiveWrongCount: Int
    var isPriority: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        type: ReviewItemType,
        content: String,
        prompt: String,
        note: String = "",
        source: String = "",
        stage: Int = 0,
        nextReviewAt: Date = .now,
        lastReviewedAt: Date? = nil,
        consecutiveCorrectCount: Int = 0,
        consecutiveWrongCount: Int = 0,
        isPriority: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.typeRawValue = type.rawValue
        self.content = content
        self.prompt = prompt
        self.note = note
        self.source = source
        self.stage = stage
        self.nextReviewAt = nextReviewAt
        self.lastReviewedAt = lastReviewedAt
        self.consecutiveCorrectCount = consecutiveCorrectCount
        self.consecutiveWrongCount = consecutiveWrongCount
        self.isPriority = isPriority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }
}
