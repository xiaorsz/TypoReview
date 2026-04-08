import SwiftUI
import WidgetKit
import QuartzCore
import Foundation

#if DEBUG
enum DebugPerf {
    private static let defaultsKey = "DebugPerf.recentEvents.v1"
    private static let maxStoredEvents = 160
    private static let lock = NSLock()
    private static var memoryEntries: [String] = []

    private final class WatchdogState {
        private let lock = NSLock()
        private var didRunMainCallback = false

        func markMainCallbackDidRun() {
            lock.lock()
            didRunMainCallback = true
            lock.unlock()
        }

        func hasMainCallbackRun() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return didRunMainCallback
        }
    }

    static func mark(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        let timestamp = String(format: "%.3f", CACurrentMediaTime())
        let thread = Thread.isMainThread ? "main" : "background"
        let entry = "[DEBUG-PERF] \(timestamp) [\(thread)] \(message) @\(file):\(line)"
        NSLog("%@", entry)
        appendToMemory(entry)
    }

    static func replayPreviousRunTrace() {
        lock.lock()
        let entries = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
        lock.unlock()

        guard !entries.isEmpty else { return }
        NSLog("[DEBUG-PERF] PREVIOUS RUN TRACE BEGIN count=%d", entries.count)
        entries.suffix(80).forEach { entry in
            NSLog("[DEBUG-PERF-PREV] %@", entry)
        }
        NSLog("[DEBUG-PERF] PREVIOUS RUN TRACE END")
    }

    static func recentEvents(limit: Int = 40) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let entries = memoryEntries
        guard limit > 0 else { return entries }
        return Array(entries.suffix(limit))
    }

    static func flushRecentEvents() {
        lock.lock()
        let entries = memoryEntries
        lock.unlock()
        persistSnapshot(entries)
    }

    static func clearRecentEvents() {
        lock.lock()
        defer { lock.unlock() }

        memoryEntries.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
    }

    static func watchMainThread(_ label: String, threshold: TimeInterval = 0.8) {
        let startedAt = CACurrentMediaTime()
        let token = UUID()
        let state = WatchdogState()

        mark("WATCHDOG start \(label) token=\(token.uuidString)")

        DispatchQueue.main.asyncAfter(deadline: .now() + threshold) {
            state.markMainCallbackDidRun()
            let elapsed = CACurrentMediaTime() - startedAt
            mark("WATCHDOG main callback reached \(label) elapsed=\(String(format: "%.3fs", elapsed)) token=\(token.uuidString)")
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + threshold + 0.2) {
            if !state.hasMainCallbackRun() {
                let elapsed = CACurrentMediaTime() - startedAt
                mark("WATCHDOG POSSIBLE MAIN THREAD STALL \(label) elapsed=\(String(format: "%.3fs", elapsed)) token=\(token.uuidString)")
            }
        }
    }

    private static func appendToMemory(_ entry: String) {
        lock.lock()
        defer { lock.unlock() }

        memoryEntries.append(entry)
        if memoryEntries.count > maxStoredEvents {
            memoryEntries.removeFirst(memoryEntries.count - maxStoredEvents)
        }
    }

    private static func persistSnapshot(_ entries: [String]) {
        let trimmedEntries: [String]
        if entries.count > maxStoredEvents {
            trimmedEntries = Array(entries.suffix(maxStoredEvents))
        } else {
            trimmedEntries = entries
        }

        UserDefaults.standard.set(trimmedEntries, forKey: defaultsKey)
        _ = UserDefaults.standard.synchronize()
    }
}
#endif

// MARK: - WidgetCenter Background Reload
// On iOS 17, WidgetCenter.shared.reloadAllTimelines() blocks the main thread
// for 1–3 seconds due to synchronous XPC. Always call via background task.
extension WidgetCenter {
    func reloadAllTimelinesInBackground() {
        Task.detached(priority: .background) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension View {
    @ViewBuilder
    func iOS17SafeSwipeActions<Actions: View>(
        edge: HorizontalEdge = .trailing,
        allowsFullSwipe: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        if #available(iOS 18.0, *) {
            swipeActions(edge: edge, allowsFullSwipe: allowsFullSwipe, content: actions)
        } else {
            self
        }
    }
}

// MARK: - Result Button Style

struct ResultButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding()
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GradingChoiceButtonStyle: ButtonStyle {
    let color: Color
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? color : color.opacity(0.12))
            )
            .foregroundStyle(isSelected ? .white : color)
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Stat Grid Card

