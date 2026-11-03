import PencilKit
import SwiftUI

@MainActor
@Observable
final class HandwrittenPractice {
    let sessionID: UUID
    let questions: [HandwrittenQuestion]
    private(set) var draft: HandwrittenDictationDraft
    var blankCount: Int?
    var error: String?
    var isWriting = false

    private var unsavedDrawings: [UUID: PKDrawing] = [:]

    init(sessionID: UUID, questions: [HandwrittenQuestion], draft: HandwrittenDictationDraft) {
        self.sessionID = sessionID
        self.questions = questions
        self.draft = draft
    }

    static func newDraft(questions: [HandwrittenQuestion]? = nil) -> HandwrittenDictationDraft {
        HandwrittenDictationDraft(
            mode: .handwriting, questions: questions,
            writingColumns: UIDevice.current.userInterfaceIdiom == .phone
                ? DictationWritingGrid.phoneColumns : DictationWritingGrid.tabletColumns
        )
    }

    func select(_ entryID: UUID) -> Bool {
        guard draft.submittedAt == nil, !isWriting, flush() else { return false }
        guard draft.entryID != entryID else { return true }
        var next = draft
        next.entryID = entryID
        return persist(next)
    }

    func drawing(for entryID: UUID) throws -> PKDrawing {
        if let unsaved = unsavedDrawings[entryID] { return unsaved }
        return try HandwrittenDictationStore.drawing(sessionID: sessionID, entryID: entryID)
    }

    func update(_ drawing: PKDrawing, for entryID: UUID) {
        guard draft.submittedAt == nil else { return }
        unsavedDrawings[entryID] = drawing
        flush()
    }

    @discardableResult
    func flush() -> Bool {
        if draft.entryID == nil, let firstID = unsavedDrawings.keys.first {
            var started = draft
            started.entryID = firstID
            guard persist(started) else { return false }
        }
        for (entryID, drawing) in unsavedDrawings {
            do {
                try HandwrittenDictationStore.save(drawing, sessionID: sessionID, entryID: entryID)
                unsavedDrawings.removeValue(forKey: entryID)
            } catch {
                self.error = "当前笔迹未能保存。请重试后再翻题或交卷。"
                return false
            }
        }
        return true
    }

    func requestSubmission() -> Bool {
        if draft.submittedAt != nil { return true }
        guard !isWriting, flush() else { return false }
        do {
            let count = try questions.filter { question in
                guard !question.type.isRecitation else { return false }
                return try drawing(for: question.id).strokes.isEmpty
            }.count
            if count > 0 {
                blankCount = count
                return false
            }
            return submit()
        } catch {
            self.error = "无法检查空白题，请重试交卷。"
            return false
        }
    }

    func submit() -> Bool {
        if draft.submittedAt != nil { return true }
        guard !isWriting, flush() else { return false }
        var next = draft
        next.submittedAt = .now
        next.questions = questions
        return persist(next)
    }

    private func persist(_ draft: HandwrittenDictationDraft) -> Bool {
        do {
            try HandwrittenDictationStore.save(draft, sessionID: sessionID)
            self.draft = draft
            return true
        } catch {
            self.error = "本机手写进度未能保存，请重试。"
            return false
        }
    }
}

extension View {
    func handwritingAlerts(_ practice: HandwrittenPractice?, onSubmitted: @escaping () -> Void) -> some View {
        modifier(HandwritingAlerts(practice: practice, onSubmitted: onSubmitted))
    }
}

private struct HandwritingAlerts: ViewModifier {
    let practice: HandwrittenPractice?
    let onSubmitted: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("还有 \(practice?.blankCount ?? 0) 题未作答", isPresented: Binding(
                get: { practice?.blankCount != nil },
                set: { if !$0 { practice?.blankCount = nil } }
            )) {
                Button("返回补写", role: .cancel) {}
                Button("确认交卷") {
                    if practice?.submit() == true { onSubmitted() }
                }
            } message: {
                Text("未作答的题会计为错误。")
            }
            .alert("手写进度", isPresented: Binding(
                get: { practice?.error != nil },
                set: { if !$0 { practice?.error = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(practice?.error ?? "")
            }
    }
}

struct HandwritingAnswerVisibilityButton: View {
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isRevealed.toggle() }
        } label: {
            Label(isRevealed ? "隐藏文字" : "显示文字", systemImage: isRevealed ? "eye.slash" : "eye")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct HandwritingAutoDictationControls: View {
    @ObservedObject var controller: AutoDictationController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                AutoDictationToggle(controller: controller)
                AutoDictationTimingControls(controller: controller, spacing: 8)
            }
        }
        .font(.subheadline)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

struct HandwrittenAnswerArea: View {
    let practice: HandwrittenPractice
    let question: HandwrittenQuestion

