import SwiftUI
import SwiftData

struct DictationHomeView: View {
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var sessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var allEntries: [DictationEntry]
    @Environment(\.modelContext) private var modelContext
    
    @State private var previewSession: DictationSession?
    @State private var activeSession: DictationSession?
    @State private var editingSession: DictationSession?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AddDictationSessionView()
                } label: {
                    Label("新增听写计划", systemImage: "plus.circle.fill")
                }
            }

            if sessions.isEmpty {
                Section {
                    ContentUnavailableView(
                        "还没有听写记录",
                        systemImage: "text.book.closed",
                        description: Text("先设置要听写的内容并指定好日期。")
                    )
                }
            } else {
                let todaySessions = todayAndOverdue
                if !todaySessions.isEmpty {
                    Section("今日及待办") {
                        ForEach(todaySessions) { session in
                            sessionRow(for: session)
                        }
                    }
                }

                let upcomingSessions = upcoming
                if !upcomingSessions.isEmpty {
                    Section("未来计划") {
                        ForEach(upcomingSessions) { session in
                            sessionRow(for: session)
                        }
                    }
                }

                let completedSessions = completed
                if !completedSessions.isEmpty {
                    Section("已完成") {
                        ForEach(completedSessions) { session in
                            sessionRow(for: session)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("听写安排")
        .sheet(item: $previewSession) { session in
            DictationPreviewView(
                session: session,
                entries: entries(for: session),
                onStartSession: {
                    activeSession = session
                },
                onEditSession: {
                    previewSession = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingSession = session
                    }
                }
            )
        }
        .navigationDestination(item: $activeSession) { session in
            DictationSessionView(session: session, entries: entries(for: session))
        }
        .sheet(item: $editingSession) { session in
            NavigationStack {
                AddDictationSessionView(editingSession: session, existingEntries: entries(for: session))
            }
        }
    }

    private var todayAndOverdue: [DictationSession] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        return sessions.filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) <= todayStart }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var upcoming: [DictationSession] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: .now)
        return sessions.filter { !$0.isReviewed && calendar.startOfDay(for: $0.scheduledDate) > todayStart }
            .sorted { $0.scheduledDate < $1.scheduledDate }
    }

    private var completed: [DictationSession] {
        sessions.filter { $0.isReviewed }
            // Sort completed ones naturally by most recently created/scheduled (since SwiftData @Query sorting applies base, we can just use the provided inverted list)
    }

    private func sessionRow(for session: DictationSession) -> some View {
        HStack(spacing: 0) {
            NavigationLink {
                destinationView(for: session)
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
                        Text("\(session.type.displayName) · \(entries(for: session).count) 条")
                        Spacer()
                        Text(session.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            
            if !session.isFinished && !session.isReviewed {
                Button {
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
        .swipeActions {
            Button(role: .destructive) {
                modelContext.delete(session)
            } label: {
                Label("删除", systemImage: "trash")
            }
            
            if !session.isFinished && !session.isReviewed {
                Button {
                    editingSession = session
                } label: {
                    Label("修改", systemImage: "pencil")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func destinationView(for session: DictationSession) -> some View {
        let sessionEntries = entries(for: session)
        if session.isReviewed {
            DictationReviewView(session: session, entries: sessionEntries)
        } else if session.isFinished {
            DictationReviewView(session: session, entries: sessionEntries)
        } else {
            DictationSessionView(session: session, entries: sessionEntries)
        }
    }

    private func entries(for session: DictationSession) -> [DictationEntry] {
        allEntries
            .filter { $0.sessionID == session.id }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func statusText(for session: DictationSession) -> String {
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

    private func statusColor(for session: DictationSession) -> Color {
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
                speaker.stop()
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Button {
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
