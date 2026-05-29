import SwiftUI
import SwiftData

struct DictationReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \ReviewItem.updatedAt, order: .reverse) private var reviewItems: [ReviewItem]

    @State private var saveErrorMessage: String?
    @State private var submittedSummaries: [DictationEntrySummary] = []
    @State private var navigateToSummary = false

    let session: DictationSession
    let entries: [DictationEntry]
    var onReturnToList: (() -> Void)? = nil

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
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        reviewStat(title: "总条数", value: "\(entries.count)", tint: .blue)
                        reviewStat(title: "未判定", value: "\(pendingCount)", tint: pendingCount == 0 ? .green : .orange)
                        reviewStat(title: "判错", value: "\(wrongCount)", tint: .red)
                    }

                    HStack(spacing: 12) {
                        Button("全部正确") { markAll(.correct) }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)

                        Button("清空") { markAll(.pending) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        
                        Spacer()
                    }
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                VStack(spacing: 10) {
                    ForEach(entries.indices, id: \.self) { index in
                        let entry = entries[index]
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 20, height: 20)
                                    .background(Color.blue.opacity(0.1), in: Circle())

                                TypeBadge(type: entry.type)
                                
                                Spacer()
                                
                                Text(entry.result.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(statusColor(for: entry.result))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(statusColor(for: entry.result).opacity(0.1), in: Capsule())
                            }

                            HStack(spacing: 12) {
                                Text(entry.content)
                                    .font(.system(size: 24, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                                HStack(spacing: 8) {
                                    Button {
                                        entry.result = entry.result == .correct ? .pending : .correct
                                        entry.updatedAt = .now
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: entry.result == .correct ? "checkmark.circle.fill" : "checkmark.circle")
                                            Text("正确")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(entry.result == .correct ? .white : .green)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(entry.result == .correct ? Color.green : Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        entry.result = entry.result == .wrong ? .pending : .wrong
                                        entry.updatedAt = .now
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: entry.result == .wrong ? "xmark.circle.fill" : "xmark.circle")
                                            Text("错误")
                                        }
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(entry.result == .wrong ? .white : .red)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .background(entry.result == .wrong ? Color.red : Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .frame(width: 160)
                            }

                            if !entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(entry.prompt)
                                    .font(.subheadline)
                                    .foregroundStyle(.blue)
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
        .navigationTitle("统一判卷")
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
                summaries: submittedSummaries,
                onReturnToList: {
                    dismiss()
                    onReturnToList?()
                }
            )
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

    private func resultButton(title: String, result: DictationResult, entry: DictationEntry, color: Color) -> some View {
        Button(title) {
            entry.result = entry.result == result ? .pending : result
            entry.updatedAt = .now
        }
        .buttonStyle(GradingChoiceButtonStyle(color: color, isSelected: entry.result == result))
        .contentShape(Rectangle())
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

        let scheduler = ReviewScheduler()
        let nextReviewStart = scheduler.nextDayStart(from: now)
        let firstFollowUpDate = scheduler.dictationFollowUpDate(for: 1, from: now)

        for entry in entries {
            if entry.result == .wrong {
                if let existing = reviewItems.first(where: { $0.type == entry.type && $0.content == entry.content }) {
                    let shouldPreserveStage = existing.reviewTrack == .standard && !scheduler.isMastered(existing)
                    existing.prompt = entry.prompt
                    existing.note = entry.note
                    existing.source = entry.source
                    existing.nextReviewAt = nextReviewStart
                    existing.isPriority = true
                    existing.reviewTrack = .standard
                    existing.dictationFollowUpStep = 0
                    existing.updatedAt = now
                    existing.isDictationPass = false
                    existing.stage = shouldPreserveStage ? existing.stage : 0
                    existing.consecutiveCorrectCount = 0
                    existing.consecutiveWrongCount = max(existing.consecutiveWrongCount, 1)
                } else {
                    modelContext.insert(
                        ReviewItem(
                            type: entry.type,
                            content: entry.content,
                            prompt: entry.prompt,
                            note: entry.note,
                            source: entry.source,
                            stage: 0,
                            nextReviewAt: nextReviewStart,
                            reviewTrack: .standard,
                            updatedAt: now
                        )
                    )
                }
            } else if entry.result == .correct {
                if let existing = reviewItems.first(where: { $0.type == entry.type && $0.content == entry.content }) {
                    existing.prompt = entry.prompt
                    existing.note = entry.note
                    existing.source = entry.source
                    existing.reviewTrack = .dictationFollowUp
                    existing.dictationFollowUpStep = 1
                    existing.isDictationPass = true
                    existing.stage = 1
                    existing.nextReviewAt = firstFollowUpDate
                    existing.isPriority = false
                    existing.lastReviewedAt = now
                    existing.updatedAt = now
                    existing.consecutiveCorrectCount = 0
                    existing.consecutiveWrongCount = 0
                } else {
                    let newItem = ReviewItem(
                        type: entry.type,
                        content: entry.content,
                        prompt: entry.prompt,
                        note: entry.note,
                        source: entry.source,
                        stage: 1,
                        nextReviewAt: firstFollowUpDate,
                        reviewTrack: .dictationFollowUp,
                        dictationFollowUpStep: 1,
                        isDictationPass: true,
                        updatedAt: now
                    )
                    modelContext.insert(newItem)
                }
            }

            if entry.result != .pending {
                PointLedgerService.awardDictationEntry(entry, in: modelContext)
            }
        }

        session.reviewedAt = now
        session.updatedAt = now

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: Notification.Name("appDataDidMutate"), object: nil)
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
            return "本次听写通过，已安排到第3天复习"
        case .wrong:
            return "已加入错题复习，明天开始待复习"
        case .pending:
            return "未判定"
        }
    }
}

