import SwiftUI
import SwiftData
import WidgetKit

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                modernTabView
            } else {
                legacyTabView
            }
        }
        .task {
            await refreshAppState(trigger: SyncStatusStore.Trigger.launch)
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            Task {
                await refreshAppState(trigger: SyncStatusStore.Trigger.foreground)
            }
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

    private func refreshAppState(trigger: SyncStatusStore.Trigger) async {
        do {
            _ = try AppSettings.ensureSingleton(in: modelContext)
        } catch {
            print("AppSettings singleton setup failed on \(trigger): \(error)")
        }
        await syncStatusStore.refresh(using: modelContext, trigger: trigger)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
