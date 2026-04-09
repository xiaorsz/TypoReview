import Foundation
import SwiftData

enum ReviewTrack: String, Codable {
    case standard
    case dictationFollowUp
}

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
    var reviewTrackRawValue: String = ReviewTrack.standard.rawValue
    var dictationFollowUpStep: Int = 0
    var isDictationPassRaw: Bool?
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
        reviewTrack: ReviewTrack = .standard,
        dictationFollowUpStep: Int = 0,
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
        self.reviewTrackRawValue = reviewTrack.rawValue
        self.dictationFollowUpStep = dictationFollowUpStep
        self.isDictationPassRaw = isDictationPass
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var isDictationPass: Bool {
        get { isDictationPassRaw ?? false }
        set { isDictationPassRaw = newValue }
    }

    var reviewTrack: ReviewTrack {
        get {
            if let track = ReviewTrack(rawValue: reviewTrackRawValue) {
                if track == .standard, isDictationPass, dictationFollowUpStep == 0 {
                    return .dictationFollowUp
                }
                return track
            }
            return isDictationPass ? .dictationFollowUp : .standard
        }
        set { reviewTrackRawValue = newValue.rawValue }
    }

    var resolvedDictationFollowUpStep: Int {
        if reviewTrack == .dictationFollowUp {
            if (1...2).contains(dictationFollowUpStep) {
                return dictationFollowUpStep
            }
            return 1
        }

        if isDictationPass {
            return stage >= 5 ? 2 : 1
        }

        return 0
    }

    var isDictationFollowUp: Bool {
        reviewTrack == .dictationFollowUp || isDictationPass
    }
}
