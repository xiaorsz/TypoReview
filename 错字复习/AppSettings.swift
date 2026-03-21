import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: UUID = UUID()
    var childName: String = "乐乐"
    var dailyLimit: Int = 15
    var remindHour: Int = 19
    var remindMinute: Int = 30

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
