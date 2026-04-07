import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var refreshAppStateTask: Task<Void, Never>?

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .task {
            guard scenePhase == .active else { return }
            scheduleAppStateRefresh(trigger: .launch, delay: 1.5)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                scheduleAppStateRefresh(trigger: .foreground, delay: 2)
            } else {
                refreshAppStateTask?.cancel()
            }
        }
        .onDisappear {
            refreshAppStateTask?.cancel()
        }
    }

    @available(iOS 18.0, *)
    private var modernTabView: some View {
        TabView {
            Tab("首页", systemImage: "house.fill") {
                NavigationStack {
                    HomeView()
                }
            }

            Tab("题库", systemImage: "square.grid.2x2.fill") {
                NavigationStack {
                    LibraryView()
                }
            }

            Tab("听写", systemImage: "text.book.closed.fill") {
                NavigationStack {
                    DictationHomeView()
                }
            }

            Tab("待办", systemImage: "checklist") {
                NavigationStack {
                    TasksView()
                }
            }

            Tab("设置", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }

    private var legacyTabView: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }

            NavigationStack {
                LibraryView()
            }
            .tabItem {
                Label("题库", systemImage: "square.grid.2x2.fill")
            }

            NavigationStack {
                DictationHomeView()
            }
            .tabItem {
                Label("听写", systemImage: "text.book.closed.fill")
            }

            NavigationStack {
                TasksView()
            }
            .tabItem {
                Label("待办", systemImage: "checklist")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
        }
    }

    private func scheduleAppStateRefresh(trigger: SyncStatusStore.Trigger, delay: TimeInterval) {
        refreshAppStateTask?.cancel()
        guard shouldRefreshAppState(for: trigger) else { return }

        refreshAppStateTask = Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard scenePhase == .active else { return }
            guard shouldRefreshAppState(for: trigger) else { return }
            await refreshAppState(trigger: trigger)
        }
    }

    private func shouldRefreshAppState(for trigger: SyncStatusStore.Trigger) -> Bool {
        guard !syncStatusStore.isRefreshing else { return false }

        guard trigger == .foreground, let lastRefreshAt = syncStatusStore.lastRefreshAt else {
            return true
        }

        return Date.now.timeIntervalSince(lastRefreshAt) >= 10 * 60
    }

    private func refreshAppState(trigger: SyncStatusStore.Trigger) async {
        appSettingsStore.bootstrap(using: modelContext)
        appSettingsStore.refreshFromSwiftDataIfPossible(using: modelContext)
        await syncStatusStore.refresh(using: modelContext, trigger: trigger)
    }
}
