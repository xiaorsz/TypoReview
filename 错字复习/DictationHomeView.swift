import SwiftUI
import SwiftData
import UIKit

private struct DictationSessionProjection: Identifiable, Hashable {
    let id: UUID
    let title: String
    let type: ReviewItemType
    let createdAt: Date
    let updatedAt: Date
    let scheduledDate: Date
    let finishedAt: Date?
    let reviewedAt: Date?

    init(_ session: DictationSession) {
        id = session.id
        title = session.title
        type = session.type
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        scheduledDate = session.scheduledDate
        finishedAt = session.finishedAt
        reviewedAt = session.reviewedAt
    }

    var isFinished: Bool {
        finishedAt != nil
    }

    var isReviewed: Bool {
        reviewedAt != nil
    }
}

private struct DictationEntryProjection: Identifiable, Hashable {
    let id: UUID
    let sessionID: UUID
    let sortOrder: Int
    let type: ReviewItemType
    let content: String
    let prompt: String
    let note: String
    let source: String
    let result: DictationResult

    init(_ entry: DictationEntry) {
        id = entry.id
        sessionID = entry.sessionID
        sortOrder = entry.sortOrder
        type = entry.type
        content = entry.content
        prompt = entry.prompt
        note = entry.note
        source = entry.source
        result = entry.result
    }
}

private struct DictationRoute: Identifiable, Hashable {
    enum Kind: Hashable {
        case session
        case review
    }

    let sessionID: UUID
    let title: String
    let kind: Kind

    var id: String {
        "\(sessionID.uuidString)-\(kind)"
    }
}

private struct DictationEditRoute: Identifiable {
    let id: UUID
    let title: String
}

struct DeferredDictationHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var isReady = false
    @State private var activationTask: Task<Void, Never>?

    private var canActivate: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if isReady {
                DictationHomeView()
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开听写安排...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("听写安排")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView onAppear")
            #endif
            activateAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                activateAfterNavigationSettles()
            } else {
                activationTask?.cancel()
                isReady = false
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView onDisappear")
            #endif
            activationTask?.cancel()
        }
    }

    private func activateAfterNavigationSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationHomeView activateAfterNavigationSettles requested")
        DebugPerf.watchMainThread("DeferredDictationHomeView activation")
        #endif
        activationTask?.cancel()
        guard !isReady else { return }
        guard canActivate else { return }

        activationTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            guard canActivate else { return }
            #if DEBUG
            DebugPerf.mark("DeferredDictationHomeView showing DictationHomeView")
            #endif
            isReady = true
        }
    }
}

