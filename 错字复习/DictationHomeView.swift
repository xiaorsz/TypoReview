import SwiftUI
import SwiftData

struct DictationHomeView: View {
    @Query(sort: \DictationSession.createdAt, order: .reverse) private var sessions: [DictationSession]
    @Query(sort: \DictationEntry.sortOrder) private var allEntries: [DictationEntry]

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
        .navigationTitle("听写安排")
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
                    Text("\(session.type.rawValue) · \(entries(for: session).count) 条")
                    Spacer()
                    Text(session.scheduledDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
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
