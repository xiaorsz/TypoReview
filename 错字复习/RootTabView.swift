import SwiftUI
import SwiftData

struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncStatusStore.self) private var syncStatusStore

    var body: some View {
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
        .task {
            await syncStatusStore.refresh(using: modelContext, trigger: .launch)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await syncStatusStore.refresh(using: modelContext, trigger: .foreground)
            }
        }
    }
}