private struct DictationSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettingsStore.self) private var settings

    @State private var learningSessionSummary: LearningSessionSummaryResult?
    @State private var learningSessionSummaryInputHash = ""
    @State private var isLoadingLearningSessionSummary = false
    @State private var learningSessionSummaryTask: Task<Void, Never>?
    @AppStorage(DailySummaryAISettings.isEnabledKey) private var aiSummaryEnabled = false
    @AppStorage(DailySummaryAISettings.modelKey) private var aiSummaryModelRawValue = DailySummaryAISettings.defaultModel

    let title: String
    let summaries: [DictationEntrySummary]
    let onReturnToList: () -> Void

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
                        Image(systemName: wrongCount == 0 ? "checkmark.seal.fill" : "pencil.and.outline")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)

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

                    learningSessionSummaryCard

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
                        DispatchQueue.main.async {
                            onReturnToList()
                        }
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
                .onAppear {
                    refreshLearningSessionSummary(force: false)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            learningSessionSummaryTask?.cancel()
        }
    }

    private var summaryText: String {
        if wrongCount == 0 {
            return "这次听写全部答对，系统会在第3天和第7天各安排一次复习。"
        }

        return "这次一共完成 \(totalCount) 条，其中答错 \(wrongCount) 条。答错内容会从明天开始进入待复习；如果第二天没复习，会继续保留在今日待复习中。"
    }

    private var learningSessionSummaryCard: some View {
        let result = learningSessionSummary ?? makeLearningSessionSummaryInput().localFallbackResult()

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: wrongCount == 0 ? "sparkles" : "lightbulb.max.fill")
                    .foregroundStyle(.purple)
                Text(wrongCount == 0 ? "AI 本次小结" : "AI 错项建议")
                    .font(.headline)

                Spacer()

                if isLoadingLearningSessionSummary {
                    ProgressView()
                        .controlSize(.small)
                }

                if aiSummaryEnabled {
                    Button {
                        refreshLearningSessionSummary(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingLearningSessionSummary)
                    .accessibilityLabel("重新生成 AI 错项建议")
                }
            }

            Text(result.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !result.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.suggestions.prefix(3).enumerated()), id: \.offset) { _, suggestion in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .padding(.top, 2)
                            Text(suggestion)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func makeLearningSessionSummaryInput() -> LearningSessionSummaryInput {
        LearningSessionSummaryInput(
            kind: .dictation,
            title: title,
            date: DailySummaryInput.dateKey(),
            childName: settings.childName.isEmpty ? "小朋友" : settings.childName,
            metrics: LearningSessionSummaryInput.Metrics(
                totalCount: totalCount,
                correctCount: correctCount,
                wrongCount: wrongCount,
                accuracyText: accuracyText
            ),
            samples: LearningSessionSummaryInput.Samples(
                wrongItems: summaries.filter { $0.result == .wrong }.map(\.content).prefix(8).map { $0 },
                correctItems: summaries.filter { $0.result == .correct }.map(\.content).prefix(4).map { $0 }
            )
        )
    }

    private func refreshLearningSessionSummary(force: Bool) {
        let input = makeLearningSessionSummaryInput()
        let inputHash = input.stableHash()
        let model = DeepSeekSummaryModel(rawValue: aiSummaryModelRawValue) ?? .flash
        let fallback = input.localFallbackResult()

        guard aiSummaryEnabled else {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = fallback
            isLoadingLearningSessionSummary = false
            return
        }

        guard let apiKey = try? DeepSeekAPIKeyStore.loadAPIKey(),
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = fallback
            isLoadingLearningSessionSummary = false
            return
        }

        if !force,
           learningSessionSummaryInputHash == inputHash,
           learningSessionSummary != nil {
            return
        }

        if !force,
           let cached = LearningSessionSummaryCache.load(inputHash: inputHash, model: model.rawValue) {
            learningSessionSummaryTask?.cancel()
            learningSessionSummaryInputHash = inputHash
            learningSessionSummary = cached
            isLoadingLearningSessionSummary = false
            return
        }

        learningSessionSummaryTask?.cancel()
        learningSessionSummaryInputHash = inputHash
        learningSessionSummary = fallback
        isLoadingLearningSessionSummary = true

        learningSessionSummaryTask = Task {
            do {
                let result = try await DeepSeekSummaryClient(apiKey: apiKey, model: model.rawValue)
                    .generateLearningSessionSummary(for: input)
                await MainActor.run {
                    LearningSessionSummaryCache.save(result, inputHash: inputHash, model: model.rawValue)
                    learningSessionSummary = result
                    learningSessionSummaryInputHash = inputHash
                    isLoadingLearningSessionSummary = false
                }
            } catch {
                await MainActor.run {
                    learningSessionSummary = fallback
                    learningSessionSummaryInputHash = inputHash
                    isLoadingLearningSessionSummary = false
                }
            }
        }
    }

}