    @State private var drawing: PKDrawing?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let drawing {
                PracticeWritingBoard(
                    title: "手写答题",
                    grid: DictationWritingGrid(isEnglish: question.type.isEnglish, answer: question.content,
                                              columns: practice.draft.writingColumns),
                    drawing: drawing,
                    onChange: { practice.update($0, for: question.id) },
                    onWritingChange: { practice.isWriting = $0 }
                )
            } else {
                Button("读取笔迹", action: load)
                    .buttonStyle(.bordered)
            }
            Text(UIDevice.current.userInterfaceIdiom == .phone ? "用手指书写，可在画板外滑动页面" : "用 Apple Pencil 书写")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(practice.draft.submittedAt != nil)
        .task { load() }
        .onDisappear { practice.isWriting = false }
    }

    private func load() {
        do {
            drawing = try practice.drawing(for: question.id)
        } catch {
            practice.error = "无法读取这题的笔迹，请重试。"
        }
    }
}

private struct PracticeWritingBoard: View {
    let title: String
    let grid: DictationWritingGrid
    let drawing: PKDrawing
    let onChange: (PKDrawing) -> Void
    let onWritingChange: (Bool) -> Void

    @StateObject private var controls = DictationCanvasControls()
    @State private var erasing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    titleLabel
                    Spacer()
                    tools
                }
                VStack(alignment: .leading, spacing: 8) {
                    titleLabel
                    tools
                }
            }
            WritingBoardLayout(grid: grid) {
                ZStack {
                    DictationGridView(grid: grid)
                    DictationPencilCanvas(
                        drawing: drawing, size: grid.size, erase: erasing,
                        controls: controls, onChange: onChange, onWritingChange: onWritingChange
                    )
                    .accessibilityLabel(grid.isEnglish ? "四线格书写区" : "田字格书写区")
                }
            }
            .frame(maxWidth: UIDevice.current.userInterfaceIdiom == .phone ? 480 : .infinity)
            .background(.white)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.secondary.opacity(0.2), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var titleLabel: some View {
        Label(title, systemImage: "pencil.tip")
            .font(.headline)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            Button {
                erasing.toggle()
            } label: {
                Label(erasing ? "切回笔" : "橡皮", systemImage: erasing ? "pencil.tip" : "eraser")
            }
            Button {
                controls.undo()
            } label: {
                Label("撤销笔迹", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                controls.clear()
            } label: {
                Label("清空笔迹", systemImage: "trash")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

}

private struct WritingBoardLayout: Layout {
    let grid: DictationWritingGrid

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? grid.size.width
        let width = proposedWidth.isFinite ? proposedWidth : grid.size.width
        return CGSize(width: width, height: grid.boardHeight(forWidth: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: grid.canvasHeight(forWidth: bounds.width))
        )
    }
}

struct DictationGridView: View {
    let grid: DictationWritingGrid

    var body: some View {
        Canvas { context, size in
            var guides = Path()
            var border = Path()
            if grid.isEnglish {
                let top = size.height * 0.16
                let bottom = size.height * 0.87
                let lineSpacing = (bottom - top) / 3
                for line in 0..<4 {
                    let position = top + CGFloat(line) * lineSpacing
                    border.move(to: CGPoint(x: 0, y: position))
                    border.addLine(to: CGPoint(x: size.width, y: position))
                }
            } else {
                let width = size.width / CGFloat(grid.columns)
                let height = size.height / CGFloat(grid.rows)
                for row in 0..<grid.rows {
                    for column in 0..<grid.columns {
                        let rect = CGRect(x: CGFloat(column) * width, y: CGFloat(row) * height,
                                          width: width, height: height)
                        border.addRect(rect)
                        guides.move(to: CGPoint(x: rect.midX, y: rect.minY))
                        guides.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                        guides.move(to: CGPoint(x: rect.minX, y: rect.midY))
                        guides.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                    }
                }
            }
            context.stroke(border, with: .color(.gray.opacity(0.55)), lineWidth: 1)
            context.stroke(guides, with: .color(.gray.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private final class DictationCanvasControls: ObservableObject {
    weak var view: PKCanvasView?

    func undo() {
        guard let view, view.undoManager?.canUndo == true else { return }
        view.undoManager?.undo()
        view.delegate?.canvasViewDrawingDidChange?(view)
    }

    func clear() {
        guard let view, !view.drawing.strokes.isEmpty else { return }
        let original = view.drawing
        view.undoManager?.registerUndo(withTarget: view) { $0.drawing = original }
        view.drawing = PKDrawing()
        view.delegate?.canvasViewDrawingDidChange?(view)
    }
}

private final class DictationCanvasView: PKCanvasView {
    private let canvasUndoManager = UndoManager()
    override var undoManager: UndoManager? { canvasUndoManager }
}

private struct DictationPencilCanvas: UIViewRepresentable {
    let drawing: PKDrawing
    let size: CGSize
    let erase: Bool
    let controls: DictationCanvasControls
    let onChange: (PKDrawing) -> Void
    let onWritingChange: (Bool) -> Void

    func makeUIView(context: Context) -> CanvasContainer {
        let container = CanvasContainer(size: size)
        let view = container.canvas
        view.drawing = drawing
        view.delegate = context.coordinator
        view.drawingPolicy = UIDevice.current.userInterfaceIdiom == .phone ? .anyInput : .pencilOnly
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isScrollEnabled = false
        controls.view = view
        return container
    }

    func updateUIView(_ container: CanvasContainer, context: Context) {
        context.coordinator.parent = self
        container.canvas.tool = erase ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .black, width: 3)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DictationPencilCanvas

        init(parent: DictationPencilCanvas) { self.parent = parent }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.onChange(canvasView.drawing)
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            parent.onWritingChange(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            parent.onWritingChange(false)
        }
    }

    final class CanvasContainer: UIView {
        let canvas = DictationCanvasView()
        private let writingSize: CGSize

        init(size: CGSize) {
            writingSize = size
            super.init(frame: .zero)
            clipsToBounds = true
            canvas.bounds = CGRect(origin: .zero, size: size)
            canvas.contentSize = size
            addSubview(canvas)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            let scale = min(bounds.width / writingSize.width, bounds.height / writingSize.height)
            guard scale > 0 else { return }
            // The grid and stored ink keep the same coordinates across layout changes.
            canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
            canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, UIDevice.current.userInterfaceIdiom == .phone else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    scrollView.panGestureRecognizer.require(toFail: canvas.drawingGestureRecognizer)
                    break
                }
                ancestor = view.superview
            }
        }
    }
}

struct DictationInkPreview: View {
    let sessionID: UUID
    let entryID: UUID
    let grid: DictationWritingGrid
    var archivedInk: Data? = nil
    @State private var image: UIImage?
    @State private var message: String?

    var body: some View {
        Group {
            if let image {
                ZStack {
                    DictationGridView(grid: grid)
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                }
                .aspectRatio(grid.size.width / grid.size.height, contentMode: .fit)
                .background(.white)
                .accessibilityLabel("本题原笔迹")
            } else {
                Text(message ?? "正在读取…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: entryID) {
            do {
                let drawing: PKDrawing
                if let archivedInk {
                    drawing = try PKDrawing(data: archivedInk)
                } else {
                    drawing = try HandwrittenDictationStore.drawing(sessionID: sessionID, entryID: entryID)
                }
                if drawing.strokes.isEmpty {
                    message = "未作答"
                } else {
                    image = drawing.image(from: CGRect(origin: .zero, size: grid.size), scale: 2)
                }
            } catch {
                message = "无法读取原笔迹"
            }
        }
    }
}

struct CorrectionPracticeRequest: Identifiable {
    let id = UUID()
    let questions: [HandwrittenQuestion]
    var handwriting = false
    var completedCopies: [UUID: Int] = [:]
    var recordCopy: (UUID, Int) throws -> Void = { _, _ in }
    let onFinish: () -> Void
}

extension View {
    func correctionPractice(_ request: Binding<CorrectionPracticeRequest?>) -> some View {
        modifier(CorrectionPracticePresentation(request: request))
    }
}

private struct CorrectionPracticePresentation: ViewModifier {
    @Binding var request: CorrectionPracticeRequest?
    @State private var onDismiss: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(item: presentation(handwriting: false), onDismiss: finishPresentation) { practice in
                correctionView(practice)
            }
            .fullScreenCover(item: presentation(handwriting: true), onDismiss: finishPresentation) { practice in
                correctionView(practice)
            }
    }

    private func presentation(handwriting: Bool) -> Binding<CorrectionPracticeRequest?> {
        Binding(
            get: { request?.handwriting == handwriting ? request : nil },
            set: { value in
                if request?.handwriting == handwriting { request = value }
            }
        )
    }

    private func correctionView(_ practice: CorrectionPracticeRequest) -> some View {
        CorrectionPracticeView(practice: practice) {
            onDismiss = practice.onFinish
            request = nil
        } onCancel: {
            request = nil
        }
    }

    private func finishPresentation() {
        let finish = onDismiss
        onDismiss = nil
        finish?()
    }
}

private struct CorrectionPracticeView: View {
    let practice: CorrectionPracticeRequest
    let onFinish: () -> Void
    let onCancel: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = DictationPlaybackDriver()
    @State private var completedCopies: [UUID: Int]
    @State private var drawing = PKDrawing()
    @State private var isWriting = false
    @State private var saveFailed = false

    init(practice: CorrectionPracticeRequest, onFinish: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.practice = practice
        self.onFinish = onFinish
        self.onCancel = onCancel
        _completedCopies = State(initialValue: practice.completedCopies)
    }

    private var currentIndex: Int? {
        practice.questions.firstIndex { completedCopies[$0.id, default: 0] < 2 }
    }

    private var canRecord: Bool {
        !practice.handwriting || (!isWriting && !drawing.strokes.isEmpty)
    }

    var body: some View {
        NavigationStack {
            if let index = currentIndex {
                let question = practice.questions[index]
                let attempt = completedCopies[question.id, default: 0] + 1
                ScrollView {
                    VStack(spacing: 20) {
                        Text("第 \(index + 1) / \(practice.questions.count) 题 · 第 \(attempt) / 2 遍")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        Text(question.content)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)

                        if let pronunciation = PracticePronunciation.hint(for: question.content, type: question.type) {
                            Text(pronunciation)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            if playback.isPlaying { playback.stop() }
                            else { readAnswer(question) }
                        } label: {
                            Label(playback.isPlaying ? "停止朗读" : "再读两遍",
                                  systemImage: playback.isPlaying ? "stop.fill" : "speaker.wave.2")
                        }
                        .buttonStyle(.bordered)

                        if practice.handwriting {
                            let columns = UIDevice.current.userInterfaceIdiom == .phone
                                ? DictationWritingGrid.phoneColumns : DictationWritingGrid.tabletColumns
                            PracticeWritingBoard(
                                title: "照着写",
                                grid: DictationWritingGrid(isEnglish: question.type.isEnglish,
                                                           answer: question.content, columns: columns),
                                drawing: drawing,
                                onChange: { drawing = $0 },
                                onWritingChange: { isWriting = $0 }
                            )
                            .id("\(question.id)-\(attempt)")
                        } else {
                            Text("照着上面的答案在纸上写一遍，写完后点下方按钮。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom) {
                    Button("写完这一遍") { record(question, attempt: attempt) }
                        .buttonStyle(ResultButtonStyle(color: canRecord ? .blue : .gray))
                        .disabled(!canRecord)
                        .padding()
                        .background(.bar)
                }
                .navigationTitle("错题重写")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: question.id) { readAnswer(question) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回判卷") {
                            playback.stop()
                            onCancel()
                        }
                    }
                }
            } else {
                ProgressView("正在保存结果…")
                    .task { onFinish() }
            }
        }
        .interactiveDismissDisabled()
        .onDisappear { playback.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.stop() }
        }
        .alert("重写进度保存失败", isPresented: $saveFailed) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("请再点一次「写完这一遍」。")
        }
    }

    private func readAnswer(_ question: HandwrittenQuestion) {
        playback.playAnswerTwice(content: question.content, type: question.type)
    }

    private func record(_ question: HandwrittenQuestion, attempt: Int) {
        guard canRecord, completedCopies[question.id, default: 0] == attempt - 1 else { return }
        playback.stop()
        do {
            try practice.recordCopy(question.id, attempt)
            completedCopies[question.id] = attempt
            drawing = PKDrawing()
        } catch {
            saveFailed = true
        }
    }
}
