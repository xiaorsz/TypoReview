import SwiftUI
import SwiftData

struct BatchReviewEntryState: Identifiable {
    let item: ReviewItem
    var result: DictationResult
    var id: PersistentIdentifier { item.persistentModelID }
}

private struct SessionReviewSummary: Identifiable {
    let id = UUID()
    let content: String
    let result: ReviewResult
    let oldStage: Int
    let newStage: Int

    var detail: String {
        if result == .correct {
            return "已从阶段 \(oldStage) 进入阶段 \(newStage)"
        }
        return "本次判错，已调整到阶段 \(newStage)"
    }
}

struct BatchReviewGradingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let items: [ReviewItem]

    @State private var entryStates: [BatchReviewEntryState] = []
    @State private var isSubmitted = false
    @State private var reviewedSummaries: [SessionReviewSummary] = []
    
    private let scheduler = ReviewScheduler()

    init(items: [ReviewItem]) {
        self.items = items
    }

    private var allMarked: Bool {
        !entryStates.isEmpty && entryStates.allSatisfy { $0.result != .pending }
    }
    
    // Using a simple navigation pop to root view since we are presented as part of daily review
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Group {
            if isSubmitted {
                completionView
            } else {
                gradingView
            }
        }
        .navigationTitle(isSubmitted ? "复习结果" : "统一判定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isSubmitted {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("便捷操作", systemImage: "ellipsis.circle") {
                        Button("全部标记为正确", systemImage: "checkmark.circle.fill") {
                            markAll(as: .correct)
                        }
                    }
                }
            }
        }
        .onAppear {
            if entryStates.isEmpty {
                entryStates = items.map { BatchReviewEntryState(item: $0, result: .pending) }
            }
        }
    }

    private var gradingView: some View {
        VStack(spacing: 0) {
            List {
                ForEach($entryStates) { $state in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TypeBadge(type: state.item.type)
                            Spacer()
                            if !state.item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(state.item.prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(state.item.content)
                            .font(.system(.title2, design: .rounded, weight: .bold))

                        HStack(spacing: 12) {
                            Button {
                                state.result = (state.result == .correct) ? .pending : .correct
                            } label: {
                                Label("正确", systemImage: state.result == .correct ? "checkmark.circle.fill" : "checkmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(state.result == .correct ? .green : .gray.opacity(0.3))
                            .foregroundStyle(state.result == .correct ? .white : .primary)

                            Button {
                                state.result = (state.result == .wrong) ? .pending : .wrong
                            } label: {
                                Label("错误", systemImage: state.result == .wrong ? "xmark.circle.fill" : "xmark.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(state.result == .wrong ? .red : .gray.opacity(0.3))
                            .foregroundStyle(state.result == .wrong ? .white : .primary)
                        }
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }
            }
            .listStyle(.plain)

            VStack(spacing: 16) {
                if !allMarked {
                    Text("还有未判定的项目")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                Button("提交复习结果") {
                    submitResults()
                }
                .buttonStyle(ResultButtonStyle(color: allMarked ? .blue : .gray))
                .disabled(!allMarked)
            }
            .padding(20)
            .background(.thinMaterial)
        }
    }

    private var completionView: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700
            
            let totalCount = entryStates.filter { $0.result != .pending }.count
            let correctCount = entryStates.filter { $0.result == .correct }.count
            let wrongCount = totalCount - correctCount
            
            let accuracyText: String = {
                guard totalCount > 0 else { return "--" }
                let accuracy = Int((Double(correctCount) / Double(totalCount) * 100).rounded())
                return "\(accuracy)%"
            }()
            
            let summaryText: String = {
                if wrongCount == 0 {
                    return "这次复习全部答对，系统已经自动安排到下一次复习日期。"
                }
                return "这次一共完成 \(totalCount) 题，其中答错 \(wrongCount) 题。答错的内容会安排到之后的日期，今天不会重复出现。"
            }()

            ScrollView {
                VStack(spacing: 20) {
                    // Hero card
                    VStack(alignment: .leading, spacing: 12) {
                        Text(wrongCount == 0 ? "🎉" : "👏")
                            .font(.system(size: 48))

                        Text("今日复习完成")
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
                                    colors: [.green.opacity(0.82), .mint.opacity(0.55)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )

                    // Stats grid
                    let columns = isWide
                        ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
                        : Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)

                    LazyVGrid(columns: columns, spacing: 12) {
                        StatGridCard(icon: "checkmark.seal", title: "完成", value: "\(totalCount)", tint: .blue)
                        StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(correctCount)", tint: .green)
                        StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(wrongCount)", tint: .red)
                        StatGridCard(icon: "percent", title: "正确率", value: accuracyText, tint: .orange)
                    }

                    if !reviewedSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("判定详情")
                                .font(.headline)

                            ForEach(reviewedSummaries) { summary in
                                HStack(spacing: 12) {
                                    Image(systemName: summary.result == .correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(summary.result == .correct ? .green : .red)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(summary.content)
                                            .fontWeight(.semibold)
                                        Text(summary.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
                    }

                    Button("返回首页") {
                        // Dismiss all the way back
                        // Using a standard dismiss doesn't pop to root if we are deeply pushed,
                        // but setting the window's root view or using a custom environment key can pop.
                        // For simplicity in iOS 16+, setting a navigation state to false works.
                        // Here we just dismiss multiple times or rely on the root view binding if available.
                        // A simple hack is setting the entry states to empty might not pop. Let's just use window root pop or rely on basic view presentation behavior (a back button is also at the top).
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let window = windowScene.windows.first {
                            window.rootViewController?.dismiss(animated: true)
                        }
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
            }
            .navigationBarBackButtonHidden(true)
        }
    }

    private func markAll(as result: DictationResult) {
        for index in entryStates.indices {
            entryStates[index].result = result
        }
    }

    private func submitResults() {
        var summaries: [SessionReviewSummary] = []
        
        for state in entryStates {
            guard state.result != .pending else { continue }
            let reviewResult: ReviewResult = state.result == .correct ? .correct : .wrong
            
            let output = scheduler.handle(item: state.item, result: reviewResult)
            modelContext.insert(output.record)
            
            summaries.append(
                SessionReviewSummary(
                    content: state.item.content,
                    result: reviewResult,
                    oldStage: output.record.oldStage,
                    newStage: output.record.newStage
                )
            )
        }
        
        // Ensure data is saved
        try? modelContext.save()
        
        self.reviewedSummaries = summaries
        
        withAnimation {
            isSubmitted = true
        }
    }
}
