import Foundation
import SwiftData

@Model
final class DictationEntry {
    var id: UUID
    var sessionID: UUID
    var sortOrder: Int
    var typeRawValue: String
    var content: String
    var prompt: String
    var note: String
    var source: String
    var resultRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sortOrder: Int,
        type: ReviewItemType,
        content: String,
        prompt: String = "",
        note: String = "",
        source: String = "",
        result: DictationResult = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sortOrder = sortOrder
        self.typeRawValue = type.rawValue
        self.content = content
        self.prompt = prompt
        self.note = note
        self.source = source
        self.resultRawValue = result.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var type: ReviewItemType {
        get { ReviewItemType(rawValue: typeRawValue) ?? .chineseCharacter }
        set { typeRawValue = newValue.rawValue }
    }

    var result: DictationResult {
        get { DictationResult(rawValue: resultRawValue) ?? .pending }
        set { resultRawValue = newValue.rawValue }
    }
}
