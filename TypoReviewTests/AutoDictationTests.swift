import XCTest
import UIKit
@testable import TypoReview

@MainActor
final class AutoDictationTests: XCTestCase {
    private final class Playback: DictationPlayback {
        var calls: [(String, (Bool) -> Void)] = []
        func play(content: String, type: ReviewItemType, prompt: String, completion: @escaping (Bool) -> Void) {
            calls.append((content, completion))
        }
        func stop() {}
        func finish(_ index: Int? = nil, success: Bool = true) {
            calls[index ?? calls.count - 1].1(success)
        }
    }

    private func fixture(last: Bool = false) -> (AutoDictationController, Playback, UserDefaults) {
        let playback = Playback()
        let defaults = UserDefaults(suiteName: "AutoDictationTests.\(UUID())")!
        let controller = AutoDictationController(playback: playback, defaults: defaults, runsTimer: false)
        controller.select(content: "apple", type: .englishWord, prompt: "苹果", isLast: last, speak: false)
        addTeardownBlock { @MainActor in
            controller.shutdown()
            defaults.removeObject(forKey: "autoDictation.writingInterval")
        }
        return (controller, playback, defaults)
    }

    private func finishBothReadings(_ controller: AutoDictationController, _ playback: Playback) {
        playback.finish()
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        playback.finish()
    }

    func testTwoCompleteReadingsBeforeThreeSecondCountdownAndSingleAdvance() {
        let (controller, playback, _) = fixture()
        var advances = 0
        controller.onAdvance = { advances += 1 }
        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .speaking(1))
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .speaking(1))
        playback.finish()
        XCTAssertEqual(controller.phase, .repeatGap(2))
        controller.advanceWaitingSecond()
        XCTAssertEqual(playback.calls.count, 1)
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .speaking(2))
        playback.finish()
        XCTAssertEqual(controller.phase, .writing(3))
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        XCTAssertEqual(advances, 0)
        controller.advanceWaitingSecond()
        controller.advanceWaitingSecond()
        XCTAssertEqual(advances, 1)
        controller.select(content: "下一条", type: .phrase, prompt: "", isLast: true)
        XCTAssertEqual(controller.phase, .speaking(1))
        XCTAssertEqual(playback.calls.last?.0, "下一条")
    }

    func testReplayAndRapidSelectionIgnoreOldCompletions() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        controller.replay()
        playback.finish(0)
        XCTAssertEqual(controller.phase, .speaking(1))
        controller.select(content: "新内容", type: .phrase, prompt: "", isLast: false)
        playback.finish(1)
        XCTAssertEqual(controller.phase, .speaking(1))
        playback.finish(2)
        XCTAssertEqual(controller.phase, .repeatGap(2))
        playback.finish(2)
        XCTAssertEqual(controller.phase, .repeatGap(2))
    }

    func testPauseDuringSpeechAndPausedNavigationRemainPaused() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        controller.pause()
        playback.finish(0)
        XCTAssertEqual(controller.phase, .paused)
        controller.select(content: "上一条", type: .phrase, prompt: "", isLast: false)
        playback.finish()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .paused)
        controller.start()
        XCTAssertEqual(controller.phase, .speaking(1))
    }

    func testPauseDuringCountdownRestartsBothReadings() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        finishBothReadings(controller, playback)
        controller.pause()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .paused)
        controller.start()
        XCTAssertEqual(controller.phase, .speaking(1))
    }

    func testIntervalChangesResetWritingTimeAndPersist() {
        let (controller, playback, defaults) = fixture()
        XCTAssertEqual(controller.interval, 3)
        controller.setEnabled(true)
        finishBothReadings(controller, playback)
        controller.advanceWaitingSecond()
        controller.setInterval(8)
        XCTAssertEqual(controller.phase, .writing(8))
        let other = AutoDictationController(playback: Playback(), defaults: defaults, runsTimer: false)
        XCTAssertEqual(other.interval, 8)
        controller.setInterval(30)
        XCTAssertEqual(controller.interval, 8)
    }

    func testLastItemEndsWithoutAdvancingAndRestoresScreenSetting() {
        let (controller, playback, _) = fixture(last: true)
        let original = UIApplication.shared.isIdleTimerDisabled
        var advances = 0
        controller.onAdvance = { advances += 1 }
        controller.setEnabled(true)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        finishBothReadings(controller, playback)
        for _ in 0..<4 { controller.advanceWaitingSecond() }
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(advances, 0)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, original)
    }

    func testFailurePausesAndShutdownInvalidatesCallbacks() {
        let (controller, playback, _) = fixture()
        controller.setEnabled(true)
        playback.finish(success: false)
        XCTAssertEqual(controller.phase, .paused)
        XCTAssertNotNil(controller.errorMessage)
        controller.start()
        XCTAssertNil(controller.errorMessage)
        controller.shutdown()
        playback.finish()
        controller.advanceWaitingSecond()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.isEnabled)
    }

    func testEmptySessionDoesNotStartPlayback() {
        let playback = Playback()
        let controller = AutoDictationController(playback: playback, runsTimer: false)
        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertTrue(playback.calls.isEmpty)
        controller.shutdown()
    }
}
