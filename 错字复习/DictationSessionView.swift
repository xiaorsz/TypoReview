import SwiftUI
import AVFoundation
import SwiftData

struct DictationSessionView: View {
    let session: DictationSession
    let entries: [DictationEntry]

    @AppStorage(HandwrittenDictationStore.writingModeKey) private var mode = HandwrittenDictationDraft.Mode.paper
    @State private var handwriting: HandwrittenPractice?
    @State private var isLoaded = false
    @State private var openResults = false
    @State private var loadError: String?

    var body: some View {
        Group {
            if session.type.isRecitation || entries.isEmpty {
                DictationPracticeView(session: session, entries: entries)
            } else if let handwriting, openResults {
                DictationReviewView(session: session, entries: entries, handwriting: handwriting.draft)
            } else if isLoaded {
                DictationPracticeView(session: session, entries: entries, handwriting: handwriting)
            } else if let loadError {
                ContentUnavailableView {
                    Label("无法打开听写", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试", action: load)
                }
            } else {
                ProgressView("正在打开听写…")
            }
        }
        .task {
            if !isLoaded, !session.type.isRecitation, !entries.isEmpty { load() }
        }
    }

    private func load() {
        do {
            let existing = try HandwrittenDictationStore.load(session.id)
            let questions = entries.map(HandwrittenQuestion.init)
            if let existing, existing.shouldResume, !session.isFinished || existing.submittedAt != nil {
                handwriting = HandwrittenPractice(sessionID: session.id, questions: questions, draft: existing)
                openResults = existing.submittedAt != nil || session.isReviewed
            } else if mode == .handwriting, session.currentEntryIndex == 0, !session.isFinished, !session.isReviewed {
                let draft = HandwrittenPractice.newDraft()
                try HandwrittenDictationStore.save(draft, sessionID: session.id)
                handwriting = HandwrittenPractice(sessionID: session.id, questions: questions, draft: draft)
            }
            loadError = nil
            isLoaded = true
        } catch {
            loadError = "无法读取或保存本机手写进度。"
        }
    }
}

private struct DictationPracticeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @State private var isContentRevealed = false
    @State private var hasAutoSpokenInitialEntry = false
    @State private var isFinishing = false
    @State private var saveErrorMessage: String?
    @State private var didPersistProgress = false
    @StateObject private var speaker = AutoDictationController()

    let session: DictationSession
    let entries: [DictationEntry]
    let handwriting: HandwrittenPractice?

    init(session: DictationSession, entries: [DictationEntry], handwriting: HandwrittenPractice? = nil) {
        self.session = session
        self.entries = entries
        self.handwriting = handwriting
        // 恢复上次听写进度；已完成/已判定的会话始终从头开始。
        let restoredIndex: Int
        if let handwriting {
            restoredIndex = entries.firstIndex { $0.id == handwriting.draft.entryID } ?? 0
        } else if session.isFinished || session.isReviewed || entries.isEmpty {
            restoredIndex = 0
        } else {
            restoredIndex = min(max(session.currentEntryIndex, 0), entries.count - 1)
        }
        _currentIndex = State(initialValue: restoredIndex)
        _isContentRevealed = State(initialValue: session.type.isRecitation)
    }

    private var currentEntry: DictationEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    private var completionProgress: Double {
        Double(currentIndex + 1) / Double(max(entries.count, 1))
    }

    private var cardContentTransition: AnyTransition {
        .opacity.combined(with: .offset(x: 12))
    }

