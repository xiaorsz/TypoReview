import PencilKit
import SwiftUI

struct HandwrittenResultsView: View {
    let sessionID: UUID
    let questions: [HandwrittenQuestion]
    @State var draft: HandwrittenDictationDraft
    var savedResults: [UUID: DictationResult]? = nil
    let isSubmitting: Bool
    let onConfirm: () -> Void

    @State private var gradingRun = 0
    @State private var gradingFailed = false
    @State private var saveErrorMessage: String?
    @State private var correctionRequest: CorrectionPracticeRequest?
    @AppStorage(AIProvider.preferenceKey) private var aiProvider = AIProvider.deepSeek
    @AppStorage(HandwrittenDictationStore.cloudEnabledKey) private var deepSeekCloudEnabled = false
    @AppStorage(HandwrittenDictationStore.openAICloudEnabledKey) private var openAICloudEnabled = false

    private var cloudEnabled: Bool { aiProvider == .openAI ? openAICloudEnabled : deepSeekCloudEnabled }

    private var readOnly: Bool { savedResults != nil }
    private var pendingCount: Int { questions.filter { result(for: $0) == .pending }.count }
    private var wrongCount: Int { questions.filter { result(for: $0) == .wrong }.count }
    private var correctCount: Int { questions.filter { result(for: $0) == .correct }.count }
    private var recognizingCount: Int { readOnly ? 0 : questions.filter { draft.grades[$0.id] == nil }.count }
    private var awaitingConfirmationCount: Int { pendingCount - recognizingCount }
    private var canSave: Bool { !isSubmitting && pendingCount == 0 && !questions.isEmpty }

    private func result(for question: HandwrittenQuestion) -> DictationResult {
        savedResults?[question.id] ?? draft.grades[question.id]?.result ?? .pending
    }

