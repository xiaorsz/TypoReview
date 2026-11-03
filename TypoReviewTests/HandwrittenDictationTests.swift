import PencilKit
import SwiftUI
import XCTest
@testable import TypoReview

final class HandwrittenDictationTests: XCTestCase {
    @MainActor
    func testWrongQuestionRewriteProgressRequiresTwoSequentialCopies() throws {
        let sessionID = UUID()
        let question = HandwrittenQuestion(DictationEntry(
            sessionID: sessionID, sortOrder: 0, type: .englishWord, content: "apple"
        ))
        defer { try? HandwrittenDictationStore.remove(sessionID) }
        let draft = HandwrittenDictationDraft(
            mode: .handwriting, submittedAt: .now, questions: [question],
            grades: [question.id: .init(result: .wrong, source: .manual)]
        )
        try HandwrittenDictationStore.save(draft, sessionID: sessionID)
        XCTAssertNil(try HandwrittenDictationStore.load(sessionID)?.rewriteCounts)
        XCTAssertThrowsError(try HandwrittenDictationStore.recordRewrite(sessionID: sessionID, questionID: question.id, count: 2))
        try HandwrittenDictationStore.recordRewrite(sessionID: sessionID, questionID: question.id, count: 1)
        XCTAssertEqual(try HandwrittenDictationStore.load(sessionID)?.rewriteCounts?[question.id], 1)
        XCTAssertThrowsError(try HandwrittenDictationStore.recordRewrite(sessionID: sessionID, questionID: question.id, count: 1))
        try HandwrittenDictationStore.recordRewrite(sessionID: sessionID, questionID: question.id, count: 2)
        let saved = try XCTUnwrap(HandwrittenDictationStore.load(sessionID))
        XCTAssertEqual(saved.rewriteCounts?[question.id], 2)
        XCTAssertEqual(saved.grades[question.id]?.result, .wrong)
    }

    func testPronunciationHighlightFollowsMatchingSpeechMarkersInOrder() {
        var progress = EnglishPronunciationProgress(text: "[bә'nænә]")
        XCTAssertEqual(progress.advance(phoneme: "bə"), .fragment(1..<3))
        XCTAssertEqual(progress.advance(phoneme: "n"), .fragment(4..<5))
        XCTAssertEqual(progress.advance(phoneme: "æ"), .fragment(5..<6))
        XCTAssertEqual(progress.advance(phoneme: "x"), .wholeWord)
        XCTAssertNil(progress.advance(phoneme: "n"))
    }

    func testChinesePronunciationHintKeepsTonesAndUsesWordContext() {
        XCTAssertEqual(PracticePronunciation.hint(for: "你好", type: .phrase), "nǐ hǎo")
        XCTAssertEqual(PracticePronunciation.hint(for: "银行", type: .phrase), "yínháng")
        XCTAssertEqual(PracticePronunciation.hint(for: "音乐", type: .phrase), "yīnyuè")
        XCTAssertEqual(PracticePronunciation.hint(for: "春天到了。", type: .phrase), "chūn tiān dào le")
        XCTAssertNil(PracticePronunciation.hint(for: "你好", type: .phrase, prompt: "nǐ hǎo"))
        XCTAssertNil(PracticePronunciation.hint(for: "123", type: .phrase))
    }

    func testEnglishGradingRespectsCapitalizationAndChineseIgnoresPunctuation() {
        let english = HandwrittenDictationRecognition.Evidence(
            text: "Apple", stable: true, cloudImage: nil, cloudCandidates: []
        )
        XCTAssertEqual(english.grade(answer: "apple", isEnglish: true).result, .wrong)
        XCTAssertEqual(english.grade(answer: "Apple", isEnglish: true).source, .local)

        let chinese = HandwrittenDictationRecognition.Evidence(
            text: "山 川", stable: true, cloudImage: nil, cloudCandidates: []
        )
        XCTAssertEqual(chinese.grade(answer: "山川。", isEnglish: false).result, .correct)
    }

    func testCompleteExactReadingPassesWithoutHighConfidence() {
        let chinese = HandwrittenDictationRecognition.Evidence(
            text: "你好", stable: false, cloudImage: nil, cloudCandidates: [],
            hasCompleteReading: true
        )
        XCTAssertEqual(chinese.grade(answer: "你好", isEnglish: false).result, .correct)
        XCTAssertEqual(chinese.grade(answer: "你好", isEnglish: false).source, .local)

        let english = HandwrittenDictationRecognition.Evidence(
            text: "HI", stable: false, cloudImage: nil, cloudCandidates: [],
            hasCompleteReading: true
        )
        XCTAssertEqual(english.grade(answer: "Hi", isEnglish: true).result, .pending)

        let partial = HandwrittenDictationRecognition.Evidence(
            text: "你好", stable: false, cloudImage: nil, cloudCandidates: []
        )
        XCTAssertEqual(partial.grade(answer: "你好", isEnglish: false).result, .pending)
    }

