import Foundation
import PencilKit
import UIKit
import Vision

struct HandwrittenQuestion: Codable, Equatable {
    let id: UUID
    let type: ReviewItemType
    let content: String
    let prompt: String

    init(_ entry: DictationEntry) {
        id = entry.id
        type = entry.type
        content = entry.content
        prompt = entry.prompt
    }

    init(_ item: ReviewItem) {
        id = item.id
        type = item.type
        content = item.content
        prompt = item.prompt
    }
}

struct HandwrittenDictationDraft: Codable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case paper, handwriting

        var id: String { rawValue }
        var title: String { self == .paper ? "纸笔" : "屏幕手写" }
    }

    struct Grade: Codable {
        enum Source: String, Codable {
            case local = "AI 判定 · 本机"
            case deepSeek = "AI 判定 · DeepSeek"
            case openAI = "AI 判定 · GPT"
            case manual = "人工确认"
            case blank = "未作答"

            var title: String {
                self == .local ? "判定 · 本机" : rawValue
            }
        }

        let result: DictationResult
        var source: Source? = nil
        var transcription: String? = nil
    }

    let mode: Mode
    var entryID: UUID?
    var submittedAt: Date?
    var questions: [HandwrittenQuestion]?
    var writingColumns: Int?
    var grades: [UUID: Grade] = [:]
    var rewriteCounts: [UUID: Int]? = nil

    var shouldResume: Bool {
        // Older drafts may contain first-question ink without recording an entry ID.
        mode == .handwriting && (entryID != nil || submittedAt != nil || writingColumns == nil)
    }
}

struct ReviewInkHistory: Codable {
    let reviewedAt: Date
    let question: HandwrittenQuestion
    let grade: HandwrittenDictationDraft.Grade
    let ink: Data?
    var writingColumns: Int? = nil
}

enum HandwrittenDictationStore {
    static let writingModeKey = "practice.writingMode"
    static let activeReviewKey = "handwrittenReview.activeSession"
    static let cloudEnabledKey = "handwrittenDictation.deepSeekEnabled"
    static let openAICloudEnabledKey = "handwrittenDictation.openAIEnabled"