    var body: some View {
        Group {
            if let currentEntry {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                            ScrollView(showsIndicators: false) {
                                VStack(spacing: handwriting == nil ? 22 : 12) {
                                    progressHeader
                                    if handwriting == nil, !session.type.isRecitation {
                                        AutoDictationControls(controller: speaker)
                                    }
                                    sessionCard(for: currentEntry, isWide: isWide)
                                }
                                .frame(maxWidth: isWide ? 860 : .infinity)
                                .padding(.horizontal, isWide ? 32 : 20)
                                .padding(.top, 20)
                                .padding(.bottom, 140)
                            }
                    .safeAreaInset(edge: .bottom) {
                        bottomActionBar(isWide: isWide)
                    }
                }
            }
        }
        .navigationTitle(session.type.isRecitation ? "今日背诵" : "今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            DictationReviewView(
                session: session,
                entries: entries,
                onReturnToList: {
                    dismiss()
                },
                handwriting: handwriting?.draft
            )
        }
        .onAppear {
            speaker.onAdvance = {
                move(to: currentIndex + 1)
            }
            selectCurrentEntry(speak: !hasAutoSpokenInitialEntry)
            hasAutoSpokenInitialEntry = true
        }
        .onChange(of: currentIndex) {
            isContentRevealed = session.type.isRecitation
            persistProgress()
            selectCurrentEntry()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                speaker.pause()
                handwriting?.flush()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: raw) == .began {
                speaker.pause()
            }
        }
        .onDisappear {
            speaker.shutdown()
            handwriting?.flush()
            persistProgress()
            // 本次访问只要保存过进度就广播一次，刷新入口列表的「继续第 X/N 条」。
            // 不依附于退出时这次保存是否发生——逐题保存可能已把进度落盘。
            if didPersistProgress {
                AppDataChangeCenter.post()
            }
        }
        .handwritingAlerts(handwriting, onSubmitted: showHandwritingResults)
        .alert("听写进度保存失败", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }


    private func selectCurrentEntry(speak: Bool = true) {
        guard let entry = currentEntry else { return }
        speaker.select(content: entry.content, type: entry.type, prompt: entry.prompt,
                       isLast: currentIndex == entries.count - 1, speak: speak && !entry.type.isRecitation)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.type.isRecitation ? "今日背诵" : "今日听写")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("第 \(currentIndex + 1) / \(entries.count) 条")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                }

                Spacer()

                Text("\(Int((completionProgress * 100).rounded()))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
            }

            ProgressView(value: Double(currentIndex + 1), total: Double(max(entries.count, 1)))
                .tint(.blue)
                .scaleEffect(x: 1, y: 1.6, anchor: .center)
                .animation(.easeInOut(duration: 0.3), value: currentIndex)

            if currentIndex > 0 {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            move(to: 0)
                        }
                    } label: {
                        Label("重新开始", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(handwriting == nil ? 20 : 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    private func sessionCard(for entry: DictationEntry, isWide: Bool) -> some View {
        ZStack {
            VStack(alignment: .leading, spacing: handwriting == nil ? 20 : 10) {
                cardHeader(for: entry, isWide: isWide)

                speakButton(for: entry)
                    .padding(.top, handwriting == nil ? 0 : 6)

                if let handwriting {
                    if !entry.type.isRecitation {
                        HandwritingAutoDictationControls(controller: speaker)
                        HandwrittenAnswerArea(practice: handwriting, question: HandwrittenQuestion(entry))
                            .id(entry.id)
                    }
                    helperFooter
                    HandwritingAnswerVisibilityButton(isRevealed: $isContentRevealed)
                } else {
                    HStack(alignment: .top) {
                        helperFooter
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
                }

                if isContentRevealed {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .padding(.vertical, 8)
                        Text(entry.type.isRecitation ? "背诵原文" : "听写内容")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        PracticePronunciationLine(
                            text: entry.content,
                            pronunciation: PracticePronunciation.englishPhonetic(for: entry.content, type: entry.type),
                            textFont: .system(isWide ? .title : .title2, design: .rounded, weight: .bold),
                            type: entry.type,
                            textColor: .blue
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .id(entry.id)
            .transition(.asymmetric(insertion: cardContentTransition, removal: .opacity))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(handwriting == nil ? (isWide ? 32 : 24) : 14)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 32)
                        .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                )
        )
        .shadow(color: .blue.opacity(0.08), radius: 24, y: 10)
        .animation(.easeInOut(duration: 0.22), value: entry.id)
    }

    private func cardHeader(for entry: DictationEntry, isWide: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TypeBadge(type: entry.type)

                    Text(session.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                PracticePronunciationLine(
                    text: entry.prompt,
                    pronunciation: PracticePronunciation.hint(for: entry.content, type: entry.type, prompt: entry.prompt),
                    textFont: .system(isWide ? .title : .title3, design: .rounded, weight: .bold),
                    type: entry.type,
                    highlight: speaker.pronunciationHighlight
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if handwriting == nil {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: isWide ? 24 : 20, weight: .medium))
                    .foregroundStyle(.blue.opacity(0.45))
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func speakButton(for entry: DictationEntry) -> some View {
        Button {
            speaker.replay()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: speaker.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                    .font(.title3.weight(.bold))
                Text(speaker.isSpeaking ? "正在朗读" : "点击朗读")
                    .font(.system(.title2, design: .rounded, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 64)
        }
        .buttonStyle(ResultButtonStyle(color: speaker.isSpeaking ? .teal : .blue))
    }

    private var helperFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(session.type.isRecitation
                 ? "先看着读几遍，再隐藏文字试着背。最后按背诵情况判对错。"
                 : "孩子先把整轮内容都写完，最后再统一批量判定。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bottomActionBar(isWide: Bool) -> some View {
        HStack(spacing: 12) {
            Button("上一条") {
                move(to: currentIndex - 1)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 56)
            .background(Color(uiColor: currentIndex == 0 ? .systemBackground : .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(currentIndex == 0 ? Color.secondary : Color.blue)
            .disabled(currentIndex == 0 || handwriting?.draft.submittedAt != nil)

            if handwriting?.draft.submittedAt != nil {
                Button("查看结果", action: showHandwritingResults)
                    .buttonStyle(ResultButtonStyle(color: .green))
            } else if currentIndex < entries.count - 1 {
                Button("下一条") {
                    move(to: currentIndex + 1)
                }
                .buttonStyle(ResultButtonStyle(color: .blue))
            } else {
                Button(isFinishing ? "正在保存…" : (session.type.isRecitation ? "完成背诵" : "完成并进入判卷")) {
                    finishSession()
                }
                .buttonStyle(ResultButtonStyle(color: .green))
                .disabled(isFinishing)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, isWide ? 32 : 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.ultraThinMaterial)
    }

    private func finishSession() {
        guard !isFinishing else { return }
        speaker.pause()
        if let handwriting {
            if handwriting.requestSubmission() { showHandwritingResults() }
            return
        }
        isFinishing = true

        let now = Date()
        session.finishedAt = now
        session.updatedAt = now
        session.currentEntryIndex = 0

        do {
            try PersistentStoreAccessGate.withAccess {
                try modelContext.save()
            }
            isFinishing = false
            AppDataChangeCenter.post()
            navigateToReview = true
        } catch {
            isFinishing = false
            saveErrorMessage = "本次听写尚未标记为完成，请保持 App 在前台后重试。\(error.localizedDescription)"
        }
    }

    private func move(to index: Int) {
        guard entries.indices.contains(index) else { return }
        if let handwriting, !handwriting.select(entries[index].id) {
            speaker.pause()
            return
        }
        currentIndex = index
    }

    private func showHandwritingResults() {
        speaker.pause()
        AppDataChangeCenter.post()
        navigateToReview = true
    }

    /// 把当前题号写回会话，退出后再次进入可以从这里继续。
    /// 逐题切换时静默落盘；退出页面时由 onDisappear 统一广播一次变更，
    /// 避免每条题都触发首页/列表快照重载。
    private func persistProgress() {
        guard handwriting == nil, !session.isFinished, !session.isReviewed else { return }
        guard session.currentEntryIndex != currentIndex else { return }

        let previousIndex = session.currentEntryIndex
        let previousUpdatedAt = session.updatedAt
        session.currentEntryIndex = currentIndex
        session.updatedAt = .now

        do {
            try PersistentStoreAccessGate.withAccess {
                try modelContext.save()
            }
            didPersistProgress = true
        } catch {
            // 保存失败必须恢复内存字段：否则 currentEntryIndex 已与 currentIndex 相等，
            // 之后（如退出页面时）再调用会被上面的 guard 提前拦住，
            // 未落盘的进度永远失去重试机会。
            session.currentEntryIndex = previousIndex
            session.updatedAt = previousUpdatedAt
            saveErrorMessage = "听写进度没有保存成功，仍可继续听写。\(error.localizedDescription)"
        }
    }
}
