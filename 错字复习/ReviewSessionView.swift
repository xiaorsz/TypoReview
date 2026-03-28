import SwiftUI
import AVFoundation
import SwiftData

struct ReviewSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var sessionItems: [ReviewItem]
    @State private var currentIndex = 0
    @State private var completedCount = 0
    @State private var wrongCount = 0
    @State private var showResultButtons = false
    @State private var isContentRevealed = false
    @State private var reviewedSummaries: [SessionReviewSummary] = []
    @State private var showFeedback = false
    @State private var lastResultCorrect = true
    @State private var undoStack: [UndoEntry] = []
    @StateObject private var speaker = ReviewSpeaker()

    private let scheduler = ReviewScheduler()

    init(items: [ReviewItem]) {
        _sessionItems = State(initialValue: items)
    }

    private var currentItem: ReviewItem? {
        guard sessionItems.indices.contains(currentIndex) else { return nil }
        return sessionItems[currentIndex]
    }

    private var progress: Double {
        guard !sessionItems.isEmpty else { return 0 }
        return Double(currentIndex) / Double(sessionItems.count)
    }

    var body: some View {
        ZStack {
            Group {
                if let item = currentItem {
                    GeometryReader { proxy in
                        let isWide = proxy.size.width >= 700

                        VStack(spacing: 20) {
                            // Progress bar
                            VStack(spacing: 8) {
                                ProgressView(value: progress)
                                    .tint(.accentColor)
                                    .animation(.easeInOut(duration: 0.3), value: progress)

                                Text("第 \(currentIndex + 1) / \(sessionItems.count) 题")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }

                            // Question card
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    TypeBadge(type: item.type)
                                    Spacer()
                                    Text("阶段 \(item.stage)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(item.stage.stageColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(item.stage.stageColor.opacity(0.12), in: Capsule())
                                }

                                Text(headlineText(for: item))
                                    .font(.system(isWide ? .largeTitle : .title2, design: .rounded, weight: .bold))


                                Button {
                                    speaker.speak(item)
                                } label: {
                                    Label(speaker.isSpeaking ? "正在朗读" : "点击朗读", systemImage: "speaker.wave.2.fill")
                                        .font(.system(.title2, design: .rounded, weight: .bold))
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 56)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)

                                HStack(alignment: .top) {
                                    Text(helperText(for: item))
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                    
                                    Spacer()
                                    
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            isContentRevealed.toggle()
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: isContentRevealed ? "eye.slash.fill" : "eye.fill")
                                            Text(isContentRevealed ? "隐藏文字" : "显示文字")
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.blue)
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 12)
                                        .background(Color.blue.opacity(0.1), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                if isContentRevealed {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Divider()
                                            .padding(.vertical, 8)
                                        Text("题目答案")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                        Text(item.content)
                                            .font(.system(isWide ? .title : .title2, design: .rounded, weight: .semibold))
                                            .foregroundStyle(.blue)
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(isWide ? 32 : 24)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))

                            if showResultButtons {
                                VStack(spacing: 14) {
                                    answerCard(for: item)

                                    HStack(spacing: 14) {
                                        Button {
                                            submit(.correct, for: item)
                                        } label: {
                                            Label("正确", systemImage: "checkmark.circle.fill")
                                        }
                                        .buttonStyle(ResultButtonStyle(color: .green))

                                        Button {
                                            submit(.wrong, for: item)
                                        } label: {
                                            Label("不正确", systemImage: "xmark.circle.fill")
                                        }
                                        .buttonStyle(ResultButtonStyle(color: .red))
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity
                                ))
                            } else {
                                Button("我写好了") {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        showResultButtons = true
                                    }
                                }
                                .buttonStyle(ResultButtonStyle(color: .blue))
                            }

                            Spacer()
                        }
                        .padding(isWide ? 32 : 20)
                    }
                    .id(currentIndex) // Force view refresh on index change
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                } else {
                    completionView
                }
            }

            // Feedback overlay
            AnswerFeedbackOverlay(isCorrect: lastResultCorrect, isVisible: $showFeedback)
        }
        .navigationTitle("开始复习")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    undoLastAnswer()
                } label: {
                    Label("撤回", systemImage: "arrow.uturn.backward")
                }
                .disabled(undoStack.isEmpty || currentItem == nil)
            }
        }
        .onAppear {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onChange(of: currentIndex) {
            isContentRevealed = false
            if let currentItem {
                speaker.prepare(currentItem)
            } else {
                speaker.stop()
            }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private var completionView: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 700

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
                        StatGridCard(icon: "checkmark.seal", title: "完成", value: "\(completedCount)", tint: .blue)
                        StatGridCard(icon: "hand.thumbsup", title: "答对", value: "\(correctCount)", tint: .green)
                        StatGridCard(icon: "hand.thumbsdown", title: "答错", value: "\(wrongCount)", tint: .red)
                        StatGridCard(icon: "percent", title: "正确率", value: accuracyText, tint: .orange)
                    }

                    if !reviewedSummaries.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("本次结果")
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
                    }
                    .buttonStyle(ResultButtonStyle(color: .blue))
                }
                .padding(isWide ? 32 : 20)
            }
        }
    }

    // MARK: - Actions

    private func submit(_ result: ReviewResult, for item: ReviewItem) {
        speaker.stop()

        // Save undo info before modifying
        let undoEntry = UndoEntry(
            itemIndex: currentIndex,
            oldStage: item.stage,
            oldNextReviewAt: item.nextReviewAt,
            oldLastReviewedAt: item.lastReviewedAt,
            oldConsecutiveCorrectCount: item.consecutiveCorrectCount,
            oldConsecutiveWrongCount: item.consecutiveWrongCount,
            oldIsPriority: item.isPriority,
            result: result
        )

        let output = scheduler.handle(item: item, result: result)
        modelContext.insert(output.record)
        reviewedSummaries.append(
            SessionReviewSummary(
                content: item.content,
                result: result,
                oldStage: output.record.oldStage,
                newStage: output.record.newStage
            )
        )

        undoEntry.recordID = output.record.id
        undoStack.append(undoEntry)

        completedCount += 1
        if result == .wrong {
            wrongCount += 1
        }

        // Show feedback overlay
        lastResultCorrect = result == .correct
        withAnimation(.easeIn(duration: 0.15)) {
            showFeedback = true
        }

        showResultButtons = false

        // Advance after feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentIndex += 1
            }
        }
    }

    private func undoLastAnswer() {
        guard let entry = undoStack.popLast() else { return }

        currentIndex = entry.itemIndex
        let item = sessionItems[entry.itemIndex]

        // Restore item state
        item.stage = entry.oldStage
        item.nextReviewAt = entry.oldNextReviewAt
        item.lastReviewedAt = entry.oldLastReviewedAt
        item.consecutiveCorrectCount = entry.oldConsecutiveCorrectCount
        item.consecutiveWrongCount = entry.oldConsecutiveWrongCount
        item.isPriority = entry.oldIsPriority

        // Delete the record
        if let recordID = entry.recordID {
            let descriptor = FetchDescriptor<ReviewRecord>(
                predicate: #Predicate { $0.id == recordID }
            )
            if let records = try? modelContext.fetch(descriptor), let record = records.first {
                modelContext.delete(record)
            }
        }

        // Restore counters
        completedCount -= 1
        if entry.result == .wrong {
            wrongCount -= 1
        }

        reviewedSummaries.removeLast()
        showResultButtons = false
    }

    // MARK: - Text Helpers

    private func headlineText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch item.type {
            case .chineseCharacter:
                return "点击朗读，听写这个汉字"
            case .phrase:
                return "点击朗读，听写这个词句"
            case .englishWord:
                return "点击朗读，听写这个英语"
            }
        }

        return item.prompt
    }

    private func helperText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "会直接播放要写的内容，孩子写完后，再由家长判定。"
        }

        return "如果不看文字，也可以直接点击朗读来做听写。"
    }

    private func answerCard(for item: ReviewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("标准答案")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(item.content)
                .font(.system(.title, design: .rounded, weight: .bold))

            if !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(item.prompt)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if !item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answerMetaRow(title: "备注", value: item.note)
            }

            if !item.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                answerMetaRow(title: "来源", value: item.source)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func answerMetaRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var correctCount: Int {
        completedCount - wrongCount
    }

    private var accuracyText: String {
        guard completedCount > 0 else { return "--" }
        let accuracy = Int((Double(correctCount) / Double(completedCount) * 100).rounded())
        return "\(accuracy)%"
    }

    private var summaryText: String {
        if wrongCount == 0 {
            return "这次复习全部答对，系统已经自动安排到下一次复习日期。"
        }

        return "这次一共完成 \(completedCount) 题，其中答错 \(wrongCount) 题。答错的内容会安排到之后的日期，今天不会重复出现。"
    }
}

