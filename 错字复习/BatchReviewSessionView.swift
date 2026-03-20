import SwiftUI
import AVFoundation

struct BatchReviewSessionView: View {
    @State private var currentIndex = 0
    @State private var navigateToReview = false
    @StateObject private var speaker = BatchReviewSpeaker()

    let items: [ReviewItem]

    private var currentItem: ReviewItem? {
        guard items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    private var progress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(currentIndex) / Double(items.count)
    }

    var body: some View {
        Group {
            if let item = currentItem {
                GeometryReader { proxy in
                    let isWide = proxy.size.width >= 700

                    VStack(spacing: 24) {
                        // Progress bar
                        VStack(spacing: 8) {
                            ProgressView(value: progress)
                                .tint(.accentColor)
                                .animation(.easeInOut(duration: 0.3), value: progress)

                            Text("第 \(currentIndex + 1) / \(items.count) 题")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

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
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .font(.headline)

                            Text(helperText(for: item))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(isWide ? 32 : 24)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28))

                        HStack(spacing: 12) {
                            Button("上一条") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    currentIndex = max(currentIndex - 1, 0)
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentIndex == 0)

                            if currentIndex < items.count - 1 {
                                Button("下一条") {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        currentIndex += 1
                                    }
                                }
                                .buttonStyle(ResultButtonStyle(color: .blue))
                            } else {
                                Button("进入统一判定") {
                                    navigateToReview = true
                                }
                                .buttonStyle(ResultButtonStyle(color: .green))
                            }
                        }

                        Spacer()
                    }
                    .padding(isWide ? 32 : 20)
                }
                .id(currentIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
        .navigationTitle("统一判卷")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToReview) {
            BatchReviewGradingView(items: items)
        }
        .onAppear {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onChange(of: currentIndex) {
            if let currentItem {
                speaker.prepare(currentItem)
            }
        }
        .onDisappear {
            speaker.stop()
        }
    }

    private func headlineText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch item.type {
            case .chineseCharacter:
                return "点击朗读，听写这个汉字"
            case .phrase:
                return "点击朗读，听写这个词语"
            case .englishWord:
                return "点击朗读，听写这个单词"
            }
        }
        return item.prompt
    }

    private func helperText(for item: ReviewItem) -> String {
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "会直接播放要写的内容，孩子整轮写完后，家长再统一判定。"
        }
        return "如果不看文字，也可以直接点击朗读来做听写。"
    }
}

// MARK: - Speech
@MainActor
private final class BatchReviewSpeaker: NSObject, ObservableObject {
    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var lastUtteranceText = ""
    private var lastType: ReviewItemType = .chineseCharacter

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepare(_ item: ReviewItem) {
        lastUtteranceText = item.content
        lastType = item.type
        stop()
    }

    func speak(_ item: ReviewItem) {
        lastUtteranceText = item.content
        lastType = item.type
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
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }
}

extension BatchReviewSpeaker: @preconcurrency AVSpeechSynthesizerDelegate {
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