struct DictationHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var previewSession: DictationSessionProjection?
    @State private var activeRoute: DictationRoute?
    @State private var editingRoute: DictationEditRoute?
    @State private var snapshot: DictationHomeSnapshot = .empty
    @State private var snapshotRefreshTask: Task<Void, Never>?
    @State private var isSnapshotLoaded = false
    @State private var deleteErrorMessage: String?
    @State private var isViewVisible = false
    @State private var isSnapshotRefreshInFlight = false
    @State private var needsSnapshotRefreshAfterCurrent = false

    private struct DictationHomeSnapshot {
        let todayAndOverdue: [DictationSessionProjection]
        let upcoming: [DictationSessionProjection]
        let completed: [DictationSessionProjection]
        let entriesBySessionID: [UUID: [DictationEntryProjection]]

        var isEmpty: Bool {
            todayAndOverdue.isEmpty && upcoming.isEmpty && completed.isEmpty
        }

        func entries(for session: DictationSessionProjection) -> [DictationEntryProjection] {
            entriesBySessionID[session.id] ?? []
        }

        static var empty: DictationHomeSnapshot {
            DictationHomeSnapshot(todayAndOverdue: [], upcoming: [], completed: [], entriesBySessionID: [:])
        }

        static func make(
            sessions: [DictationSessionProjection],
            entries: [DictationEntryProjection],
            referenceDate: Date = .now
        ) -> DictationHomeSnapshot {
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: referenceDate)
            let entriesBySessionID = Dictionary(grouping: entries, by: \.sessionID)
                .mapValues { sessionEntries in
                    sessionEntries.sorted { $0.sortOrder < $1.sortOrder }
                }

            let todayAndOverdue = sessions
                .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart }
                .sorted { $0.scheduledDate < $1.scheduledDate }
            let upcoming = sessions
                .filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) > todayStart }
                .sorted { $0.scheduledDate < $1.scheduledDate }
            let completed = sessions
                .filter(\.isReviewed)

            return DictationHomeSnapshot(
                todayAndOverdue: todayAndOverdue,
                upcoming: upcoming,
                completed: completed,
                entriesBySessionID: entriesBySessionID
            )
        }
    }

    private var canRenderLiveContent: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active && isViewVisible
    }
    
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AddDictationSessionView()
                } label: {
                    Label("新增听写计划", systemImage: "plus.circle.fill")
                }
            }

            if !canRenderLiveContent {
                EmptyView()
            } else if !isSnapshotLoaded {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载听写安排...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            } else if snapshot.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有听写记录",
                        systemImage: "text.book.closed",
                        description: Text("先设置要听写的内容并指定好日期。")
                    )
                }
            } else {
                let todaySessions = snapshot.todayAndOverdue
                if !todaySessions.isEmpty {
                    Section("今日及待办") {
                        ForEach(todaySessions) { session in
                            sessionRow(for: session, entries: snapshot.entries(for: session))
                        }
                    }
                }

                let upcomingSessions = snapshot.upcoming
                if !upcomingSessions.isEmpty {
                    Section("未来计划") {
                        ForEach(upcomingSessions) { session in
                            sessionRow(for: session, entries: snapshot.entries(for: session))
                        }
                    }
                }

                let completedSessions = snapshot.completed
                if !completedSessions.isEmpty {
                    Section("已完成") {
                        ForEach(completedSessions) { session in
                            sessionRow(for: session, entries: snapshot.entries(for: session))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("听写安排")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            isViewVisible = true
            #if DEBUG
            DebugPerf.mark("DictationHomeView onAppear")
            #endif
            if !isSnapshotLoaded {
                requestSnapshotRefresh(reason: "onAppear")
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DictationHomeView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                if isViewVisible {
                    requestSnapshotRefresh(
                        reason: "scenePhase active",
                        delay: isSnapshotLoaded ? 0.08 : 0.12
                    )
                }
            } else {
                snapshotRefreshTask?.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("appDataDidMutate"))) { _ in
            #if DEBUG
            DebugPerf.mark("DictationHomeView received appDataDidMutate visible=\(isViewVisible)")
            #endif
            requestSnapshotRefresh(reason: "appDataDidMutate")
        }
        .sheet(item: $previewSession) { session in
            DictationProjectionPreviewView(
                session: session,
                entries: snapshot.entries(for: session),
                onStartSession: {
                    activeRoute = DictationRoute(sessionID: session.id, title: session.title, kind: .session)
                },
                onEditSession: {
                    previewSession = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingRoute = DictationEditRoute(id: session.id, title: session.title)
                    }
                }
            )
        }
        .navigationDestination(item: $activeRoute) { route in
            DeferredDictationDestinationView(route: route)
        }
        .sheet(item: $editingRoute) { route in
            NavigationStack {
                DeferredDictationEditView(sessionID: route.id, title: route.title)
            }
        }
        .alert("删除失败", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .onDisappear {
            isViewVisible = false
            #if DEBUG
            DebugPerf.mark("DictationHomeView onDisappear")
            #endif
            snapshotRefreshTask?.cancel()
        }
    }

    private func requestSnapshotRefresh(reason: String, delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("DictationHomeView requestSnapshotRefresh reason=\(reason) delay=\(delay)")
        #endif
        guard canRenderLiveContent else { return }
        if isSnapshotRefreshInFlight {
            needsSnapshotRefreshAfterCurrent = true
            #if DEBUG
            DebugPerf.mark("DictationHomeView refresh queued reason=\(reason)")
            #endif
            return
        }
        scheduleSnapshotRefresh(delay: delay)
    }

    private func scheduleSnapshotRefresh(delay: TimeInterval = 0.08) {
        #if DEBUG
        DebugPerf.mark("DictationHomeView scheduleSnapshotRefresh delay=\(delay)")
        #endif
        snapshotRefreshTask?.cancel()
        guard canRenderLiveContent else { return }

        let container = modelContext.container
        snapshotRefreshTask = Task(priority: .utility) {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            await MainActor.run {
                isSnapshotRefreshInFlight = true
            }

            #if DEBUG
            DebugPerf.mark("DictationHomeView snapshot fetch begin")
            #endif
            let refreshedSnapshot = await Task.detached(priority: .utility) {
                #if DEBUG
                DebugPerf.mark("DictationHomeView background fetch begin")
                #endif
                let backgroundContext = ModelContext(container)
                let sessionModels = (try? backgroundContext.fetch(FetchDescriptor<DictationSession>())) ?? []
                let entryModels = (try? backgroundContext.fetch(FetchDescriptor<DictationEntry>())) ?? []
                let sessions = sessionModels
                    .map(DictationSessionProjection.init)
                    .sorted { $0.createdAt > $1.createdAt }
                let entries = entryModels.map(DictationEntryProjection.init)
                #if DEBUG
                DebugPerf.mark("DictationHomeView background fetch end sessions=\(sessions.count) entries=\(entries.count)")
                #endif
                return DictationHomeSnapshot.make(sessions: sessions, entries: entries)
            }.value

            guard !Task.isCancelled else { return }
            guard canRenderLiveContent else { return }
            snapshot = refreshedSnapshot
            isSnapshotLoaded = true
            isSnapshotRefreshInFlight = false
            #if DEBUG
            DebugPerf.mark("DictationHomeView snapshot applied empty=\(refreshedSnapshot.isEmpty)")
            #endif
            if needsSnapshotRefreshAfterCurrent {
                needsSnapshotRefreshAfterCurrent = false
                requestSnapshotRefresh(reason: "coalesced", delay: 0.02)
            }
        }
    }

    private func sessionRow(for session: DictationSessionProjection, entries: [DictationEntryProjection]) -> some View {
        let routeKind: DictationRoute.Kind = (session.isReviewed || session.isFinished) ? .review : .session

        return HStack(spacing: 0) {
            Button {
                #if DEBUG
                DebugPerf.mark("DictationHomeView session row tap title=\(session.title) kind=\(routeKind)")
                DebugPerf.watchMainThread("DictationHomeView session row tap")
                #endif
                activeRoute = DictationRoute(sessionID: session.id, title: session.title, kind: routeKind)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(session.title)
                            .font(.headline)
                        Spacer()
                        Text(statusText(for: session))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusColor(for: session))
                    }

                    HStack {
                        Text("\(session.type.displayName) · \(entries.count) 条")
                        Spacer()
                        Text(session.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if !session.isFinished && !session.isReviewed {
                Button {
                    #if DEBUG
                    DebugPerf.mark("DictationHomeView preview tap title=\(session.title)")
                    DebugPerf.watchMainThread("DictationHomeView preview tap")
                    #endif
                    previewSession = session
                } label: {
                    Image(systemName: "eye.circle")
                        .font(.title2)
                        .foregroundStyle(.blue.opacity(0.8))
                        .padding(.leading, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .iOS17SafeSwipeActions {
            Button(role: .destructive) {
                deleteSession(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
            
            if !session.isFinished && !session.isReviewed {
                Button {
                    editingRoute = DictationEditRoute(id: session.id, title: session.title)
                } label: {
                    Label("修改", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    private func deleteSession(_ session: DictationSessionProjection) {
        let sessionID = session.id
        let container = modelContext.container

        Task.detached(priority: .utility) {
            let backgroundContext = ModelContext(container)

            do {
                let sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                guard let session = try backgroundContext.fetch(sessionDescriptor).first else { return }

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID }
                )
                for entry in try backgroundContext.fetch(entryDescriptor) {
                    backgroundContext.delete(entry)
                }

                backgroundContext.delete(session)
                try backgroundContext.save()

                await MainActor.run {
                    NotificationCenter.default.post(name: Notification.Name("appDataDidMutate"), object: nil)
                }
            } catch {
                await MainActor.run {
                    deleteErrorMessage = "听写计划没有删除成功，请稍后再试。\(error.localizedDescription)"
                }
            }
        }
    }

    private func statusText(for session: DictationSessionProjection) -> String {
        if session.isReviewed {
            return "已判定"
        }
        if session.isFinished {
            return "待判定"
        }
        
        let calendar = Calendar.current
        if calendar.startOfDay(for: session.scheduledDate) < calendar.startOfDay(for: .now) {
            return "逾期"
        }
        if calendar.startOfDay(for: session.scheduledDate) > calendar.startOfDay(for: .now) {
            return "未开始"
        }
        return "进行中"
    }

    private func statusColor(for session: DictationSessionProjection) -> Color {
        if session.isReviewed {
            return .green
        }
        if session.isFinished {
            return .orange
        }
        
        let calendar = Calendar.current
        if calendar.startOfDay(for: session.scheduledDate) < calendar.startOfDay(for: .now) {
            return .red
        }
        if calendar.startOfDay(for: session.scheduledDate) > calendar.startOfDay(for: .now) {
            return .gray
        }
        return .blue
    }
}

struct DictationPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()
    
    let session: DictationSession
    let entries: [DictationEntry]
    var onStartSession: () -> Void
    var onEditSession: (() -> Void)? = nil
    
    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        
                        Text("共 \(entries.count) 条内容 · \(session.type.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    
                    VStack(spacing: 12) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 22, height: 22)
                                            .background(Color.blue.opacity(0.1), in: Circle())
                                        
                                        TypeBadge(type: entry.type)
                                        
                                        Spacer()
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)
                                        
                                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(entry.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Button {
                                    speaker.speak(content: entry.content, type: entry.type)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle("听写预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                if let onEditAction = onEditSession {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("修改") {
                            dismiss()
                            onEditAction()
                        }
                    }
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DictationPreviewView onDisappear title=\(session.title)")
                #endif
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        #if DEBUG
                        DebugPerf.mark("DictationPreviewView start session title=\(session.title)")
                        DebugPerf.watchMainThread("DictationPreviewView start session")
                        #endif
                        dismiss()
                        onStartSession()
                    } label: {
                        Text("开始听写")
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                    .padding()
                }
                .background(.bar)
            }
        }
    }
}

private struct DictationProjectionPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speaker = DictationSpeaker()

    let session: DictationSessionProjection
    let entries: [DictationEntryProjection]
    var onStartSession: () -> Void
    var onEditSession: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(session.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))

                        Text("共 \(entries.count) 条内容 · \(session.type.displayName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                    VStack(spacing: 12) {
                        ForEach(entries.indices, id: \.self) { index in
                            let entry = entries[index]
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.blue)
                                            .frame(width: 22, height: 22)
                                            .background(Color.blue.opacity(0.1), in: Circle())

                                        TypeBadge(type: entry.type)

                                        Spacer()
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.content)
                                            .font(.system(.title3, design: .rounded, weight: .bold))
                                            .foregroundStyle(.primary)

                                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(entry.prompt)
                                                .font(.headline.weight(.medium))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                }

                                Spacer()

                                Button {
                                    speaker.speak(content: entry.content, type: entry.type)
                                } label: {
                                    Image(systemName: "speaker.wave.2.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                            )
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 100)
            }
            .navigationTitle("听写预习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
                if let onEditAction = onEditSession {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("修改") {
                            dismiss()
                            onEditAction()
                        }
                    }
                }
            }
            .onDisappear {
                #if DEBUG
                DebugPerf.mark("DictationProjectionPreviewView onDisappear title=\(session.title)")
                #endif
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
                        #if DEBUG
                        DebugPerf.mark("DictationProjectionPreviewView start session title=\(session.title)")
                        DebugPerf.watchMainThread("DictationProjectionPreviewView start session")
                        #endif
                        dismiss()
                        onStartSession()
                    } label: {
                        Text("开始听写")
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                    .padding()
                }
                .background(.bar)
            }
        }
    }
}

