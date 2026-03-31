import SwiftUI
import SwiftData

@main
struct TypoReviewApp: App {
    @State private var syncStatusStore = SyncStatusStore()
    private let cloudKitContainerIdentifier = "iCloud.cc.xiaorsz.typo-review"
    private let appGroupIdentifier = "group.cc.xiaorsz.typo-review"
    private let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self
        ])

        let fileManager = FileManager.default
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let defaultStoreURL = appSupportDir.appendingPathComponent("default.store")
        let cloudConfiguration: ModelConfiguration
        let fallbackConfiguration: ModelConfiguration

        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            cloudConfiguration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(appGroupIdentifier),
                cloudKitDatabase: .automatic
            )
            fallbackConfiguration = ModelConfiguration(
                schema: schema,
                groupContainer: .identifier(appGroupIdentifier),
                cloudKitDatabase: .none
            )

            let legacyGroupStoreURL = groupURL.appendingPathComponent("typo-review.store")
            Self.migrateLegacyStoreIfNeeded(
                candidates: [defaultStoreURL, legacyGroupStoreURL],
                targetStoreURL: cloudConfiguration.url,
                fileManager: fileManager
            )
        } else {
            print("WARNING: App Group container URL is nil. Falling back to default store URL.")
            cloudConfiguration = ModelConfiguration(
                schema: schema,
                url: defaultStoreURL,
                cloudKitDatabase: .automatic
            )
            fallbackConfiguration = ModelConfiguration(
                schema: schema,
                url: defaultStoreURL,
                cloudKitDatabase: .none
            )
        }

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
            let nsError1 = error as NSError

            let container: ModelContainer
            do {
                container = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
            } catch {
                print("Fallback ModelContainer also failed: \(error)")
                let inMemoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try! ModelContainer(for: schema, configurations: [inMemoryConfig])
            }
            sharedModelContainer = container
            
            let detailedError = [
                "domain=\(nsError1.domain)",
                "code=\(nsError1.code)",
                "description=\(nsError1.localizedDescription)",
                "failureReason=\(nsError1.localizedFailureReason ?? "nil")",
                "recoverySuggestion=\(nsError1.localizedRecoverySuggestion ?? "nil")",
                "userInfo=\(nsError1.userInfo)"
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

    private static func migrateLegacyStoreIfNeeded(
        candidates: [URL],
        targetStoreURL: URL,
        fileManager: FileManager
    ) {
        guard !fileManager.fileExists(atPath: targetStoreURL.path) else { return }

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            do {
                try moveStoreBundle(from: candidate, to: targetStoreURL, fileManager: fileManager)
                print("Migrated legacy SwiftData store from \(candidate.path) to \(targetStoreURL.path)")
                return
            } catch {
                print("Legacy store migration failed from \(candidate.path): \(error)")
            }
        }
    }

    private static func moveStoreBundle(
        from sourceURL: URL,
        to targetURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for (source, target) in zip(storeBundleURLs(for: sourceURL), storeBundleURLs(for: targetURL)) {
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: target)
        }
    }

    private static func storeBundleURLs(for baseURL: URL) -> [URL] {
        [
            baseURL,
            URL(fileURLWithPath: baseURL.path + "-wal"),
            URL(fileURLWithPath: baseURL.path + "-shm")
        ]
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
