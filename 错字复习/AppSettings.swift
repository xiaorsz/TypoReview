import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID
    var childName: String
    var dailyLimit: Int
    var remindHour: Int
    var remindMinute: Int

    init(
        id: UUID = UUID(),
        childName: String = "乐乐",
        dailyLimit: Int = 15,
        remindHour: Int = 19,
        remindMinute: Int = 30
    ) {
        self.id = id
        self.childName = childName
        self.dailyLimit = dailyLimit
        self.remindHour = remindHour
        self.remindMinute = remindMinute
    }
}
