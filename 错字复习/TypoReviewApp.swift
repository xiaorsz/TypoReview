import SwiftUI
import SwiftData
import SQLite3
import UIKit

@main
struct TypoReviewApp: App {
    private static let cloudKitContainerIdentifierValue = "iCloud.cc.xiaorsz.typo-review"
    private static let appGroupIdentifierValue = "group.cc.xiaorsz.typo-review"

    @State private var syncStatusStore = SyncStatusStore()
    @State private var mediaLibraryStore = MediaLibraryStore()
    @State private var appSettingsStore: AppSettingsStore
    private let cloudKitContainerIdentifier = Self.cloudKitContainerIdentifierValue
    private let appGroupIdentifier = Self.appGroupIdentifierValue
    private let sharedModelContainer: ModelContainer

    init() {
        #if DEBUG
        DebugPerf.replayPreviousRunTrace()
        DebugPerf.mark("TypoReviewApp init begin")
        #endif
        #if DEBUG
        if #available(iOS 18.0, *) {
        } else {
            DebugPerf.mark("TypoReviewApp defer iOS17 background scene shield to RootTabView")
        }
        #endif

        _appSettingsStore = State(
            initialValue: AppSettingsStore(appGroupIdentifier: Self.appGroupIdentifierValue)
        )
        let schema = Schema([
            ReviewItem.self,
            ReviewRecord.self,
            TaskItem.self,
            TaskCompletion.self,
            TaskSubitem.self,
            TaskExecutionRecord.self,
            TaskSubitemExecutionRecord.self,
            AppSettings.self,
            DictationSession.self,
            DictationEntry.self,
            ScheduleItem.self,
            MediaAsset.self
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
            Self.repairLegacySchemaIfNeeded(at: cloudConfiguration.url, fileManager: fileManager)
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
            Self.repairLegacySchemaIfNeeded(at: defaultStoreURL, fileManager: fileManager)
        }

        do {
            #if DEBUG
            DebugPerf.mark("TypoReviewApp ModelContainer cloud init begin")
            #endif
            let container = try ModelContainer(for: schema, configurations: [cloudConfiguration])
            #if DEBUG
            DebugPerf.mark("TypoReviewApp ModelContainer cloud init success")
            #endif
            Self.migrateLegacyTaskExecutionsIfNeeded(in: container.mainContext)
            TaskExecutionSupport.migrateLegacySubtasksIfNeeded(in: container.mainContext)
            _ = try? AppSettings.ensureSingleton(in: container.mainContext)
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
            #if DEBUG
            DebugPerf.mark("TypoReviewApp ModelContainer cloud init failed domain=\(nsError1.domain) code=\(nsError1.code)")
            #endif

            let container: ModelContainer
            do {
                #if DEBUG
                DebugPerf.mark("TypoReviewApp ModelContainer fallback init begin")
                #endif
                container = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
                #if DEBUG
                DebugPerf.mark("TypoReviewApp ModelContainer fallback init success")
                #endif
                Self.migrateLegacyTaskExecutionsIfNeeded(in: container.mainContext)
                TaskExecutionSupport.migrateLegacySubtasksIfNeeded(in: container.mainContext)
                _ = try? AppSettings.ensureSingleton(in: container.mainContext)
            } catch {
                #if DEBUG
                DebugPerf.mark("TypoReviewApp ModelContainer fallback init failed error=\(error.localizedDescription)")
                #endif
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

        #if DEBUG
        DebugPerf.mark("TypoReviewApp init end")
        #endif
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

    private static func repairLegacySchemaIfNeeded(
        at storeURL: URL,
        fileManager: FileManager
    ) {
        guard fileManager.fileExists(atPath: storeURL.path) else { return }

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let database {
                sqlite3_close(database)
            }
            print("Failed to open legacy store for schema repair at \(storeURL.path)")
            return
        }

        defer { sqlite3_close(database) }

        guard let database else { return }
        guard tableExists(named: "ZAPPSETTINGS", in: database) else { return }

        let existingColumns = fetchColumnNames(for: "ZAPPSETTINGS", in: database)
        let requiredStatements = [
            ("ZBOARDAUTOPLAYENABLED", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENABLED INTEGER NOT NULL DEFAULT 1"),
            ("ZBOARDAUTOPLAYSTARTHOUR", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSTARTHOUR INTEGER NOT NULL DEFAULT 7"),
            ("ZBOARDAUTOPLAYSTARTMINUTE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSTARTMINUTE INTEGER NOT NULL DEFAULT 0"),
            ("ZBOARDAUTOPLAYENDHOUR", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENDHOUR INTEGER NOT NULL DEFAULT 7"),
            ("ZBOARDAUTOPLAYENDMINUTE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYENDMINUTE INTEGER NOT NULL DEFAULT 30"),
            ("ZBOARDAUTOPLAYDURATIONMINUTES", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYDURATIONMINUTES INTEGER NOT NULL DEFAULT 30"),
            ("ZBOARDAUTOPLAYSLOTSRAWVALUE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSLOTSRAWVALUE TEXT NOT NULL DEFAULT ''"),
            ("ZBOARDMANUALPLAYBACKOPTIONRAWVALUE", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDMANUALPLAYBACKOPTIONRAWVALUE TEXT NOT NULL DEFAULT 'until_playlist_ends'"),
            ("ZBOARDAUTOPLAYSKIPWEEKENDS", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSKIPWEEKENDS INTEGER NOT NULL DEFAULT 1"),
            ("ZBOARDAUTOPLAYSKIPCHINAHOLIDAYS", "ALTER TABLE ZAPPSETTINGS ADD COLUMN ZBOARDAUTOPLAYSKIPCHINAHOLIDAYS INTEGER NOT NULL DEFAULT 1")
        ]

        for (columnName, statement) in requiredStatements where !existingColumns.contains(columnName) {
            if sqlite3_exec(database, statement, nil, nil, nil) != SQLITE_OK {
                let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
                print("Failed to add \(columnName) to legacy store: \(message)")
            }
        }

        if tableExists(named: "ZTASKSUBITEM", in: database) {
            let subtaskColumns = fetchColumnNames(for: "ZTASKSUBITEM", in: database)
            let subtaskStatements = [
                ("ZTASKEXECUTIONIDRAWVALUE", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZTASKEXECUTIONIDRAWVALUE TEXT NOT NULL DEFAULT ''"),
                ("ZDETAIL", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZDETAIL TEXT NOT NULL DEFAULT ''"),
                ("ZSTATUSRAWVALUE", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZSTATUSRAWVALUE TEXT NOT NULL DEFAULT '待处理'"),
                ("ZCOMPLETEDAT", "ALTER TABLE ZTASKSUBITEM ADD COLUMN ZCOMPLETEDAT DOUBLE")
            ]

            for (columnName, statement) in subtaskStatements where !subtaskColumns.contains(columnName) {
                if sqlite3_exec(database, statement, nil, nil, nil) != SQLITE_OK {
                    let message = sqlite3_errmsg(database).map { String(cString: $0) } ?? "unknown"
                    print("Failed to add \(columnName) to legacy subtask store: \(message)")
                }
            }
        }
    }

    private static func tableExists(named tableName: String, in database: OpaquePointer) -> Bool {
        let escapedTableName = tableName.replacingOccurrences(of: "'", with: "''")
        let query = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(escapedTableName)' LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func fetchColumnNames(for tableName: String, in database: OpaquePointer) -> Set<String> {
        let query = "PRAGMA table_info(\(tableName))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let rawName = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: rawName))
            }
        }
        return columns
    }

    private static func storeBundleURLs(for baseURL: URL) -> [URL] {
        [
            baseURL,
            URL(fileURLWithPath: baseURL.path + "-wal"),
            URL(fileURLWithPath: baseURL.path + "-shm")
        ]
    }

    private static func migrateLegacyTaskExecutionsIfNeeded(in modelContext: ModelContext) {
        let executionCount = (try? modelContext.fetchCount(FetchDescriptor<TaskExecutionRecord>())) ?? 0
        guard executionCount == 0 else { return }

        let legacyCompletions = (try? modelContext.fetch(FetchDescriptor<TaskCompletion>())) ?? []
        guard !legacyCompletions.isEmpty else { return }

        let calendar = Calendar.current
        for completion in legacyCompletions {
            let record = TaskExecutionRecord(
                id: completion.id,
                taskID: completion.taskID,
                occurrenceDate: calendar.startOfDay(for: completion.completedDate),
                detail: "",
                status: .completed,
                completedAt: completion.completedAt,
                createdAt: completion.completedAt,
                updatedAt: completion.completedAt
            )
            modelContext.insert(record)
        }

        if modelContext.hasChanges {
            try? modelContext.save()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(syncStatusStore)
                .environment(mediaLibraryStore)
                .environment(appSettingsStore)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    #if DEBUG
                    DebugPerf.flushRecentEvents()
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    #if DEBUG
                    DebugPerf.flushRecentEvents()
                    #endif
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

@MainActor
final class IOS17BackgroundSceneShield {
    static let shared = IOS17BackgroundSceneShield()

    private struct ShieldedWindow {
        weak var window: UIWindow?
        let rootViewController: UIViewController
    }

    private var isStarted = false
    private var observers: [NSObjectProtocol] = []
    private var shieldedWindows: [ObjectIdentifier: ShieldedWindow] = [:]

    func start() {
        guard !isStarted else { return }
        guard isEnabled else { return }

        isStarted = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UIScene.willDeactivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.shieldScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIScene.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.shieldScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shieldActiveWindows()
                }
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.shieldActiveWindows()
                }
            },
            center.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.restoreScene(from: notification)
                }
            },
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreShieldedWindows()
                }
            }
        ]
    }

    private var isEnabled: Bool {
        if #available(iOS 18.0, *) {
            false
        } else {
            true
        }
    }

    private func shieldActiveWindows() {
        guard isEnabled else { return }

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard windowScene.session.role == .windowApplication else { continue }

            shield(windowScene)
        }
    }

    private func shieldScene(from notification: Notification) {
        guard let windowScene = notification.object as? UIWindowScene else {
            shieldActiveWindows()
            return
        }
        shield(windowScene)
    }

    private func shield(_ windowScene: UIWindowScene) {
        guard isEnabled else { return }
        guard windowScene.session.role == .windowApplication else { return }

        for window in windowScene.windows where shouldShield(window) {
            guard let rootViewController = window.rootViewController else { continue }

            let windowID = ObjectIdentifier(window)
            shieldedWindows[windowID] = ShieldedWindow(
                window: window,
                rootViewController: rootViewController
            )

            UIView.performWithoutAnimation {
                removeContextMenuInteractions(from: window)
                window.rootViewController = IOS17BackgroundShieldViewController()
                window.layoutIfNeeded()
            }
        }
    }

    private func removeContextMenuInteractions(from view: UIView) {
        for interaction in view.interactions where interaction is UIContextMenuInteraction {
            view.removeInteraction(interaction)
        }

        for subview in view.subviews {
            removeContextMenuInteractions(from: subview)
        }
    }

    private func shouldShield(_ window: UIWindow) -> Bool {
        guard !window.isHidden else { return false }
        guard window.windowLevel == .normal else { return false }
        guard window.rootViewController != nil else { return false }
        return !(window.rootViewController is IOS17BackgroundShieldViewController)
    }

    private func restoreShieldedWindows() {
        for (_, shieldedWindow) in shieldedWindows {
            guard let window = shieldedWindow.window else { continue }
            guard window.rootViewController is IOS17BackgroundShieldViewController else { continue }
            window.rootViewController = shieldedWindow.rootViewController
            window.makeKeyAndVisible()
        }
        shieldedWindows.removeAll()
    }

    private func restoreScene(from notification: Notification) {
        guard let windowScene = notification.object as? UIWindowScene else {
            restoreShieldedWindows()
            return
        }

        let windowIDs = Set(windowScene.windows.map(ObjectIdentifier.init))
        for (windowID, shieldedWindow) in shieldedWindows where windowIDs.contains(windowID) {
            guard let window = shieldedWindow.window else { continue }
            guard window.rootViewController is IOS17BackgroundShieldViewController else { continue }
            window.rootViewController = shieldedWindow.rootViewController
            window.makeKeyAndVisible()
            shieldedWindows.removeValue(forKey: windowID)
        }
    }
}

private final class IOS17BackgroundShieldViewController: UIViewController {
    override func loadView() {
        let shieldView = UIView()
        shieldView.backgroundColor = .systemBackground
        view = shieldView
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .all
    }
}
