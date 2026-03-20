import SwiftUI
import SwiftData

struct DictationReviewView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]

    @State private var saveErrorMessage: String?
    @State private var submittedSummaries: [DictationEntrySummary] = []
    @State private var navigateToSummary = false

    let session: DictationSession
    let entries: [DictationEntry]

    private var pendingCount: Int {
        entries.filter { $0.result == .pending }.count
    }

    private var wrongCount: Int {
        entries.filter { $0.result == .wrong }.count
    }

    private var canSubmit: Bool {
        !entries.isEmpty && pendingCount == 0
    }

    var body: some View {
        List {
            Section {
                statRow(title: "总条数", value: "\(entries.count)")
                statRow(title: "未判定", value: "\(pendingCount)")
                statRow(title: "判错", value: "\(wrongCount)")
            } header: {
                Text("批量判定")
            } footer: {
                Text("点“正确”或“错误”都可以选；再点一次会取消，回到未判定。")
            }

            Section {
                Button("全部标记正确") {
                    markAll(.correct)
                }
                Button("清空判定") {
                    markAll(.pending)
                }
            }

            Section("逐条判定") {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(entry.content)
                                .font(.headline)
                            Spacer()
                            Text(entry.result.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor(for: entry.result))
                            Text(entry.type.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(entry.prompt)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !entry.source.isEmpty {
                            Text(entry.source)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        HStack(spacing: 10) {
                            resultButton(title: "正确", result: .correct, entry: entry, color: .green)
                            resultButton(title: "错误", result: .wrong, entry: entry, color: .red)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("统一判定")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button("完成判定") {
                submitReview()
            }
            .buttonStyle(ResultButtonStyle(color: .blue))
            .padding()
            .background(.bar)
            .disabled(!canSubmit)
        }
        .alert("提交失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .navigationDestination(isPresented: $navigateToSummary) {
            DictationSummaryView(
                title: session.title,
                summaries: submittedSummaries
            )
        }
    }

    private func statRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
    }

    private func resultButton(title: String, result: DictationResult, entry: DictationEntry, color: Color) -> some View {
        Button(title) {
            entry.result = entry.result == result ? .pending : result
            entry.updatedAt = .now
        }
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(entry.result == result ? color : color.opacity(0.12))
        )
        .foregroundStyle(entry.result == result ? .white : color)
    }

    private func statusColor(for result: DictationResult) -> Color {
        switch result {
        case .pending:
            return .secondary
        case .correct:
            return .green
        case .wrong:
            return .red
        }
    }

    private func markAll(_ result: DictationResult) {
        let now = Date()
        for entry in entries {
            entry.result = result
            entry.updatedAt = now
        }
    }

    private func submitReview() {
        guard canSubmit else { return }

        let now = Date()
        let summaries = entries.map {
            DictationEntrySummary(
                content: $0.content,
                prompt: $0.prompt,
                source: $0.source,
                result: $0.result
            )
        }

        for entry in entries where entry.result == .wrong {
            if let existing = reviewItems.first(where: { $0.type == entry.type && $0.content == entry.content }) {
                existing.prompt = entry.prompt
                existing.note = entry.note
                existing.source = entry.source
                existing.nextReviewAt = now
                existing.isPriority = true
                existing.updatedAt = now
                existing.stage = max(existing.stage, 1)
            } else {
                modelContext.insert(
                    ReviewItem(
                        type: entry.type,
                        content: entry.content,
                        prompt: entry.prompt,
                        note: entry.note,
                        source: entry.source,
                        stage: 0,
                        nextReviewAt: now,
                        updatedAt: now
                    )
                )
            }
        }

        session.reviewedAt = now
        session.updatedAt = now

        do {
            try modelContext.save()
            submittedSummaries = summaries
            navigateToSummary = true
        } catch {
            saveErrorMessage = "这次判定没有保存成功，请再试一次。\(error.localizedDescription)"
        }
    }
}

private struct DictationEntrySummary: Identifiable {
    let id = UUID()
    let content: String
    let prompt: String
    let source: String
    let result: DictationResult

    var detail: String {
        switch result {
        case .correct:
            return "本次听写通过"
        case .wrong:
            return "已加入错题复习"
        case .pending:
            return "未判定"
        }
    }
}

private struct DictationSummaryView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let summaries: [DictationEntrySummary]

    private var totalCount: Int {
        summaries.count
    }

    private var correctCount: Int {
        summaries.filter { $0.result == .correct }.count
    }

    private var wrongCount: Int {
        summaries.filter { $0.result == .wrong }.count
    }

    private var accuracyText: String {
        guard totalCount > 0 else { return "--" }
        let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
        return "\(accuracy)%"
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(wrongCount == 0 ? "🎉" : "👏")
                            .font(.system(size: 48))

                        Text("今日听写完成")
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))

                        Text(summaryText)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 28)
                            .fill(
                                LinearGradient(
                                    colors: [.teal.opacity(0.85), .mint.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                    let columns = isWide
                        ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
                        : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

                    LazyVGrid(columns: columns, spacing: 12) {
                        StatGridCard(icon: "checkmark.seal", title: "完成", value: "\(totalCount)", tint: .blue)
                        StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(correctCount)", tint: .green)
                        StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(wrongCount)", tint: .red)
                        StatGridCard(icon: "percent", title: "正确率", value: accuracyText, tint: .orange)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("本次结果")
                            .font(.headline)

                        ForEach(summaries) { summary in
                            HStack(spacing: 12) {
                                Image(systemName: summary.result == .correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(summary.result == .correct ? .green : .red)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.content)
                                        .fontWeight(.semibold)
                                    Text(summary.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    if !summary.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(summary.prompt)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    if !summary.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(summary.source)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))

                    Button("返回听写列表") {
                        dismiss()
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryText: String {
        if wrongCount == 0 {
            return "这次听写全部答对，本轮内容已经完成。"
        }

        return "这次一共完成 \(totalCount) 条，其中答错 \(wrongCount) 条。答错内容已经加入错题复习。"
    }

}
