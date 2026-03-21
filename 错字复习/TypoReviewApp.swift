import SwiftUI
import SwiftData

@main
struct TypoReviewApp: App {
    @State private var syncStatusStore = SyncStatusStore()
    private let cloudKitContainerIdentifier = "iCloud.cc.xiaorsz.typo-review"
    private let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self
        ])
        
        let sharedContainerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.cc.xiaorsz.typo-review")!
            .appendingPathComponent("typo-review.store")
            
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let defaultStoreURL = appSupportDir.appendingPathComponent("default.store")
        
        if FileManager.default.fileExists(atPath: defaultStoreURL.path) && !FileManager.default.fileExists(atPath: sharedContainerURL.path) {
            do {
                try FileManager.default.moveItem(at: defaultStoreURL, to: sharedContainerURL)
                let defaultWal = appSupportDir.appendingPathComponent("default.store-wal")
                let sharedWal = URL(fileURLWithPath: sharedContainerURL.path + "-wal")
                if FileManager.default.fileExists(atPath: defaultWal.path) {
                    try FileManager.default.moveItem(at: defaultWal, to: sharedWal)
                }
                let defaultShm = appSupportDir.appendingPathComponent("default.store-shm")
                let sharedShm = URL(fileURLWithPath: sharedContainerURL.path + "-shm")
                if FileManager.default.fileExists(atPath: defaultShm.path) {
                    try FileManager.default.moveItem(at: defaultShm, to: sharedShm)
                }
            } catch {
                print("Migration to App Group failed: \(error)")
            }
        }

        let cloudConfiguration = ModelConfiguration(
            url: sharedContainerURL,
            cloudKitDatabase: .automatic
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [cloudConfiguration])
            sharedModelContainer = container

            _syncStatusStore = State(initialValue: {
                let store = SyncStatusStore()
                store.configure(
                    cloudKitEnabled: true,
                    containerIdentifier: cloudKitContainerIdentifier
                )
                return store
            }())
        } catch {
            let fallbackConfiguration = ModelConfiguration(
                url: sharedContainerURL,
                cloudKitDatabase: .none
            )
            sharedModelContainer = try! ModelContainer(for: schema, configurations: [fallbackConfiguration])
            let nsError = error as NSError
            let detailedError = [
                "domain=\(nsError.domain)",
                "code=\(nsError.code)",
                "description=\(nsError.localizedDescription)",
                "failureReason=\(nsError.localizedFailureReason ?? "nil")",
                "recoverySuggestion=\(nsError.localizedRecoverySuggestion ?? "nil")",
                "userInfo=\(nsError.userInfo)"
            ].joined(separator: "\n")

            _syncStatusStore = State(initialValue: {
                let store = SyncStatusStore()
                store.configure(
                    cloudKitEnabled: false,
                    containerIdentifier: cloudKitContainerIdentifier,
                    initializationError: detailedError
                )
                return store
            }())
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(syncStatusStore)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
        }
        .modelContainer(sharedModelContainer)
    }
}