    var body: some View {
        handwritingResults
            .safeAreaInset(edge: .bottom) {
                if !readOnly {
                    VStack(spacing: 8) {
                        if awaitingConfirmationCount > 0 {
                            Text("请先确认剩余 \(awaitingConfirmationCount) 题")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if recognizingCount > 0 {
                            Text(gradingFailed ? "请先继续判卷" : "还有 \(recognizingCount) 题正在判卷")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button(confirmTitle, action: confirmResults)
                            .buttonStyle(ResultButtonStyle(color: canSave ? .blue : .gray))
                            .disabled(!canSave)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .correctionPractice($correctionRequest)
            .task(id: gradingRun) { await gradeHandwriting() }
            .alert("判卷进度保存失败", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveErrorMessage ?? "")
            }
    }

    private var corrections: [HandwrittenQuestion] {
        questions.filter { !$0.type.isRecitation && result(for: $0) == .wrong
            && (draft.rewriteCounts?[$0.id] ?? 0) < 2 }
    }

    private var confirmTitle: String {
        if isSubmitting { return "正在保存…" }
        return canSave && !corrections.isEmpty ? "确认判定并重写错题" : "确认并保存"
    }

    private func confirmResults() {
        guard canSave, !readOnly else { return }
        if corrections.isEmpty {
            onConfirm()
        } else {
            correctionRequest = CorrectionPracticeRequest(
                questions: corrections, handwriting: true, completedCopies: draft.rewriteCounts ?? [:],
                recordCopy: { questionID, count in
                    try HandwrittenDictationStore.recordRewrite(sessionID: sessionID, questionID: questionID, count: count)
                    var counts = draft.rewriteCounts ?? [:]
                    counts[questionID] = count
                    draft.rewriteCounts = counts
                }, onFinish: onConfirm
            )
        }
    }

    private var handwritingResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    reviewStat(title: "正确", value: String(correctCount), tint: .green)
                    reviewStat(title: "错误", value: String(wrongCount), tint: .red)
                    reviewStat(title: "待确认", value: String(awaitingConfirmationCount), tint: .orange)
                }
                if recognizingCount > 0 {
                    if gradingFailed {
                        Button("继续判卷") { gradingRun += 1 }
                            .buttonStyle(.bordered)
                    } else {
                        ProgressView("正在判卷 · \(recognizingCount) 题识别中")
                            .font(.subheadline)
                    }
                }

                let pending = questions.indices.filter { index in
                    draft.grades[questions[index].id]?.result == .pending && !readOnly
                }
                if !pending.isEmpty {
                    Text("待确认").font(.headline)
                    ForEach(pending, id: \.self) { handwritingRow($0) }
                }

                let graded = questions.indices.filter { result(for: questions[$0]) != .pending }
                if !graded.isEmpty {
                    Text("已判定 · \(graded.count) 题").font(.headline)
                    ForEach(graded, id: \.self) { handwritingRow($0) }
                }
            }
            .frame(maxWidth: 820)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private func handwritingRow(_ index: Int) -> some View {
        let entry = questions[index]
        let grade = draft.grades[entry.id]
        let result = result(for: entry)
        let tint: Color = switch result {
        case .correct: .green
        case .wrong: .red
        case .pending: .orange
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("第 \(index + 1) 题").font(.subheadline.bold())
                Spacer()
                Text(grade?.source?.title ?? (result == .pending ? "待确认" : "已判定"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if result != .pending {
                    Text(result.rawValue).font(.caption.bold()).foregroundStyle(tint)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                if !entry.type.isRecitation {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("原笔迹").font(.caption).foregroundStyle(.secondary)
                        DictationInkPreview(
                            sessionID: sessionID, entryID: entry.id,
                            grid: DictationWritingGrid(isEnglish: entry.type.isEnglish, answer: entry.content,
                                                       columns: draft.writingColumns)
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.type.isRecitation ? "背诵原文" : "标准答案").font(.caption).foregroundStyle(.secondary)
                    Text(entry.content).font(.title3.bold())
                    if let transcription = grade?.transcription {
                        Text("识别为 \(transcription)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !readOnly {
                HStack(spacing: 12) {
                    Button(entry.type.isRecitation ? "背出来了" : "正确") { confirm(.correct, entry: entry) }
                        .buttonStyle(GradingChoiceButtonStyle(color: .green, isSelected: result == .correct))
                    Button(entry.type.isRecitation ? "没背出来" : "错误") { confirm(.wrong, entry: entry) }
                        .buttonStyle(GradingChoiceButtonStyle(color: .red, isSelected: result == .wrong))
                }
                .disabled(isSubmitting)
            }
        }
        .padding(14)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
    }

    private func confirm(_ result: DictationResult, entry: HandwrittenQuestion) {
        guard !readOnly, !isSubmitting else { return }
        saveGrade(.init(result: result, source: .manual, transcription: draft.grades[entry.id]?.transcription),
                  entryID: entry.id, automatic: false)
    }

    @discardableResult
    private func saveGrade(_ grade: HandwrittenDictationDraft.Grade, entryID: UUID,
                           automatic: Bool = true, resolvePendingMatch: Bool = false) -> Bool {
        guard !readOnly else { return false }
        do {
            guard let current = try HandwrittenDictationStore.recordGrade(
                grade, sessionID: sessionID, entryID: entryID, automatic: automatic,
                resolvePendingMatch: resolvePendingMatch
            ) else {
                gradingFailed = true
                return false
            }
            draft = current
            return true
        } catch {
            gradingFailed = true
            saveErrorMessage = "这道题的判定未能保存，请重试。"
            return false
        }
    }

    private struct CloudJob {
        let entryID: UUID
        let answer: String
        let isEnglish: Bool
        let image: Data
        let evidence: HandwrittenDictationRecognition.Evidence
    }

    private func gradeHandwriting() async {
        guard !readOnly else { return }
        do {
            guard let current = try HandwrittenDictationStore.load(sessionID), current.submittedAt != nil else { return }
            draft = current
        } catch {
            gradingFailed = true
            saveErrorMessage = "无法读取本机判卷进度，请重试。"
            return
        }
        let entriesToGrade = questions.filter { entry in
            guard let grade = draft.grades[entry.id] else { return true }
            guard grade.result == .pending, let transcription = grade.transcription else { return false }
            let normalize = HandwrittenDictationRecognition.normalized
            return normalize(transcription, entry.type.isEnglish) == normalize(entry.content, entry.type.isEnglish)
        }
        guard !entriesToGrade.isEmpty else { return }
        gradingFailed = false
        let provider = aiProvider
        let apiKey = cloudEnabled ? (try? provider.loadAPIKey()) ?? "" : ""
        let canUseCloud = cloudEnabled && !apiKey.isEmpty
        let cloudClient = AIResponsesClient(provider: provider, apiKey: apiKey)
        var jobs: [CloudJob] = []
        for entry in entriesToGrade {
            guard !Task.isCancelled else { return }
            let answer = entry.content
            let isEnglish = entry.type.isEnglish
            let entryID = entry.id
            let recheckingPending = draft.grades[entryID] != nil
            if recheckingPending, draft.grades[entryID]?.result != .pending { continue }
            if entry.type.isRecitation {
                guard saveGrade(.init(result: .pending), entryID: entryID) else { return }
                continue
            }
            do {
                let drawing = try HandwrittenDictationStore.drawing(sessionID: sessionID, entryID: entryID)
                if drawing.strokes.isEmpty {
                    if recheckingPending { continue }
                    guard saveGrade(.init(result: .wrong, source: .blank), entryID: entryID) else { return }
                    continue
                }
                let grid = DictationWritingGrid(isEnglish: isEnglish, answer: answer, columns: draft.writingColumns)
                let evidence = try await HandwrittenDictationRecognition.inspect(
                    drawing, grid: grid, allowCloud: canUseCloud && !recheckingPending
                )
                guard !Task.isCancelled else { return }
                let grade = evidence.grade(answer: answer, isEnglish: isEnglish)
                if recheckingPending {
                    if grade.result == .correct {
                        guard saveGrade(grade, entryID: entryID, resolvePendingMatch: true) else { return }
                    }
                } else if grade.result == .pending, let image = evidence.cloudImage {
                    jobs.append(CloudJob(entryID: entryID, answer: answer, isEnglish: isEnglish,
                                         image: image, evidence: evidence))
                } else {
                    guard saveGrade(grade, entryID: entryID) else { return }
                }
            } catch is CancellationError {
                return
            } catch {
                if recheckingPending { continue }
                guard saveGrade(.init(result: .pending), entryID: entryID) else { return }
            }
        }

        // Bound cloud concurrency while publishing each completed response immediately.
        for start in stride(from: 0, to: jobs.count, by: 4) {
            guard !Task.isCancelled, !gradingFailed else { return }
            await withTaskGroup(of: (Int, String?).self) { group in
                for index in start..<min(start + 4, jobs.count) {
                    let job = jobs[index]
                    if cloudEnabled, aiProvider == provider {
                        group.addTask {
                            let text = try? await cloudClient.recognizeDictation(image: job.image, isEnglish: job.isEnglish)
                            return (index, text)
                        }
                    } else {
                        _ = saveGrade(job.evidence.grade(answer: job.answer, isEnglish: job.isEnglish), entryID: job.entryID)
                    }
                }

                for await (index, text) in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    let job = jobs[index]
                    let grade = job.evidence.grade(answer: job.answer, isEnglish: job.isEnglish, cloudText: text, provider: provider)
                    guard saveGrade(grade, entryID: job.entryID) else { group.cancelAll(); break }
                }
            }
        }
    }

    private func reviewStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title3.bold()).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }
}
