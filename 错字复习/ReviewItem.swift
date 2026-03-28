import Foundation
import SwiftData

@Model
final class ReviewItem {
    var id: UUID = UUID()
    var typeRawValue: String = ReviewItemType.chineseCharacter.rawValue
    var content: String = ""
    var prompt: String = ""
    var note: String = ""
    var source: String = ""
    var stage: Int = 0
    var nextReviewAt: Date = Date()
    var lastReviewedAt: Date?
    var consecutiveCorrectCount: Int = 0
    var consecutiveWrongCount: Int = 0
    var isPriority: Bool = false
    var isDictationPass: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

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
        isDictationPass: Bool = false,
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
        self.isDictationPass = isDictationPass
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }
}
