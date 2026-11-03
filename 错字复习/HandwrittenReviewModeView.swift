import SwiftUI

struct HandwrittenReviewModeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HandwrittenDictationStore.activeReviewKey) private var activeSession = ""
    @AppStorage(HandwrittenDictationStore.writingModeKey) private var mode = HandwrittenDictationDraft.Mode.paper

    @State private var handwriting: HandwrittenPractice?
    @State private var activeItems: [ReviewItem]?
    @State private var openResults = false
    @State private var error: String?

    let items: [ReviewItem]
    let style: ReviewInteractionStyle

    var body: some View {
        Group {
            if let activeItems {
                if let handwriting, openResults {
                    HandwrittenReviewResultsView(items: activeItems, practice: handwriting, onReturn: { dismiss() })
                } else if style == .batch {
                    BatchReviewSessionView(items: activeItems, handwriting: handwriting)
                } else {
                    ReviewSessionView(items: activeItems, handwriting: handwriting)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("无法打开复习", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试", action: load)
                }
            } else {
                ProgressView("正在准备复习…")
            }
        }
        .task { if activeItems == nil { load() } }
    }

    private func load() {
        let previousID = UUID(uuidString: activeSession)
        let currentQuestions = items.map(HandwrittenQuestion.init)
        do {
            if let previousID, let draft = try HandwrittenDictationStore.load(previousID),
               draft.shouldResume, let previousQuestions = draft.questions {
                let matched = previousQuestions.compactMap { question in
                    items.first { HandwrittenQuestion($0) == question }
                }
                if !matched.isEmpty {
                    handwriting = HandwrittenPractice(sessionID: previousID,
                                                       questions: matched.map(HandwrittenQuestion.init), draft: draft)
                    openResults = draft.submittedAt != nil
                    activeItems = matched
                    return
                }
            }
            if mode == .handwriting, items.contains(where: { !$0.type.isRecitation }) {
                let sessionID = UUID()
                let draft = HandwrittenPractice.newDraft(questions: currentQuestions)
                try HandwrittenDictationStore.save(draft, sessionID: sessionID)
                activeSession = sessionID.uuidString
                handwriting = HandwrittenPractice(sessionID: sessionID, questions: currentQuestions, draft: draft)
                if let previousID { try? HandwrittenDictationStore.remove(previousID) }
            }
            activeItems = items
        } catch {
            self.error = "无法读取或保存本机复习进度。"
        }
    }
}

struct HandwrittenReviewResultsView: View {
    @AppStorage(HandwrittenDictationStore.activeReviewKey) private var activeSession = ""

    let items: [ReviewItem]
    let practice: HandwrittenPractice
    let onReturn: () -> Void

    var body: some View {
        BatchReviewGradingView(
            items: items,
            onReturnFromCompletion: onReturn,
            onSubmittedSuccessfully: {
                if activeSession == practice.sessionID.uuidString { activeSession = "" }
                try? HandwrittenDictationStore.remove(practice.sessionID)
            },
            handwritingID: practice.sessionID,
            handwriting: practice.draft
        )
    }
}

struct ReviewInkHistoryView: View {
    let recordID: UUID
    let reviewedAt: Date
    @State private var history: ReviewInkHistory?
    @State private var expanded = false

    var body: some View {
        Group {
            if let history {
                DisclosureGroup("手写笔迹 · \(history.grade.source?.title ?? "已判定")", isExpanded: $expanded) {
                    if expanded {
                        let grid = DictationWritingGrid(isEnglish: history.question.type.isEnglish, answer: history.question.content,
                                                        columns: history.writingColumns)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("标准答案  \(history.question.content)")
                            DictationInkPreview(sessionID: recordID, entryID: history.question.id, grid: grid,
                                                archivedInk: history.ink)
                        }
                        .padding(.top, 6)
                    }
                }
                .font(.subheadline)
            }
        }
        .task(id: recordID) {
            history = HandwrittenDictationStore.reviewInk(recordID: recordID, reviewedAt: reviewedAt)
        }
    }
}