private struct DeferredDictationDestinationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let route: DictationRoute

    @State private var session: DictationSession?
    @State private var entries: [DictationEntry] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let session {
                switch route.kind {
                case .session:
                    DictationSessionView(session: session, entries: entries)
                case .review:
                    DictationReviewView(session: session, entries: entries)
                }
            } else if loadFailed {
                ContentUnavailableView("听写记录不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(route.title)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView onAppear title=\(route.title) kind=\(route.kind)")
            DebugPerf.watchMainThread("DeferredDictationDestinationView onAppear")
            #endif
            loadAfterNavigationSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                loadAfterNavigationSettles()
            } else {
                loadTask?.cancel()
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationDestinationView onDisappear title=\(route.title)")
            #endif
            loadTask?.cancel()
        }
    }

    private func loadAfterNavigationSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationDestinationView loadAfterNavigationSettles requested title=\(route.title)")
        DebugPerf.watchMainThread("DeferredDictationDestinationView load \(route.title)")
        #endif
        loadTask?.cancel()
        guard session == nil else { return }
        guard canLoad else { return }

        loadTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard canLoad else { return }

            do {
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch begin title=\(route.title)")
                #endif
                let sessionID = route.sessionID
                var sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                sessionDescriptor.fetchLimit = 1

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )

                session = try modelContext.fetch(sessionDescriptor).first
                entries = try modelContext.fetch(entryDescriptor)
                loadFailed = session == nil
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch end title=\(route.title) entries=\(entries.count) failed=\(loadFailed)")
                #endif
            } catch {
                #if DEBUG
                DebugPerf.mark("DeferredDictationDestinationView main fetch error title=\(route.title) error=\(error.localizedDescription)")
                #endif
                loadFailed = true
            }
        }
    }
}

