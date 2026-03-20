import SwiftUI
import SwiftData

@main
struct TypoReviewApp: App {
    @State private var syncStatusStore = SyncStatusStore()

    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self
        ])

        do {
            let configuration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .automatic
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            assertionFailure("Failed to create CloudKit model container: \(error)")
            let fallbackConfiguration = ModelConfiguration(
                schema: schema,
                cloudKitDatabase: .none
            )
            return try! ModelContainer(for: schema, configurations: [fallbackConfiguration])
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(syncStatusStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
