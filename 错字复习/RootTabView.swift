import SwiftUI
import SwiftData
import UIKit

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore
    @Environment(AppSettingsStore.self) private var appSettingsStore
    @State private var refreshAppStateTask: Task<Void, Never>?
    @State private var ios17ShieldStartTask: Task<Void, Never>?
    @State private var hasStartedIOS17BackgroundShield = false
    @State private var selectedLegacyTab: LegacyTab = .home
    @State private var visitedLegacyTabs: Set<LegacyTab> = [.home]

    private enum LegacyTab: Hashable {
        case home
        case library
        case dictation
        case tasks
        case settings
    }

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .task {
            #if DEBUG
            DebugPerf.mark("RootTabView .task scenePhase=\(scenePhase)")
            #endif
            guard canRefreshLiveAppState else { return }
            scheduleIOS17BackgroundShieldStartIfNeeded()
            scheduleAppStateRefresh(trigger: .launch, delay: launchRefreshDelay)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                scheduleIOS17BackgroundShieldStartIfNeeded()
                scheduleAppStateRefresh(trigger: .foreground, delay: foregroundRefreshDelay)
            } else {
                refreshAppStateTask?.cancel()
                ios17ShieldStartTask?.cancel()
            }
        }
        .onDisappear {
            refreshAppStateTask?.cancel()
            ios17ShieldStartTask?.cancel()
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
        TabView(selection: $selectedLegacyTab) {
            legacyTabRoot(for: .home) {
                HomeView()
            }
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }
            .tag(LegacyTab.home)

            legacyTabRoot(for: .library) {
                LibraryView()
            }
            .tabItem {
                Label("题库", systemImage: "square.grid.2x2.fill")
            }
            .tag(LegacyTab.library)

            legacyTabRoot(for: .dictation) {
                DictationHomeView()
            }
            .tabItem {
                Label("听写", systemImage: "text.book.closed.fill")
            }
            .tag(LegacyTab.dictation)

            legacyTabRoot(for: .tasks) {
                TasksView()
            }
            .tabItem {
                Label("待办", systemImage: "checklist")
            }
            .tag(LegacyTab.tasks)

            legacyTabRoot(for: .settings) {
                SettingsView()
            }
            .tabItem {
                Label("设置", systemImage: "gearshape.fill")
            }
            .tag(LegacyTab.settings)
        }
        .onChange(of: selectedLegacyTab) { _, newTab in
            markLegacyTabVisited(newTab)
            #if DEBUG
            DebugPerf.mark("RootTabView selectedLegacyTab=\(newTab)")
            #endif
        }
    }

    @ViewBuilder
    private func legacyTabRoot<Content: View>(
        for tab: LegacyTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            if shouldMaterializeLegacyTab(tab) {
                content()
                    .onAppear {
                        markLegacyTabVisited(tab)
                        #if DEBUG
                        DebugPerf.mark("RootTabView legacy tab content appear \(tab)")
                        #endif
                    }
            } else {
                Color.clear
                    .onAppear {
                        #if DEBUG
                        DebugPerf.mark("RootTabView legacy tab placeholder appear \(tab)")
                        #endif
                    }
            }
        }
    }

    private func shouldMaterializeLegacyTab(_ tab: LegacyTab) -> Bool {
        selectedLegacyTab == tab || visitedLegacyTabs.contains(tab)
    }

    private func markLegacyTabVisited(_ tab: LegacyTab) {
        visitedLegacyTabs.insert(tab)
    }

    private func scheduleAppStateRefresh(trigger: SyncStatusStore.Trigger, delay: TimeInterval) {
        #if DEBUG
        DebugPerf.mark("RootTabView scheduleAppStateRefresh trigger=\(trigger) delay=\(delay)")
        #endif
        refreshAppStateTask?.cancel()
        guard shouldRefreshAppState(for: trigger) else { return }

        refreshAppStateTask = Task { @MainActor in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard canRefreshLiveAppState else { return }
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

    private var canRefreshLiveAppState: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    private var launchRefreshDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 1.5
        }
        return 6.0
    }

    private var foregroundRefreshDelay: TimeInterval {
        if #available(iOS 18.0, *) {
            return 2.0
        }
        return 5.0
    }

    private func scheduleIOS17BackgroundShieldStartIfNeeded() {
        if #available(iOS 18.0, *) {
            return
        }

        ios17ShieldStartTask?.cancel()
        guard !hasStartedIOS17BackgroundShield else { return }
        guard canRefreshLiveAppState else { return }

        #if DEBUG
        DebugPerf.mark("RootTabView schedule iOS17 background scene shield start")
        #endif

        ios17ShieldStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            guard canRefreshLiveAppState else { return }

            hasStartedIOS17BackgroundShield = true
            #if DEBUG
            DebugPerf.mark("RootTabView starting iOS17 background scene shield after settle")
            #endif
            IOS17BackgroundSceneShield.shared.start()
        }
    }
}