struct StatGridCard: View {
    let icon: String
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            ZStack {
                Color(uiColor: .secondarySystemGroupedBackground)
                tint.opacity(0.1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.06), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Toast Overlay Modifier

struct ToastOverlay: ViewModifier {
    let message: String
    @Binding var isPresented: Bool
    var duration: Double = 1.2

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(message)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.ultraThickMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 40)
                    }
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isPresented)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                            withAnimation {
                                isPresented = false
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    func toast(_ message: String, isPresented: Binding<Bool>, duration: Double = 1.2) -> some View {
        modifier(ToastOverlay(message: message, isPresented: isPresented, duration: duration))
    }
}

// MARK: - Placeholder Text Editor

struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 220

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(uiColor: .secondarySystemBackground))

            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity)
                .frame(minHeight: minHeight)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)

            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Feedback Answer Overlay

struct AnswerFeedbackOverlay: View {
    let isCorrect: Bool
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            ZStack {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    Image(systemName: isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(isCorrect ? .green : .red)
                        .symbolEffect(.bounce, value: isVisible)

                    Text(isCorrect ? "答对了！" : "再加油！")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(isCorrect ? .green : .red)
                }
                .transition(.scale.combined(with: .opacity))
            }
            .onAppear {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(isCorrect ? .success : .error)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isVisible = false
                    }
                }
            }
        }
    }
}

// MARK: - Type Badge

struct TypeBadge: View {
    let type: ReviewItemType

    private var badgeColor: Color {
        switch type {
        case .chineseCharacter: return .orange
        case .phrase: return .blue
        case .englishWord: return .purple
        }
    }

    var body: some View {
        Text(type.displayName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor, in: Capsule())
    }
}

// MARK: - Stage Color Helper

extension Int {
    var stageColor: Color {
        switch self {
        case 0...2: return .red
        case 3...5: return .orange
        default: return .green
        }
    }
}

enum ReviewItemTypeInference {
    static func infer(from text: String) -> ReviewItemType? {
        let sample = text
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let content = line
                    .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return content.isEmpty ? nil : content
            }
            .first

        guard let sample else { return nil }

        if sample.containsChineseCharacters {
            return .phrase
        }

        if sample.isLikelyEnglishContent {
            return .englishWord
        }

        return nil
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    var isLikelyEnglishContent: Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.containsChineseCharacters else { return false }

        let allowedPunctuation = CharacterSet(charactersIn: " -'")
        let allowedScalars = CharacterSet.decimalDigits
            .union(.letters)
            .union(allowedPunctuation)

        guard trimmed.unicodeScalars.allSatisfy({ allowedScalars.contains($0) && $0.isASCII }) else {
            return false
        }

        return trimmed.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar) && scalar.isASCII
        }
    }
}

import AVFoundation

@MainActor
final class DictationSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastUtteranceText = ""
    private var lastType: ReviewItemType = .chineseCharacter

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(content: String, type: ReviewItemType) {
        lastUtteranceText = content
        lastType = type
        stop()
    }

    func speak(content: String, type: ReviewItemType) {
        lastUtteranceText = content
        lastType = type
        speakCurrentText()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        SpeechAudioSession.deactivate()
        isSpeaking = false
    }

    private func speakCurrentText() {
        stop()
        SpeechAudioSession.activate()
        let utterance = AVSpeechUtterance(string: lastUtteranceText)
        utterance.voice = SpeechVoicePicker.voice(for: lastType)
        utterance.rate = lastType == .englishWord ? 0.42 : 0.36
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }
}

extension DictationSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
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
}
