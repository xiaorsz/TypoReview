import SwiftUI
import AVFoundation
import SwiftData

struct DictationSessionView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @StateObject private var speaker = DictationSpeaker()

    let session: DictationSession
    let entries: [DictationEntry]

    private var currentEntry: DictationEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    var body: some View {
        Group {
            if let currentEntry {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                    VStack(spacing: 24) {
                        Text("第 \(currentIndex + 1) / \(entries.count) 条")
                            .font(.headline)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 16) {
                            Text(session.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Text(promptText(for: currentEntry))
                                .font(.system(isWide ? .largeTitle : .title2, design: .rounded, weight: .bold))

                            Button {
                                speaker.speak(content: currentEntry.content, type: currentEntry.type)
                            } label: {
                                Label(speaker.isSpeaking ? "正在朗读" : "点击朗读", systemImage: "speaker.wave.2.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .font(.headline)

                            Text("孩子先把整轮内容都写完，最后再统一批量判定。")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(isWide ? 32 : 24)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))

                        HStack(spacing: 12) {
                            Button("上一条") {
                                currentIndex = max(currentIndex - 1, 0)
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentIndex == 0)

                            if currentIndex < entries.count - 1 {
                                Button("下一条") {
                                    currentIndex += 1
                                }
                                .buttonStyle(ResultButtonStyle(color: .blue))
                            } else {
                                Button("进入统一判定") {
                                    finishSession()
                                }
                                .buttonStyle(ResultButtonStyle(color: .green))
                            }
                        }

                        Spacer()
                    }
                    .padding(isWide ? 32 : 20)
                }
            }
        }
        .navigationTitle("今日听写")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            DictationReviewView(session: session, entries: entries)
        }
        .onAppear {
            if let currentEntry {
                speaker.prepare(content: currentEntry.content, type: currentEntry.type)
            }
        }
        .onChange(of: currentIndex) {
            if let currentEntry {
                speaker.prepare(content: currentEntry.content, type: currentEntry.type)
            }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private func promptText(for entry: DictationEntry) -> String {
        let prompt = entry.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            return prompt
        }

        switch entry.type {
        case .chineseCharacter:
            return "点击朗读，听写这个汉字"
        case .phrase:
            return "点击朗读，听写这个词语"
        case .englishWord:
            return "点击朗读，听写这个单词"
        }
    }

    private func finishSession() {
        let now = Date()
        session.finishedAt = now
        session.updatedAt = now
        navigateToReview = true
    }
}

@MainActor
private final class DictationSpeaker: NSObject, ObservableObject {
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
        utterance.voice = preferredVoice(for: lastType)
        utterance.rate = lastType == .englishWord ? 0.42 : 0.36
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }

    private func preferredVoice(for type: ReviewItemType) -> AVSpeechSynthesisVoice? {
        switch type {
        case .englishWord:
            return AVSpeechSynthesisVoice(language: "en-US")
        case .chineseCharacter, .phrase:
            let voices = AVSpeechSynthesisVoice.speechVoices()
            let preferredLanguages = ["zh-CN", "zh-Hans-CN", "zh-Hans", "zh-CN_#Hans"]

            for language in preferredLanguages {
                if let voice = bestVoice(in: voices, matching: language) {
                    return voice
                }
            }

            return AVSpeechSynthesisVoice(language: "zh-CN")
        }
    }

    private func bestVoice(in voices: [AVSpeechSynthesisVoice], matching language: String) -> AVSpeechSynthesisVoice? {
        voices
            .filter { $0.language == language }
            .sorted { lhs, rhs in
                voiceRank(lhs) > voiceRank(rhs)
            }
            .first
    }

    private func voiceRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium:
            return 3
        case .enhanced:
            return 2
        default:
            return 1
        }
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