    private static func directory(_ sessionID: UUID) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "HandwrittenDictation", directoryHint: .isDirectory)
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
    }

    static func load(_ sessionID: UUID) throws -> HandwrittenDictationDraft? {
        let url = directory(sessionID).appending(path: "session.json")
        do {
            return try JSONDecoder().decode(HandwrittenDictationDraft.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    static func save(_ draft: HandwrittenDictationDraft, sessionID: UUID) throws {
        try write(JSONEncoder().encode(draft), name: "session.json", sessionID: sessionID)
    }

    @MainActor
    static func recordGrade(_ grade: HandwrittenDictationDraft.Grade, sessionID: UUID,
                            entryID: UUID, automatic: Bool,
                            resolvePendingMatch: Bool = false) throws -> HandwrittenDictationDraft? {
        guard var draft = try load(sessionID), draft.submittedAt != nil else { return nil }
        let previous = draft.grades[entryID]
        if !automatic || previous == nil
            || (resolvePendingMatch && previous?.result == .pending && grade.result == .correct) {
            draft.grades[entryID] = grade
            try save(draft, sessionID: sessionID)
        }
        return draft
    }

    @MainActor
    static func recordRewrite(sessionID: UUID, questionID: UUID, count: Int) throws {
        guard var draft = try load(sessionID), draft.submittedAt != nil,
              draft.grades[questionID]?.result == .wrong,
              draft.questions?.contains(where: { $0.id == questionID && !$0.type.isRecitation }) == true else {
            throw CocoaError(.fileWriteUnknown)
        }
        var counts = draft.rewriteCounts ?? [:]
        guard (1...2).contains(count), count == counts[questionID, default: 0] + 1 else {
            throw CocoaError(.fileWriteUnknown)
        }
        counts[questionID] = count
        draft.rewriteCounts = counts
        try save(draft, sessionID: sessionID)
    }

    static func drawingData(sessionID: UUID, entryID: UUID) throws -> Data? {
        let url = directory(sessionID).appending(path: entryID.uuidString)
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    static func drawing(sessionID: UUID, entryID: UUID) throws -> PKDrawing {
        guard let data = try drawingData(sessionID: sessionID, entryID: entryID) else { return PKDrawing() }
        return try PKDrawing(data: data)
    }

    static func save(_ drawing: PKDrawing, sessionID: UUID, entryID: UUID) throws {
        try write(drawing.dataRepresentation(), name: entryID.uuidString, sessionID: sessionID)
    }

    static func saveReviewInk(_ history: ReviewInkHistory, recordID: UUID) throws {
        try write(JSONEncoder().encode(history), name: "review.json", sessionID: recordID)
    }

    static func reviewInk(recordID: UUID, reviewedAt: Date) -> ReviewInkHistory? {
        let url = directory(recordID).appending(path: "review.json")
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(ReviewInkHistory.self, from: data),
              abs(history.reviewedAt.timeIntervalSince(reviewedAt)) < 0.01 else { return nil }
        return history
    }

    private static func write(_ data: Data, name: String, sessionID: UUID) throws {
        let folder = directory(sessionID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keep children's ink out of both app sync and device backups.
        var root = folder.deletingLastPathComponent()
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try root.setResourceValues(resources)
        try data.write(to: folder.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ sessionID: UUID) throws {
        do {
            try FileManager.default.removeItem(at: directory(sessionID))
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }
}

struct DictationWritingGrid {
    static let cellSize: CGFloat = 64
    static let tabletColumns = 6
    static let phoneColumns = 4

    private static let legacyTabletColumns = 10
    private static let legacyPhoneColumns = 5

    let isEnglish: Bool
    let columns: Int
    let rows: Int

    init(isEnglish: Bool, answer: String, columns: Int? = nil) {
        self.isEnglish = isEnglish
        switch columns {
        case Self.phoneColumns, Self.legacyPhoneColumns, Self.tabletColumns, Self.legacyTabletColumns:
            self.columns = columns ?? Self.legacyTabletColumns
        default:
            self.columns = Self.legacyTabletColumns
        }
        let count = HandwrittenDictationRecognition.normalized(answer, isEnglish: false).count
        rows = max(1, (count + 2 + self.columns - 1) / self.columns)
    }

    var size: CGSize {
        if isEnglish { return englishSize }
        return CGSize(width: CGFloat(columns) * Self.cellSize, height: CGFloat(rows) * Self.cellSize)
    }

    private var englishSize: CGSize {
        let phoneLayout = columns == Self.phoneColumns || columns == Self.legacyPhoneColumns
        let lineColumns = phoneLayout ? Self.legacyPhoneColumns : Self.legacyTabletColumns
        return CGSize(width: CGFloat(lineColumns) * Self.cellSize, height: 160)
    }

    func canvasHeight(forWidth width: CGFloat) -> CGFloat {
        width * size.height / size.width
    }

    func boardHeight(forWidth width: CGFloat) -> CGFloat {
        max(canvasHeight(forWidth: width), width * englishSize.height / englishSize.width)
    }

    func cell(at point: CGPoint) -> Int? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        return Int(point.y / Self.cellSize) * columns + Int(point.x / Self.cellSize)
    }

    func bounds(of cell: Int) -> CGRect {
        CGRect(
            x: CGFloat(cell % columns) * Self.cellSize,
            y: CGFloat(cell / columns) * Self.cellSize,
            width: Self.cellSize,
            height: Self.cellSize
        )
    }
}

enum HandwrittenDictationRecognition {
    typealias Grade = HandwrittenDictationDraft.Grade

    struct Evidence {
        let text: String?
        let stable: Bool
        let cloudImage: Data?
        let cloudCandidates: Set<String>
        var hasCompleteReading = false

        func grade(answer: String, isEnglish: Bool, cloudText: String? = nil, provider: AIProvider = .deepSeek) -> Grade {
            if let text {
                let local = resolved(text, answer: answer, isEnglish: isEnglish, source: .local)
                if stable || (hasCompleteReading && local.result == .correct) {
                    return local
                }
            }
            if let cloudText,
               cloudCandidates.contains(HandwrittenDictationRecognition.normalized(cloudText, isEnglish: isEnglish)) {
                return resolved(cloudText, answer: answer, isEnglish: isEnglish, source: provider == .openAI ? .openAI : .deepSeek)
            }
            return Grade(result: .pending, transcription: cloudText ?? text)
        }

        private func resolved(_ text: String, answer: String, isEnglish: Bool, source: Grade.Source) -> Grade {
            let compare = HandwrittenDictationRecognition.normalized
            return Grade(
                result: compare(text, isEnglish) == compare(answer, isEnglish) ? .correct : .wrong,
                source: source,
                transcription: text
            )
        }
    }

    private struct Candidate: Sendable {
        let text: String
        let clear: Bool
    }

    static func normalized(_ text: String, isEnglish: Bool) -> String {
        let canonical = text.precomposedStringWithCanonicalMapping
        if isEnglish {
            return canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(canonical.filter { !$0.isWhitespace && !$0.isPunctuation })
    }

    @MainActor
    static func inspect(_ drawing: PKDrawing, grid: DictationWritingGrid, allowCloud: Bool) async throws -> Evidence {
        let isEnglish = grid.isEnglish
        let language = isEnglish ? "en-US" : "zh-Hans"
        let regions = writingRegions(drawing, grid: grid)
        var readings: [String] = []
        var alternatives: [[String]] = [[], [], []]
        var stable = true

        for region in regions {
            try Task.checkCancellation()
            let tight = rasterize(region, padding: 7)
            let padded = rasterize(region, padding: 15)
            let candidates = await Task.detached(priority: .userInitiated) {
                [recognize(tight, language: language), recognize(padded, language: language)]
            }.value
            try Task.checkCancellation()

            var strokeText: String?
            if #available(iOS 27, *) {
                let requested = Locale.Language(identifier: language)
                let recognizer = PKStrokeRecognizer(preferredLanguages: [requested])
                await recognizer.updateDrawing(region)
                strokeText = await recognizer.recognizedText()
            }
            let texts = [candidates[0]?.text, candidates[1]?.text, strokeText].map { text -> String in
                guard let text else { return "" }
                return normalized(text, isEnglish: isEnglish)
            }
            for (index, text) in texts.enumerated() {
                alternatives[index].append(text)
            }
            let reading = texts.first(where: { !$0.isEmpty }) ?? ""
            readings.append(reading)
            let visionAgrees = !reading.isEmpty && texts[0] == texts[1]
                && candidates.allSatisfy { $0?.clear == true }
            if #available(iOS 27, *) {
                stable = stable && visionAgrees && texts[2] == reading
            } else {
                stable = stable && visionAgrees
            }
        }

        let primary = readings.joined()
        let hasCompleteReading = !readings.isEmpty && readings.allSatisfy { !$0.isEmpty }
        let wholeReadings = Set(alternatives.compactMap { parts in
            !parts.isEmpty && parts.allSatisfy { !$0.isEmpty } ? parts.joined() : nil
        })
        // A cloud transcript can corroborate a local reading, but cannot resolve conflicting readings.
        let agreeOnCharacters = zip(alternatives[0], alternatives[1]).allSatisfy { first, second in
            first.isEmpty || second.isEmpty || first == second
        } && zip(alternatives[0], alternatives[2]).allSatisfy { first, stroke in
            first.isEmpty || stroke.isEmpty || first == stroke
        } && zip(alternatives[1], alternatives[2]).allSatisfy { second, stroke in
            second.isEmpty || stroke.isEmpty || second == stroke
        }
        let eligible = wholeReadings.count == 1 && agreeOnCharacters ? wholeReadings : []
        return Evidence(
            text: primary.isEmpty ? nil : primary,
            stable: stable && !primary.isEmpty,
            cloudImage: allowCloud && !stable ? rasterize(drawing, padding: 12)?.pngData() : nil,
            cloudCandidates: eligible,
            hasCompleteReading: hasCompleteReading
        )
    }

    static func writingRegions(_ drawing: PKDrawing, grid: DictationWritingGrid) -> [PKDrawing] {
        if grid.isEnglish { return [drawing] }
        var cells: [Int: [PKStroke]] = [:]
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            guard let cell = grid.cell(at: CGPoint(x: bounds.midX, y: bounds.midY)),
                  grid.bounds(of: cell).insetBy(dx: -4, dy: -4).contains(bounds) else {
                // Children can join characters or carry a stroke across grid lines.
                // Preserve every stroke and recognize the complete drawing in that case.
                return [drawing]
            }
            cells[cell, default: []].append(stroke)
        }
        return cells.keys.sorted().compactMap { cells[$0].map { PKDrawing(strokes: $0) } }
    }

    private static func rasterize(_ drawing: PKDrawing, padding: CGFloat) -> UIImage? {
        let bounds = drawing.bounds.insetBy(dx: -padding, dy: -padding)
        guard !bounds.isEmpty, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let scale = min(3, 1_400 / max(bounds.width, bounds.height))
        let ink = drawing.image(from: bounds, scale: scale)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = scale
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
    }

    private static func recognize(_ image: UIImage?, language: String) -> Candidate? {
        guard let image = image?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? request.supportedRecognitionLanguages())?.contains(language) == true else { return nil }
        request.recognitionLanguages = [language]
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }
            let ordered = observations.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            let candidates = ordered.map { $0.topCandidates(2) }
            guard candidates.allSatisfy({ !$0.isEmpty }) else { return nil }
            let text = candidates.compactMap(\.first?.string).joined(separator: language == "en-US" ? " " : "")
            let clear = candidates.allSatisfy { choices in
                guard let best = choices.first, best.confidence >= 0.85 else { return false }
                return choices.count == 1 || best.confidence - choices[1].confidence >= 0.15
            }
            return Candidate(text: text, clear: clear)
        } catch {
            return nil
        }
    }
}
