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
    var onReturnFromCompletion: (() -> Void)? = nil

    @State private var entryStates: [BatchReviewEntryState] = []
    @State private var isSubmitted = false
    @State private var reviewedSummaries: [SessionReviewSummary] = []
    
    private let scheduler = ReviewScheduler()

    init(items: [ReviewItem], onReturnFromCompletion: (() -> Void)? = nil) {
        self.items = items
        self.onReturnFromCompletion = onReturnFromCompletion
    }

    private var allMarked: Bool {
        !entryStates.isEmpty && entryStates.allSatisfy { $0.result != .pending }
    }
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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    reviewStat(title: "总条数", value: "\(entryStates.count)", tint: .blue)
                    reviewStat(title: "未判定", value: "\(entryStates.filter { $0.result == .pending }.count)", tint: allMarked ? .green : .orange)
                    reviewStat(title: "已判定", value: "\(entryStates.filter { $0.result != .pending }.count)", tint: .mint)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 10) {
                    ForEach(entryStates.indices, id: \.self) { index in
                        let state = $entryStates[index]
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 20, height: 20)
                                    .background(Color.blue.opacity(0.1), in: Circle())

                                TypeBadge(type: state.wrappedValue.item.type)
                                
                                Spacer()
                                
                                Text(resultText(for: state.wrappedValue.result))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(statusColor(for: state.wrappedValue.result))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(statusColor(for: state.wrappedValue.result).opacity(0.1), in: Capsule())
                            }

                            HStack(spacing: 12) {
                                Text(state.wrappedValue.item.content)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                                HStack(spacing: 8) {
                                    Button {
                                        state.wrappedValue.result = (state.wrappedValue.result == .correct) ? .pending : .correct
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: state.wrappedValue.result == .correct ? "checkmark.circle.fill" : "checkmark.circle")
                                            Text("正确")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(state.wrappedValue.result == .correct ? .white : .green)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(state.wrappedValue.result == .correct ? Color.green : Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        state.wrappedValue.result = (state.wrappedValue.result == .wrong) ? .pending : .wrong
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: state.wrappedValue.result == .wrong ? "xmark.circle.fill" : "xmark.circle")
                                            Text("错误")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(state.wrappedValue.result == .wrong ? .white : .red)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(state.wrappedValue.result == .wrong ? Color.red : Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(width: 160)
                            }

                            if !state.wrappedValue.item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(state.wrappedValue.item.prompt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.thinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .strokeBorder(.secondary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 110)
        }
        .safeAreaInset(edge: .bottom) {
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

    private func reviewStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private func resultText(for result: DictationResult) -> String {
        switch result {
        case .pending:
            return "未判定"
        case .correct:
            return "正确"
        case .wrong:
            return "错误"
        }
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
                        Image(systemName: wrongCount == 0 ? "checkmark.seal.fill" : "arrow.trianglehead.clockwise")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)

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
                        dismiss()
                        DispatchQueue.main.async {
                            onReturnFromCompletion?()
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