    func testCrossGridChineseRecognizesTheWholeDrawingWithoutDroppingInk() throws {
        let path = PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: 1),
            PKStrokePoint(location: CGPoint(x: 40, y: 40), timeOffset: 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: 1)
        ], creationDate: .now)
        let first = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        let grid = DictationWritingGrid(isEnglish: false, answer: "艺福堂", columns: DictationWritingGrid.phoneColumns)
        let secondCell = first.transformed(using: CGAffineTransform(translationX: 64, y: 0))
        let separate = PKDrawing(strokes: first.strokes + secondCell.strokes)
        XCTAssertEqual(HandwrittenDictationRecognition.writingRegions(separate, grid: grid).count, 2)

        let crossing = first.transformed(using: CGAffineTransform(translationX: 40, y: 0))
        let joined = PKDrawing(strokes: first.strokes + crossing.strokes)
        let regions = HandwrittenDictationRecognition.writingRegions(joined, grid: grid)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(try XCTUnwrap(regions.first).strokes.count, joined.strokes.count)
        XCTAssertEqual(regions.first?.bounds, joined.bounds)

        let reading = HandwrittenDictationRecognition.Evidence(
            text: "艺福堂", stable: false, cloudImage: nil, cloudCandidates: [], hasCompleteReading: true
        )
        XCTAssertEqual(reading.grade(answer: "艺福堂", isEnglish: false).result, .correct)
    }

    func testCloudRequiresCorroborationAndCanIdentifyWrongAnswers() {
        let unclear = HandwrittenDictationRecognition.Evidence(
            text: "aple", stable: false, cloudImage: nil, cloudCandidates: ["aple"]
        )
        XCTAssertEqual(unclear.grade(answer: "apple", isEnglish: true).result, .pending)
        XCTAssertEqual(unclear.grade(answer: "apple", isEnglish: true, cloudText: "apple").result, .pending)
        let corroborated = unclear.grade(answer: "apple", isEnglish: true, cloudText: "aple")
        XCTAssertEqual(corroborated.result, .wrong)
        XCTAssertEqual(corroborated.source, .deepSeek)
    }

    func testGPTUsesItsOwnSourceAndSummaryModel() {
        let evidence = HandwrittenDictationRecognition.Evidence(
            text: "CAT", stable: false, cloudImage: nil, cloudCandidates: ["CAT"]
        )
        let grade = evidence.grade(answer: "CAT", isEnglish: true, cloudText: "CAT", provider: .openAI)
        XCTAssertEqual(grade.result, .correct)
        XCTAssertEqual(grade.source, .openAI)
        XCTAssertEqual(AIProvider.openAI.summaryModel(DeepSeekSummaryModel.pro.rawValue), "gpt-5-mini")
        XCTAssertEqual(AIProvider.deepSeek.summaryModel(DeepSeekSummaryModel.pro.rawValue), DeepSeekSummaryModel.pro.rawValue)
    }

    func testGPTSummaryConnectsDirectlyToOpenAI() async throws {
        try await withStubbedAIResponse(
            result: #"{"message":"连接成功"}"#,
            verify: { request, body in
                XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gpt-test-key")
                XCTAssertEqual(body["model"] as? String, "gpt-5-mini")
                XCTAssertEqual(body["store"] as? Bool, false)
            },
            operation: { session in
                let client = AIResponsesClient(provider: .openAI, apiKey: "gpt-test-key", session: session)
                let result = try await client.summarize(kind: .connection, instructions: "Test", input: "Hello")
                XCTAssertEqual(result, #"{"message":"连接成功"}"#)
            }
        )
    }

    func testDeepSeekHandwritingConnectsDirectlyToDeepSeek() async throws {
        try await withStubbedAIResponse(
            result: #"{"transcription":"CAT"}"#,
            verify: { request, body in
                XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/responses")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer deepseek-test-key")
                XCTAssertEqual(body["model"] as? String, "deepseek-flash")
                let messages = body["input"] as? [[String: Any]]
                let userContent = messages?.last?["content"] as? [[String: String]]
                XCTAssertEqual(userContent?.first?["image_url"], "data:image/png;base64,AQID")
            },
            operation: { session in
                let client = AIResponsesClient(provider: .deepSeek, apiKey: "deepseek-test-key", session: session)
                let result = try await client.recognizeDictation(image: Data([1, 2, 3]), isEnglish: true)
                XCTAssertEqual(result, "CAT")
            }
        )
    }

    private func withStubbedAIResponse(
        result: String,
        verify: @escaping (URLRequest, [String: Any]) -> Void,
        operation: (URLSession) async throws -> Void
    ) async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "status": "completed",
            "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": result]]]]
        ])
        AIRequestStub.handler = { request in
            let bytes: Data
            if let body = request.httpBody {
                bytes = body
            } else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    collected.append(contentsOf: buffer.prefix(count))
                }
                bytes = collected
            } else {
                bytes = Data()
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            verify(request, body)
            return response
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIRequestStub.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            AIRequestStub.handler = nil
        }
        try await operation(session)
    }

    func testPhoneGridWrapsAndLegacyTabletGridKeepsItsCoordinates() {
        let phone = DictationWritingGrid(isEnglish: false, answer: "春夏秋冬风雨", columns: 5)
        let legacy = DictationWritingGrid(isEnglish: false, answer: "春夏秋冬风雨")
        XCTAssertEqual(phone.size, CGSize(width: 320, height: 128))
        XCTAssertEqual(phone.cell(at: CGPoint(x: 32, y: 96)), 5)
        XCTAssertEqual(phone.bounds(of: 5).origin, CGPoint(x: 0, y: 64))
        XCTAssertEqual(legacy.size, CGSize(width: 640, height: 64))
        XCTAssertEqual(legacy.cell(at: CGPoint(x: 352, y: 32)), 5)
    }

    func testLargerChineseGridsWrapWhileEnglishKeepsItsWritingArea() {
        let phone = DictationWritingGrid(isEnglish: false, answer: "春夏秋冬风雨", columns: DictationWritingGrid.phoneColumns)
        let tablet = DictationWritingGrid(isEnglish: false, answer: "春夏秋冬风雨", columns: DictationWritingGrid.tabletColumns)
        XCTAssertEqual(phone.columns, 4)
        XCTAssertEqual(phone.size, CGSize(width: 256, height: 128))
        XCTAssertEqual(phone.cell(at: CGPoint(x: 32, y: 96)), 4)
        XCTAssertEqual(tablet.columns, 6)
        XCTAssertEqual(tablet.size, CGSize(width: 384, height: 128))
        XCTAssertEqual(tablet.cell(at: CGPoint(x: 32, y: 96)), 6)

        let englishPhone = DictationWritingGrid(isEnglish: true, answer: "hello", columns: DictationWritingGrid.phoneColumns)
        let englishTablet = DictationWritingGrid(isEnglish: true, answer: "hello", columns: DictationWritingGrid.tabletColumns)
        XCTAssertEqual(englishPhone.size, CGSize(width: 320, height: 160))
        XCTAssertEqual(englishTablet.size, CGSize(width: 640, height: 160))
    }

    @MainActor
    func testHandwrittenProgressKeepsPhoneLayoutAndDoesNotCountRecitationAsBlank() throws {
        let sessionID = UUID()
        defer { try? HandwrittenDictationStore.remove(sessionID) }
        let word = HandwrittenQuestion(ReviewItem(type: .chineseCharacter, content: "山", prompt: ""))
        let recitation = HandwrittenQuestion(ReviewItem(type: .englishSentence, content: "This is a book.", prompt: ""))
        let draft = HandwrittenDictationDraft(mode: .handwriting, writingColumns: 5)
        let practice = HandwrittenPractice(sessionID: sessionID, questions: [word, recitation], draft: draft)

        XCTAssertTrue(practice.select(recitation.id))
        XCTAssertFalse(practice.requestSubmission())
        XCTAssertEqual(practice.blankCount, 1)
        XCTAssertTrue(practice.submit())
        XCTAssertFalse(practice.select(word.id))
        let restored = try XCTUnwrap(HandwrittenDictationStore.load(sessionID))
        XCTAssertEqual(restored.entryID, recitation.id)
        XCTAssertEqual(restored.writingColumns, 5)
        XCTAssertEqual(restored.questions, [word, recitation])
    }

    func testSingleRowChineseBoardMatchesEnglishHeightWithoutStretchingTheGrid() {
        for (columns, width) in [(DictationWritingGrid.phoneColumns, 320.0), (DictationWritingGrid.tabletColumns, 720.0)] {
            let chinese = DictationWritingGrid(isEnglish: false, answer: "山", columns: columns)
            let english = DictationWritingGrid(isEnglish: true, answer: "apple", columns: columns)
            let longChinese = DictationWritingGrid(isEnglish: false, answer: "春夏秋冬风雨雪霜", columns: columns)
            XCTAssertEqual(chinese.boardHeight(forWidth: width), english.boardHeight(forWidth: width), accuracy: 0.01)
            XCTAssertEqual(chinese.canvasHeight(forWidth: width), width / CGFloat(columns), accuracy: 0.01)
            XCTAssertGreaterThan(longChinese.boardHeight(forWidth: width), english.boardHeight(forWidth: width))
        }
    }

    @MainActor
    func testInlineCanvasFitsItsViewportAndUsesTheDeviceInputPolicy() async throws {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let columns = isPhone ? DictationWritingGrid.phoneColumns : DictationWritingGrid.tabletColumns
        let width: CGFloat = isPhone ? 320 : 700
        let sessionID = UUID()
        let word = HandwrittenQuestion(ReviewItem(type: .chineseCharacter, content: "山", prompt: ""))
        let practice = HandwrittenPractice(
            sessionID: sessionID, questions: [word],
            draft: .init(mode: .handwriting, writingColumns: columns)
        )
        let host = UIHostingController(rootView: ScrollView {
            HandwrittenAnswerArea(practice: practice, question: word)
        }.frame(width: width, height: 380))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        var canvas: PKCanvasView?
        for _ in 0..<20 {
            host.view.layoutIfNeeded()
            canvas = findCanvas(in: host.view)
            if canvas != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let mountedCanvas = try XCTUnwrap(canvas)
        XCTAssertEqual(mountedCanvas.drawingPolicy, isPhone ? .anyInput : .pencilOnly)
        XCTAssertEqual(mountedCanvas.bounds.width, CGFloat(columns) * DictationWritingGrid.cellSize)
        XCTAssertEqual(mountedCanvas.frame.width, width, accuracy: 1)
    }

    @MainActor
    private func findCanvas(in view: UIView) -> PKCanvasView? {
        if let canvas = view as? PKCanvasView { return canvas }
        for subview in view.subviews {
            if let canvas = findCanvas(in: subview) { return canvas }
        }
        return nil
    }

    @MainActor
    func testLateAutomaticGradeCannotReplaceManualConfirmation() throws {
        let sessionID = UUID()
        let entryID = UUID()
        defer { try? HandwrittenDictationStore.remove(sessionID) }
        var draft = HandwrittenDictationDraft(mode: .handwriting, submittedAt: .now)
        draft.grades[entryID] = .init(result: .pending, transcription: "你好")
        try HandwrittenDictationStore.save(draft, sessionID: sessionID)

        let rechecked = try HandwrittenDictationStore.recordGrade(
            .init(result: .correct, source: .local, transcription: "你好"),
            sessionID: sessionID, entryID: entryID, automatic: true, resolvePendingMatch: true
        )
        XCTAssertEqual(rechecked?.grades[entryID]?.source, .local)

        _ = try HandwrittenDictationStore.recordGrade(
            .init(result: .correct, source: .manual), sessionID: sessionID, entryID: entryID, automatic: false
        )
        _ = try HandwrittenDictationStore.recordGrade(
            .init(result: .wrong, source: .deepSeek), sessionID: sessionID, entryID: entryID, automatic: true
        )
        _ = try HandwrittenDictationStore.recordGrade(
            .init(result: .correct, source: .local), sessionID: sessionID, entryID: entryID,
            automatic: true, resolvePendingMatch: true
        )
        let confirmed = try HandwrittenDictationStore.load(sessionID)?.grades[entryID]
        XCTAssertEqual(confirmed?.source, .manual)
        XCTAssertEqual(confirmed?.result, .correct)
    }

    func testHandwritingDraftAndInkAreRestoredAndDeletedTogether() throws {
        let sessionID = UUID()
        let entryID = UUID()
        defer { try? HandwrittenDictationStore.remove(sessionID) }
        XCTAssertNil(try HandwrittenDictationStore.load(sessionID))

        var draft = HandwrittenDictationDraft(mode: .handwriting, entryID: entryID, submittedAt: .now)
        draft.grades[entryID] = .init(result: .correct, source: .manual)
        let path = PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 10, y: 10), timeOffset: 0, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: 1),
            PKStrokePoint(location: CGPoint(x: 40, y: 40), timeOffset: 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: 1)
        ], creationDate: .now)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])

        try HandwrittenDictationStore.save(draft, sessionID: sessionID)
        try HandwrittenDictationStore.save(drawing, sessionID: sessionID, entryID: entryID)
        let restored = try XCTUnwrap(HandwrittenDictationStore.load(sessionID))
        XCTAssertEqual(restored.entryID, entryID)
        XCTAssertEqual(restored.grades[entryID]?.source, .manual)
        XCTAssertEqual(try HandwrittenDictationStore.drawing(sessionID: sessionID, entryID: entryID).strokes.count, 1)
        try HandwrittenDictationStore.remove(sessionID)
        XCTAssertNil(try HandwrittenDictationStore.load(sessionID))
        XCTAssertTrue(try HandwrittenDictationStore.drawing(sessionID: sessionID, entryID: entryID).strokes.isEmpty)
    }
}


private final class AIRequestStub: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let data = try handler(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