// MARK: - Supporting Types

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

private class UndoEntry {
    let itemIndex: Int
    let oldStage: Int
    let oldNextReviewAt: Date
    let oldLastReviewedAt: Date?
    let oldConsecutiveCorrectCount: Int
    let oldConsecutiveWrongCount: Int
    let oldIsPriority: Bool
    let result: ReviewResult
    var recordID: UUID?

    init(itemIndex: Int, oldStage: Int, oldNextReviewAt: Date, oldLastReviewedAt: Date?, oldConsecutiveCorrectCount: Int, oldConsecutiveWrongCount: Int, oldIsPriority: Bool, result: ReviewResult) {
        self.itemIndex = itemIndex
        self.oldStage = oldStage
        self.oldNextReviewAt = oldNextReviewAt
        self.oldLastReviewedAt = oldLastReviewedAt
        self.oldConsecutiveCorrectCount = oldConsecutiveCorrectCount
        self.oldConsecutiveWrongCount = oldConsecutiveWrongCount
        self.oldIsPriority = oldIsPriority
        self.result = result
    }
}

// MARK: - Speech

@MainActor
private final class ReviewSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var currentItem: ReviewItem?
    private var lastUtteranceText = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(_ item: ReviewItem) {
        currentItem = item
        lastUtteranceText = speechText(for: item)
        stop()
    }

    func speak(_ item: ReviewItem) {
        currentItem = item
        lastUtteranceText = speechText(for: item)
        speakCurrentText(for: item.type)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }

    private func speakCurrentText(for type: ReviewItemType) {
        guard !lastUtteranceText.isEmpty else { return }

        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.activate()

        let utterance = AVSpeechUtterance(string: lastUtteranceText)
        utterance.voice = SpeechVoicePicker.voice(for: type)
        utterance.rate = type == .englishWord ? 0.42 : 0.36
        utterance.pitchMultiplier = 1.0

        synthesizer.speak(utterance)
    }

    private func speechText(for item: ReviewItem) -> String {
        item.content
    }
}

extension ReviewSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {}
