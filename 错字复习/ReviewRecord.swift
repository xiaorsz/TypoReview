import Foundation
import SwiftData

@Model
final class ReviewRecord {
    var id: UUID = UUID()
    var itemID: UUID = UUID()
    var reviewedAt: Date = Date()
    var resultRawValue: String = ReviewResult.correct.rawValue
    var modeRawValue: String = ReviewMode.scheduled.rawValue
    var oldStage: Int = 0
    var newStage: Int = 0
    var note: String = ""

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
