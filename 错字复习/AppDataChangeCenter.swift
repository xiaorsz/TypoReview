import Foundation

extension Notification.Name {
    /// Posted after persisted app data changes and read models should refresh.
    static let appDataDidChange = Notification.Name("appDataDidMutate")
}

enum AppDataChangeCenter {
    static func post(using center: NotificationCenter = .default) {
        center.post(name: .appDataDidChange, object: nil)
    }
}
