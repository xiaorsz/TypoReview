import Foundation
import SwiftData

@Model
final class ReviewRecord {
    var id: UUID
    var itemID: UUID
    var reviewedAt: Date
    var resultRawValue: String
    var modeRawValue: String
    var oldStage: Int
    var newStage: Int
    var note: String

    init(
        id: UUID = UUID(),
        itemID: UUID,
        reviewedAt: Date = .now,
        result: ReviewResult,
        mode: ReviewMode,
        oldStage: Int,
        newStage: Int,
        note: String = ""
    ) {
        self.id = id
        self.itemID = itemID
        self.reviewedAt = reviewedAt
        self.resultRawValue = result.rawValue
        self.modeRawValue = mode.rawValue
        self.oldStage = oldStage
        self.newStage = newStage
        self.note = note
    }

    var result: ReviewResult {
        get { ReviewResult(rawValue: resultRawValue) ?? .correct }
        set { resultRawValue = newValue.rawValue }
    }

    var mode: ReviewMode {
        get { ReviewMode(rawValue: modeRawValue) ?? .scheduled }
        set { modeRawValue = newValue.rawValue }
    }
}