private struct DeferredDictationEditView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    let sessionID: UUID
    let title: String

    @State private var session: DictationSession?
    @State private var entries: [DictationEntry] = []
    @State private var loadTask: Task<Void, Never>?
    @State private var loadFailed = false

    private var canLoad: Bool {
        scenePhase == .active && UIApplication.shared.applicationState == .active
    }

    var body: some View {
        Group {
            if let session {
                AddDictationSessionView(editingSession: session, existingEntries: entries)
            } else if loadFailed {
                ContentUnavailableView("听写记录不存在", systemImage: "exclamationmark.triangle")
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在打开 \(title)...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .onAppear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView onAppear title=\(title)")
            DebugPerf.watchMainThread("DeferredDictationEditView onAppear")
            #endif
            loadAfterSheetSettles()
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView scenePhase=\(newPhase)")
            #endif
            if newPhase == .active {
                loadAfterSheetSettles()
            } else {
                loadTask?.cancel()
            }
        }
        .onDisappear {
            #if DEBUG
            DebugPerf.mark("DeferredDictationEditView onDisappear title=\(title)")
            #endif
            loadTask?.cancel()
        }
    }

    private func loadAfterSheetSettles() {
        #if DEBUG
        DebugPerf.mark("DeferredDictationEditView loadAfterSheetSettles requested title=\(title)")
        DebugPerf.watchMainThread("DeferredDictationEditView load \(title)")
        #endif
        loadTask?.cancel()
        guard session == nil else { return }
        guard canLoad else { return }

        loadTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            guard canLoad else { return }

            do {
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch begin title=\(title)")
                #endif
                var sessionDescriptor = FetchDescriptor<DictationSession>(
                    predicate: #Predicate<DictationSession> { $0.id == sessionID }
                )
                sessionDescriptor.fetchLimit = 1

                let entryDescriptor = FetchDescriptor<DictationEntry>(
                    predicate: #Predicate<DictationEntry> { $0.sessionID == sessionID },
                    sortBy: [SortDescriptor(\.sortOrder)]
                )

                session = try modelContext.fetch(sessionDescriptor).first
                entries = try modelContext.fetch(entryDescriptor)
                loadFailed = session == nil
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch end title=\(title) entries=\(entries.count) failed=\(loadFailed)")
                #endif
            } catch {
                #if DEBUG
                DebugPerf.mark("DeferredDictationEditView main fetch error title=\(title) error=\(error.localizedDescription)")
                #endif
                loadFailed = true
            }
        }
    }
}
